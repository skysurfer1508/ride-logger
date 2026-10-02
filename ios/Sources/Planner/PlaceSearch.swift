import CoreLocation
import MapKit
import SwiftUI

/// As-you-type address and place suggestions from Apple's MapKit (no key, no server: the phone asks Apple Maps, like the Maps app does).
@MainActor
final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Favour results near this place (the map's centre or the rider).
    func prefer(near center: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(center: center, latitudinalMeters: 150_000, longitudinalMeters: 150_000)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// The exact place for a suggestion.
    func resolve(_ completion: MKLocalSearchCompletion) async -> Place? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(), let item = response.mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        return Place(name: item.name ?? completion.title, subtitle: completion.subtitle, lat: coordinate.latitude, lon: coordinate.longitude)
    }
}

/// One look at where the phone is, for "My location" as a start. Gives nil when location is off or takes too long.
@MainActor
final class CurrentLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fetch() async -> CLLocation? {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { return nil }
        finish(nil)                                                                  // a look still in flight is given up
        return await withCheckedContinuation { (next: CheckedContinuation<CLLocation?, Never>) in
            continuation = next
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()                             // the answer arrives in locationManagerDidChangeAuthorization
            } else {
                manager.requestLocation()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.requestLocation() }
            else if status == .denied || status == .restricted { self.finish(nil) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}

/// Choose a place: type an address or a name, or take one of the recent places, Home or Work, or drop a pin on the map. `onPick(nil)` means "my location".
struct PlacePickerSheet: View {
    let title: String
    let allowMyLocation: Bool
    let near: CLLocationCoordinate2D
    let onPick: (Place?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearchModel()
    @State private var resolving = false
    @State private var problem: String?
    @State private var refresh = 0
    private let store = PlaceStore()

    var body: some View {
        NavigationStack {
            List {
                if search.query.isEmpty {
                    if allowMyLocation {
                        Button { choose(nil) } label: { Label("My location", systemImage: "location.fill").foregroundStyle(Theme.accent) }
                    }
                    ForEach(TripLogic.suggestions(saved: store.saved, recents: store.recents)) { item in
                        Button { choose(item.place) } label: { row(item.place, label: item.label) }
                            .contextMenu {
                                Button("Save as Home") { store.save(item.place, as: "home"); refresh += 1 }
                                Button("Save as Work") { store.save(item.place, as: "work"); refresh += 1 }
                                if item.label == nil { Button("Remove from recents", role: .destructive) { store.removeRecent(item.place); refresh += 1 } }
                            }
                    }
                    NavigationLink { MapPinPicker(near: near) { choose($0) } } label: { Label("Choose on the map", systemImage: "mappin.and.ellipse") }
                } else {
                    ForEach(Array(search.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        Button { Task { await pick(suggestion) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).foregroundStyle(Theme.text)
                                if !suggestion.subtitle.isEmpty { Text(suggestion.subtitle).font(.caption).foregroundStyle(Theme.muted) }
                            }
                        }
                    }
                    if search.suggestions.isEmpty { Text("Keep typing: a street and number, a town, a place name.").font(.footnote).foregroundStyle(Theme.muted) }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.accent) }
            }
            .id(refresh)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address or place")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if resolving { ProgressView().tint(Theme.accent) } }
            .onAppear { search.prefer(near: near) }
        }
    }

    private func row(_ place: Place, label: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: label == "Home" ? "house.fill" : (label == "Work" ? "briefcase.fill" : "clock")).foregroundStyle(Theme.muted).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label ?? place.name).foregroundStyle(Theme.text)
                Text(label == nil ? place.subtitle : place.line).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    private func pick(_ suggestion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        if let place = await search.resolve(suggestion) {
            choose(place)
        } else {
            problem = "That place could not be found. Try another spelling."
        }
    }

    private func choose(_ place: Place?) {
        if let place { store.addRecent(place) }
        onPick(place)
        dismiss()
    }
}

/// Drop a pin: tap the map, then "Use this place". The pin is named from the address under it when Apple Maps knows it.
struct MapPinPicker: View {
    let near: CLLocationCoordinate2D
    let onPick: (Place) -> Void
    @State private var camera: MapCameraPosition
    @State private var pin: CLLocationCoordinate2D?
    @State private var name = "Dropped pin"
    @State private var subtitle = ""

    init(near: CLLocationCoordinate2D, onPick: @escaping (Place) -> Void) {
        self.near = near
        self.onPick = onPick
        _camera = State(initialValue: .region(MKCoordinateRegion(center: near, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4))))
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let pin {
                    Annotation("", coordinate: pin, anchor: .bottom) { Image(systemName: "mappin.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.danger) }
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                if let coordinate = proxy.convert(location, from: .local) {
                    pin = coordinate
                    Task { await describe(coordinate) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let pin {
                Button { onPick(Place(name: name, subtitle: subtitle, lat: pin.latitude, lon: pin.longitude)) } label: {
                    Text("Use \(name)").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(16)
            }
        }
        .navigationTitle("Choose on the map")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func describe(_ coordinate: CLLocationCoordinate2D) async {
        name = "Dropped pin"
        subtitle = ""
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard let mark = marks?.first else { return }
        let street = [mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        name = street.isEmpty ? (mark.name ?? "Dropped pin") : street
        subtitle = [mark.locality, mark.country].compactMap { $0 }.joined(separator: ", ")
    }
}
