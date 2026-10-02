import CoreLocation
import Foundation

/// Turn-by-turn navigation along a planned route: follows the phone's position, speaks the turns, asks the server for a new route when the rider leaves the old one.
/// It can run on its own location updates (also with the screen locked) or on a simulated ride, to hear the whole thing from the couch.
@MainActor
final class NavigationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var route: GuidanceRoute?
    @Published private(set) var status = GuidanceStatus()
    @Published private(set) var rerouting = false
    @Published private(set) var arrived = false
    @Published private(set) var isSimulating = false
    @Published private(set) var simulatedPosition: CLLocationCoordinate2D?
    @Published private(set) var speedKmh = 0
    @Published private(set) var loading = false
    @Published var problem: String?
    @Published var muted = false {
        didSet { engine?.muted = muted }
    }

    private var engine: GuidanceEngine?
    private let manager = CLLocationManager()
    private var background: CLBackgroundActivitySession?
    private var api: APIClient?
    private var simulator: DriveSimulator?
    private var simulationTimer: Timer?
    private var simulationSpeed = 14.0
    private var simulationClock = 0.0
    private var lastFix: CLLocation?

    var coordinates: [CLLocationCoordinate2D] {
        guard let line = route?.line else { return [] }
        let stride = max(1, line.lat.count / 1500)
        return (0..<line.lat.count).filter { $0 % stride == 0 || $0 == line.lat.count - 1 }.map { CLLocationCoordinate2D(latitude: line.lat[$0], longitude: line.lon[$0]) }
    }

    var destination: CLLocationCoordinate2D? {
        guard let line = route?.line, let lat = line.lat.last, let lon = line.lon.last else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The turn the banner talks about.
    var nextManeuver: Maneuver? {
        guard let route, let index = status.nextIndex, route.maneuvers.indices.contains(index) else { return nil }
        return route.maneuvers[index]
    }

    // MARK: starting

    /// Gets a route ready to navigate: the turns are there already for a route that was just planned, and asked for from the server for a saved one. nil (with `problem` set) when it cannot be.
    func prepare(route planned: PlannedRoute, name: String, api: APIClient) async -> GuidanceRoute? {
        self.api = api
        problem = nil
        if let ready = GuidanceRoute(route: planned, name: name) { return ready }
        guard let waypoints = planned.waypoints, !waypoints.isEmpty else {
            problem = "This route has no turn-by-turn data. Plan it again to navigate it."
            return nil
        }
        return await fetch(waypoints: waypoints, mode: planned.mode ?? "relaxed", name: name)
    }

    func prepare(saved: SavedRouteSummary, api: APIClient) async -> GuidanceRoute? {
        self.api = api
        problem = nil
        loading = true
        defer { loading = false }
        do {
            let detail: SavedRouteDetailResponse = try await api.get("planner/routes/\(saved.id)")
            guard let waypoints = detail.route.waypoints, !waypoints.isEmpty else {
                problem = "This saved route was made before turn-by-turn existed and has no stops to navigate. Plan it again and save the new one."
                return nil
            }
            return await fetch(waypoints: waypoints, mode: detail.route.mode ?? "relaxed", name: saved.name)
        } catch APIError.unauthorized {
            return nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            return nil
        }
    }

    private func fetch(waypoints: [RouteWaypoint], mode: String, name: String) async -> GuidanceRoute? {
        guard let api else { return nil }
        loading = true
        defer { loading = false }
        do {
            let answer: PlanResponse = try await api.post("planner/directions", form: TripLogic.directionsForm(waypoints: waypoints, mode: mode))
            if let message = PlannerLogic.problem(answer) { problem = message; return nil }
            guard let planned = answer.routes.first, let ready = GuidanceRoute(route: planned, name: name) else { problem = "The server sent no turns for this route."; return nil }
            return ready
        } catch APIError.unauthorized {
            return nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            return nil
        }
    }

    /// Starts guiding along a prepared route: on the phone's position, or (`simulate`) on a pretend ride. `record` starts recording the ride too (never for a simulation).
    func start(_ ready: GuidanceRoute, record: Bool, simulate: Bool) async {
        stopEverything()
        route = ready
        engine = GuidanceEngine(route: ready)
        engine?.muted = muted
        status = GuidanceStatus(alongM: 0, remainingM: ready.totalM, remainingS: ready.maneuvers.reduce(0) { $0 + $1.timeS }, nextIndex: nil, distanceToNextM: nil, isOffRoute: false)
        arrived = false
        isActive = true
        if simulate {
            startSimulation()
        } else {
            startLocation()
            if record { _ = await AppServices.shared.autoStart.startFromIntent(trigger: "navigation") }
        }
    }

    // MARK: ending

    func end() {
        stopEverything()
        isActive = false
        route = nil
        engine = nil
        arrived = false
        SpeechOutput.shared.stopAll()
    }

    private func stopEverything() {
        manager.stopUpdatingLocation()
        background?.invalidate()
        background = nil
        simulationTimer?.invalidate()
        simulationTimer = nil
        simulator = nil
        simulatedPosition = nil
        isSimulating = false
        lastFix = nil
    }

    // MARK: the phone's position

    private func startLocation() {
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true                      // guidance and speech go on with the screen locked
            manager.showsBackgroundLocationIndicator = true
            background = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.receive(last) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isActive, !self.isSimulating, self.manager.authorizationStatus == .authorizedWhenInUse || self.manager.authorizationStatus == .authorizedAlways {
                self.manager.allowsBackgroundLocationUpdates = true
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func receive(_ location: CLLocation) {
        guard isActive, !isSimulating, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 60 else { return }
        var speed = location.speed
        if speed < 0, let previous = lastFix {
            let dt = location.timestamp.timeIntervalSince(previous.timestamp)
            speed = dt > 0 ? Geo.haversineM(lat1: previous.coordinate.latitude, lon1: previous.coordinate.longitude, lat2: location.coordinate.latitude, lon2: location.coordinate.longitude) / dt : 0
        }
        lastFix = location
        feed(lat: location.coordinate.latitude, lon: location.coordinate.longitude, speed: max(0, speed), now: location.timestamp.timeIntervalSince1970, course: location.course)
    }

    private func feed(lat: Double, lon: Double, speed: Double, now: Double, course: Double) {
        guard var current = engine else { return }
        let outputs = current.update(lat: lat, lon: lon, speedMps: speed, now: now)
        engine = current
        status = current.status
        speedKmh = Int((speed * 3.6).rounded())
        for output in outputs {
            switch output {
            case .say(let text): SpeechOutput.shared.say(text)
            case .needReroute: reroute(lat: lat, lon: lon, course: course)
            case .arrived: arrived = true
            }
        }
    }

    // MARK: rerouting

    private func reroute(lat: Double, lon: Double, course: Double) {
        guard !rerouting, let route, let api else { return }
        rerouting = true
        let ahead = RouteWaypoints.remaining(waypoints: route.waypoints, alongM: status.alongM, on: route.line, current: (lat, lon))
        let waypoints = ahead.count >= 2 ? ahead : ahead + [RouteWaypoint(lat: route.line.lat.last ?? lat, lon: route.line.lon.last ?? lon)]
        let form = TripLogic.directionsForm(waypoints: waypoints, mode: route.mode, heading: course >= 0 ? course : nil)
        Task {
            defer { rerouting = false }
            do {
                let answer: PlanResponse = try await api.post("planner/directions", form: form)
                guard isActive, let planned = answer.routes.first, let fresh = GuidanceRoute(route: planned, name: route.name) else { return }
                self.route = fresh
                var engine = GuidanceEngine(route: fresh, announceStart: false)
                engine.muted = muted
                self.engine = engine
                SpeechOutput.shared.say("Route updated.")
            } catch APIError.unauthorized {
                // AuthService takes over
            } catch {
                SpeechOutput.shared.say("No connection. Follow the blue line.")
            }
        }
    }

    // MARK: simulated ride

    /// Rides the route in the phone: the voice, the banner and the map behave as on the road. Nothing is recorded.
    func startSimulation(speedKmh: Double = 50) {
        guard let route else { return }
        stopEverything()
        simulator = DriveSimulator(line: route.line)
        simulationSpeed = speedKmh / 3.6
        simulationClock = Date().timeIntervalSince1970
        engine = GuidanceEngine(route: route)
        engine?.muted = muted
        arrived = false
        isSimulating = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.simulationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        simulationTimer = timer
        simulationTick()
    }

    func setSimulationSpeed(kmh: Double) { simulationSpeed = kmh / 3.6 }

    /// Jumps 2 km ahead in a simulated ride, to hear the later turns.
    func skipAhead() { simulator?.skip(metres: 2000) }

    private func simulationTick() {
        guard isSimulating, var sim = simulator else { return }
        let position = sim.step(seconds: 1, speedMps: simulationSpeed)
        simulator = sim
        simulationClock += 1
        simulatedPosition = CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)
        feed(lat: position.lat, lon: position.lon, speed: sim.isFinished ? 0 : simulationSpeed, now: simulationClock, course: -1)
        if arrived { simulationTimer?.invalidate() }
    }
}
