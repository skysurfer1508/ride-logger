import Foundation

// POST /api/v1/import/gpx (app/routers/api_v1.py, app/views.py import_tracks). Foundation only: also compiled into the test target.

struct ImportResult: Decodable, Equatable {
    /// imported | already_imported | already_have_this_ride | skipped
    let status: String
    let name: String
    let rideId: Int?
    let points: Int
    let reason: String?
}

struct ImportResponse: Decodable, Equatable {
    let results: [ImportResult]
    let imported: Int
}

enum ImportSummary {
    /// One plain sentence (or two) for the banner after importing a file.
    static func text(_ response: ImportResponse) -> String {
        let already = response.results.filter { $0.status == "already_imported" || $0.status == "already_have_this_ride" }.count
        let skipped = response.results.filter { $0.status == "skipped" }
        var parts: [String] = []
        if response.imported > 0 { parts.append("Imported \(response.imported) ride\(response.imported == 1 ? "" : "s").") }
        if already > 0 { parts.append(already == 1 ? "1 was already in RideLog." : "\(already) were already in RideLog.") }
        if let first = skipped.first { parts.append((first.reason ?? "A track could not be used.") + (skipped.count > 1 ? " (\(skipped.count) tracks skipped.)" : "")) }
        return parts.isEmpty ? "The file had nothing to import." : parts.joined(separator: " ")
    }
}
