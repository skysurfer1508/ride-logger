import XCTest

func makeSample(_ seconds: Double, lat: Double = 47.0, lon: Double = 8.0, speed: Double = 10, accuracy: Double = 5,
                altitude: Double = 400, verticalAccuracy: Double = 8, battery: Double = 0.8, speedAccuracy: Double = -1, course: Double = -1, courseAccuracy: Double = -1) -> LocationSample {
    LocationSample(timestamp: Date(timeIntervalSince1970: 1_790_586_900 + seconds), latitude: lat, longitude: lon, speed: speed,
                   altitude: altitude, horizontalAccuracy: accuracy, verticalAccuracy: verticalAccuracy, batteryLevel: battery, speedAccuracy: speedAccuracy, course: course, courseAccuracy: courseAccuracy)
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
        XCTAssertEqual(d, 109.8, accuracy: 0.5)
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

final class LiveSnapshotTests: XCTestCase {
    func testTheSnapshotCarriesWhatTheLockScreenShows() {
        let fixes = [makeSample(0, lat: 47.0, speed: 20), makeSample(5, lat: 47.001, speed: 25)]
        let stats = LiveStats.from(fixes)
        let snap = RecordingLogic.snapshot(latest: fixes.last, stats: stats, now: fixes[1].timestamp.addingTimeInterval(1))
        XCTAssertEqual(snap.speedKmh, 90)                       // 25 m/s
        XCTAssertEqual(snap.maxKmh, 90)
        XCTAssertEqual(snap.distanceM, stats.distanceM)
        XCTAssertTrue(snap.gpsOK)
    }

    func testAStoppedBikeShowsZeroAndAWeakSignalIsFlagged() {
        let fix = makeSample(0, speed: 20, accuracy: 120)
        XCTAssertFalse(RecordingLogic.snapshot(latest: fix, stats: LiveStats.from([fix]), now: fix.timestamp).gpsOK)        // 120 m: weak
        let good = makeSample(0, speed: 20)
        XCTAssertEqual(RecordingLogic.snapshot(latest: good, stats: LiveStats.from([good]), now: good.timestamp.addingTimeInterval(10)).speedKmh, 0)
        let none = RecordingLogic.snapshot(latest: nil, stats: LiveStats(), now: Date())
        XCTAssertEqual(none, LiveSnapshot(speedKmh: 0, distanceM: 0, maxKmh: 0, gpsOK: false))
    }

    func testDistanceTextIsShortEnoughForTheIslandsCompactSlot() {
        XCTAssertEqual(LiveSnapshot(speedKmh: 0, distanceM: 12_345, maxKmh: 0, gpsOK: true).distanceCompact, "12.3")
        XCTAssertEqual(LiveSnapshot(speedKmh: 0, distanceM: 99_949, maxKmh: 0, gpsOK: true).distanceCompact, "99.9")
        XCTAssertEqual(LiveSnapshot(speedKmh: 0, distanceM: 123_456, maxKmh: 0, gpsOK: true).distanceCompact, "123")
        XCTAssertEqual(LiveSnapshot(speedKmh: 0, distanceM: 0, maxKmh: 0, gpsOK: true).distanceKm, "0.0")
    }

    func testTheSnapshotSurvivesTheRoundTripTheSystemDoesBetweenAppAndWidget() throws {
        let snap = LiveSnapshot(speedKmh: 87, distanceM: 4321.5, maxKmh: 112, gpsOK: true)
        XCTAssertEqual(try JSONDecoder().decode(LiveSnapshot.self, from: JSONEncoder().encode(snap)), snap)
    }
}

final class TrustedSpeedTests: XCTestCase {
    private func trusted(reported: Double, speedAccuracy: Double, horizontalAccuracy: Double = 5, lat: Double = 47.00009, at seconds: Double = 1,
                         previous: LocationSample?) -> Double {
        RecordingLogic.trustedSpeed(reported: reported, speedAccuracy: speedAccuracy, horizontalAccuracy: horizontalAccuracy, latitude: lat, longitude: 8.0,
                                    at: makeSample(seconds).timestamp, previous: previous)
    }

    func testAGoodReadingFromThePhoneIsUsedAsItIs() {
        XCTAssertEqual(trusted(reported: 12.34, speedAccuracy: 0.4, previous: makeSample(0, speed: 11)), 12.34)
        XCTAssertEqual(trusted(reported: 12.34, speedAccuracy: 1.5, previous: makeSample(0, speed: 11)), 12.34)        // right at the limit
        XCTAssertEqual(trusted(reported: 0, speedAccuracy: 0.2, previous: makeSample(0, speed: 11)), 0)               // a true standstill is a real reading
    }

    func testAnUnknownAccuracyIsTrustedLikeRidesFromBeforeTheFieldExisted() {
        XCTAssertEqual(trusted(reported: 12.34, speedAccuracy: -1, previous: nil), 12.34)
    }

    func testAPoorReadingBecomesTheSpeedBetweenTwoGoodPositions() {
        // 0.00009 degrees of latitude is 10.0 m, in one second
        let v = trusted(reported: 25, speedAccuracy: 3.0, previous: makeSample(0, lat: 47.0, speed: 11, accuracy: 5))
        XCTAssertEqual(v, 10.0, accuracy: 0.05)
    }

    func testPoorPositionsAreNotUsedToWorkOutASpeedTheLastSpeedIsKeptInstead() {
        XCTAssertEqual(trusted(reported: 25, speedAccuracy: 3.0, horizontalAccuracy: 25, previous: makeSample(0, lat: 47.0, speed: 11, accuracy: 5)), 11)
        XCTAssertEqual(trusted(reported: 25, speedAccuracy: 3.0, previous: makeSample(0, lat: 47.0, speed: 11, accuracy: 25)), 11)
    }

    func testAnUnknownSpeedWithNothingToGoOnIsZeroNeverNegative() {
        XCTAssertEqual(trusted(reported: -1, speedAccuracy: -1, previous: nil), 0)
        XCTAssertEqual(trusted(reported: -1, speedAccuracy: -1, at: 20, previous: makeSample(0, speed: 11)), 0)         // the previous fix is too old to say anything
    }

    func testAnUnknownSpeedIsWorkedOutFromAccuratePositions() {
        XCTAssertEqual(trusted(reported: -1, speedAccuracy: -1, previous: makeSample(0, lat: 47.0, speed: 11, accuracy: 4)), 10.0, accuracy: 0.05)
    }

    func testTheSpeedIsWorkedOutOverTheRealTimeBetweenFixesNotTheRoundedStamps() {
        // two fixes 1.99 s apart that are stamped 1 s apart (100.0 -> 100, 101.99 -> 101): 20 m in 1.99 s is 10 m/s, not 20
        let previous = makeSample(0, lat: 47.0, speed: 11, accuracy: 4)
        let real = previous.timestamp.addingTimeInterval(1.99)
        let v = RecordingLogic.trustedSpeed(reported: -1, speedAccuracy: -1, horizontalAccuracy: 4, latitude: 47.00018, longitude: 8.0, at: real, previous: previous)
        XCTAssertEqual(v, 20.0 / 1.99, accuracy: 0.05)
        let stampedOnly = RecordingLogic.trustedSpeed(reported: -1, speedAccuracy: -1, horizontalAccuracy: 4, latitude: 47.00018, longitude: 8.0, at: makeSample(1).timestamp, previous: previous)
        XCTAssertEqual(stampedOnly, 20.0, accuracy: 0.05)                                                            // what the rounded stamps used to give
    }

    func testThePreviousFixsRealTimeWinsOverItsRoundedStamp() {
        // the previous fix was really at 0.9 s past its stamp, this one at 1.9 s past the next: 1 s apart, as the stamps say
        let previous = makeSample(0, lat: 47.0, speed: 11, accuracy: 4)
        let v = RecordingLogic.trustedSpeed(reported: -1, speedAccuracy: -1, horizontalAccuracy: 4, latitude: 47.00009, longitude: 8.0,
                                            at: previous.timestamp.addingTimeInterval(2.0), previous: previous, previousTime: previous.timestamp.addingTimeInterval(0.9))
        XCTAssertEqual(v, 10.0 / 1.1, accuracy: 0.05)
    }

    func testAGapTooLongToMeasureASpeedFallsBackToTheReportedOne() {
        XCTAssertEqual(trusted(reported: 7, speedAccuracy: 3.0, at: 10, previous: makeSample(0, speed: 11)), 7)
    }

    func testSamplesSavedBeforeTheSpeedAccuracyExistedStillLoad() throws {
        let json = #"{"timestamp":"2026-09-28T09:15:00Z","latitude":47.0,"longitude":8.0,"speed":12.5,"altitude":400,"horizontalAccuracy":5,"verticalAccuracy":8,"batteryLevel":0.8}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sample = try decoder.decode(LocationSample.self, from: Data(json.utf8))
        XCTAssertEqual(sample.speed, 12.5)
        XCTAssertEqual(sample.speedAccuracy, -1)
    }

    func testSamplesSavedBeforeTheCourseExistedStillLoadWithoutOne() throws {
        let json = #"{"timestamp":"2026-09-28T09:15:00Z","latitude":47.0,"longitude":8.0,"speed":12.5,"altitude":400,"horizontalAccuracy":5,"verticalAccuracy":8,"batteryLevel":0.8,"speedAccuracy":0.4}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sample = try decoder.decode(LocationSample.self, from: Data(json.utf8))
        XCTAssertEqual(sample.course, -1)
        XCTAssertEqual(sample.courseAccuracy, -1)
    }

    func testTheCourseIsKeptWhenASampleIsSavedAndRead() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sample = makeSample(5, speed: 8.2, course: 271.5, courseAccuracy: 3)
        let back = try decoder.decode(LocationSample.self, from: encoder.encode(sample))
        XCTAssertEqual(back, sample)
        XCTAssertEqual(back.course, 271.5)
    }

    func testTheSpeedAccuracyIsKeptWhenASampleIsSavedAndRead() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sample = makeSample(5, speed: 8.2, speedAccuracy: 0.35)
        XCTAssertEqual(try decoder.decode(LocationSample.self, from: encoder.encode(sample)), sample)
    }
}
