import Foundation

/// The diary of automatic starts: when, what triggered it, what happened. Auto-start can fail in ways only the phone shows (a locked screen, a killed
/// process, a Bluetooth device iOS does not report), so every attempt is written down and shown in Settings instead of being guessed at.
struct AutoStartLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    /// shortcut | motion | notification | watch | stop
    let trigger: String
    let outcome: String
    let detail: String
}

/// JSON lines in Application Support, newest appended last, trimmed to the last `maxEntries`. Foundation only; tested in Tests/AutoStartLogTests.swift.
final class AutoStartLogStore {
    static let maxEntries = 200

    private let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(url: URL = AutoStartLogStore.defaultURL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RideLog", isDirectory: true).appendingPathComponent("autostart-log.jsonl")
    }

    @discardableResult
    func append(trigger: String, outcome: String, detail: String = "", now: Date = Date()) -> AutoStartLogEntry {
        let entry = AutoStartLogEntry(id: UUID(), date: now, trigger: trigger, outcome: outcome, detail: detail)
        var all = readAll()
        all.append(entry)
        if all.count > Self.maxEntries { all.removeFirst(all.count - Self.maxEntries) }
        write(all)
        return entry
    }

    /// Newest first.
    func entries(limit: Int = 50) -> [AutoStartLogEntry] {
        Array(readAll().reversed().prefix(limit))
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func readAll() -> [AutoStartLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { try? decoder.decode(AutoStartLogEntry.self, from: Data($0)) }
    }

    private func write(_ entries: [AutoStartLogEntry]) {
        var data = Data()
        for entry in entries {
            if let line = try? encoder.encode(entry) {
                data.append(line)
                data.append(0x0A)
            }
        }
        try? data.write(to: url, options: .atomic)
    }
}
