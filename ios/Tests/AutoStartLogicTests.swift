import XCTest

final class AutoStartLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_586_900)

    /// One reading a second for `seconds`, ending now, all at `kmh`.
    private func steady(_ kmh: Double, seconds: Int) -> [SpeedReading] {
        (0...seconds).map { SpeedReading(time: now.addingTimeInterval(Double($0 - seconds)), kmh: kmh) }
    }

    private func decide(_ readings: [SpeedReading], helmetRequired: Bool = false, helmetPresent: Bool = false, mode: AutoStartMode = .silent) -> StartDecision {
        AutoStartLogic.decideStart(readings: readings, now: now, helmetRequired: helmetRequired, helmetPresent: helmetPresent, mode: mode)
    }

    // MARK: starting

    func testRidingAtSpeedForTwentySecondsStartsARide() {
        XCTAssertEqual(decide(steady(30, seconds: 20)), .start)
        XCTAssertEqual(decide(steady(15, seconds: 20)), .start)                                   // exactly at the threshold counts
    }

    func testTheSameRideAsksFirstWhenThatIsChosen() {
        XCTAssertEqual(decide(steady(30, seconds: 20), mode: .askFirst), .askToStart)
    }

    func testNotLongEnoughYetKeepsWatching() {
        XCTAssertEqual(decide(steady(30, seconds: 10)), .keepWatching)
        XCTAssertEqual(decide([]), .keepWatching)
        XCTAssertEqual(decide(steady(30, seconds: 0)), .keepWatching)
    }

    func testAShortGapInTheReadingsIsTolerated() {
        XCTAssertEqual(decide(steady(30, seconds: 18)), .start)                                   // 18 s of readings is within the 3 s slack of 20
        XCTAssertEqual(decide(steady(30, seconds: 16)), .keepWatching)
    }

    func testOneSlowReadingInTheWindowRestartsTheCount() {
        var readings = steady(30, seconds: 20)
        readings[10] = SpeedReading(time: readings[10].time, kmh: 5)
        XCTAssertEqual(decide(readings), .keepWatching)
    }

    func testWalkingOrCyclingPaceDoesNotStart() {
        XCTAssertEqual(decide(steady(12, seconds: 30)), .keepWatching)
    }

    func testOnlyTheLastTwentySecondsCountSoAnEarlyStopIsForgotten() {
        let slow = (0..<10).map { SpeedReading(time: now.addingTimeInterval(Double(-40 + $0)), kmh: 0) }
        XCTAssertEqual(decide(slow + steady(30, seconds: 20)), .start)
    }

    func testReadingsOutOfOrderAreSorted() {
        XCTAssertEqual(decide(steady(30, seconds: 20).reversed()), .start)
    }

    func testTheHelmetMustBeConnectedWhenRequired() {
        XCTAssertEqual(decide(steady(30, seconds: 20), helmetRequired: true, helmetPresent: false), .ignore("The helmet is not connected."))
        XCTAssertEqual(decide(steady(30, seconds: 20), helmetRequired: true, helmetPresent: true), .start)
        XCTAssertEqual(decide(steady(30, seconds: 20), helmetRequired: false, helmetPresent: false), .start)
    }

    // MARK: the helmet

    func testTheHelmetNameMatchesPartOfAnAudioDeviceNameIgnoringCaseAndAccents() {
        XCTAssertTrue(AutoStartLogic.helmetPresent(routeNames: ["iPhone Speaker", "CARDO PACKTALK EDGE"], helmetName: "cardo"))
        XCTAssertTrue(AutoStartLogic.helmetPresent(routeNames: ["Sénā 50S"], helmetName: "sena 50"))
        XCTAssertFalse(AutoStartLogic.helmetPresent(routeNames: ["AirPods Pro"], helmetName: "Cardo"))
    }

    func testAnEmptyHelmetNameOrNoDevicesNeverMatches() {
        XCTAssertFalse(AutoStartLogic.helmetPresent(routeNames: ["Cardo"], helmetName: ""))
        XCTAssertFalse(AutoStartLogic.helmetPresent(routeNames: ["Cardo"], helmetName: "   "))
        XCTAssertFalse(AutoStartLogic.helmetPresent(routeNames: [], helmetName: "Cardo"))
    }

    // MARK: stopping and giving up

    func testParkedForTenMinutesEndsTheRide() {
        XCTAssertFalse(AutoStartLogic.shouldAutoStop(lastMovingAt: now.addingTimeInterval(-599), now: now))
        XCTAssertTrue(AutoStartLogic.shouldAutoStop(lastMovingAt: now.addingTimeInterval(-600), now: now))
        XCTAssertFalse(AutoStartLogic.shouldAutoStop(lastMovingAt: now, now: now))
    }

    func testTheGPSIsNotWatchedForeverAfterAMovement() {
        XCTAssertFalse(AutoStartLogic.probeExpired(startedAt: now.addingTimeInterval(-119), now: now))
        XCTAssertTrue(AutoStartLogic.probeExpired(startedAt: now.addingTimeInterval(-120), now: now))
    }

    func testOldReadingsAreDropped() {
        let all = (0..<100).map { SpeedReading(time: now.addingTimeInterval(Double(-$0)), kmh: 20) }
        let kept = AutoStartLogic.pruned(all, now: now)
        XCTAssertEqual(kept.count, 61)
        XCTAssertTrue(kept.allSatisfy { now.timeIntervalSince($0.time) <= 60 })
    }

    func testTheConstantsAreWhatTheReadmePromises() {
        XCTAssertEqual(AutoStartLogic.startSpeedKmh, 15)
        XCTAssertEqual(AutoStartLogic.startSustainedSeconds, 20)
        XCTAssertEqual(AutoStartLogic.stopIdleSeconds, 600)
        XCTAssertEqual(AutoStartLogic.fixWatchdogSeconds, 25)
    }

    func testModesHaveWords() {
        XCTAssertEqual(AutoStartMode.allCases.map(\.title), ["Ask me first", "Start silently"])
    }
}
