import Foundation

/// The Rides tab's filters, turned into the query the server's GET /api/v1/rides understands (the same four the website's /rides page has).
struct RideFilters: Equatable {
    var dateFrom: Date?
    var dateTo: Date?
    var minKm = ""
    var maxKm = ""

    var isActive: Bool { !query(limit: 1, offset: 0).filter { $0.key != "limit" && $0.key != "offset" }.isEmpty }

    func query(limit: Int, offset: Int, calendar: Calendar = .current) -> [String: String] {
        var q = ["limit": String(limit), "offset": String(offset)]
        if let dateFrom { q["date_from"] = RideFilters.day(dateFrom, calendar: calendar) }
        if let dateTo { q["date_to"] = RideFilters.day(dateTo, calendar: calendar) }
        if let value = RideFilters.number(minKm) { q["min_km"] = value }
        if let value = RideFilters.number(maxKm) { q["max_km"] = value }
        return q
    }

    /// "2026-09-28", the local calendar day (the server compares it with the start of each ride).
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// A typed distance ("12,5" on a comma-decimal keyboard, " 40 ") as the plain number text the server parses; nil when it isn't a number.
    static func number(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value >= 0, value.isFinite else { return nil }
        return cleaned
    }
}
