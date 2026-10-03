import Foundation

/// The voice's settings and the way its audio route is described, free of AVFoundation so it can be unit-tested (Tests/VoiceSettingsTests.swift).
enum VoiceSettings {
    static let enabledKey = "voice.enabled"
    static let rateKey = "voice.rate"
    /// "Intercom compatibility": for a headset that only takes the call profile (lower quality, but it works).
    static let compatibilityKey = "voice.compat"

    static let engineKey = "voice.engine"
    static let identifierKey = "voice.identifier"
    static let streetsKey = "voice.streets"
    static let curvesKey = "voice.curves"
    static let limitsKey = "voice.limits"
    static let hapticsKey = "voice.haptics"
    static let rerouteKey = "nav.reroute"
    static let boostKey = "voice.boost"

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

    // MARK: loudness

    /// How much louder than the system's own level the voice is made, in dB (0 = not at all: the voice is played the ordinary way). A player cannot go past full volume, so a boost
    /// goes through an amplifier with a peak limiter in front of the output (see LoudSpeaker). Every 10 dB sounds about twice as loud; 12 dB is about what it takes to be heard
    /// in a helmet at speed.
    static let boostRange: ClosedRange<Double> = 0...18
    static let boostStep = 3.0

    static func clampedBoost(_ value: Double) -> Double {
        let stepped = (min(max(value, boostRange.lowerBound), boostRange.upperBound) / boostStep).rounded() * boostStep
        return min(max(stepped, boostRange.lowerBound), boostRange.upperBound)
    }

    static func boostDb(in defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: boostKey) == nil ? 0 : clampedBoost(defaults.double(forKey: boostKey))
    }

    /// "Normal" or "+9 dB, louder".
    static func boostLabel(_ db: Double) -> String {
        let value = clampedBoost(db)
        if value <= 0 { return "Normal" }
        return "+\(Int(value)) dB" + (value >= 15 ? ", loudest" : value >= 9 ? ", much louder" : ", louder")
    }

    // MARK: the new settings

    static func engine(in defaults: UserDefaults = .standard) -> VoiceEngine {
        VoiceEngine(rawValue: defaults.string(forKey: engineKey) ?? "") ?? .natural
    }

    static func streetNames(in defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: streetsKey) as? Bool ?? true }
    static func curveWarnings(in defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: curvesKey) as? Bool ?? true }
    static func watchHaptics(in defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: hapticsKey) as? Bool ?? true }

    static func limitCallouts(in defaults: UserDefaults = .standard) -> LimitCallouts {
        LimitCallouts(rawValue: defaults.string(forKey: limitsKey) ?? "") ?? .changes
    }

    static func rerouteChoice(in defaults: UserDefaults = .standard) -> RerouteChoice {
        RerouteChoice(rawValue: defaults.string(forKey: rerouteKey) ?? "") ?? .rejoin
    }

    /// Everything the guidance engine is told about how to speak.
    static func guidanceOptions(in defaults: UserDefaults = .standard) -> GuidanceOptions {
        var options = GuidanceOptions()
        options.streetNames = streetNames(in: defaults)
        options.curveWarnings = curveWarnings(in: defaults)
        options.limitCallouts = limitCallouts(in: defaults)
        options.offRouteLine = rerouteChoice(in: defaults).offRouteLine
        return options
    }

    // MARK: choosing a phone voice

    /// An installed system voice, described without AVFoundation.
    struct VoiceInfo: Equatable {
        let identifier: String
        let name: String
        let language: String
        /// 1 default, 2 enhanced, 3 premium.
        let quality: Int
    }

    private static let englishOrder = ["en-GB", "en-US", "en-AU", "en-IE", "en-ZA", "en-IN"]
    private static let germanOrder = ["de-CH", "de-DE", "de-AT"]

    /// The voice to use for English: the one picked in Settings when it is still installed, otherwise the best quality, then the language order above.
    static func pickEnglish(from voices: [VoiceInfo], identifier: String) -> VoiceInfo? {
        let english = voices.filter { $0.language.hasPrefix("en") }
        if !identifier.isEmpty, let chosen = english.first(where: { $0.identifier == identifier }) { return chosen }
        return best(of: english, order: englishOrder)
    }

    /// The voice for street names: a Swiss German voice if there is one, then German, then Austrian; nil without any (the street is then read by the English voice).
    static func pickGerman(from voices: [VoiceInfo]) -> VoiceInfo? {
        best(of: voices.filter { $0.language.hasPrefix("de") }, order: germanOrder)
    }

    private static func best(of voices: [VoiceInfo], order: [String]) -> VoiceInfo? {
        func rank(_ language: String) -> Int { order.firstIndex(of: language) ?? order.count }
        return voices.min { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            if rank(a.language) != rank(b.language) { return rank(a.language) < rank(b.language) }
            return a.name < b.name
        }
    }

    /// "Daniel (en-GB, enhanced)" for the picker.
    static func label(_ voice: VoiceInfo) -> String {
        let quality = voice.quality >= 3 ? "premium" : voice.quality == 2 ? "enhanced" : "standard"
        return "\(voice.name) (\(voice.language), \(quality))"
    }
}

/// Where the voice comes from: the server's natural voice when its clips are on the phone, otherwise (or when chosen) the phone's own.
enum VoiceEngine: String {
    case natural, phone
}

/// When the speed limit is called out.
enum LimitCallouts: String {
    case off
    /// Only when the rider is over the limit of the road they have just entered.
    case whenOver
    /// Whenever the limit changes.
    case changes
}

/// What to do when the rider leaves the route.
enum RerouteChoice: String {
    /// Plan a way back onto the route and carry on along it.
    case rejoin
    /// Plan a new route from here to the destination.
    case destination
    /// Offer both on the screen (the default is taken after a few seconds).
    case ask

    var offRouteLine: String {
        switch self {
        case .rejoin: return GuidanceLines.offRouteBack
        case .destination: return GuidanceLines.offRoute
        case .ask: return GuidanceLines.offRouteAsk
        }
    }
}

/// How the guidance engine speaks (see GuidanceEngine).
struct GuidanceOptions: Equatable {
    var streetNames = true
    var curveWarnings = true
    var limitCallouts: LimitCallouts = .changes
    /// What is said when the rider has been off the route for a few seconds.
    var offRouteLine = GuidanceLines.offRoute
}
