import XCTest

/// The tap on the wrist for a turn (Shared/WatchProtocol.swift WatchCue).
final class WatchCueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testACueSurvivesTheTripAsAPropertyList() throws {
        for kind in WatchCue.Kind.allCases {
            let cue = WatchCue(kind: kind, sentAt: now)
            let data = try PropertyListSerialization.data(fromPropertyList: [WatchKeys.cue: cue.dictionary()], format: .binary, options: 0)
            let back = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            XCTAssertEqual(WatchCue(dictionary: try XCTUnwrap(back[WatchKeys.cue] as? [String: Any])), cue)
        }
    }

    func testABrokenCueIsNothingNotACrash() {
        XCTAssertNil(WatchCue(dictionary: [:]))
        XCTAssertNil(WatchCue(dictionary: ["kind": "sideways", "sentAt": 1.0]))
        XCTAssertNil(WatchCue(dictionary: ["kind": "left"]))
    }

    func testACueThatArrivesLateIsDropped() {
        let cue = WatchCue(kind: .left, sentAt: now)
        XCTAssertFalse(cue.isStale(now: now.addingTimeInterval(WatchCue.staleAfter - 0.5)))
        XCTAssertTrue(cue.isStale(now: now.addingTimeInterval(WatchCue.staleAfter + 0.5)))
    }

    func testLeftAndRightFeelDifferentAndEveryCueTapsAtLeastOnce() {
        XCTAssertNotEqual(WatchCue(kind: .left, sentAt: now).pulses, WatchCue(kind: .right, sentAt: now).pulses)
        XCTAssertEqual(WatchCue(kind: .left, sentAt: now).pulses.count, 2)
        for kind in WatchCue.Kind.allCases { XCTAssertFalse(WatchCue(kind: kind, sentAt: now).pulses.isEmpty, "\(kind)") }
    }

    func testTheEnginesCuesAreTheWatchsCues() {
        for cue in [TurnCue.left, .right, .uturn, .curve, .arrive] { XCTAssertNotNil(WatchCue.Kind(rawValue: cue.rawValue), cue.rawValue) }
    }

    func testTheManeuverTypesPointTheWayTheyShould() {
        XCTAssertEqual(GuidanceText.cue(forType: 15), .left)
        XCTAssertEqual(GuidanceText.cue(forType: 10), .right)
        XCTAssertEqual(GuidanceText.cue(forType: 14), .left)
        XCTAssertEqual(GuidanceText.cue(forType: 11), .right)
        XCTAssertEqual(GuidanceText.cue(forType: 13), .uturn)
        XCTAssertNil(GuidanceText.cue(forType: 26))                                  // a roundabout has no side
        XCTAssertNil(GuidanceText.cue(forType: 8))
    }
}
