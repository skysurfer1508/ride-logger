import XCTest

final class TripStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TripStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ridelog-trips-test-\(UUID().uuidString)", isDirectory: true)
        store = TripStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func record(_ id: String, start: Double = 0, ended: Double? = nil, uploaded: Int = 0, markerSent: Bool = false) -> TripRecord {
        TripRecord(tripId: id, deviceId: "dev", ownerEmail: "a@b.c", startedAt: makeSample(start).timestamp,
                   endedAt: ended.map { makeSample($0).timestamp }, uploadedCount: uploaded, markerSent: markerSent)
    }

    func testFileNamesAreSafeForAnyTripId() {
        XCTAssertEqual(TripStore.fileName(for: "2026-09-28T09:15:00Z#a1b2c3d4"), "2026-09-28T09_15_00Z_a1b2c3d4")
        XCTAssertFalse(TripStore.fileName(for: "../../etc/passwd").contains("/"))
    }

    func testSamplesComeBackInTheOrderTheyWereWritten() throws {
        try store.begin(record("t1"))
        for i in 0..<5 { try store.append(makeSample(Double(i) * 5, lat: 47 + Double(i) * 0.001), tripId: "t1") }
        let back = store.samples(tripId: "t1")
        XCTAssertEqual(back.count, 5)
        XCTAssertEqual(back.map(\.latitude), [47.0, 47.001, 47.002, 47.003, 47.004])
        XCTAssertEqual(back[0], makeSample(0, lat: 47))
    }

    func testTheRecordRoundTripsAndKeepsUploadProgress() throws {
        try store.begin(record("t1"))
        var saved = try XCTUnwrap(store.record(tripId: "t1"))
        XCTAssertEqual(saved.uploadedCount, 0)
        saved.uploadedCount = 100
        saved.endedAt = makeSample(60).timestamp
        saved.markerSent = true
        try store.save(saved)
        XCTAssertEqual(store.record(tripId: "t1"), saved)
        XCTAssertNil(store.record(tripId: "nope"))
    }

    func testARideCutOffMidWriteLosesOnlyItsLastFixAndCanBeResumed() throws {
        try store.begin(record("t1"))
        try store.append(makeSample(0), tripId: "t1")
        try store.append(makeSample(5, lat: 47.001), tripId: "t1")
        // simulate the app being killed halfway through writing the third line
        let url = directory.appendingPathComponent(TripStore.fileName(for: "t1") + ".samples.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"2026-09-28T09:15:1"#.utf8))
        try handle.close()

        XCTAssertEqual(store.samples(tripId: "t1").count, 2)                 // the torn line is skipped
        store.repairTail(tripId: "t1")
        try store.append(makeSample(15, lat: 47.003), tripId: "t1")
        XCTAssertEqual(store.samples(tripId: "t1").count, 3)                 // ...and the next fix is not glued onto it
    }

    func testRecordsListOldestFirstAndIgnoreOtherFiles() throws {
        try store.begin(record("late", start: 1000))
        try store.begin(record("early", start: 10))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        XCTAssertEqual(store.records().map(\.tripId), ["early", "late"])
    }

    func testDeleteRemovesBothFiles() throws {
        try store.begin(record("t1"))
        try store.append(makeSample(0), tripId: "t1")
        store.delete(tripId: "t1")
        XCTAssertNil(store.record(tripId: "t1"))
        XCTAssertTrue(store.samples(tripId: "t1").isEmpty)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: directory.path)).count, 0)
    }

    func testPurgeKeepsTheNewestUploadedRidesAndNeverTouchesUnfinishedWork() throws {
        // three fully uploaded rides, one finished but not yet uploaded, one still being recorded
        for (i, id) in ["u1", "u2", "u3"].enumerated() {
            try store.begin(record(id, start: Double(i) * 100, ended: Double(i) * 100 + 50, uploaded: 1, markerSent: true))
            try store.append(makeSample(Double(i) * 100), tripId: id)
        }
        try store.begin(record("waiting", start: 400, ended: 450, uploaded: 0, markerSent: false))
        try store.append(makeSample(400), tripId: "waiting")
        try store.begin(record("live", start: 500))
        store.purgeUploaded(keeping: 2)
        XCTAssertEqual(Set(store.records().map(\.tripId)), ["u2", "u3", "waiting", "live"])
        store.purgeUploaded(keeping: 0)
        XCTAssertEqual(Set(store.records().map(\.tripId)), ["waiting", "live"])
    }
}
