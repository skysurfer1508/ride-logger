import XCTest

/// The wire format of an upload, locked to Tests/Fixtures/ingest_batch.json. The server's tests (tests/test_ingest_app_batch.py) ingest that
/// same `body` and check the ride it makes; here we check the app builds exactly that `body` from the raw samples.
final class IngestPayloadTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ingest_batch", withExtension: "json"), "missing fixture ingest_batch.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func samples(from doc: [String: Any]) throws -> [LocationSample] {
        let raw = try XCTUnwrap(doc["samples"] as? [[String: Any]])
        return try raw.map { s in
            LocationSample(
                timestamp: try XCTUnwrap(WireTime.date(try XCTUnwrap(s["timestamp"] as? String))),
                latitude: try XCTUnwrap(s["lat"] as? Double), longitude: try XCTUnwrap(s["lon"] as? Double),
                speed: try XCTUnwrap(s["speed"] as? Double), altitude: try XCTUnwrap(s["altitude"] as? Double),
                horizontalAccuracy: try XCTUnwrap(s["horizontal_accuracy"] as? Double),
                verticalAccuracy: try XCTUnwrap(s["vertical_accuracy"] as? Double),
                batteryLevel: try XCTUnwrap(s["battery_level"] as? Double))
        }
    }

    func testTheBodyIsExactlyWhatTheServerTestsIngest() throws {
        let doc = try fixture()
        let samples = try samples(from: doc)
        let tripInfo = try XCTUnwrap(doc["trip"] as? [String: Any])
        let trip = TripRecord(tripId: try XCTUnwrap(doc["trip_id"] as? String), deviceId: try XCTUnwrap(doc["device_id"] as? String),
                              ownerEmail: "alice@example.com", startedAt: try XCTUnwrap(WireTime.date(try XCTUnwrap(tripInfo["start"] as? String))))
        let stats = LiveStats.from(samples)
        let last = try XCTUnwrap(samples.last)
        let marker = IngestPayload.Marker(end: last.timestamp, durationS: last.timestamp.timeIntervalSince(trip.startedAt),
                                          distanceM: stats.distanceM, latitude: last.latitude, longitude: last.longitude)

        XCTAssertEqual(samples.count, 40)
        XCTAssertEqual(stats.distanceM, try XCTUnwrap(tripInfo["distance_m"] as? Double), accuracy: 0.1)        // the app's own total agrees with the server's

        let data = try IngestPayload.body(samples: samples, trip: trip, marker: marker)
        let ours = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let expected = try XCTUnwrap(doc["body"] as? NSDictionary)
        XCTAssertEqual(ours, expected)
    }

    func testTheMarkerIsLastAndRepeatsTheTripId() throws {
        let trip = TripRecord(tripId: "2026-09-28T09:15:00Z#a1b2c3d4", deviceId: "dev", ownerEmail: "x@y.z", startedAt: makeSample(0).timestamp)
        let marker = IngestPayload.Marker(end: makeSample(60).timestamp, durationS: 60, distanceM: 1234.56, latitude: 47, longitude: 8)
        let data = try IngestPayload.body(samples: [makeSample(0), makeSample(5)], trip: trip, marker: marker)
        let locations = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["locations"] as? [[String: Any]])
        XCTAssertEqual(locations.count, 3)
        let last = try XCTUnwrap(locations.last?["properties"] as? [String: Any])
        XCTAssertEqual(last["type"] as? String, "trip")
        XCTAssertEqual(last["start"] as? String, trip.tripId)
        XCTAssertEqual(last["distance"] as? Double, 1234.6)                                         // rounded to a tenth of a metre
        for point in locations.dropLast() {
            XCTAssertEqual((point["properties"] as? [String: Any])?["trip_id"] as? String, trip.tripId)
        }
    }

    func testCoordinatesAreLongitudeFirst() throws {
        let f = IngestPayload.feature(for: makeSample(0, lat: 47.5, lon: 8.25), deviceId: "d", tripId: "t")
        let geometry = try XCTUnwrap(f["geometry"] as? [String: Any])
        XCTAssertEqual(geometry["coordinates"] as? [Double], [8.25, 47.5])
    }

    func testAnUnknownAltitudeAndBatteryAreLeftOut() throws {
        let f = IngestPayload.feature(for: makeSample(0, verticalAccuracy: -1, battery: -1), deviceId: "d", tripId: "t")
        let p = try XCTUnwrap(f["properties"] as? [String: Any])
        XCTAssertNil(p["altitude"])
        XCTAssertNil(p["battery_level"])
        XCTAssertNotNil(p["speed"])
    }

    func testAFixWithNonFiniteNumbersNeverReachesTheBody() throws {
        let trip = TripRecord(tripId: "t", deviceId: "d", ownerEmail: "x", startedAt: Date())
        let bad = makeSample(5, lat: .nan)
        let data = try IngestPayload.body(samples: [makeSample(0), bad], trip: trip, marker: nil)
        let locations = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["locations"] as? [Any])
        XCTAssertEqual(locations.count, 1)
    }
}
