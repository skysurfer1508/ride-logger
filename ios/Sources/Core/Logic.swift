import Foundation

// Pure decisions, no UIKit: kept apart so they can be unit-tested (Tests/LogicTests.swift, Cmd+U in Xcode).

extension Notification.Name {
    /// Posted when the set of rides on the server changed (one was deleted, or a recorded ride finished uploading): screens that show rides reload.
    static let ridesChanged = Notification.Name("ridelog.ridesChanged")
}

/// The tabs, in order.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, rides, record, traffic, settings

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .rides: return "Rides"
        case .record: return "Record"
        case .traffic: return "Traffic"
        case .settings: return "Settings"
        }
    }
    /// SF Symbols closest to the website's sections.
    var symbol: String {
        switch self {
        case .home: return "gauge.with.dots.needle.bottom.50percent"
        case .rides: return "list.bullet"
        case .record: return "record.circle"
        case .traffic: return "car.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum Logic {
    /// base64url without padding (RFC 4648 section 5), as the server expects.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Extracts ?code=... from the ridelogger://auth callback.
    static func code(fromCallback url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    /// A number typed into a settings field: accepts a comma as the decimal mark ("7,5"), rejects blanks, text, NaN and infinity.
    static func parseDecimal(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// The upload address shown in Settings and used by the recorder: the site plus the path the server reports.
    static func ingestURL(base: URL, path: String) -> URL {
        URL(string: path, relativeTo: base)?.absoluteURL ?? base
    }
}
