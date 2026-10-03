import XCTest

/// The natural voice's clip bookkeeping (Sources/Core/VoiceClipLogic.swift) and the preview of everything a route can make the guidance say.
final class VoiceClipLogicTests: XCTestCase {
    private func part(_ text: String, _ kind: SpokenPart.Kind = .instruction) -> SpokenPart { SpokenPart(kind: kind, text: text) }

    private func route() throws -> GuidanceRoute {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api_planner_trip", withExtension: "json"))
        let answer = try JSONDecoder.ridelog.decode(PlanResponse.self, from: Data(contentsOf: url))
        return try XCTUnwrap(GuidanceRoute(route: try XCTUnwrap(answer.routes.first), name: "Test"))
    }

    func testOnlyWhatIsMissingIsFetchedAndEachOnce() {
        let parts = [part("turn left"), part("Hardstrasse", .street), part("turn left"), part("turn right")]
        let missing = VoiceClipLogic.missing(parts, have: ["en|turn right"])
        XCTAssertEqual(missing.map(\.key), ["en|turn left", "de|Hardstrasse"])
    }

    func testPiecesTheServerWouldRefuseAreNotAskedFor() {
        let long = String(repeating: "x", count: VoiceClipLogic.maxCharacters + 1)
        XCTAssertTrue(VoiceClipLogic.missing([part(long), part("")], have: []).isEmpty)
    }

    func testRequestsAreSplitIntoBatchesTheServerAccepts() {
        let parts = (0..<(VoiceClipLogic.batchSize * 2 + 5)).map { part("p\($0)") }
        let batches = VoiceClipLogic.batches(parts)
        XCTAssertEqual(batches.map(\.count), [VoiceClipLogic.batchSize, VoiceClipLogic.batchSize, 5])
        XCTAssertEqual(batches.flatMap { $0 }, parts)
        XCTAssertTrue(VoiceClipLogic.batches([]).isEmpty)
    }

    func testTheRequestIsJSONWithTextAndLanguage() throws {
        let json = VoiceClipLogic.requestJSON([part("turn left"), part("Hardstrasse \"Süd\"", .street)])
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
        XCTAssertEqual(items, [["text": "turn left", "lang": "en"], ["text": "Hardstrasse \"Süd\"", "lang": "de"]])
    }

    func testAPhraseIsPlayableOnlyWhenEveryPieceHasAClip() {
        let phrase = Phrase(parts: [part("In 300 meters", .distance), part("turn left onto"), part("Hardstrasse", .street)])
        let index = ["en|In 300 meters": "aaaaaaaaaaaaaaaa", "en|turn left onto": "bbbbbbbbbbbbbbbb"]
        XCTAssertNil(VoiceClipLogic.clipIDs(for: phrase, index: index))
        XCTAssertEqual(VoiceClipLogic.clipIDs(for: phrase, index: index.merging(["de|Hardstrasse": "cccccccccccccccc"]) { a, _ in a }), ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "cccccccccccccccc"])
        XCTAssertNil(VoiceClipLogic.clipIDs(for: Phrase(parts: []), index: index))
    }

    func testTheIndexSurvivesBeingKeptOnDisk() {
        let index = ["en|turn left": "0123456789abcdef"]
        XCTAssertEqual(VoiceClipLogic.decode(VoiceClipLogic.encode(index)), index)
        XCTAssertEqual(VoiceClipLogic.decode(Data("not json".utf8)), [:])
    }

    func testOnlyRealClipIDsBecomeFileNames() {
        XCTAssertTrue(VoiceClipLogic.isValid(id: "0123456789abcdef"))
        for bad in ["", "0123456789abcde", "0123456789ABCDEF", "../../etc/passwd", "0123456789abcdeg", "0123456789abcdef0"] { XCTAssertFalse(VoiceClipLogic.isValid(id: bad), bad) }
    }

    func testClipsAreDecodedFromTheServersAnswer() throws {
        let json = #"{"api":1,"status":"ok","message":null,"clips":[{"text":"turn left","lang":"en","id":"0123456789abcdef","url":"/api/v1/voice/clips/0123456789abcdef.mp3"}]}"#
        let answer = try JSONDecoder.ridelog.decode(VoiceClipsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(answer.clips?.first?.key, "en|turn left")
        let status = try JSONDecoder.ridelog.decode(VoiceStatusResponse.self, from: Data(#"{"api":1,"status":"ok","message":null,"available":true,"street_available":false,"voice":"en_GB-alan-medium","street_voice":"de_DE-thorsten-medium"}"#.utf8))
        XCTAssertTrue(status.available)
        XCTAssertFalse(status.streetAvailable)
    }

    // MARK: the preview

    func testThePreviewHoldsWhatTheEngineSaysOnTheRealRoute() throws {
        let route = try route()
        let preview = Set(GuidancePreview.parts(for: route))
        XCTAssertTrue(preview.contains(SpokenPart(kind: .street, text: "Schaffhauserplatz")))
        XCTAssertTrue(preview.contains(SpokenPart(kind: .instruction, text: "turn right onto")))
        XCTAssertTrue(preview.contains(SpokenPart(kind: .instruction, text: "You have arrived at your destination.")))
        XCTAssertTrue(preview.contains(SpokenPart(kind: .distance, text: "In 600 meters")))
    }

    func testEverythingSaidOnARideIsInThePreview() throws {
        let route = try route()
        let preview = Set(GuidancePreview.parts(for: route))
        var engine = GuidanceEngine(route: route)
        var sim = DriveSimulator(line: route.line)
        var t = 0.0
        while !sim.isFinished && !engine.arrived && t < 20_000 {
            let position = sim.step(seconds: 1, speedMps: 14)
            for case .say(let phrase) in engine.update(lat: position.lat, lon: position.lon, speedMps: 14, now: t) {
                for piece in phrase.parts { XCTAssertTrue(preview.contains(piece), "not in the preview: \(piece)") }
            }
            t += 1
        }
        XCTAssertTrue(engine.arrived)
    }

    func testThePreviewHasNoPieceTwice() throws {
        let parts = GuidancePreview.parts(for: try route())
        XCTAssertEqual(parts.count, Set(parts).count)
    }
}
