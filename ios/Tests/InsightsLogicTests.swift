import XCTest

/// The insights models against the server's own golden JSON, and the logic the ride screen uses for them.
final class InsightsLogicTests: XCTestCase {
    private func fixture() throws -> RideInsights {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api_insights", withExtension: "json"), "missing fixture api_insights.json")
        return try JSONDecoder.ridelog.decode(RideInsights.self, from: Data(contentsOf: url))
    }

    private func point(_ t: Double, dist: Double) -> TrackPoint { TrackPoint(t: t, lat: 47, lon: 8, mps: 10, dist: dist) }

    // MARK: decoding

    func testTheGoldenAnswerDecodes() throws {
        let insights = try fixture()
        XCTAssertEqual(insights.roadNames, [RoadName(t: 0, name: "Hardstrasse")])
        XCTAssertEqual(try XCTUnwrap(insights.elevation).maxM, 411)
        XCTAssertGreaterThan(try XCTUnwrap(insights.elevation).points.count, 10)
        let smooth = try XCTUnwrap(insights.smoothness)
        XCTAssertEqual(smooth.hardBraking, 1)
        XCTAssertEqual(smooth.hardAcceleration, 2)
        XCTAssertEqual(smooth.events.count, 3)
        XCTAssertTrue(smooth.events.contains { $0.isBraking && $0.fromKmh == 90 && $0.toKmh == 11 })
        XCTAssertEqual(insights.weather.status, "ok")
        XCTAssertEqual(insights.weather.condition, "Overcast")
        XCTAssertEqual(insights.weather.windMaxKmh, 10)
        XCTAssertEqual(insights.weather.wet, false)
        XCTAssertTrue(try XCTUnwrap(insights.weather.attribution).contains("Open-Meteo"))
    }

    func testTheLimitsPartDecodes() throws {
        let limits = try fixture().limits
        XCTAssertTrue(limits.isOk)
        XCTAssertEqual(limits.tagged?.overSeconds, 120)
        XCTAssertEqual(limits.estimated?.seconds, 0)
        XCTAssertEqual(limits.worst, WorstOver(t: 2, overKmh: 10, kmh: 90, limitKmh: 80, name: "Hardstrasse"))
        XCTAssertEqual(limits.stretches?.count, 1)
        XCTAssertEqual(limits.stretches?.first?.maxOverKmh, 10)
        XCTAssertEqual(limits.taggedShare, 100)
    }

    func testPartsThatAreSwitchedOffDecodeWithoutTheirNumbers() throws {
        let json = """
        {"api":1,"ride_id":3,"elevation":null,"smoothness":null,"weather":{"status":"disabled"},"limits":{"status":"disabled"},"road_names":[]}
        """
        let insights = try JSONDecoder.ridelog.decode(RideInsights.self, from: Data(json.utf8))
        XCTAssertNil(insights.elevation)
        XCTAssertNil(insights.smoothness)
        XCTAssertEqual(insights.weather.status, "disabled")
        XCTAssertNil(insights.weather.temperatureMinC)
        XCTAssertFalse(insights.limits.isOk)
        XCTAssertNil(insights.limits.stretches)
    }

    // MARK: roads

    func testTheRoadIsTheLastNameChangeAtOrBeforeTheMoment() {
        let names = [RoadName(t: 0, name: "A"), RoadName(t: 60, name: "B"), RoadName(t: 120, name: "C")]
        XCTAssertEqual(InsightsLogic.roadName(at: 0, in: names), "A")
        XCTAssertEqual(InsightsLogic.roadName(at: 59.9, in: names), "A")
        XCTAssertEqual(InsightsLogic.roadName(at: 60, in: names), "B")
        XCTAssertEqual(InsightsLogic.roadName(at: 5000, in: names), "C")
        XCTAssertNil(InsightsLogic.roadName(at: 5, in: [RoadName(t: 10, name: "late")]))
        XCTAssertNil(InsightsLogic.roadName(at: 5, in: []))
    }

    // MARK: places on the track

    func testAStretchIsDrawnFromTheFixesAroundIt() {
        let pts = (0...10).map { point(Double($0) * 10, dist: Double($0) * 100) }
        XCTAssertEqual(InsightsLogic.points(from: 25, to: 55, in: pts).map(\.t), [20, 30, 40, 50, 60])
        XCTAssertEqual(InsightsLogic.points(from: 30, to: 50, in: pts).map(\.t), [30, 40, 50])
        XCTAssertEqual(InsightsLogic.points(from: 0, to: 1000, in: pts).count, 11)
        XCTAssertTrue(InsightsLogic.points(from: 50, to: 20, in: pts).isEmpty)
        XCTAssertTrue(InsightsLogic.points(from: 0, to: 10, in: [point(0, dist: 0)]).isEmpty)
    }

    func testADistanceBecomesATime() {
        let pts = [point(0, dist: 0), point(10, dist: 100), point(20, dist: 100), point(50, dist: 400)]          // stood still from 10 to 20
        XCTAssertEqual(try XCTUnwrap(InsightsLogic.time(atDistance: 50, in: pts)), 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(InsightsLogic.time(atDistance: 250, in: pts)), 35, accuracy: 0.001)
        XCTAssertEqual(InsightsLogic.time(atDistance: -5, in: pts), 0)
        XCTAssertEqual(InsightsLogic.time(atDistance: 9999, in: pts), 50)
        XCTAssertNil(InsightsLogic.time(atDistance: 1, in: []))
    }

