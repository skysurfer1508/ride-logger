import Foundation

/// The voice's settings and the way its audio route is described, free of AVFoundation so it can be unit-tested (Tests/VoiceSettingsTests.swift).
enum VoiceSettings {
    static let enabledKey = "voice.enabled"
    static let rateKey = "voice.rate"
    /// "Intercom compatibility": for a headset that only takes the call profile (lower quality, but it works).
    static let compatibilityKey = "voice.compat"

    /// AVSpeechUtteranceDefaultSpeechRate.
    static let defaultRate = 0.5
    static let rateRange: ClosedRange<Double> = 0.38...0.62
    static let testSentence = "In 300 meters, turn left onto Hardstrasse."

    static func clampedRate(_ value: Double) -> Double { min(max(value, rateRange.lowerBound), rateRange.upperBound) }

    static func rate(from defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: rateKey) == nil ? defaultRate : clampedRate(defaults.double(forKey: rateKey))
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// What kind of output an iOS audio port is, in words (the port's raw type string).
    static func portKind(_ raw: String) -> String {
        switch raw {
        case "BluetoothA2DPOutput": return "Bluetooth, music quality"
        case "BluetoothHFPOutput", "BluetoothHFP": return "Bluetooth, call quality"
        case "BluetoothLE": return "Bluetooth LE"
        case "Speaker": return "the phone's speaker"
        case "Receiver": return "the phone's earpiece"
        case "Headphones": return "wired headphones"
        case "AirPlay": return "AirPlay"
        case "CarAudio": return "car audio"
        case "USBAudio": return "USB audio"
        default: return raw.isEmpty ? "unknown output" : raw
        }
    }

    /// "Sena 50S (Bluetooth, call quality)", or "the phone's speaker" with a hint when nothing like a headset is connected.
    static func routeDescription(_ outputs: [(name: String, type: String)]) -> String {
        guard !outputs.isEmpty else { return "No audio output" }
        return outputs.map { output in
            let kind = portKind(output.type)
            return output.name.isEmpty || output.name == kind ? kind : "\(output.name) (\(kind))"
        }.joined(separator: ", ")
    }

    /// True when the voice is going to the phone's own speaker or earpiece: probably not what a rider with an intercom wants.
    static func isPhoneSpeaker(_ outputs: [(name: String, type: String)]) -> Bool {
        !outputs.isEmpty && outputs.allSatisfy { $0.type == "Speaker" || $0.type == "Receiver" }
    }
}
