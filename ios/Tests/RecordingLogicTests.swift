import XCTest

func makeSample(_ seconds: Double, lat: Double = 47.0, lon: Double = 8.0, speed: Double = 10, accuracy: Double = 5,
                altitude: Double = 400, verticalAccuracy: Double = 8, battery: Double = 0.8) -> LocationSample {
    LocationSample(timestamp: Date(timeIntervalSince1970: 1_790_586_900 + seconds), latitude: lat, longitude: lon, speed: speed,
                   altitude: altitude, horizontalAccuracy: accuracy, verticalAccuracy: verticalAccuracy, batteryLevel: battery)
}

final class LiveStatsTests: XCTestCase {
    func testDistanceOfOneThousandthOfADegreeOfLatitude() {
        let stats = LiveStats.from([makeSample(0), makeSample(5, lat: 47.001)])
        XCTAssertEqual(stats.distanceM, 111.19, accuracy: 0.05)          // 6371000 m * 0.001 degrees in radians
        XCTAssertEqual(stats.acceptedCount, 2)
    }

    func testHaversineMatchesThePythonServer() {
        // app/geo.py haversine_m(47.3769, 8.5417, 47.3778, 8.5423)
        let d = Geo.haversineM(lat1: 47.3769, lon1: 8.5417, lat2: 47.3778, lon2: 8.5423)
        XCTAssertEqual(d, 107.9, accuracy: 0.5)
    }

    func testAFixWithPoorAccuracyIsIgnoredLikeTheServerDoes() {
        let stats = LiveStats.from([makeSample(0), makeSample(5, lat: 47.001, accuracy: 51), makeSample(10, lat: 47.001, accuracy: -1)])
        XCTAssertEqual(stats.distanceM, 0)
        XCTAssertEqual(stats.acceptedCount, 1)
        XCTAssertEqual(stats.receivedCount, 3)
    }

    func testAnImpossibleJumpIsIgnored() {
        // 1 degree of latitude (111 km) in 5 seconds is 22 000 m/s
        let stats = LiveStats.from([makeSample(0), makeSample(5, lat: 48.0), makeSample(10, lat: 47.0005)])
        XCTAssertEqual(stats.distanceM, Geo.haversineM(lat1: 47.0, lon1: 8.0, lat2: 47.0005, lon2: 8.0), accuracy: 0.01)
    }

    func testMaxSpeedIgnoresUnknownSpeeds() {
        let stats = LiveStats.from([makeSample(0, speed: 12), makeSample(5, lat: 47.0002, speed: -1), makeSample(10, lat: 47.0004, speed: 30)])
        XCTAssertEqual(stats.maxSpeedMps, 30)
        XCTAssertEqual(LiveStats.from([makeSample(0, speed: -1)]).maxSpeedMps, 0)
    }

    func testAnEmptyRide() {
        XCTAssertEqual(LiveStats(), LiveStats.from([]))
        XCTAssertEqual(LiveStats().distanceM, 0)
    }
}

final class RecordingLogicTests: XCTestCase {
    func testTheSpeedFallsToZeroWhenNoFixArrivesForAWhile() {
        let sample = makeSample(0, speed: 20)
        XCTAssertEqual(RecordingLogic.displayedSpeedKmh(latest: sample, now: sample.timestamp.addingTimeInterval(1)), 72)
        XCTAssertEqual(RecordingLogic.displayedSpeedKmh(latest: sample, now: sample.timestamp.addingTimeInterval(4)), 72)
        XCTAssertEqual(RecordingLogic.displayedSpeedKmh(latest: sample, now: sample.timestamp.addingTimeInterval(5)), 0)
        XCTAssertEqual(RecordingLogic.displayedSpeedKmh(latest: nil, now: Date()), 0)
        XCTAssertEqual(RecordingLogic.displayedSpeedKmh(latest: makeSample(0, speed: -1), now: sample.timestamp), 0)
    }

    func testAverageSpeed() {
        XCTAssertEqual(RecordingLogic.averageKmh(distanceM: 10_000, elapsed: 600), 60)
        XCTAssertEqual(RecordingLogic.averageKmh(distanceM: 10_000, elapsed: 0), 0)
    }

    func testGPSQuality() {
        let now = makeSample(0).timestamp
        XCTAssertEqual(RecordingLogic.quality(of: makeSample(0, accuracy: 5), now: now), .good)
        XCTAssertEqual(RecordingLogic.quality(of: makeSample(0, accuracy: 35), now: now), .fair)
        XCTAssertEqual(RecordingLogic.quality(of: makeSample(0, accuracy: 120), now: now), .weak)
        XCTAssertEqual(RecordingLogic.quality(of: makeSample(0, accuracy: 5), now: now.addingTimeInterval(16)), .none)
        XCTAssertEqual(RecordingLogic.quality(of: nil, now: now), .none)
    }

    func testAVeryShortRideIsNotKept() {
        XCTAssertFalse(RecordingLogic.isWorthKeeping(sampleCount: 0))
        XCTAssertFalse(RecordingLogic.isWorthKeeping(sampleCount: 1))
        XCTAssertTrue(RecordingLogic.isWorthKeeping(sampleCount: 2))
    }
}

final class UploadPlanTests: XCTestCase {
    func testBatchesWalkThroughTheRide() {
        XCTAssertEqual(UploadPlan.nextRange(total: 250, uploaded: 0), 0..<100)
        XCTAssertEqual(UploadPlan.nextRange(total: 250, uploaded: 100), 100..<200)
        XCTAssertEqual(UploadPlan.nextRange(total: 250, uploaded: 200), 200..<250)
        XCTAssertTrue(UploadPlan.nextRange(total: 250, uploaded: 250).isEmpty)
    }

    func testNonsenseCursorsAreClamped() {
        XCTAssertEqual(UploadPlan.nextRange(total: 10, uploaded: 99), 10..<10)
        XCTAssertEqual(UploadPlan.nextRange(total: 10, uploaded: -5), 0..<10)
        XCTAssertEqual(UploadPlan.nextRange(total: 10, uploaded: 0, batchSize: 0), 0..<1)
    }

    func testOnlyTheLastBatchOfAFinishedRideCarriesTheMarker() {
        XCTAssertFalse(UploadPlan.carriesMarker(range: 0..<100, total: 250, finished: true, markerSent: false))
        XCTAssertTrue(UploadPlan.carriesMarker(range: 200..<250, total: 250, finished: true, markerSent: false))
        XCTAssertTrue(UploadPlan.carriesMarker(range: 250..<250, total: 250, finished: true, markerSent: false))      // marker alone
        XCTAssertFalse(UploadPlan.carriesMarker(range: 200..<250, total: 250, finished: false, markerSent: false))    // still recording
        XCTAssertFalse(UploadPlan.carriesMarker(range: 250..<250, total: 250, finished: true, markerSent: true))      // already sent
    }
}

final class TripRecordTests: XCTestCase {
    func testTripIdIsTheStartTimeAndARandomSuffix() {
        XCTAssertEqual(TripRecord.makeId(start: Date(timeIntervalSince1970: 1_790_586_900), suffix: "a1b2c3d4"), "2026-09-28T09:15:00Z#a1b2c3d4")
    }

    func testARecordSavedByAnOlderVersionStillLoads() throws {
        let json = #"{"tripId":"t#1","deviceId":"d","ownerEmail":"a@b.c","startedAt":"2026-09-28T09:15:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TripRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.uploadedCount, 0)
        XCTAssertFalse(record.markerSent)
        XCTAssertFalse(record.isFinished)
    }
}
