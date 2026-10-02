import XCTest

/// What the phone and the Watch say to each other (Shared/WatchProtocol.swift).
final class WatchProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(recording: Bool = true, started: Date? = Date(timeIntervalSince1970: 1_789_999_000)) -> WatchSnapshot {
        WatchSnapshot(recording: recording, speedKmh: 87, distanceM: 12_345.6, maxKmh: 121, gpsOK: true, startedAt: started, sentAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testASnapshotSurvivesTheTripAsAPropertyList() throws {
        let original = snapshot()
        let dictionary = original.dictionary()
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)          // all WatchConnectivity can carry
        let back = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(WatchSnapshot(dictionary: back), original)
    }

    func testAnIdleSnapshotHasNoStartTime() throws {
        let idle = snapshot(recording: false, started: nil)
        XCTAssertNil(idle.dictionary()["started"])
        XCTAssertEqual(WatchSnapshot(dictionary: idle.dictionary()), idle)
        XCTAssertNil(WatchSnapshot(dictionary: idle.dictionary())?.startedAt)
    }

    func testABrokenSnapshotIsNothingNotACrash() {
        XCTAssertNil(WatchSnapshot(dictionary: [:]))
        XCTAssertNil(WatchSnapshot(dictionary: ["recording": true, "speed": "fast"]))
        var d = snapshot().dictionary()
        d.removeValue(forKey: "sent")
        XCTAssertNil(WatchSnapshot(dictionary: d))
    }

    func testTheDistanceReadsLikeTheLiveActivity() {
        XCTAssertEqual(snapshot().distanceText, "12.3")
        var long = snapshot()
        long.distanceM = 123_456
        XCTAssertEqual(long.distanceText, "123")
    }

    func testStatsSurviveTheTripAndMayLackALastRide() throws {
        let stats = WatchStats(weekKm: 123.4, lastRideKm: 45.6, lastRideAt: Date(timeIntervalSince1970: 1_789_900_000), updatedAt: now)
        XCTAssertEqual(WatchStats(dictionary: stats.dictionary()), stats)
        let none = WatchStats(weekKm: 0, lastRideKm: nil, lastRideAt: nil, updatedAt: now)
        XCTAssertEqual(WatchStats(dictionary: none.dictionary()), none)
        XCTAssertNil(WatchStats(dictionary: ["week": 1.0]))
        XCTAssertNil(WatchStats(dictionary: [:]))
    }

    func testTheStatsAreKeptInTheSharedStore() throws {
        let suite = "ridelog.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchStatsStore(defaults: defaults)
        XCTAssertNil(store.load())
        let stats = WatchStats(weekKm: 77.7, lastRideKm: 12.3, lastRideAt: Date(timeIntervalSince1970: 1_789_900_000), updatedAt: now)
        store.save(stats)
        XCTAssertEqual(store.load(), stats)
        let newer = WatchStats(weekKm: 99, lastRideKm: nil, lastRideAt: nil, updatedAt: now.addingTimeInterval(60))
        store.save(newer)
        XCTAssertEqual(store.load(), newer)
    }

    func testLiveMessagesAreSpacedByASecondButAStateChangeGoesAtOnce() {
        XCTAssertTrue(WatchPolicy.shouldSendLive(last: nil, now: now, stateChanged: false))
        XCTAssertFalse(WatchPolicy.shouldSendLive(last: now, now: now.addingTimeInterval(0.4), stateChanged: false))
        XCTAssertTrue(WatchPolicy.shouldSendLive(last: now, now: now.addingTimeInterval(1), stateChanged: false))
        XCTAssertTrue(WatchPolicy.shouldSendLive(last: now, now: now.addingTimeInterval(0.1), stateChanged: true))
    }

