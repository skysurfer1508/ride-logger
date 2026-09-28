import MapKit
import SwiftUI

extension Array where Element == [Double] {
    /// The server's [[lat, lon], ...] as map coordinates (a malformed pair is skipped).
    var coordinates: [CLLocationCoordinate2D] {
        compactMap { pair in pair.count >= 2 ? CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]) : nil }
    }
}

enum MapFit {
    /// A rectangle that shows every point with some margin, and never smaller than about 600 m across (one point still gets a sensible view).
    static func rect(for routes: [[CLLocationCoordinate2D]]) -> MKMapRect? {
        var rect = MKMapRect.null
        for route in routes {
            for coordinate in route {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
        }
        if rect.isNull { return nil }
        let perMeter = MKMapPointsPerMeterAtLatitude(MKMapPoint(x: rect.midX, y: rect.midY).coordinate.latitude)
        let minimum = 600 * perMeter
        let pad = max(rect.width, rect.height, minimum) * 0.15
        var padded = rect.insetBy(dx: -pad, dy: -pad)
        if padded.width < minimum { padded = padded.insetBy(dx: -(minimum - padded.width) / 2, dy: 0) }
        if padded.height < minimum { padded = padded.insetBy(dx: 0, dy: -(minimum - padded.height) / 2) }
        return padded
    }
}

/// One or many routes on a dark map, in the accent colour.
struct RouteMap: View {
    let routes: [[CLLocationCoordinate2D]]
    var showEndpoints = false
    var interactive = true

    var body: some View {
        let fit = MapFit.rect(for: routes)
        Map(initialPosition: fit.map { MapCameraPosition.rect($0) } ?? MapCameraPosition.automatic,
            interactionModes: interactive ? .all : []) {
            ForEach(routes.indices, id: \.self) { index in
                MapPolyline(coordinates: routes[index])
                    .stroke(Theme.accent, lineWidth: routes.count > 1 ? 2 : 4)
            }
            if showEndpoints, let route = routes.first, let start = route.first, let end = route.last {
                Annotation("Start", coordinate: start) { EndpointDot(color: Theme.success) }
                Annotation("Finish", coordinate: end) { EndpointDot(color: Theme.danger) }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .id(routes.reduce(0) { $0 + $1.count })     // a refreshed answer with a different route redraws the camera
    }
}

private struct EndpointDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}
