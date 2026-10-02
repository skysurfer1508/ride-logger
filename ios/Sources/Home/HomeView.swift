import SwiftUI

struct HomeView: View {
    let api: APIClient

    var body: some View {
        NavigationStack {
            LoaderScreen(api: api, path: "home") { (home: HomeResponse) in
                HomeContent(api: api, home: home)
            }
            .navigationTitle("RideLog")
            .navigationDestination(for: RideSummary.self) { RideDetailView(api: api, ride: $0) }
        }
    }
}

private struct HomeContent: View {
    let api: APIClient
    let home: HomeResponse

    var body: some View {
        VStack(spacing: 14) {
            Panel {
                HStack {
                    StatTile(value: "\(home.rideCount)", label: "Rides")
                    StatTile(value: home.totalDistanceDisplay, unit: "km", label: "Total")
                    StatTile(value: home.avgSpeedDisplay, unit: "km/h", label: "Avg speed")
                }
            }

            NavigationLink {
                OverviewScreen(api: api)
            } label: {
                Panel {
                    HStack {
                        Label("Totals, records and weekly distance", systemImage: "chart.bar.xaxis").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                    }
                }
            }
            .buttonStyle(.plain)

            NavigationLink {
                GarageView(api: api)
            } label: {
                Panel {
                    HStack {
                        Label("Garage: odometer, service, fuel and costs", systemImage: "wrench.and.screwdriver.fill").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                    }
                }
            }
            .buttonStyle(.plain)

            if let latest = home.latest {
                Text("LATEST RIDE").font(Theme.label).tracking(1.4).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink(value: latest) { RideCard(ride: latest, prominent: true) }
                    .buttonStyle(.plain)
            }

            if home.recentRoutes.isEmpty {
                Panel(title: "No rides yet") {
                    Text("Rides show up here once they have been recorded.").foregroundStyle(Theme.muted)
                }
            } else {
                Text("RECENT ROUTES").font(Theme.label).tracking(1.4).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink {
                    AllRidesMapView(api: api)
                } label: {
                    RouteMap(routes: home.recentRoutes.map { $0.polyline.coordinates }, interactive: false)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) {
                            Label("All rides", systemImage: "map")
                                .font(.caption.weight(.semibold))
                                .padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Every ride on one map (the website's /map page).
struct AllRidesMapView: View {
    @StateObject private var loader: Loader<MapResponse>

    init(api: APIClient) {
        _loader = StateObject(wrappedValue: Loader(api: api, path: "map"))
    }

    var body: some View {
        Group {
            switch loader.phase {
            case .loading:
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                LoadFailure(message: message) { Task { await loader.refresh() } }
            case .loaded(let map):
                if map.routes.isEmpty {
                    Text("No rides yet.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RouteMap(routes: map.routes.map { $0.polyline.coordinates })
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("All rides")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .ridesChanged)) { _ in
            Task { await loader.refresh() }
        }
    }
}
