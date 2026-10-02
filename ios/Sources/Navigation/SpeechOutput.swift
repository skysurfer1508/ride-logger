import AVFoundation
import Foundation

/// Speaks guidance through whatever the phone is sending sound to: your Bluetooth intercom when it is connected. Music is turned down while it talks and comes back after.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechOutput()

    /// Where the last phrase went, in words (for Settings > Voice guidance).
    @Published private(set) var lastRoute = ""
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isEnabled: Bool { VoiceSettings.isEnabled() }

    /// The best English voice installed (the "enhanced" and "premium" ones sound far better; they are downloaded in iPhone Settings > Accessibility > Spoken Content).
    private static var voice: AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return english.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Says it, unless the voice is switched off (`force` for the test button).
    func say(_ text: String, force: Bool = false) {
        guard force || isEnabled, !text.isEmpty else { return }
        configureSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = Float(VoiceSettings.rate())
        utterance.volume = 1
        utterance.preUtteranceDelay = 0.05
        synthesizer.speak(utterance)
        lastRoute = currentRoute()
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        release()
    }

    /// Says the sample sentence and reports where it went.
    func test() {
        say(VoiceSettings.testSentence, force: true)
    }

    func outputs() -> [(name: String, type: String)] {
        session.currentRoute.outputs.map { (name: $0.portName, type: $0.portType.rawValue) }
    }

    func currentRoute() -> String { VoiceSettings.routeDescription(outputs()) }

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
            if !self.synthesizer.isSpeaking { self.release() }
        }
    }
}
