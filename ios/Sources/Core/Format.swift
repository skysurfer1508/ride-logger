import Foundation

/// Turns the server's numbers and ISO timestamps into the words and digits the screens show. Foundation only (also compiled into the tests).
enum Format {
    // The server stores UTC timestamps (Python isoformat: "2026-09-27T14:03:11+00:00", or "...Z" as Overland sent them).
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoNaive: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMMyyyy")
        return f
    }()
    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func parseISO(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? isoPlain.date(from: text) ?? isoNaive.date(from: String(text.prefix(19)))
    }

    /// "Sunday, 27 September 2026" (in the phone's language, in local time).
    static func day(iso: String) -> String {
        parseISO(iso).map { dayFormatter.string(from: $0) } ?? String(iso.prefix(10))
    }

    /// "Sun, 27 Sep".
    static func shortDay(iso: String) -> String {
        parseISO(iso).map { shortDayFormatter.string(from: $0) } ?? String(iso.prefix(10))
    }

    /// "14:03".
    static func time(iso: String) -> String {
        parseISO(iso).map { timeFormatter.string(from: $0) } ?? ""
    }

    /// The time of day of a moment: "14:03".
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// 5.0 -> "5:00", 3725 -> "1:02:05". The ride timer and the HUD.
    static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Metres to kilometres with one decimal: 12345 -> "12.3".
    static func km(fromMeters meters: Double) -> String {
        String(format: "%.1f", meters / 1000)
    }

    /// m/s to whole km/h. A negative speed is what CoreLocation reports for "unknown", so it shows as 0.
    static func kmh(fromMps mps: Double) -> Int {
        mps < 0 ? 0 : Int((mps * 3.6).rounded())
    }

    /// "2026-W38" -> "W38".
    static func weekLabel(_ week: String) -> String {
        if let range = week.range(of: "-") { return String(week[range.upperBound...]) }
        return week
    }
}
