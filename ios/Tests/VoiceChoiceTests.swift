import XCTest

/// The newer voice and navigation settings, and the choice of a phone voice (Sources/Core/VoiceSettings.swift).
final class VoiceChoiceTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "ridelog.test.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    private func voice(_ id: String, _ language: String, _ quality: Int, name: String? = nil) -> VoiceSettings.VoiceInfo {
        VoiceSettings.VoiceInfo(identifier: id, name: name ?? id, language: language, quality: quality)
    }

    func testTheDefaultsAreTheNaturalVoiceWithStreetsCornersLimitsAndAWayBack() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        XCTAssertEqual(VoiceSettings.engine(in: d), .natural)
        XCTAssertTrue(VoiceSettings.streetNames(in: d))
        XCTAssertTrue(VoiceSettings.curveWarnings(in: d))
        XCTAssertTrue(VoiceSettings.watchHaptics(in: d))
        XCTAssertEqual(VoiceSettings.limitCallouts(in: d), .changes)
        XCTAssertEqual(VoiceSettings.rerouteChoice(in: d), .rejoin)
    }

    func testSavedChoicesAreReadBackAndGarbageFallsToTheDefault() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        d.set("phone", forKey: VoiceSettings.engineKey)
        d.set(false, forKey: VoiceSettings.streetsKey)
        d.set("whenOver", forKey: VoiceSettings.limitsKey)
        d.set("ask", forKey: VoiceSettings.rerouteKey)
        XCTAssertEqual(VoiceSettings.engine(in: d), .phone)
        XCTAssertFalse(VoiceSettings.streetNames(in: d))
        XCTAssertEqual(VoiceSettings.limitCallouts(in: d), .whenOver)
        XCTAssertEqual(VoiceSettings.rerouteChoice(in: d), .ask)
        d.set("loud", forKey: VoiceSettings.engineKey)
        d.set("sometimes", forKey: VoiceSettings.limitsKey)
        XCTAssertEqual(VoiceSettings.engine(in: d), .natural)
        XCTAssertEqual(VoiceSettings.limitCallouts(in: d), .changes)
    }

    func testTheEngineIsToldWhatToSayWhenTheRiderLeavesTheRoute() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        XCTAssertEqual(VoiceSettings.guidanceOptions(in: d).offRouteLine, GuidanceLines.offRouteBack)
        d.set("destination", forKey: VoiceSettings.rerouteKey)
        XCTAssertEqual(VoiceSettings.guidanceOptions(in: d).offRouteLine, "Off route. Recalculating.")
        d.set("ask", forKey: VoiceSettings.rerouteKey)
        XCTAssertEqual(VoiceSettings.guidanceOptions(in: d).offRouteLine, "Off route.")
        d.set(false, forKey: VoiceSettings.curvesKey)
        XCTAssertFalse(VoiceSettings.guidanceOptions(in: d).curveWarnings)
    }

    func testTheBestInstalledEnglishVoiceWinsAndAnEnglishAccentBreaksTies() {
        let voices = [voice("a", "en-US", 1), voice("b", "en-GB", 2), voice("c", "en-US", 3), voice("d", "en-AU", 3), voice("e", "de-DE", 3)]
        XCTAssertEqual(VoiceSettings.pickEnglish(from: voices, identifier: "")?.identifier, "c")       // premium: US before AU in the order
        XCTAssertEqual(VoiceSettings.pickEnglish(from: voices.filter { $0.quality < 3 }, identifier: "")?.identifier, "b")
        XCTAssertNil(VoiceSettings.pickEnglish(from: [voice("e", "de-DE", 3)], identifier: ""))
    }

    func testAVoiceThePersonPickedIsKeptWhileInstalledAndForgottenWhenNot() {
        let voices = [voice("a", "en-US", 1), voice("c", "en-US", 3)]
        XCTAssertEqual(VoiceSettings.pickEnglish(from: voices, identifier: "a")?.identifier, "a")
        XCTAssertEqual(VoiceSettings.pickEnglish(from: voices, identifier: "gone")?.identifier, "c")
        XCTAssertEqual(VoiceSettings.pickEnglish(from: voices, identifier: "de")?.identifier, "c")
    }

    func testStreetNamesGoToASwissGermanVoiceThenGermanThenAustrian() {
        let voices = [voice("at", "de-AT", 3), voice("de", "de-DE", 2), voice("ch", "de-CH", 2), voice("en", "en-US", 3)]
        XCTAssertEqual(VoiceSettings.pickGerman(from: voices)?.identifier, "at")                        // quality first
        XCTAssertEqual(VoiceSettings.pickGerman(from: voices.filter { $0.identifier != "at" })?.identifier, "ch")
        XCTAssertNil(VoiceSettings.pickGerman(from: [voice("en", "en-US", 3)]))
    }

    func testTheVoicesAreLabelledForThePicker() {
        XCTAssertEqual(VoiceSettings.label(voice("x", "en-GB", 2, name: "Daniel")), "Daniel (en-GB, enhanced)")
        XCTAssertEqual(VoiceSettings.label(voice("x", "en-US", 3, name: "Zoe")), "Zoe (en-US, premium)")
        XCTAssertEqual(VoiceSettings.label(voice("x", "en-US", 1, name: "Fred")), "Fred (en-US, standard)")
    }

    func testTheVoiceIsNotBoostedUntilSomeoneAsksForIt() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        XCTAssertEqual(VoiceSettings.boostDb(in: d), 0)
        d.set(9.0, forKey: VoiceSettings.boostKey)
        XCTAssertEqual(VoiceSettings.boostDb(in: d), 9)
    }

    func testTheBoostStaysInRangeAndInSteps() {
        XCTAssertEqual(VoiceSettings.clampedBoost(-5), 0)
        XCTAssertEqual(VoiceSettings.clampedBoost(40), 18)
        XCTAssertEqual(VoiceSettings.clampedBoost(7.4), 6)
        XCTAssertEqual(VoiceSettings.clampedBoost(7.6), 9)
        XCTAssertEqual(VoiceSettings.clampedBoost(12), 12)
    }

    func testASavedBoostOutOfRangeIsBroughtBack() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        d.set(99.0, forKey: VoiceSettings.boostKey)
        XCTAssertEqual(VoiceSettings.boostDb(in: d), 18)
    }

    func testTheBoostIsDescribedInWords() {
        XCTAssertEqual(VoiceSettings.boostLabel(0), "Normal")
        XCTAssertEqual(VoiceSettings.boostLabel(6), "+6 dB, louder")
        XCTAssertEqual(VoiceSettings.boostLabel(12), "+12 dB, much louder")
        XCTAssertEqual(VoiceSettings.boostLabel(18), "+18 dB, loudest")
    }
}
