import CoreLocation
import MapKit
import SwiftUI

/// Asks for location once so the map can show where you are and open there. (The Record tab uses the same permission.)
@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    func requestIfNeeded() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.status = manager.authorizationStatus }
    }
}

/// What the Traffic tab has loaded, and what it last asked for.
@MainActor
final class TrafficModel: ObservableObject {
    @Published private(set) var config: TrafficConfig?
    @Published private(set) var incidents: [TrafficIncident] = []
    @Published private(set) var webcams: [TrafficWebcam] = []
    @Published private(set) var unlocated = 0
    @Published private(set) var incidentsError: String?
    @Published private(set) var webcamsError: String?
    @Published private(set) var loading = false
    @Published private(set) var configError: String?
    @Published fileprivate(set) var roads: RoadsResponse?
    @Published fileprivate(set) var roadsError: String?
    @Published fileprivate(set) var roadsTooWide = false

    fileprivate let api: APIClient
    private var lastIncidents: TrafficLogic.Query?
    private var lastWebcams: TrafficLogic.Query?
    fileprivate var lastRoads: RoadsLogic.Fetched?
    fileprivate var roadsRetries = 0
    fileprivate var roadsRetry: Task<Void, Never>?

    init(api: APIClient) { self.api = api }

    func loadConfig() async {
        do {
            let loaded: TrafficConfig = try await api.get("traffic/config")
            config = loaded
            configError = nil
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    func refresh(lat: Double, lon: Double, radiusKm: Double, incidents wantIncidents: Bool, webcams wantWebcams: Bool, force: Bool) async {
        guard let config else { return }
        let now = Date()
        loading = true
        defer { loading = false }
        let query = ["lat": String(format: "%.4f", lat), "lon": String(format: "%.4f", lon), "radius_km": String(Int(radiusKm))]
        if wantIncidents, config.incidents, force || TrafficLogic.needsRefresh(last: lastIncidents, lat: lat, lon: lon, radiusKm: radiusKm, now: now) {
            do {
                let result: IncidentsResponse = try await api.get("traffic/incidents", query: query)
                incidents = result.incidents
                unlocated = result.unlocated
                incidentsError = nil
                lastIncidents = TrafficLogic.Query(lat: lat, lon: lon, radiusKm: radiusKm, at: now)
            } catch APIError.unauthorized {
                // AuthService takes over
            } catch {
                incidentsError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
        }
        if wantWebcams, config.webcams, force || TrafficLogic.needsRefresh(last: lastWebcams, lat: lat, lon: lon, radiusKm: min(radiusKm, 50), now: now, maxAge: 300) {
            do {
                let result: WebcamsResponse = try await api.get("traffic/webcams", query: ["lat": query["lat"]!, "lon": query["lon"]!, "radius_km": String(Int(min(radiusKm, 50)))])
                webcams = result.webcams
                webcamsError = nil
                lastWebcams = TrafficLogic.Query(lat: lat, lon: lon, radiusKm: min(radiusKm, 50), at: now)
            } catch APIError.unauthorized {
                // AuthService takes over
            } catch {
                webcamsError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
        }
    }
}

extension TrafficModel {
    /// The twisty roads in (and a margin around) the visible map. While the server is still working out which of them you have ridden it says so, and
    /// this asks again a few seconds later, a handful of times.
    func refreshRoads(visible: RoadsLogic.Box, force: Bool) async {
        guard RoadsLogic.canQuery(visible) else {
            roadsTooWide = true
            return
        }
        roadsTooWide = false
        let now = Date()
        guard force || RoadsLogic.needsRefresh(last: lastRoads, visible: visible, now: now) else { return }
        let box = RoadsLogic.queryBox(for: visible)
        let query = ["south": String(format: "%.4f", box.south), "west": String(format: "%.4f", box.west), "north": String(format: "%.4f", box.north),
                     "east": String(format: "%.4f", box.east), "limit": "100", "min_score": "35", "paved_only": "true"]
        do {
            let result: RoadsResponse = try await api.get("roads", query: query)
            roads = result
            roadsError = nil
            lastRoads = RoadsLogic.Fetched(box: box, at: now)
            if result.riddenStatus == "updating", roadsRetries < 5 {
                roadsRetries += 1
                roadsRetry?.cancel()
                roadsRetry = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshRoads(visible: visible, force: true)
                }
            } else if result.riddenStatus != "updating" {
                roadsRetries = 0
            }
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            roadsError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    func stopRoadsRetry() {
        roadsRetry?.cancel()
        roadsRetry = nil
        roadsRetries = 0
    }
}

struct TrafficView: View {
    let api: APIClient
    @StateObject private var model: TrafficModel
    @StateObject private var location = LocationAccess()
    @AppStorage("traffic.colours") private var showColours = true
    @AppStorage("traffic.incidents") private var showIncidents = true
    @AppStorage("traffic.webcams") private var showWebcams = true
    @AppStorage("traffic.works") private var showWorks = false
    @AppStorage("traffic.roads") private var showRoads = false
    @AppStorage("traffic.roads.unridden") private var onlyUnridden = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417), span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))))
    @State private var visible: MKCoordinateRegion?
    @State private var selectedIncident: TrafficIncident?
    @State private var selectedWebcam: TrafficWebcam?
    @State private var selectedRoad: TwistyRoad?
    @State private var hint: String?

