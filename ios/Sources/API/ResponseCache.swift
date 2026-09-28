import CryptoKit
import Foundation

/// The last good answer of each screen's GET, kept on the phone (Caches folder, so iOS may clear it and it is not backed up) so a screen can show
/// what it had instantly and refresh quietly, or still show something with no signal. Emptied when you sign out or the session ends.
/// Foundation + CryptoKit only; tested in Tests/ResponseCacheTests.swift.
enum ResponseCache {
    static var directory: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ridelog-responses", isDirectory: true)
    }()

    /// The file name for one request: a hash of the path and query, so nothing about the request shows in the name.
    static func key(path: String, query: [String: String]) -> String {
        let text = path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32) + ".json"
    }

    static func store(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key), options: [.atomic, .completeFileProtection])
    }

    static func load(key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(key))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