    func testTheStretchAtAMoment() {
        let a = LimitStretch(tStart: 10, tEnd: 20, limitKmh: 50, maxKmh: 60, maxOverKmh: 10, name: nil, distStartM: 100)
        let b = LimitStretch(tStart: 40, tEnd: 45, limitKmh: 80, maxKmh: 95, maxOverKmh: 15, name: "X", distStartM: 400)
        XCTAssertEqual(InsightsLogic.stretch(at: 15, in: [a, b]), a)
        XCTAssertEqual(InsightsLogic.stretch(at: 45, in: [a, b]), b)
        XCTAssertNil(InsightsLogic.stretch(at: 30, in: [a, b]))
    }

    // MARK: words

    func testTheOverLimitSentence() {
        XCTAssertEqual(InsightsLogic.overLimitSummary(LimitTotals(seconds: 280, overSeconds: 120, notableSeconds: 100, overMetres: 3000, overShare: 42.9)),
                       "2:00 over the limit, 43 % of the time on roads with a limit on the map.")
        XCTAssertEqual(InsightsLogic.overLimitSummary(LimitTotals(seconds: 280, overSeconds: 0, notableSeconds: 0, overMetres: 0, overShare: 0)),
                       "Never over the limit on roads with a limit on the map.")
        XCTAssertEqual(InsightsLogic.overLimitSummary(LimitTotals(seconds: 0, overSeconds: 0, notableSeconds: 0, overMetres: 0, overShare: nil)),
                       "No road with a limit written on the map.")
    }

    func testTheWorstSentenceAndTheStatusTexts() {
        XCTAssertEqual(InsightsLogic.worstText(WorstOver(t: 1, overKmh: 10, kmh: 90, limitKmh: 80, name: "Hardstrasse")), "+10 km/h on Hardstrasse (90 in a 80 zone)")
        XCTAssertEqual(InsightsLogic.worstText(WorstOver(t: 1, overKmh: 7, kmh: 57, limitKmh: 50, name: nil)), "+7 km/h (57 in a 50 zone)")
        XCTAssertNil(InsightsLogic.limitsStatusText("ok"))
        for status in ["disabled", "unavailable", "no_match", "no_data", "something-new"] {
            XCTAssertNotNil(InsightsLogic.limitsStatusText(status), status)
        }
    }

    private func weather(min: Double? = 12, max: Double? = 16, rain: Double? = 0, wet: Bool? = false, condition: String? = "Overcast") -> WeatherInfo {
        WeatherInfo(status: "ok", message: nil, temperatureStartC: 12, temperatureEndC: 16, temperatureMinC: min, temperatureMaxC: max, precipitationMm: rain,
                    windMaxKmh: 10, gustMaxKmh: 22, condition: condition, conditionStart: condition, wet: wet, attribution: nil)
    }

    func testWeatherWords() {
        XCTAssertEqual(InsightsLogic.temperatureText(weather()), "12° to 16°")
        XCTAssertEqual(InsightsLogic.temperatureText(weather(min: 15.6, max: 16.4)), "16°")
        XCTAssertEqual(InsightsLogic.temperatureText(weather(min: nil, max: nil)), "12°")
        XCTAssertEqual(InsightsLogic.rainText(weather()), "Dry")
        XCTAssertEqual(InsightsLogic.rainText(weather(rain: 1.46, wet: true)), "Rain 1.5 mm")
        XCTAssertEqual(InsightsLogic.rainText(weather(rain: 0, wet: true)), "Wet")
        XCTAssertEqual(InsightsLogic.rainText(weather(rain: nil, wet: nil)), "Dry")
        XCTAssertEqual(InsightsLogic.weatherSymbol(weather(condition: "Thunderstorm with hail")), "cloud.bolt.rain.fill")
        XCTAssertEqual(InsightsLogic.weatherSymbol(weather(condition: "Light showers")), "cloud.rain.fill")
        XCTAssertEqual(InsightsLogic.weatherSymbol(weather(condition: "Heavy snow")), "cloud.snow.fill")
        XCTAssertEqual(InsightsLogic.weatherSymbol(weather(condition: "Clear")), "sun.max.fill")
        XCTAssertEqual(InsightsLogic.weatherSymbol(weather(condition: nil)), "sun.max.fill")
    }

    func testSmoothnessWords() {
        let event = SmoothnessEvent(kind: "braking", tStart: 1, tEnd: 3, peakMps2: -5.5, fromKmh: 90, toKmh: 11, lat: 1, lon: 2, distM: 3000)
        XCTAssertEqual(InsightsLogic.eventText(event), "Hard braking from 90 to 11 km/h")
        XCTAssertTrue(event.isBraking)
        XCTAssertEqual(InsightsLogic.scoreWord(95), "Very smooth")
        XCTAssertEqual(InsightsLogic.scoreWord(85), "Very smooth")
        XCTAssertEqual(InsightsLogic.scoreWord(84), "Smooth")
        XCTAssertEqual(InsightsLogic.scoreWord(55), "Lively")
        XCTAssertEqual(InsightsLogic.scoreWord(10), "Hard")
    }
}
