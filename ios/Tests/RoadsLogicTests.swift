import XCTest

/// The roads models against the server's own golden JSON, and the logic the Traffic tab's Roads layer uses.
final class RoadsLogicTests: XCTestCase {
    private func fixture() throws -> RoadsResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api_roads", withExtension: "json"), "missing fixture api_roads.json")
        return try JSONDecoder.ridelog.decode(RoadsResponse.self, from: Data(contentsOf: url))
    }

    private func road(id: Int = 1, name: String? = "Kurvenstrasse", ref: String? = "7", ridden: Bool? = false, score: Int = 68) -> TwistyRoad {
        TwistyRoad(id: id, wayId: id * 10, name: name, ref: ref, highway: "secondary", surface: nil, paved: true, maxspeed: 80, lengthM: 1607, curvyM: 1100, score: score,
                   geometry: [RoadPoint(lat: 47.40, lon: 8.60), RoadPoint(lat: 47.41, lon: 8.61), RoadPoint(lat: 47.42, lon: 8.62)], ridden: ridden)
    }

    private func response(_ roads: [TwistyRoad], status: String = "ok", ridden: String = "ok", truncated: Bool = false) -> RoadsResponse {
        RoadsResponse(status: status, roads: roads, truncated: truncated, riddenStatus: ridden, pendingRides: 0, attribution: "x")
    }

    // MARK: decoding

    func testTheGoldenAnswerDecodes() throws {
        let answer = try fixture()
        XCTAssertTrue(answer.isBuilt)
        XCTAssertEqual(answer.riddenStatus, "ok")
        XCTAssertEqual(answer.pendingRides, 0)
        XCTAssertFalse(answer.truncated)
        XCTAssertTrue(answer.attribution.contains("OpenStreetMap"))
        XCTAssertEqual(answer.roads.count, 2)
        let first = answer.roads[0]
        XCTAssertEqual(first.name, "Kurvenstrasse")
        XCTAssertEqual(first.ref, "7")
        XCTAssertEqual(first.wayId, 111)
        XCTAssertEqual(first.maxspeed, 80)
        XCTAssertNil(first.surface)
        XCTAssertEqual(first.ridden, true)
        XCTAssertEqual(answer.roads[1].ridden, false)
        XCTAssertGreaterThan(first.geometry.count, 20)
        XCTAssertEqual(first.geometry[0], RoadPoint(lat: 47.4, lon: 8.6))
        XCTAssertEqual(Set(answer.roads.map(\.id)).count, 2)
    }

    func testAnAnswerFromAServerWithoutTheDatabaseDecodes() throws {
        let json = #"{"api":1,"status":"not_built","roads":[],"truncated":false,"ridden_status":"unavailable","attribution":"Roads"}"#
        let answer = try JSONDecoder.ridelog.decode(RoadsResponse.self, from: Data(json.utf8))
        XCTAssertFalse(answer.isBuilt)
        XCTAssertNil(answer.pendingRides)
        XCTAssertEqual(RoadsLogic.summary(answer, shown: 0), "The twisty-road database has not been built on your server yet.")
    }

    func testARoadWhoseRidingIsUnknownDecodesToNil() throws {
        let json = #"{"id":1,"way_id":2,"name":null,"ref":null,"highway":"tertiary","surface":null,"paved":true,"maxspeed":null,"length_m":900,"curvy_m":500,"score":55,"geometry":[[47.0,8.0],[47.1,8.1]],"ridden":null}"#
        let road = try JSONDecoder.ridelog.decode(TwistyRoad.self, from: Data(json.utf8))
        XCTAssertNil(road.ridden)
        XCTAssertNil(road.name)
        XCTAssertEqual(RoadsLogic.title(road), "Road without a name")
    }

    // MARK: the map box

    func testTheBoxIsTheScreenWithAMarginButNeverMoreThanTheServerAccepts() {
        let screen = RoadsLogic.box(centerLat: 47.4, centerLon: 8.6, latSpan: 0.2, lonSpan: 0.3)
        XCTAssertEqual(screen.south, 47.3, accuracy: 1e-9)
        XCTAssertEqual(screen.west, 8.45, accuracy: 1e-9)
        XCTAssertEqual(screen.north, 47.5, accuracy: 1e-9)
        XCTAssertEqual(screen.east, 8.75, accuracy: 1e-9)
        let asked = RoadsLogic.queryBox(for: screen)
        XCTAssertEqual(asked.latSpan, 0.32, accuracy: 1e-9)
        XCTAssertEqual(asked.lonSpan, 0.48, accuracy: 1e-9)
        XCTAssertEqual((asked.south + asked.north) / 2, 47.4, accuracy: 1e-9)
        XCTAssertTrue(asked.contains(screen))
        let wide = RoadsLogic.queryBox(for: RoadsLogic.box(centerLat: 47, centerLon: 8, latSpan: 0.7, lonSpan: 1.0))
        XCTAssertEqual(wide.latSpan, RoadsLogic.maxLatSpan, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(wide.lonSpan, RoadsLogic.maxLonSpan + 1e-9)
    }

    func testRoadsAreOnlyAskedForWhenTheScreenShowsLittleEnoughMap() {
        XCTAssertTrue(RoadsLogic.canQuery(RoadsLogic.box(centerLat: 47, centerLon: 8, latSpan: 0.3, lonSpan: 0.4)))
        XCTAssertTrue(RoadsLogic.canQuery(RoadsLogic.box(centerLat: 47, centerLon: 8, latSpan: 0.6, lonSpan: 0.9)))
        XCTAssertFalse(RoadsLogic.canQuery(RoadsLogic.box(centerLat: 47, centerLon: 8, latSpan: 0.7, lonSpan: 0.5)))
        XCTAssertFalse(RoadsLogic.canQuery(RoadsLogic.box(centerLat: 47, centerLon: 8, latSpan: 0.3, lonSpan: 1.0)))
        XCTAssertFalse(RoadsLogic.canQuery(RoadsLogic.Box(south: 47, west: 8, north: 47, east: 8)))
    }

    func testRefreshingHappensOnlyWhenTheAnswerNoLongerFits() {
        let now = Date()
        let screen = RoadsLogic.box(centerLat: 47.4, centerLon: 8.6, latSpan: 0.2, lonSpan: 0.3)
        let fetched = RoadsLogic.Fetched(box: RoadsLogic.queryBox(for: screen), at: now)
        XCTAssertTrue(RoadsLogic.needsRefresh(last: nil, visible: screen, now: now))
        XCTAssertFalse(RoadsLogic.needsRefresh(last: fetched, visible: screen, now: now.addingTimeInterval(10)))
        let nudged = RoadsLogic.box(centerLat: 47.42, centerLon: 8.62, latSpan: 0.2, lonSpan: 0.3)                    // a small pan stays inside the margin
        XCTAssertFalse(RoadsLogic.needsRefresh(last: fetched, visible: nudged, now: now.addingTimeInterval(10)))
        let panned = RoadsLogic.box(centerLat: 47.55, centerLon: 8.6, latSpan: 0.2, lonSpan: 0.3)
        XCTAssertTrue(RoadsLogic.needsRefresh(last: fetched, visible: panned, now: now.addingTimeInterval(10)))
        XCTAssertTrue(RoadsLogic.needsRefresh(last: fetched, visible: screen, now: now.addingTimeInterval(RoadsLogic.maxAge + 1)))
        let zoomedIn = RoadsLogic.box(centerLat: 47.4, centerLon: 8.6, latSpan: 0.03, lonSpan: 0.04)                  // far smaller than what was fetched
        XCTAssertTrue(RoadsLogic.needsRefresh(last: fetched, visible: zoomedIn, now: now.addingTimeInterval(10)))
    }

    // MARK: words

    func testTheTitleUsesWhatTheMapKnows() {
        XCTAssertEqual(RoadsLogic.title(road()), "Kurvenstrasse (7)")
        XCTAssertEqual(RoadsLogic.title(road(ref: nil)), "Kurvenstrasse")
        XCTAssertEqual(RoadsLogic.title(road(name: nil)), "7")
        XCTAssertEqual(RoadsLogic.title(road(name: nil, ref: nil)), "Road without a name")
    }

    func testLengthAndScoreWords() {
        XCTAssertEqual(RoadsLogic.lengthText(640), "640 m")
        XCTAssertEqual(RoadsLogic.lengthText(1607), "1.6 km")
        XCTAssertEqual(RoadsLogic.scoreWord(90), "Very twisty")
        XCTAssertEqual(RoadsLogic.scoreWord(85), "Very twisty")
        XCTAssertEqual(RoadsLogic.scoreWord(68), "Twisty")
        XCTAssertEqual(RoadsLogic.scoreWord(50), "Lively")
        XCTAssertEqual(RoadsLogic.scoreWord(30), "Gentle bends")
        XCTAssertEqual(RoadsLogic.highwayText("primary"), "Main road")
        XCTAssertEqual(RoadsLogic.highwayText("tertiary"), "Minor road")
        XCTAssertEqual(RoadsLogic.highwayText("mystery"), "Road")
        XCTAssertEqual(RoadsLogic.riddenText(true), "You have ridden this")
        XCTAssertEqual(RoadsLogic.riddenText(false), "Not ridden yet")
        XCTAssertEqual(RoadsLogic.riddenText(nil), "Not known whether you have ridden this")
    }

    func testTheSummaryTellsTheTruthAboutWhatIsMissing() {
        let two = [road(id: 1, ridden: true), road(id: 2, ridden: false)]
        XCTAssertEqual(RoadsLogic.summary(response(two), shown: 2), "2 twisty stretches in view (1 not ridden yet)")
        XCTAssertEqual(RoadsLogic.summary(response([road()]), shown: 1), "1 twisty stretch in view (1 not ridden yet)")
        XCTAssertEqual(RoadsLogic.summary(response(two, ridden: "updating"), shown: 2), "2 twisty stretches in view, working out which you have ridden…")
        XCTAssertEqual(RoadsLogic.summary(response(two, ridden: "unavailable"), shown: 2), "2 twisty stretches in view")
        XCTAssertEqual(RoadsLogic.summary(response(two, truncated: true), shown: 2), "2 twisty stretches in view (1 not ridden yet). Zoom in to see more.")
        XCTAssertEqual(RoadsLogic.summary(response([]), shown: 0), "No twisty roads in view. Move the map or zoom out a little.")
    }

    func testOnlyNotRiddenKeepsRoadsWhoseStatusIsUnknown() {
        let roads = [road(id: 1, ridden: true), road(id: 2, ridden: false), road(id: 3, ridden: nil)]
        XCTAssertEqual(RoadsLogic.visible(roads, onlyUnridden: false).map(\.id), [1, 2, 3])
        XCTAssertEqual(RoadsLogic.visible(roads, onlyUnridden: true).map(\.id), [2, 3])
    }

    func testTheBadgeSitsHalfwayAndTheMapsLinkPointsThere() throws {
        let r = road()
        XCTAssertEqual(RoadsLogic.midpoint(r), RoadPoint(lat: 47.41, lon: 8.61))
        let url = try XCTUnwrap(RoadsLogic.mapsURL(r))
        XCTAssertEqual(url.host, "maps.apple.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "ll" }?.value, "47.41000,8.61000")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Kurvenstrasse (7)")
        let empty = TwistyRoad(id: 9, wayId: 9, name: nil, ref: nil, highway: "tertiary", surface: nil, paved: true, maxspeed: nil, lengthM: 500, curvyM: 300, score: 60, geometry: [], ridden: nil)
        XCTAssertNil(RoadsLogic.midpoint(empty))
        XCTAssertNil(RoadsLogic.mapsURL(empty))
    }
}
