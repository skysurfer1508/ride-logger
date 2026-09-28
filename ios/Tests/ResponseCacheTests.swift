import XCTest

final class ResponseCacheTests: XCTestCase {
    private var original: URL!

    override func setUp() {
        super.setUp()
        original = ResponseCache.directory
        ResponseCache.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ridelog-cache-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        ResponseCache.clear()
        ResponseCache.directory = original
        super.tearDown()
    }

    func testKeyIsStableAndIgnoresQueryOrder() {
        let a = ResponseCache.key(path: "rides", query: ["limit": "50", "offset": "0"])
        let b = ResponseCache.key(path: "rides", query: ["offset": "0", "limit": "50"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "82a2385fcaf3e390bcf8d40fffe25e11.json")          // sha256("rides?limit=50&offset=0"), first 32 hex digits
        XCTAssertNotEqual(a, ResponseCache.key(path: "rides", query: ["limit": "50", "offset": "50"]))
    }

    func testStoreLoadAndClear() {
        let key = ResponseCache.key(path: "home", query: [:])
        XCTAssertNil(ResponseCache.load(key: key))
        ResponseCache.store(Data("{\"ok\":true}".utf8), key: key)
        XCTAssertEqual(ResponseCache.load(key: key), Data("{\"ok\":true}".utf8))
        ResponseCache.clear()
        XCTAssertNil(ResponseCache.load(key: key))
    }
}
