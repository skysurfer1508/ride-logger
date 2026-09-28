import SwiftUI

/// The paged, filtered list behind the Rides tab. The unfiltered first page is kept on the phone so the list still shows with no signal.
@MainActor
final class RidesModel: ObservableObject {
    static let pageSize = 50

    @Published private(set) var rides: [RideSummary] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    @Published var staleMessage: String?
    @Published var filters = RideFilters()

    private let api: APIClient

    init(api: APIClient) { self.api = api }

    func reload() async {
        await fetch(offset: 0, replacing: true)
    }

    func loadMore() async {
        guard hasMore, !busy else { return }
        await fetch(offset: rides.count, replacing: false)
    }

    private func fetch(offset: Int, replacing: Bool) async {
        busy = true
        defer { busy = false }
        let query = filters.query(limit: Self.pageSize, offset: offset)
        let key = ResponseCache.key(path: "rides", query: query)
        do {
            let data = try await api.getRaw("rides", query: query)
            let page = try JSONDecoder.ridelog.decode(RidesResponse.self, from: data)
            if !filters.isActive && offset == 0 { ResponseCache.store(data, key: key) }
            rides = replacing ? page.rides : rides + page.rides
            hasMore = page.hasMore
            loaded = true
            errorMessage = nil
            staleMessage = nil
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            if replacing, !filters.isActive, let saved = ResponseCache.load(key: key),
               let page = try? JSONDecoder.ridelog.decode(RidesResponse.self, from: saved) {
                rides = page.rides
                hasMore = false
                loaded = true
                staleMessage = "Showing what was saved on this phone. " + message
            } else if loaded {
                staleMessage = message
            } else {
                errorMessage = message
            }
        }
    }
}

struct RidesView: View {
    let api: APIClient
    @StateObject private var model: RidesModel
    @State private var showFilters = false

    init(api: APIClient) {
        self.api = api
        _model = StateObject(wrappedValue: RidesModel(api: api))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.loaded, let message = model.errorMessage {
                    LoadFailure(message: message) { Task { await model.reload() } }
                } else if !model.loaded {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Rides")
            .navigationDestination(for: RideSummary.self) { RideDetailView(api: api, ride: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: model.filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")
                }
            }
            .sheet(isPresented: $showFilters) {
                RideFiltersSheet(filters: model.filters) { applied in
                    model.filters = applied
                    Task { await model.reload() }
                }
            }
            .task { if !model.loaded { await model.reload() } }
        }
    }

    private var list: some View {
        List {
            if let note = model.staleMessage {
                StaleNote(message: note).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if model.rides.isEmpty {
                Text(model.filters.isActive ? "No rides match these filters." : "No rides yet.")
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Color.clear)
            }
            ForEach(model.rides) { ride in
                NavigationLink(value: ride) { RideRow(ride: ride) }
                    .listRowBackground(Theme.surface)
                    .onAppear {
                        if ride.id == model.rides.last?.id { Task { await model.loadMore() } }
                    }
            }
            if model.hasMore {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.reload() }
    }
}

struct RideFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RideFilters
    @State private var useFrom: Bool
    @State private var useTo: Bool
    let onApply: (RideFilters) -> Void

    init(filters: RideFilters, onApply: @escaping (RideFilters) -> Void) {
        _draft = State(initialValue: filters)
        _useFrom = State(initialValue: filters.dateFrom != nil)
        _useTo = State(initialValue: filters.dateTo != nil)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dates") {
                    Toggle("From", isOn: $useFrom)
                    if useFrom {
                        DatePicker("From", selection: Binding(get: { draft.dateFrom ?? Date() }, set: { draft.dateFrom = $0 }), displayedComponents: .date)
                    }
                    Toggle("To", isOn: $useTo)
                    if useTo {
                        DatePicker("To", selection: Binding(get: { draft.dateTo ?? Date() }, set: { draft.dateTo = $0 }), displayedComponents: .date)
                    }
                }
                Section("Distance (km)") {
                    TextField("At least", text: $draft.minKm).keyboardType(.decimalPad)
                    TextField("At most", text: $draft.maxKm).keyboardType(.decimalPad)
                }
                Section {
                    Button("Clear filters", role: .destructive) {
                        onApply(RideFilters())
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        var applied = draft
                        if !useFrom { applied.dateFrom = nil } else if applied.dateFrom == nil { applied.dateFrom = Date() }
                        if !useTo { applied.dateTo = nil } else if applied.dateTo == nil { applied.dateTo = Date() }
                        onApply(applied)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct RideDetailView: View {
    let api: APIClient
    let ride: RideSummary

    var body: some View {
        LoaderScreen(api: api, path: "rides/\(ride.id)") { (detail: RideDetailResponse) in
            RideDetailContent(ride: detail.ride, polyline: detail.polyline)
        }
        .navigationTitle(Format.shortDay(iso: ride.startTime))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RideDetailContent: View {
    let ride: RideSummary
    let polyline: [[Double]]

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.day(iso: ride.startTime)).font(.headline).foregroundStyle(Theme.text)
                Text("\(Format.time(iso: ride.startTime)) – \(Format.time(iso: ride.endTime))").font(.subheadline).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Panel {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    StatTile(value: String(format: "%.1f", ride.distanceKm), unit: "km", label: "Distance")
                    StatTile(value: ride.durationHm, label: "Duration")
                    StatTile(value: "\(ride.avgKmh)", unit: "km/h", label: "Avg speed")
                    StatTile(value: "\(ride.maxKmh)", unit: "km/h", label: "Max speed")
                    StatTile(value: "\(ride.elevationGainM)", unit: "m", label: "Elevation gain")
                    StatTile(value: "\(ride.pointCount)", label: ride.source == "trip_marker" ? "Points · trip" : "Points · inferred")
                }
            }

            if polyline.coordinates.isEmpty {
                Text("This ride has no route.").foregroundStyle(Theme.muted)
            } else {
                RouteMap(routes: [polyline.coordinates], showEndpoints: true)
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
        }
    }
}
