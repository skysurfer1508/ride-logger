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
        case loop = "Loop", route = "Trip"
        var id: String { rawValue }
    }

    /// Which place the picker is choosing.
    enum Picking: String, Identifiable {
        case origin, destination, stop
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
    @State private var origin: Place?                       // nil: where the phone is
    @State private var destination: Place?
    @State private var stops: [Place] = []
    @State private var routeMode: RouteMode = .fast
    @State private var detour = TripLogic.defaultDetour
    @State private var picking: Picking?
    @State private var editingStop: Int?
    @State private var locator = CurrentLocationFetcher()
    @State private var phase: Phase = .idle
    @State private var selected = 0
    @State private var saved: [SavedRouteSummary] = []
    @State private var notice: String?
    @State private var shareItem: ShareItem?
    @State private var busy = false
    @State private var confirmDelete: SavedRouteSummary?
    @State private var noRoadData = false
    @State private var recordToo = true
    @ObservedObject private var navigation = AppServices.shared.navigation

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
            .sheet(item: $picking) { which in
                PlacePickerSheet(title: title(for: which), allowMyLocation: which == .origin, near: start) { place in picked(place, for: which) }
            }
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
        Panel(title: "A loop") {
            fromButton
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
        }
    }

    private var routePanel: some View {
        Panel(title: "Where to?") {
            fromButton
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                HStack(spacing: 8) {
                    placeButton(icon: "\(index + 1).circle.fill", tint: Theme.muted, title: "Stop \(index + 1)", text: stop.line) { editingStop = index; picking = .stop }
                    Button { stops.remove(at: index); phase = .idle } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                        .accessibilityLabel("Remove stop \(index + 1)")
                }
            }
            placeButton(icon: "mappin.circle.fill", tint: Theme.danger, title: "To", text: destination?.line ?? "Choose a place") { picking = .destination }
            HStack {
                Button { editingStop = nil; picking = .stop } label: { Label("Add stop", systemImage: "plus.circle") }
                    .disabled(destination == nil || stops.count >= TripLogic.maxStops)
                Spacer()
                Button { swapEnds() } label: { Label("Swap", systemImage: "arrow.up.arrow.down") }
                    .disabled(origin == nil || destination == nil)
            }
            .font(.footnote)
            modeChips
            Toggle("Paved roads only", isOn: $pavedOnly).tint(Theme.accent).foregroundStyle(Theme.text)
            Button { Task { await planRoute() } } label: {
                Text("Find routes").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(isPlanning || !TripLogic.canPlan(finish: destination, stops: stops))
        }
    }

    // MARK: places

    private var fromButton: some View {
        placeButton(icon: "location.circle.fill", tint: Theme.accent, title: "From", text: origin?.line ?? "My location") { picking = .origin }
    }

    private func placeButton(icon: String, tint: Color, title: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(Theme.label).tracking(1).foregroundStyle(Theme.muted)
                    Text(text).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(text)")
    }

    private func title(for which: Picking) -> String {
        switch which {
        case .origin: return "From"
        case .destination: return "To"
        case .stop: return "Add a stop"
        }
    }

    private func picked(_ place: Place?, for which: Picking) {
        switch which {
        case .origin: origin = place
        case .destination: destination = place
        case .stop:
            if let place {
                if let index = editingStop, stops.indices.contains(index) { stops[index] = place } else if stops.count < TripLogic.maxStops { stops.append(place) }
            }
            editingStop = nil
        }
        phase = .idle                                                         // the routes shown belong to the old places
    }

    private func swapEnds() {
        guard let from = origin, let to = destination else { return }
        origin = to
        destination = from
        stops.reverse()
        phase = .idle
    }

    /// Where the trip starts: the chosen place, else where the phone is, else the middle of the map (said so).
    private func startPoint() async -> (lat: Double, lon: Double) {
        if let origin { return (origin.lat, origin.lon) }
        if let here = await locator.fetch() { return (here.coordinate.latitude, here.coordinate.longitude) }
        notice = "Could not find where you are, so the middle of the map is the start. Choose a start address, or allow location for RideLog."
        return (start.latitude, start.longitude)
    }

    // MARK: styles

    private var modeChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(RouteMode.allCases) { mode in
                    Button { routeMode = mode; phase = .idle } label: {
                        Label(mode.title, systemImage: mode.symbol)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(routeMode == mode ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                            .foregroundStyle(routeMode == mode ? Color.black : Theme.text)
                    }
                    .accessibilityLabel("\(mode.title): \(mode.blurb)")
                }
            }
            Text(routeMode.blurb).font(.caption).foregroundStyle(Theme.muted)
            if routeMode == .twisty {
                HStack {
                    Text("Up to \(TripLogic.detourText(minutes: detour)) longer").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                }
                Slider(value: $detour, in: TripLogic.detourRange, step: TripLogic.detourStep).tint(Theme.accent)
                    .accessibilityLabel("How much longer a twisty trip may take, in minutes")
            }
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
        VStack(spacing: 8) {
            Button { Task { await navigate(route) } } label: {
                Label(navigation.loading ? "Getting the turns…" : "Navigate with voice", systemImage: "location.north.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Color(hex: 0x3478F6)).disabled(navigation.loading)
            Toggle("Record this ride too", isOn: $recordToo).tint(Theme.accent).foregroundStyle(Theme.text).font(.footnote)
            Button { Task { await navigate(route, simulate: true) } } label: {
                Label("Simulate the drive (hear the voice from the couch)", systemImage: "play.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).font(.footnote).disabled(navigation.loading)
            if let problem = navigation.problem { Text(problem).font(.footnote).foregroundStyle(Theme.accent) }
            routeActions(for: route)
        }
    }

    private func routeActions(for route: PlannedRoute) -> some View {
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
                            Button("Navigate") { Task { await navigateSaved(route) } }.buttonStyle(.borderedProminent).tint(Color(hex: 0x3478F6))
                            Button("Follow") { Task { await followSaved(route) } }.buttonStyle(.bordered)
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
            let from = await startPoint()
            let form = PlannerLogic.loopForm(lat: from.lat, lon: from.lon, km: km, avoidMotorways: avoidMotorways, pavedOnly: pavedOnly, preferNew: preferNew)
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
            let from = await startPoint()
            let form = TripLogic.tripForm(start: from, stops: stops, finish: destination, mode: routeMode, detourMin: detour, pavedOnly: pavedOnly, alternatives: true)
            let answer: PlanResponse = try await api.post("planner/route", form: form)
            if let note = answer.note { notice = note }
            if let problem = PlannerLogic.problem(answer) { phase = .failed(problem) } else { phase = .done(answer.routes) }
        } catch APIError.unauthorized {
            phase = .idle
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
    }

    /// "To Hardstrasse 10 (Twisty)" for a trip, "Loop 118 km, 2 Oct" for a loop.
    private func routeName(_ route: PlannedRoute) -> String {
        if mode == .route, let destination { return "To \(destination.name) (\(RouteMode(rawValue: route.mode ?? "")?.title ?? "Route"))" }
        return PlannerLogic.defaultName(kind: mode == .loop ? "loop" : "route", km: route.distanceKm, now: Date())
    }

    /// Gets the route ready, closes this sheet, and only then opens the navigation screen (two presentations at once would fight).
    private func navigate(_ route: PlannedRoute, simulate: Bool = false) async {
        guard let ready = await navigation.prepare(route: route, name: routeName(route), api: api) else { notice = navigation.problem; return }
        await open(ready, simulate: simulate)
    }

    private func navigateSaved(_ route: SavedRouteSummary) async {
        guard let ready = await navigation.prepare(saved: route, api: api) else { notice = navigation.problem; return }
        await open(ready, simulate: false)
    }

    private func open(_ ready: GuidanceRoute, simulate: Bool) async {
        let record = recordToo && !simulate
        let navigation = self.navigation
        dismiss()
        try? await Task.sleep(nanoseconds: 450_000_000)
        await navigation.start(ready, record: record, simulate: simulate)
    }

    private func follow(_ route: PlannedRoute) {
        let name = routeName(route)
        activeRoute.set(PlannerLogic.activeRoute(from: route, name: name, now: Date()))
        notice = "Following \"\(name)\". Open the Record tab before you set off."
    }

    /// Keeps a planned route on the server. Returns its id, or nil after telling the person why not.
    @discardableResult
    private func save(_ route: PlannedRoute, thenShare: Bool) async -> Int? {
        busy = true
        defer { busy = false }
        let kind = mode == .loop ? "loop" : "route"
        let name = routeName(route)
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
            Annotation("", coordinate: routes.indices.contains(selected) ? (routes[selected].shape.first?.coordinate ?? start) : start, anchor: .center) {
                Image(systemName: "circle.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent).background(Circle().fill(Color.white))
            }
            if routes.indices.contains(selected), let end = routes[selected].shape.last, routes[selected].mode != "loop" {
                Annotation("", coordinate: end.coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.danger).background(Circle().fill(Color.white))
                }
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