    init(api: APIClient) {
        self.api = api
        _model = StateObject(wrappedValue: TrafficModel(api: api))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                VStack(spacing: 8) {
                    layerChips
                    status
                }
                .padding(10)
            }
            .navigationTitle("Traffic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.loading)
                        .accessibilityLabel("Refresh traffic")
                }
            }
            .task {
                location.requestIfNeeded()
                await model.loadConfig()
                await refresh(force: true)
            }
            .onChange(of: showIncidents) { _, _ in Task { await refresh(force: true) } }
            .onChange(of: showWebcams) { _, _ in Task { await refresh(force: true) } }
            .onChange(of: showRoads) { _, on in
                if on { Task { await refresh(force: true) } } else { model.stopRoadsRetry() }
            }
            .onDisappear { model.stopRoadsRetry() }
            .sheet(item: $selectedIncident) { incident in IncidentSheet(incident: incident).presentationDetents([.medium]) }
            .sheet(item: $selectedWebcam) { webcam in WebcamSheet(webcam: webcam).presentationDetents([.medium, .large]) }
            .sheet(item: $selectedRoad) { road in RoadSheet(road: road, attribution: model.roads?.attribution ?? "").presentationDetents([.medium]) }
            .alert("Not set up", isPresented: Binding(get: { hint != nil }, set: { if !$0 { hint = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(hint ?? "")
            }
        }
    }

    // MARK: map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if showRoads {
                ForEach(shownRoads) { road in
                    let line = road.geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    if road.ridden != true {
                        MapPolyline(coordinates: line).stroke(Color.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    }
                    MapPolyline(coordinates: line)
                        .stroke(RoadColors.color(score: road.score).opacity(road.ridden == true ? 0.4 : 1), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(shownRoads) { road in
                    if let mid = RoadsLogic.midpoint(road) {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: mid.lat, longitude: mid.lon), anchor: .center) {
                            RoadBadge(road: road).onTapGesture { selectedRoad = road }
                        }
                    }
                }
            }
            if showIncidents {
                ForEach(shownIncidents) { incident in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: incident.lat, longitude: incident.lon), anchor: .center) {
                        IncidentPin(kind: incident.incidentKind).onTapGesture { selectedIncident = incident }
                    }
                }
            }
            if showWebcams {
                ForEach(model.webcams) { webcam in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: webcam.lat, longitude: webcam.lon), anchor: .center) {
                        WebcamPin().onTapGesture { selectedWebcam = webcam }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, showsTraffic: showColours))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visible = context.region
            Task { await refresh(force: false) }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: controls

    private var layerChips: some View {
        HStack(spacing: 8) {
            chip("Traffic", systemImage: "car.fill", isOn: $showColours, available: true, layer: "colours")
            chip("Incidents", systemImage: "exclamationmark.triangle.fill", isOn: $showIncidents, available: model.config?.incidents ?? false, layer: "incidents")
            if showIncidents, model.config?.incidents == true {
                chip("Works", systemImage: "hammer.fill", isOn: $showWorks, available: true, layer: "works")
            }
            chip("Webcams", systemImage: "video.fill", isOn: $showWebcams, available: model.config?.webcams ?? false, layer: "webcams")
            chip("Roads", systemImage: "arrow.triangle.turn.up.right.diamond.fill", isOn: $showRoads, available: true, layer: "roads")
            if showRoads {
                chip("New", systemImage: "sparkles", isOn: $onlyUnridden, available: true, layer: "unridden")
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, systemImage: String, isOn: Binding<Bool>, available: Bool, layer: String) -> some View {
        Button {
            if available { isOn.wrappedValue.toggle() } else if model.config != nil { hint = TrafficLogic.setupHint(layer: layer) }
        } label: {
            Label(title, systemImage: available ? systemImage : "lock.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background((available && isOn.wrappedValue) ? Theme.accent : Theme.bg.opacity(0.85), in: Capsule())
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .foregroundStyle((available && isOn.wrappedValue) ? Color.black : Theme.text)
        }
        .accessibilityLabel("\(title) layer, \(available ? (isOn.wrappedValue ? "on" : "off") : "not set up")")
    }

    @ViewBuilder
    private var status: some View {
        let lines = statusLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(Theme.text)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var shownRoads: [TwistyRoad] { RoadsLogic.visible(model.roads?.roads ?? [], onlyUnridden: onlyUnridden) }

    private var shownIncidents: [TrafficIncident] { TrafficLogic.visibleIncidents(model.incidents, showWorks: showWorks) }

    private var statusLines: [String] {
        var lines: [String] = []
        if let error = model.configError { lines.append(error) }
        if showColours { lines.append("Road colours: green flowing, orange slow, red jammed (Apple Maps live traffic).") }
        if showIncidents, model.config?.incidents == true {
            if let error = model.incidentsError {
                lines.append("Incidents: \(error)")
            } else {
                let hidden = model.incidents.count - shownIncidents.count
                var line = "Jams, accidents and hazards nearby: \(shownIncidents.count)"
                if showWorks { line = "Incidents and works nearby: \(shownIncidents.count)" }
                if hidden > 0 { line += " (\(hidden) roadworks and closures hidden: tap Works)" }
                if model.unlocated > 0 { line += " (\(model.unlocated) have no map position)" }
                lines.append(line)
            }
        }
        if showRoads {
            if model.roadsTooWide {
                lines.append("Roads: zoom in to see twisty roads.")
            } else if let error = model.roadsError {
                lines.append("Roads: \(error)")
            } else if let roads = model.roads {
                lines.append(RoadsLogic.summary(roads, shown: shownRoads.count))
                if roads.isBuilt { lines.append("Brighter violet is twistier, faded is ridden. Tap a badge for details. Roads © OpenStreetMap contributors.") }
            }
        }
        if showWebcams, model.config?.webcams == true {
            if let error = model.webcamsError { lines.append("Webcams: \(error)") } else { lines.append("Webcams nearby: \(model.webcams.count)") }
        }
        return lines
    }

    private func refresh(force: Bool) async {
        if showRoads, let region = visible {
            await model.refreshRoads(visible: RoadsLogic.box(centerLat: region.center.latitude, centerLon: region.center.longitude,
                                                              latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta), force: force)
        }
        guard let region = visible else {
            // no map position yet (first launch): ask for the area around the default view
            await model.refresh(lat: 47.3769, lon: 8.5417, radiusKm: 15, incidents: showIncidents, webcams: showWebcams, force: force)
            return
        }
        let radius = TrafficLogic.radiusKm(latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta, atLat: region.center.latitude)
        await model.refresh(lat: region.center.latitude, lon: region.center.longitude, radiusKm: radius,
                            incidents: showIncidents, webcams: showWebcams, force: force)
    }
}

// MARK: - pins

struct IncidentPin: View {
    let kind: IncidentKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }

    private var color: Color {
        switch kind {
        case .accident, .closure: return Theme.danger
        case .congestion, .hazard: return Color(hex: 0xE67E22)
        case .roadworks: return Color(hex: 0xC9A227)
        case .other: return Theme.muted
        }
    }
}

/// Twistiness as colour: light violet for lively roads, deep purple for twisty ones, magenta for the best. Not green, orange or red, which are the traffic.
enum RoadColors {
    static func color(score: Int) -> Color {
        switch score {
        case 85...: return Color(hex: 0xE040FB)
        case 65..<85: return Color(hex: 0x9C5CF0)
        default: return Color(hex: 0xB39DDB)
        }
    }
}

struct RoadBadge: View {
    let road: TwistyRoad

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: road.ridden == true ? "checkmark" : "arrow.triangle.turn.up.right.diamond.fill").font(.system(size: 9, weight: .bold))
            Text("\(road.score)").font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoadColors.color(score: road.score).opacity(road.ridden == true ? 0.7 : 1), in: Capsule())
        .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
        .foregroundStyle(Color.white)
        .accessibilityLabel("\(RoadsLogic.title(road)), \(RoadsLogic.scoreWord(road.score)), \(RoadsLogic.riddenText(road.ridden))")
    }
}

