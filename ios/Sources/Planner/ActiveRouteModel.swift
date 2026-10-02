import Combine
import CoreLocation
import Foundation

/// The route the rider is following, if any: kept in a file (so it is still there after the app is closed), drawn on the Traffic and Record maps, and
/// compared with the rider's position by the Record tab. One for the whole app.
@MainActor
final class ActiveRouteModel: ObservableObject {
    @Published private(set) var route: ActiveRoute?
    private var line: RouteFollow.Line?
    private var hint: Int?
    private let file: ActiveRouteFile

    init(file: ActiveRouteFile = .standard) {
        self.file = file
        if let saved = file.load() { apply(saved) }
    }

    var coordinates: [CLLocationCoordinate2D] {
        (route?.points ?? []).filter { $0.count >= 2 }.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }

    func set(_ newRoute: ActiveRoute) {
        file.save(newRoute)
        apply(newRoute)
    }

    func clear() {
        file.clear()
        route = nil
        line = nil
        hint = nil
    }

    /// Where a position is on the route. The segment of the last answer on the line is remembered so the next one keeps moving forward along it.
    func progress(lat: Double, lon: Double) -> RouteFollow.Progress? {
        guard let line else { return nil }
        let result = RouteFollow.progress(lat: lat, lon: lon, on: line, hint: hint)
        if !result.isOffRoute { hint = result.segment }
        return result
    }

    private func apply(_ newRoute: ActiveRoute) {
        route = newRoute
        line = RouteFollow.line(newRoute.points)
        hint = nil
    }
}
