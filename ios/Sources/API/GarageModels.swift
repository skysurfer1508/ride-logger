import Foundation

// GET/POST /api/v1/garage/* (app/routers/api_garage.py). Foundation only: also compiled into the test target, and
// Tests/Fixtures/api_garage*.json (written by the server's tests) lock the shapes decoded here.

struct GarageOverview: Decodable {
    let bikes: [BikeSummary]
}

/// The service that is closest to being due on a bike (the server's status fields plus the item's name).
struct NextDue: Decodable, Equatable {
    let name: String
    let state: String
    let dueKm: Double?
    let dueDate: String?
    let remainingKm: Double?
    let remainingDays: Int?
    let limitedBy: String?
}

struct BikeSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let make: String
    let model: String
    let year: Int?
    let isDefault: Bool
    let odometerKm: Double
    let overdue: Int
    let soon: Int
    let nextDue: NextDue?

    /// "Aprilia 1100 RR 2021", or just the name's companions that exist.
    var subtitle: String {
        [make, model, year.map { String($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct BikeInfo: Decodable, Equatable {
    let id: Int
    let name: String
    let make: String
    let model: String
    let year: Int?
    let isDefault: Bool
    let startOdometerKm: Double
    let startDate: String
    let odometerKm: Double
    let riddenKm: Double
}

struct ServiceStatus: Decodable, Equatable {
    /// never_done | ok | soon | overdue
    let state: String
    let dueKm: Double?
    let dueDate: String?
    let remainingKm: Double?
    let remainingDays: Int?
    /// "km" or "date": which interval is the tighter one right now.
    let limitedBy: String?

    var serviceState: ServiceState { ServiceState(rawValue: state) ?? .neverDone }
}

enum ServiceState: String {
    case neverDone = "never_done", ok, soon, overdue
}

struct ServiceItem: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let intervalKm: Double?
    let intervalMonths: Int?
    let lastDoneDate: String?
    let lastDoneKm: Double?
    let status: ServiceStatus

    /// "every 6000 km or 12 months".
    var intervalText: String {
        var parts: [String] = []
        if let km = intervalKm { parts.append("\(Int(km.rounded())) km") }
        if let months = intervalMonths { parts.append(months == 1 ? "1 month" : "\(months) months") }
        return "every " + parts.joined(separator: " or ")
    }
}

struct ServiceLogEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let itemId: Int
    let itemName: String
    let doneDate: String
    let odometerKm: Double?
    let cost: Double?
    let note: String
}

struct FuelFill: Decodable, Identifiable, Equatable {
    let id: Int
    let date: String
    let odometerKm: Double
    let litres: Double
    let price: Double?
    let fullTank: Bool
    let lPer100Km: Double?
    let kmSince: Double?
}

struct FuelBlock: Decodable, Equatable {
    let fills: [FuelFill]
    let averageLPer100Km: Double?
    let measuredKm: Double
    let totalLitres: Double
    let totalSpent: Double
    let averagePricePerLitre: Double?
}

struct Expense: Decodable, Identifiable, Equatable {
    let id: Int
    let date: String
    let category: String
    let amount: Double
    let note: String
}

struct GarageTotals: Decodable, Equatable {
    let fuel: Double
    let service: Double
    let other: Double
    let all: Double
    let perKm: Double?
}

struct BikeDetail: Decodable, Equatable {
    let bike: BikeInfo
    let items: [ServiceItem]
    let serviceLog: [ServiceLogEntry]
    let fuel: FuelBlock
    let expenses: [Expense]
    let totals: GarageTotals
}

struct DeletedResponse: Decodable {
    let deleted: Int
}

struct BikeAssignment: Decodable {
    let rideId: Int
    let bikeId: Int?
}

// MARK: - words

enum GarageLogic {
    /// The headline for a service: "Overdue by 200 km", "500 km left", "in 30 days", "Not done yet".
    static func dueText(_ status: ServiceStatus) -> String {
        switch status.serviceState {
        case .neverDone:
            return "Not done yet"
        case .overdue:
            var parts: [String] = []
            if let km = status.remainingKm, km < 0 { parts.append("\(Int((-km).rounded())) km") }
            if let days = status.remainingDays, days < 0 { parts.append(days == -1 ? "1 day" : "\(-days) days") }
            return "Overdue by " + parts.joined(separator: " and ")
        case .ok, .soon:
            let km = status.remainingKm.map { "\(Int($0.rounded())) km left" }
            let days = status.remainingDays.map(daysText)
            switch status.limitedBy {
            case "date": return days ?? km ?? ""
            default: return km ?? days ?? ""
            }
        }
    }

    /// The other interval, when there is one: shown in a smaller line under the headline.
    static func dueDetail(_ status: ServiceStatus) -> String? {
        guard status.serviceState != .neverDone, status.serviceState != .overdue, let km = status.remainingKm, let days = status.remainingDays else { return nil }
        return status.limitedBy == "date" ? "\(Int(km.rounded())) km left" : daysText(days)
    }

    static func daysText(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days == 1 { return "tomorrow" }
        if days <= 90 { return "in \(days) days" }
        return "in about \(days / 30) months"
    }

    static func money(_ amount: Double) -> String { String(format: "%.2f", amount) }

    static func consumption(_ litresPer100km: Double) -> String { String(format: "%.1f L/100 km", litresPer100km) }

    static func odometer(_ km: Double) -> String { String(format: "%.0f km", km) }
}

/// When to remind about services that are due. The phone cannot work out "500 km left" while the app is closed, so it looks when the app opens and
/// schedules at most one notification for the next evening.
enum ReminderPolicy {
    static let repeatAfterDays = 3.0

    static func shouldNotify(due: Int, lastNotified: Date?, now: Date) -> Bool {
        guard due > 0 else { return false }
        guard let last = lastNotified else { return true }
        return now.timeIntervalSince(last) >= repeatAfterDays * 86_400
    }

    static func text(overdue: Int, soon: Int) -> String {
        var parts: [String] = []
        if overdue > 0 { parts.append(overdue == 1 ? "1 service is overdue" : "\(overdue) services are overdue") }
        if soon > 0 { parts.append(soon == 1 ? "1 is due soon" : "\(soon) are due soon") }
        return parts.joined(separator: ", ") + "."
    }
}
