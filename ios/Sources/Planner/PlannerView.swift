import CoreLocation
import MapKit
import SwiftUI

extension RoadPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// Plan a loop or a route, keep it, follow it. Opened from the Traffic tab; the start is the middle of the map that was showing.
struct PlannerView: View {
    let api: APIClient
    let start: CLLocationCoordinate2D
    @ObservedObject var activeRoute: ActiveRouteModel
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case loop = "Loop", route = "A to B"
        var id: String { rawValue }
    }

    enum Phase {
        case idle
        case planning
        case done([PlannedRoute])
        case failed(String)
    }

    @State private var mode: Mode = .loop
    @State private var km = PlannerLogic.defaultKm
    @State private var avoidMotorways = true
    @State private var pavedOnly = true
    @State private var preferNew = false
    @State private var destination: CLLocationCoordinate2D?
    @State private var phase: Phase = .idle
    @State private var selected = 0
    @State private var saved: [SavedRouteSummary] = []
    @State private var notice: String?
    @State private var shareItem: ShareItem?
    @State private var busy = false
    @State private var confirmDelete: SavedRouteSummary?
    @State private var noRoadData = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let notice {
                        Text(notice).font(.footnote).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let active = activeRoute.route { followingPanel(active) }
                    Picker("What to plan", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if mode == .loop { loopPanel } else { routePanel }
                    resultPanel
                    savedPanel
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Plan a ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loadSaved() }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
            .confirmationDialog("Delete this route?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete route", role: .destructive) {
                    if let route = confirmDelete { Task { await delete(route) } }
                }
            } message: {
                Text(confirmDelete?.name ?? "")
            }
        }
    }

    // MARK: following

    private func followingPanel(_ route: ActiveRoute) -> some View {
        Panel(title: "Following") {
            Text(route.name).font(.headline).foregroundStyle(Theme.text)
            Text("\(PlannerLogic.kmText(route.distanceKm)). The Record tab shows how far along you are and how far off the line, with no turn-by-turn.")
                .font(.footnote).foregroundStyle(Theme.muted)
            Button("Stop following", role: .destructive) { activeRoute.clear() }.buttonStyle(.bordered)
        }
    }

    // MARK: asking

    private var loopPanel: some View {
        Panel(title: "A loop from the middle of the map") {
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(km))").font(Theme.readout(40, weight: .bold)).foregroundStyle(Theme.text)
                Text("KM").font(Theme.label).foregroundStyle(Theme.accent)
                Spacer()
            }
            Slider(value: $km, in: PlannerLogic.minKm...PlannerLogic.maxKm, step: PlannerLogic.stepKm).tint(Theme.accent)
                .accessibilityLabel("Length of the loop in kilometres")
            options
            Toggle("Prefer roads I have not ridden", isOn: $preferNew).tint(Theme.accent).foregroundStyle(Theme.text)
            Button { Task { await planLoop() } } label: {
                Text("Find loops").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(isPlanning)
            Text("Starts at \(String(format: "%.4f, %.4f", start.latitude, start.longitude)). Pan the map to your start point before opening this.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var routePanel: some View {
        Panel(title: "From the middle of the map to a place you tap") {
            RoutePicker(start: start, destination: $destination).frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            Text(destination == nil ? "Tap the map to set the destination." : "Tap again to move it.").font(.caption).foregroundStyle(Theme.muted)
            options
            Button { Task { await planRoute() } } label: {
                Text("Find a route").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(isPlanning || destination == nil)
        }
    }

    private var options: some View {
        VStack(spacing: 6) {
            Toggle("Avoid motorways", isOn: $avoidMotorways).tint(Theme.accent).foregroundStyle(Theme.text)
            Toggle("Paved roads only", isOn: $pavedOnly).tint(Theme.accent).foregroundStyle(Theme.text)
        }
    }

    private var isPlanning: Bool {
        if case .planning = phase { return true }
        return false
    }

    // MARK: answers

    @ViewBuilder private var resultPanel: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .planning:
            Panel(title: "Planning") {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Trying many ways round and keeping the best. This takes a few seconds.").font(.footnote).foregroundStyle(Theme.muted)
                }
            }
        case .failed(let message):
            Panel(title: "No route") { Text(message).font(.subheadline).foregroundStyle(Theme.text) }
        case .done(let routes):
            Panel(title: routes.count == 1 ? "The route" : "\(routes.count) options") {
                ResultMap(start: start, routes: routes, selected: selected).frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                    Button { selected = index } label: { routeRow(route, isSelected: index == selected) }.buttonStyle(.plain)
                    Divider().overlay(Theme.border)
                }
                if noRoadData {
                    Text("This server has no twisty-road database yet, so these loops are not steered through twisty roads (see the README).").font(.caption).foregroundStyle(Theme.muted)
                }
                if routes.indices.contains(selected) { actions(for: routes[selected]) }
                Text("Roads © OpenStreetMap contributors. The score comes from the shape of the roads, not their surface, traffic or whether a pass is open. Check before you go.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    private func routeRow(_ route: PlannedRoute, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle").foregroundStyle(isSelected ? Theme.accent : Theme.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(route.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(PlannerLogic.summary(route)).font(.caption).foregroundStyle(Theme.muted)
                if let warning = PlannerLogic.retraceWarning(route) { Text(warning).font(.caption).foregroundStyle(Theme.accent) }
                if let fresh = PlannerLogic.newText(route) { Text(fresh).font(.caption).foregroundStyle(Theme.muted) }
            }
            Spacer()
            Text("\(route.twistiness)").font(Theme.readout(18)).foregroundStyle(Theme.text)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func actions(for route: PlannedRoute) -> some View {
        HStack(spacing: 8) {
            Button { follow(route) } label: { Label("Follow", systemImage: "location.north.line.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            Button { Task { await save(route, thenShare: false) } } label: { Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.buttonStyle(.bordered).disabled(busy)
            Button { Task { await save(route, thenShare: true) } } label: { Label("GPX", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.bordered).disabled(busy)
        }
        .font(.footnote.weight(.semibold))
    }

    // MARK: saved routes

    @ViewBuilder private var savedPanel: some View {
        if !saved.isEmpty {
            Panel(title: "Saved routes") {
                ForEach(saved) { route in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(route.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(PlannerLogic.summary(route)).font(.caption).foregroundStyle(Theme.muted)
                        HStack(spacing: 8) {
                            Button("Follow") { Task { await followSaved(route) } }.buttonStyle(.borderedProminent)
                            Button("GPX") { Task { await share(route) } }.buttonStyle(.bordered)
                            Button("Delete", role: .destructive) { confirmDelete = route }.buttonStyle(.bordered)
                        }
                        .font(.footnote)
                        .disabled(busy)
                    }
                    Divider().overlay(Theme.border)
                }
            }
        }
    }

    // MARK: doing things

    private func planLoop() async {
        phase = .planning
        selected = 0
        notice = nil
        do {
            let form = PlannerLogic.loopForm(lat: start.latitude, lon: start.longitude, km: km, avoidMotorways: avoidMotorways, pavedOnly: pavedOnly, preferNew: preferNew)
            let answer: PlanResponse = try await api.post("planner/loop", form: form)
            noRoadData = answer.roadsData == false
            if let problem = PlannerLogic.problem(answer) { phase = .failed(problem) } else { phase = .done(answer.routes) }
        } catch APIError.unauthorized {
            phase = .idle
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
    }

    private func planRoute() async {
        guard let destination else { return }
        phase = .planning
        selected = 0
        notice = nil
        noRoadData = false
        do {
            let form = PlannerLogic.routeForm(fromLat: start.latitude, fromLon: start.longitude, toLat: destination.latitude, toLon: destination.longitude,
                                              avoidMotorways: avoidMotorways, pavedOnly: pavedOnly)
            let answer: PlanResponse = try await api.post("planner/route", form: form)
            if let problem = PlannerLogic.problem(answer) { phase = .failed(problem) } else { phase = .done(answer.routes) }
        } catch APIError.unauthorized {
            phase = .idle
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
    }

    private func follow(_ route: PlannedRoute) {
        let name = PlannerLogic.defaultName(kind: mode == .loop ? "loop" : "route", km: route.distanceKm, now: Date())
        activeRoute.set(PlannerLogic.activeRoute(from: route, name: name, now: Date()))
        notice = "Following \"\(name)\". Open the Record tab before you set off."
    }

    /// Keeps a planned route on the server. Returns its id, or nil after telling the person why not.
    @discardableResult
    private func save(_ route: PlannedRoute, thenShare: Bool) async -> Int? {
        busy = true
        defer { busy = false }
        let kind = mode == .loop ? "loop" : "route"
        let name = PlannerLogic.defaultName(kind: kind, km: route.distanceKm, now: Date())
        do {
            let answer: SavedRouteResponse = try await api.post("planner/routes", form: PlannerLogic.saveForm(name: name, kind: kind, route: route))
            notice = "Saved as \"\(answer.route.name)\"."
            await loadSaved()
            if thenShare { shareItem = ShareItem(url: try await api.download("planner/routes/\(answer.route.id)/gpx")) }
            return answer.route.id
        } catch APIError.unauthorized {
            return nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            return nil
        }
    }

    private func loadSaved() async {
        do {
            let answer: SavedRoutesResponse = try await api.get("planner/routes")
            saved = answer.routes
        } catch {
            // the list is a convenience: planning still works without it
        }
    }

    private func followSaved(_ route: SavedRouteSummary) async {
        busy = true
        defer { busy = false }
        do {
            let detail: SavedRouteDetailResponse = try await api.get("planner/routes/\(route.id)")
            activeRoute.set(PlannerLogic.activeRoute(from: detail.route, now: Date()))
            notice = "Following \"\(route.name)\". Open the Record tab before you set off."
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    private func share(_ route: SavedRouteSummary) async {
        busy = true
        defer { busy = false }
        do {
            shareItem = ShareItem(url: try await api.download("planner/routes/\(route.id)/gpx"))
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    private func delete(_ route: SavedRouteSummary) async {
        busy = true
        defer { busy = false }
        do {
            let _: DeletedRouteResponse = try await api.delete("planner/routes/\(route.id)")
            await loadSaved()
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }
}

// MARK: - maps

/// A small map where a tap sets the destination.
private struct RoutePicker: View {
    let start: CLLocationCoordinate2D
    @Binding var destination: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition

    init(start: CLLocationCoordinate2D, destination: Binding<CLLocationCoordinate2D?>) {
        self.start = start
        _destination = destination
        _camera = State(initialValue: .region(MKCoordinateRegion(center: start, span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.5))))
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                Annotation("", coordinate: start, anchor: .center) {
                    Image(systemName: "circle.fill").foregroundStyle(Theme.accent).overlay(Circle().stroke(Color.white, lineWidth: 2))
                }
                if let destination {
                    Annotation("", coordinate: destination, anchor: .bottom) {
                        Image(systemName: "mappin.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.danger)
                    }
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                if let coordinate = proxy.convert(location, from: .local) { destination = coordinate }
            }
        }
    }
}

/// The planned routes on a map: the chosen one bold, the others faint.
private struct ResultMap: View {
    let start: CLLocationCoordinate2D
    let routes: [PlannedRoute]
    let selected: Int

    var body: some View {
        Map(initialPosition: .rect(Self.rect(for: routes, fallback: start)), interactionModes: [.pan, .zoom]) {
            ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                if index != selected {
                    MapPolyline(coordinates: route.shape.map { $0.coordinate }).stroke(Color(hex: 0x3478F6).opacity(0.35), lineWidth: 3)
                }
            }
            if routes.indices.contains(selected) {
                MapPolyline(coordinates: routes[selected].shape.map { $0.coordinate })
                    .stroke(Color(hex: 0x3478F6), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            Annotation("", coordinate: start, anchor: .center) {
                Image(systemName: "flag.checkered.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent).background(Circle().fill(Color.white))
            }
        }
        .id(routes.map(\.name).joined(separator: "|") + "\(routes.first?.distanceKm ?? 0)")
    }

    static func rect(for routes: [PlannedRoute], fallback: CLLocationCoordinate2D) -> MKMapRect {
        var rect = MKMapRect.null
        for route in routes {
            for point in route.shape { rect = rect.union(MKMapRect(origin: MKMapPoint(point.coordinate), size: MKMapSize(width: 0, height: 0))) }
        }
        if rect.isNull {
            return MKMapRect(origin: MKMapPoint(fallback), size: MKMapSize(width: 20_000, height: 20_000))
        }
        return rect.insetBy(dx: -rect.width * 0.1 - 100, dy: -rect.height * 0.1 - 100)
    }
}