    func testTheContextIsRefreshedEveryFewSecondsAndOnAChange() {
        XCTAssertTrue(WatchPolicy.shouldSendContext(last: nil, now: now, stateChanged: false))
        XCTAssertFalse(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(4.9), stateChanged: false))
        XCTAssertTrue(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(5), stateChanged: false))
        XCTAssertTrue(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(0.2), stateChanged: true))
    }

    func testWhileIdleTheContextIsLeftAloneForFiveMinutes() {
        XCTAssertFalse(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(60), stateChanged: false, recording: false))
        XCTAssertFalse(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(299), stateChanged: false, recording: false))
        XCTAssertTrue(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(300), stateChanged: false, recording: false))
        XCTAssertTrue(WatchPolicy.shouldSendContext(last: now, now: now.addingTimeInterval(1), stateChanged: true, recording: false))
    }

    func testOnlyARecordingSnapshotCanGoStale() {
        let recording = snapshot()
        XCTAssertFalse(WatchPolicy.isStale(recording, now: recording.sentAt.addingTimeInterval(WatchPolicy.staleAfter)))
        XCTAssertTrue(WatchPolicy.isStale(recording, now: recording.sentAt.addingTimeInterval(WatchPolicy.staleAfter + 1)))
        let idle = snapshot(recording: false, started: nil)
        XCTAssertFalse(WatchPolicy.isStale(idle, now: idle.sentAt.addingTimeInterval(3600)))
    }

    func testTheLastRideIsNamedByItsDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: 2, hour: 12).date!
        XCTAssertEqual(WatchPolicy.dayText(noon.addingTimeInterval(-3600), now: noon, calendar: calendar), "Today")
        XCTAssertEqual(WatchPolicy.dayText(noon.addingTimeInterval(-86_400), now: noon, calendar: calendar), "Yesterday")
        let older = WatchPolicy.dayText(noon.addingTimeInterval(-3 * 86_400), now: noon, calendar: calendar)
        XCTAssertTrue(older.contains("Tue") && older.contains("29") && older.contains("Sep"), older)
    }

    func testKilometresShortEnoughForAWatch() {
        XCTAssertEqual(WatchPolicy.kmText(7.84), "7.8")
        XCTAssertEqual(WatchPolicy.kmText(123.4), "123")
        XCTAssertEqual(WatchPolicy.kmText(0), "0.0")
    }

    func testTheCommandsAreWhatBothSidesExpect() {
        XCTAssertEqual(WatchCommand.start.rawValue, "start")
        XCTAssertEqual(WatchCommand(rawValue: "stop"), .stop)
        XCTAssertNil(WatchCommand(rawValue: "explode"))
        XCTAssertEqual(WatchKeys.command, "cmd")
    }

    // MARK: link state

    func testTheLinkStateFollowsTheFactsInOrder() {
        func state(_ supported: Bool = true, _ activated: Bool = true, _ paired: Bool = true, _ installed: Bool = true, _ reachable: Bool = true) -> WatchLinkState {
            WatchLinkState.from(supported: supported, activated: activated, paired: paired, installed: installed, reachable: reachable)
        }
        XCTAssertEqual(state(false), .unsupported)
        XCTAssertEqual(state(true, false), .starting)
        XCTAssertEqual(state(true, true, false), .notPaired)
        XCTAssertEqual(state(true, true, true, false), .appNotInstalled)
        XCTAssertEqual(state(true, true, true, true, false), .outOfReach)
        XCTAssertEqual(state(), .connected)
        XCTAssertEqual(state(true, true, false, false, true), .notPaired)                    // the first missing thing is the one reported
        XCTAssertEqual(state(false, false, false, false, false), .unsupported)
    }

    func testEveryStateSaysWhatToDoAndOnlyConnectedIsGood() {
        let all: [WatchLinkState] = [.unsupported, .starting, .notPaired, .appNotInstalled, .outOfReach, .connected]
        for state in all {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertEqual(state.isGood, state == .connected)
        }
        XCTAssertTrue(WatchLinkState.appNotInstalled.detail.contains("RideLogWatch"))
        XCTAssertTrue(WatchLinkState.outOfReach.detail.contains("Open RideLog on the watch"))
    }

    func testTheRecordScreenOnlyMentionsAWatchThatExists() {
        XCTAssertFalse(WatchLinkState.unsupported.showsOnRecordScreen)
        XCTAssertFalse(WatchLinkState.notPaired.showsOnRecordScreen)
        XCTAssertTrue(WatchLinkState.appNotInstalled.showsOnRecordScreen)
        XCTAssertTrue(WatchLinkState.outOfReach.showsOnRecordScreen)
        XCTAssertTrue(WatchLinkState.connected.showsOnRecordScreen)
    }

    func testThePingKeysAreWhatBothSidesUse() {
        XCTAssertEqual(WatchKeys.ping, "ping")
        XCTAssertEqual(WatchKeys.pong, "pong")
    }
}
