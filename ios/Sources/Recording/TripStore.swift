import Foundation

/// Rides on this phone, as plain files, so nothing is lost if the app is killed or there is no signal:
///   <name>.trip.json      the TripRecord (who, when, how much the server has)
///   <name>.samples.jsonl  one location fix per line, appended the moment it arrives
/// Foundation only. Used from the main thread only (the recorder and the uploader both run there).
///
/// The files use the default file protection (readable after the first unlock since boot), NOT "complete": a ride keeps writing fixes while the
/// phone is locked in a pocket, and "complete" protection would make every write fail then.
final class TripStore {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RideLog", isDirectory: true).appendingPathComponent("trips", isDirectory: true)
    }

    let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]          // never pretty-printed: a sample must stay on one line
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL = TripStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: files

    /// A file-system-safe name for a trip id ("2026-09-28T09:15:00Z#a1b2c3d4" -> "2026-09-28T09_15_00Z_a1b2c3d4").
    static func fileName(for tripId: String) -> String {
        String(tripId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    private func recordURL(_ tripId: String) -> URL { directory.appendingPathComponent(Self.fileName(for: tripId) + ".trip.json") }
    private func samplesURL(_ tripId: String) -> URL { directory.appendingPathComponent(Self.fileName(for: tripId) + ".samples.jsonl") }

    // MARK: records

    func begin(_ record: TripRecord) throws {
        try save(record)
        if !FileManager.default.fileExists(atPath: samplesURL(record.tripId).path) {
            FileManager.default.createFile(atPath: samplesURL(record.tripId).path, contents: nil)
        }
    }

    func save(_ record: TripRecord) throws {
        try encoder.encode(record).write(to: recordURL(record.tripId), options: .atomic)
    }

    func record(tripId: String) -> TripRecord? {
        guard let data = try? Data(contentsOf: recordURL(tripId)) else { return nil }
        return try? decoder.decode(TripRecord.self, from: data)
    }

    /// Every ride on the phone, oldest first.
    func records() -> [TripRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".trip.json") }
            .compactMap { name in (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap { try? decoder.decode(TripRecord.self, from: $0) } }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func delete(tripId: String) {
        try? FileManager.default.removeItem(at: recordURL(tripId))
        try? FileManager.default.removeItem(at: samplesURL(tripId))
    }

    // MARK: samples

    func append(_ sample: LocationSample, tripId: String) throws {
        var line = try encoder.encode(sample)
        line.append(0x0A)
        let url = samplesURL(tripId)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Every readable fix of a ride, in the order written. A line cut short by a crash is skipped.
    func samples(tripId: String) -> [LocationSample] {
        guard let data = try? Data(contentsOf: samplesURL(tripId)) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { try? decoder.decode(LocationSample.self, from: Data($0)) }
    }

    /// Before writing to a ride that was cut off: if its last line has no newline (a crash mid-write), end it, so the next fix starts a new line.
    func repairTail(tripId: String) {
        let url = samplesURL(tripId)
        guard let data = try? Data(contentsOf: url), let last = data.last, last != 0x0A,
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data([0x0A]))
    }

    // MARK: housekeeping

    /// Keeps the newest `keep` rides that are finished and fully uploaded as a local backup; deletes older ones. Rides that still have
    /// something to upload, or are still being recorded, are never touched.
    func purgeUploaded(keeping keep: Int) {
        let done = records().filter { $0.isFinished && $0.markerSent && $0.uploadedCount >= samples(tripId: $0.tripId).count }
        for old in done.dropLast(max(0, keep)) { delete(tripId: old.tripId) }
    }
}
