import AVFoundation
import AudioToolbox
import Foundation

/// Plays speech louder than a player can on its own. `AVAudioPlayer` and `AVSpeechSynthesizer` stop at full volume, which is quiet next to music; this runs the voice through an
/// amplifier (a gain of up to +18 dB) followed by a peak limiter, so it gets louder without turning into crackle. It plays pieces of audio (the natural voice's clips, or what the
/// phone's own voice rendered) in order, one after another, with silences between them.
@MainActor
final class LoudSpeaker {
    /// Everything is converted to this before it is played, so that a clip, an English voice and a German voice can follow each other on one player.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let amplifier = AVAudioUnitEQ(numberOfBands: 1)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var built = false
    private var pending = 0
    /// Bumped by stop(): the completion callbacks of buffers that were cancelled must not be counted against whatever is played next.
    private var generation = 0

    /// Called when everything handed over has been played.
    var onIdle: (@MainActor () -> Void)?

    var isBusy: Bool { pending > 0 }

    private func build() {
        guard !built else { return }
        engine.attach(player)
        engine.attach(amplifier)
        engine.attach(limiter)
        engine.connect(player, to: amplifier, format: Self.format)
        engine.connect(amplifier, to: limiter, format: Self.format)
        engine.connect(limiter, to: engine.mainMixerNode, format: Self.format)
        built = true
    }

    /// Plays the pieces after whatever is still playing, `gainDb` louder. False (nothing was started) when the audio engine cannot start: the caller then says it the ordinary way.
    func play(_ pieces: [AVAudioPCMBuffer], gainDb: Float) -> Bool {
        guard !pieces.isEmpty else { return false }
        build()
        amplifier.globalGain = min(max(gainDb, 0), 24)
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        let mine = generation
        for piece in pieces {
            pending += 1
            player.scheduleBuffer(piece, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    if let self, self.generation == mine { self.pieceFinished() }
                }
            }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    func stop() {
        generation += 1
        player.stop()
        pending = 0
        if engine.isRunning { engine.stop() }
    }

    private func pieceFinished() {
        pending = max(0, pending - 1)
        if pending == 0 {
            player.stop()
            engine.stop()                                                           // not running while nothing is said: no battery spent
            onIdle?()
        }
    }

    // MARK: making pieces

    /// A clip file as one piece, in the common format. nil when it cannot be read.
    static func piece(from file: URL) -> AVAudioPCMBuffer? {
        guard let audio = try? AVAudioFile(forReading: file), audio.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { return nil }
        do { try audio.read(into: buffer) } catch { return nil }
        return converted(buffer)
    }

    /// `seconds` of silence in the common format.
    static func silence(_ seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(1, seconds * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { channel[i] = 0 }
        return buffer
    }

    /// The buffer in the common format (the same buffer when it already is). nil when it cannot be converted.
    static func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .endOfStream
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

/// Collects the audio the phone's own voice renders (`AVSpeechSynthesizer.write` calls back from a background thread, once per chunk, and with an empty chunk at the end).
final class RenderedSpeech: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []
    private var done = false

    func add(_ chunk: AVAudioPCMBuffer) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    /// True the first time it is called (the end of the speech, or the time-out, whichever comes first).
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    var all: [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}
