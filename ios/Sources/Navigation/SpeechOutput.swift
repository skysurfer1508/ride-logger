import AVFoundation
import Foundation

/// Speaks guidance through whatever the phone is sending sound to: your Bluetooth intercom when it is connected. Music is turned down while it talks and comes back after.
/// Two voices: the natural one (clips rendered by the server, see VoiceClips) when every piece of a phrase has a clip, otherwise the phone's own voice, so that nothing is
/// ever left unsaid and the two are never mixed inside one phrase.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechOutput()

    /// Where the last phrase went, in words (for Settings > Voice guidance).
    @Published private(set) var lastRoute = ""
    /// Which voice said the last phrase: "natural voice" or "phone voice".
    @Published private(set) var lastVoice = ""
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()
    private var players: [AVAudioPlayer] = []
    private var clipQueueEnd: TimeInterval = 0
    /// For a boosted voice (Settings > Voice guidance > Loudness): the amplifier, and a second synthesizer that only renders the phone's voice into audio for it.
    private let loud = LoudSpeaker()
    private let writer = AVSpeechSynthesizer()
    private var waiting: [(phrase: Phrase, db: Double)] = []
    private var rendering = false
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
        loud.onIdle = { [weak self] in self?.releaseIfIdle() }
    }

    var isEnabled: Bool { VoiceSettings.isEnabled() }

    /// The voices installed on the phone, as the picker and the choice logic see them.
    static func installedVoices() -> [VoiceSettings.VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { VoiceSettings.VoiceInfo(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
    }

    /// The English voice: the one picked in Settings, else the best installed ("enhanced" and "premium" sound far better; they are downloaded in iPhone Settings > Accessibility >
    /// Spoken Content).
    private static var voice: AVSpeechSynthesisVoice? {
        let picked = UserDefaults.standard.string(forKey: VoiceSettings.identifierKey) ?? ""
        let chosen = VoiceSettings.pickEnglish(from: installedVoices(), identifier: picked)
        return chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// The voice for street names; nil when no German voice is installed.
    private static var germanVoice: AVSpeechSynthesisVoice? {
        VoiceSettings.pickGerman(from: installedVoices()).flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
    }

    /// Says a sentence, unless the voice is switched off (`force` for the test button).
    func say(_ text: String, force: Bool = false) {
        say(Phrase(text), force: force)
    }

    /// Says a phrase: with the natural voice if all of it is on the phone, else with the phone's own.
    func say(_ phrase: Phrase, force: Bool = false) {
        guard force || isEnabled, !phrase.parts.isEmpty else { return }
        configureSession()
        let boost = VoiceSettings.boostDb()
        if boost > 0 {
            sayBoosted(phrase, db: boost)
            lastRoute = currentRoute()
            return
        }
        if VoiceSettings.engine() == .natural, let files = VoiceClips.shared.files(for: phrase), playClips(files, parts: phrase.parts) {
            lastVoice = "natural voice"
        } else {
            speakWithPhoneVoice(phrase)
            lastVoice = "phone voice"
        }
        lastRoute = currentRoute()
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        players.forEach { $0.stop() }
        players = []
        clipQueueEnd = 0
        generation += 1
        waiting = []
        rendering = false
        loud.stop()
        release()
    }

    /// Says the sample sentence and reports where it went.
    func test() {
        say(Self.testPhrase(), force: true)
    }

    /// "In 300 meters, turn left onto Hardstrasse." as pieces: the same shape as a real instruction, with a Swiss street name to hear how it is said.
    static func testPhrase() -> Phrase {
        PhraseBook.spoken("turn left onto Hardstrasse.", street: "Hardstrasse", speedMps: 10, streetNames: VoiceSettings.streetNames(), distance: "300 meters")
    }

    func outputs() -> [(name: String, type: String)] {
        session.currentRoute.outputs.map { (name: $0.portName, type: $0.portType.rawValue) }
    }

    func currentRoute() -> String { VoiceSettings.routeDescription(outputs()) }

    // MARK: the natural voice

    /// Plays the clips one after the other with the pauses of PhraseBook, after any phrase that is still playing. False (nothing is left playing) when a clip cannot be played.
    private func playClips(_ files: [URL], parts: [SpokenPart]) -> Bool {
        var fresh: [AVAudioPlayer] = []
        for file in files {
            guard let player = try? AVAudioPlayer(contentsOf: file) else { return false }
            player.delegate = self
            player.prepareToPlay()
            fresh.append(player)
        }
        guard let first = fresh.first else { return false }
        var at = max(first.deviceCurrentTime + 0.05, clipQueueEnd + 0.3)
        for (i, player) in fresh.enumerated() {
            if i > 0 { at += PhraseBook.pause(after: parts[i - 1], before: parts[i]) }
            guard player.play(atTime: at) else {
                fresh.forEach { $0.stop() }
                return false
            }
            at += player.duration
        }
        clipQueueEnd = at
        players.append(contentsOf: fresh)
        return true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.players.removeAll { $0 === player }
            if self.players.isEmpty {
                self.clipQueueEnd = 0
                self.releaseIfIdle()
            }
        }
    }

    // MARK: the phone's own voice

    private func makeUtterance(_ part: SpokenPart, english: AVSpeechSynthesisVoice?, german: AVSpeechSynthesisVoice?) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: part.text)
        utterance.voice = part.kind == .street ? (german ?? english) : english
        utterance.rate = Float(VoiceSettings.rate())
        utterance.volume = 1
        return utterance
    }

    private func speakWithPhoneVoice(_ phrase: Phrase) {
        let english = Self.voice
        let german = Self.germanVoice
        for (i, part) in phrase.parts.enumerated() {
            let utterance = makeUtterance(part, english: english, german: german)
            utterance.preUtteranceDelay = i == 0 ? 0.05 : PhraseBook.pause(after: phrase.parts[i - 1], before: part)
            synthesizer.speak(utterance)
        }
    }

    // MARK: louder than a player can go

    /// Says a phrase `db` louder: the natural voice's clips if all of them are on the phone, otherwise the phone's own voice rendered into audio first. Whatever goes wrong, the phrase
    /// is still said the ordinary way.
    private func sayBoosted(_ phrase: Phrase, db: Double) {
        if VoiceSettings.engine() == .natural, let files = VoiceClips.shared.files(for: phrase), let pieces = clipPieces(files, parts: phrase.parts), loud.play(pieces, gainDb: Float(db)) {
            lastVoice = "natural voice, \(VoiceSettings.boostLabel(db))"
            return
        }
        waiting.append((phrase, db))
        renderNext()
    }

    /// The clips as pieces of audio with the pauses between them; nil when one cannot be read.
    private func clipPieces(_ files: [URL], parts: [SpokenPart]) -> [AVAudioPCMBuffer]? {
        var pieces: [AVAudioPCMBuffer] = []
        for (i, file) in files.enumerated() {
            if i > 0, let gap = LoudSpeaker.silence(PhraseBook.pause(after: parts[i - 1], before: parts[i])) { pieces.append(gap) }
            guard let piece = LoudSpeaker.piece(from: file) else { return nil }
            pieces.append(piece)
        }
        return pieces
    }

    /// One phrase at a time is rendered, so that they are said in the order they came.
    private func renderNext() {
        guard !rendering, !waiting.isEmpty else { return }
        rendering = true
        let item = waiting.removeFirst()
        let mine = generation
        renderPhrase(item.phrase) { [weak self] pieces in
            guard let self, mine == self.generation else { return }
            self.rendering = false
            if let pieces, self.loud.play(pieces, gainDb: Float(item.db)) {
                self.lastVoice = "phone voice, \(VoiceSettings.boostLabel(item.db))"
            } else {
                self.speakWithPhoneVoice(item.phrase)
                self.lastVoice = "phone voice"
            }
            self.renderNext()
        }
    }

    /// The phone's voice saying the phrase, as pieces of audio (nil when it would not render within a few seconds).
    private func renderPhrase(_ phrase: Phrase, done: @escaping @MainActor ([AVAudioPCMBuffer]?) -> Void) {
        let english = Self.voice
        let german = Self.germanVoice
        var pieces: [AVAudioPCMBuffer] = []

        func next(_ index: Int) {
            guard index < phrase.parts.count else {
                done(pieces.isEmpty ? nil : pieces)
                return
            }
            let utterance = makeUtterance(phrase.parts[index], english: english, german: german)
            let rendered = RenderedSpeech()

            func finish() {
                guard rendered.finish() else { return }
                let chunks = rendered.all.compactMap { LoudSpeaker.converted($0) }
                guard !chunks.isEmpty else {
                    done(nil)
                    return
                }
                if index > 0, let gap = LoudSpeaker.silence(PhraseBook.pause(after: phrase.parts[index - 1], before: phrase.parts[index])) { pieces.append(gap) }
                pieces.append(contentsOf: chunks)
                next(index + 1)
            }

            writer.write(utterance) { buffer in
                guard let chunk = buffer as? AVAudioPCMBuffer else { return }
                if chunk.frameLength == 0 {
                    Task { @MainActor in finish() }
                } else {
                    rendered.add(chunk)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)                    // never wait for ever for a voice that does not render
                finish()
            }
        }
        next(0)
    }

    private func releaseIfIdle() {
        if !synthesizer.isSpeaking && players.isEmpty && !loud.isBusy { release() }
    }

    // MARK: the audio session

    private func configureSession() {
        let compatibility = UserDefaults.standard.bool(forKey: VoiceSettings.compatibilityKey)
        do {
            if compatibility {
                // call profile: works with headsets that do not offer music quality, at lower quality
                try session.setCategory(.playAndRecord, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            }
            try session.setActive(true)
        } catch {
            // without a session the phrase is still spoken, on whatever the system picks
        }
    }

    private func release() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)           // music comes back up
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.releaseIfIdle()
        }
    }
}
