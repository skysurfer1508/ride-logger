import XCTest

/// The voice's settings and the words for where it is going (Sources/Core/VoiceSettings.swift).
final class VoiceSettingsTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "ridelog.test.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    func testTheVoiceIsOnAndAtNormalSpeedUntilSomeoneChangesIt() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        XCTAssertTrue(VoiceSettings.isEnabled(in: d))
        XCTAssertEqual(VoiceSettings.rate(from: d), 0.5)
        d.set(false, forKey: VoiceSettings.enabledKey)
        d.set(0.55, forKey: VoiceSettings.rateKey)
        XCTAssertFalse(VoiceSettings.isEnabled(in: d))
        XCTAssertEqual(VoiceSettings.rate(from: d), 0.55)
    }

    func testTheSpeedStaysWithinWhatIsUnderstandable() {
        XCTAssertEqual(VoiceSettings.clampedRate(0.1), 0.38)
        XCTAssertEqual(VoiceSettings.clampedRate(0.9), 0.62)
        XCTAssertEqual(VoiceSettings.clampedRate(0.5), 0.5)
        XCTAssertTrue(VoiceSettings.rateRange.contains(VoiceSettings.defaultRate))
    }

    func testAnOutOfRangeSavedSpeedIsBroughtBack() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        d.set(5.0, forKey: VoiceSettings.rateKey)
        XCTAssertEqual(VoiceSettings.rate(from: d), 0.62)
    }

    func testPortsAreNamedInWords() {
        XCTAssertEqual(VoiceSettings.portKind("BluetoothA2DPOutput"), "Bluetooth, music quality")
        XCTAssertEqual(VoiceSettings.portKind("BluetoothHFPOutput"), "Bluetooth, call quality")
        XCTAssertEqual(VoiceSettings.portKind("Speaker"), "the phone's speaker")
        XCTAssertEqual(VoiceSettings.portKind("Headphones"), "wired headphones")
        XCTAssertEqual(VoiceSettings.portKind("Something New"), "Something New")
        XCTAssertEqual(VoiceSettings.portKind(""), "unknown output")
    }

    func testTheRouteReadsLikeASentence() {
        XCTAssertEqual(VoiceSettings.routeDescription([(name: "Sena 50S", type: "BluetoothHFPOutput")]), "Sena 50S (Bluetooth, call quality)")
        XCTAssertEqual(VoiceSettings.routeDescription([(name: "Speaker", type: "Speaker")]), "the phone's speaker")
        XCTAssertEqual(VoiceSettings.routeDescription([(name: "Cardo", type: "BluetoothA2DPOutput"), (name: "Speaker", type: "Speaker")]),
                       "Cardo (Bluetooth, music quality), Speaker (the phone's speaker)")
        XCTAssertEqual(VoiceSettings.routeDescription([]), "No audio output")
    }

    func testOnlyThePhonesOwnSpeakerIsFlaggedAsNotTheIntercom() {
        XCTAssertTrue(VoiceSettings.isPhoneSpeaker([(name: "Speaker", type: "Speaker")]))
        XCTAssertTrue(VoiceSettings.isPhoneSpeaker([(name: "Receiver", type: "Receiver")]))
        XCTAssertFalse(VoiceSettings.isPhoneSpeaker([(name: "Sena", type: "BluetoothHFPOutput")]))
        XCTAssertFalse(VoiceSettings.isPhoneSpeaker([(name: "Sena", type: "BluetoothHFPOutput"), (name: "Speaker", type: "Speaker")]))
        XCTAssertFalse(VoiceSettings.isPhoneSpeaker([]))
    }
}