struct WebcamPin: View {
    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color(hex: 0x3478F6)))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}

// MARK: - sheets

struct IncidentSheet: View {
    let incident: TrafficIncident
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        IncidentPin(kind: incident.incidentKind)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(incident.title).font(.headline).foregroundStyle(Theme.text)
                            Text([incident.road, TrafficLogic.severityText(incident.severity), TrafficLogic.distanceText(incident.distanceKm) + " away"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    if !incident.comment.isEmpty {
                        Text(incident.comment).font(.body).foregroundStyle(Theme.text)
                    } else {
                        Text("The feed gives no description for this one.").foregroundStyle(Theme.muted)
                    }
                    if let validity = TrafficLogic.validity(start: incident.start, end: incident.end) {
                        Label(validity, systemImage: "clock").font(.subheadline).foregroundStyle(Theme.text)
                    }
                    Text("Source: ASTRA / opentransportdata.swiss. Reports can lag behind what is on the road.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Incident")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct WebcamSheet: View {
    let webcam: TrafficWebcam
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(webcam.title).font(.headline).foregroundStyle(Theme.text)
                    Text(TrafficLogic.distanceText(webcam.distanceKm) + " away").font(.subheadline).foregroundStyle(Theme.muted)
                    Text(webcam.isTrafficCamera ? "Traffic camera" : "City webcam: it may or may not show a road.")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    if let preview = webcam.preview, let url = URL(string: preview) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                            case .failure: Label("The picture could not be loaded.", systemImage: "photo").foregroundStyle(Theme.muted)
                            default: ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, minHeight: 160)
                            }
                        }
                    }
                    if let live = webcam.playerUrl.flatMap(URL.init(string:)) ?? webcam.detailUrl.flatMap(URL.init(string:)) {
                        Link(destination: live) {
                            Label("Open the live view", systemImage: "play.rectangle.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Webcam pictures by Windy and the webcam owners. The picture is a snapshot and may be several minutes old.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if let detail = webcam.detailUrl.flatMap(URL.init(string:)) {
                        Link("View on Windy", destination: detail).font(.caption)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Webcam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct RoadSheet: View {
    let road: TwistyRoad
    let attribution: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        RoadBadge(road: road)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RoadsLogic.title(road)).font(.headline).foregroundStyle(Theme.text)
                            Text("\(RoadsLogic.scoreWord(road.score)) · \(RoadsLogic.lengthText(road.lengthM))").font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    Label(RoadsLogic.riddenText(road.ridden), systemImage: road.ridden == true ? "checkmark.circle.fill" : "sparkles")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(road.ridden == false ? Theme.accent : Theme.text)
                    HStack {
                        StatTile(value: "\(road.score)", unit: "/ 100", label: "Twistiness")
                        StatTile(value: RoadsLogic.lengthText(road.curvyM), label: "Of it bendy")
                        StatTile(value: road.maxspeed.map { "\($0)" } ?? "-", unit: road.maxspeed == nil ? "" : "km/h", label: "Limit on map")
                    }
                    Text("\(RoadsLogic.highwayText(road.highway)), \(road.paved ? "paved" : "unpaved")" + (road.surface.map { " (\($0))" } ?? ""))
                        .font(.footnote).foregroundStyle(Theme.muted)
                    if let url = RoadsLogic.mapsURL(road) {
                        Link(destination: url) {
                            Label("Show in Apple Maps", systemImage: "map.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Twistiness is calculated from the shape of the road alone: how much of it is made of tight and medium bends. It knows nothing about the surface condition, traffic, speed cameras or whether the road is closed in winter. Check before you go.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if !attribution.isEmpty { Text(attribution).font(.caption2).foregroundStyle(Theme.muted) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Road")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
