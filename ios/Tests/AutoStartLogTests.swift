import XCTest

final class AutoStartLogTests: XCTestCase {
    private var url: URL!
    private var store: AutoStartLogStore!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ridelog-autostart-\(UUID().uuidString)/log.jsonl")
        store = AutoStartLogStore(url: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    func testAnEmptyDiaryIsEmpty() {
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testEntriesComeBackNewestFirstWithTheirDetails() {
        let t = Date(timeIntervalSince1970: 1_790_586_900)
        store.append(trigger: "shortcut", outcome: "started", detail: "permission: always", now: t)
        store.append(trigger: "motion", outcome: "ignored", detail: "The helmet is not connected.", now: t.addingTimeInterval(60))
        let entries = store.entries()
        XCTAssertEqual(entries.map(\.trigger), ["motion", "shortcut"])
        XCTAssertEqual(entries[1].outcome, "started")
        XCTAssertEqual(entries[1].detail, "permission: always")
        XCTAssertEqual(entries[1].date.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1)
    }

    func testTheDiaryKeepsOnlyTheNewestTwoHundred() {
        for i in 0..<(AutoStartLogStore.maxEntries + 25) { store.append(trigger: "t", outcome: "o\(i)") }
        let entries = store.entries(limit: 1000)
        XCTAssertEqual(entries.count, AutoStartLogStore.maxEntries)
        XCTAssertEqual(entries.first?.outcome, "o\(AutoStartLogStore.maxEntries + 24)")
        XCTAssertEqual(entries.last?.outcome, "o25")
    }

    func testTheLimitCutsTheList() {
        for i in 0..<10 { store.append(trigger: "t", outcome: "o\(i)") }
        XCTAssertEqual(store.entries(limit: 3).map(\.outcome), ["o9", "o8", "o7"])
    }

    func testClearEmptiesTheDiary() {
        store.append(trigger: "t", outcome: "o")
        store.clear()
        XCTAssertTrue(store.entries().isEmpty)
        store.append(trigger: "t", outcome: "again")
        XCTAssertEqual(store.entries().count, 1)
    }

    func testACorruptLineIsSkippedNotFatal() throws {
        store.append(trigger: "a", outcome: "one")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken json\n".utf8))
        try handle.close()
        store.append(trigger: "b", outcome: "two")
        XCTAssertEqual(store.entries().map(\.trigger), ["b", "a"])
    }
}
