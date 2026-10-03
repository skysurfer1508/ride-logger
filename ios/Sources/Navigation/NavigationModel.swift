import CoreLocation
import Foundation

/// What is on offer when the rider has left the route and has chosen to be asked what to do (Settings > Navigation).
struct RerouteOffer: Equatable {
    let lat: Double
    let lon: Double
    let course: Double
    let startedAt: Date
}

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
    /// When navigation began (for the elapsed time on the screen when no ride is being recorded).
    @Published private(set) var startedAt: Date?
    /// Set while the rider is off the route and is being asked what to do about it.
    @Published private(set) var rerouteOffer: RerouteOffer?
    /// True while the rider has chosen to explore: no rerouting for a few minutes.
    @Published private(set) var exploring = false
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
    private var offerTask: Task<Void, Never>?
    private var extrasTask: Task<Void, Never>?
    private var exploringUntil = Date.distantPast
    /// How long the rider has to choose, and how long "keep exploring" lasts.
    static let offerSeconds = 10.0, exploreSeconds = 180.0

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
        if let ready = GuidanceRoute(route: planned, name: name) {
            prefetchVoice(for: ready)
            return ready
        }
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
            prefetchVoice(for: ready)
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
        engine = GuidanceEngine(route: ready, options: VoiceSettings.guidanceOptions())
        engine?.muted = muted
        startedAt = Date()
        rerouteOffer = nil
        exploring = false
        status = GuidanceStatus(alongM: 0, remainingM: ready.totalM, remainingS: ready.maneuvers.reduce(0) { $0 + $1.timeS }, nextIndex: nil, distanceToNextM: nil, isOffRoute: false)
        arrived = false
        isActive = true
        prefetchVoice(for: ready)
        loadExtras(for: ready, announce: true)
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
        startedAt = nil
        offerTask?.cancel()
        extrasTask?.cancel()
        rerouteOffer = nil
        exploring = false
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
        let outputs = current.update(lat: lat, lon: lon, speedMps: speed, now: now, course: course >= 0 ? course : nil)
        engine = current
        status = current.status
        speedKmh = Int((speed * 3.6).rounded())
        if rerouteOffer != nil && !status.isOffRoute { dismissOffer() }
        if exploring && (!status.isOffRoute || Date() >= exploringUntil) { stopExploring() }
        for output in outputs {
            switch output {
            case .say(let phrase): SpeechOutput.shared.say(phrase)
            case .cue(let cue): if VoiceSettings.watchHaptics() { WatchBridge.shared.sendCue(cue) }
            case .needReroute: offRoute(lat: lat, lon: lon, course: course)
            case .arrived: arrived = true
            }
        }
    }

    // MARK: rerouting

    /// The rider has been off the route for a few seconds: do what Settings says (or ask).
    private func offRoute(lat: Double, lon: Double, course: Double) {
        guard !rerouting, rerouteOffer == nil else { return }
        switch VoiceSettings.rerouteChoice() {
        case .rejoin: reroute(lat: lat, lon: lon, course: course, rejoin: true)
        case .destination: reroute(lat: lat, lon: lon, course: course, rejoin: false)
        case .ask:
            let offer = RerouteOffer(lat: lat, lon: lon, course: course, startedAt: Date())
            rerouteOffer = offer
            offerTask?.cancel()
            offerTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.offerSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.rerouteOffer == offer else { return }
                self.choose(.rejoin)                                                // no answer: the way back onto the route
            }
        }
    }

    enum RerouteAnswer { case rejoin, destination, explore }

    /// The rider's answer to the offer on the screen.
    func choose(_ answer: RerouteAnswer) {
        guard let offer = rerouteOffer else { return }
        dismissOffer()
        switch answer {
        case .rejoin: reroute(lat: offer.lat, lon: offer.lon, course: offer.course, rejoin: true)
        case .destination: reroute(lat: offer.lat, lon: offer.lon, course: offer.course, rejoin: false)
        case .explore: startExploring()
        }
    }

    private func dismissOffer() {
        offerTask?.cancel()
        rerouteOffer = nil
    }

    /// No rerouting for a few minutes (or until the rider is back on the route): for a detour on purpose.
    func startExploring() {
        exploring = true
        exploringUntil = Date().addingTimeInterval(Self.exploreSeconds)
        engine?.watchesOffRoute = false
    }

    func stopExploring() {
        exploring = false
        engine?.watchesOffRoute = true
    }

    private func reroute(lat: Double, lon: Double, course: Double, rejoin: Bool) {
        guard !rerouting, let route, let api else { return }
        rerouting = true
        let waypoints: [RouteWaypoint]
        if rejoin {
            waypoints = RouteWaypoints.rejoin(waypoints: route.waypoints, alongM: status.alongM, on: route.line, current: (lat, lon))
        } else {
            let ahead = RouteWaypoints.remaining(waypoints: route.waypoints, alongM: status.alongM, on: route.line, current: (lat, lon))
            waypoints = ahead.count >= 2 ? ahead : ahead + [RouteWaypoint(lat: route.line.lat.last ?? lat, lon: route.line.lon.last ?? lon)]
        }
        let form = TripLogic.directionsForm(waypoints: waypoints, mode: route.mode, heading: course >= 0 ? course : nil)
        Task {
            defer { rerouting = false }
            do {
                let answer: PlanResponse = try await api.post("planner/directions", form: form)
                guard isActive, let planned = answer.routes.first, let fresh = GuidanceRoute(route: planned, name: route.name) else { return }
                self.route = fresh
                var engine = GuidanceEngine(route: fresh, announceStart: false, options: VoiceSettings.guidanceOptions())
                engine.muted = muted
                self.engine = engine
                SpeechOutput.shared.say(GuidanceLines.routeUpdated)
                prefetchVoice(for: fresh)
                loadExtras(for: fresh, announce: false)
            } catch APIError.unauthorized {
                // AuthService takes over
            } catch {
                SpeechOutput.shared.say(GuidanceLines.noConnection)
            }
        }
    }

    // MARK: what the server knows about the route

    /// Asks for the speed limits and the weather and light along the route, in the background: guidance does not wait for them, and speaks of them when they arrive.
    private func loadExtras(for ready: GuidanceRoute, announce: Bool) {
        guard let api, !ready.encodedLine.isEmpty else { return }
        let minutes = max(1, Int((ready.maneuvers.reduce(0) { $0 + $1.timeS } / 60).rounded()))
        extrasTask?.cancel()
        extrasTask = Task { [weak self] in
            async let limitsAnswer: LimitsResponse? = try? await api.post("planner/limits", form: ["shape6": ready.encodedLine])
            async let conditionsAnswer: ConditionsResponse? = try? await api.post("planner/conditions", form: ["shape6": ready.encodedLine, "duration_min": String(minutes), "tz": TimeZone.current.identifier])
            let limits = await limitsAnswer?.limits ?? []
            let conditions = await conditionsAnswer
            guard let self, !Task.isCancelled, self.isActive, self.route?.encodedLine == ready.encodedLine else { return }
            let alerts = conditions?.alerts ?? []
            let summary = announce ? conditions?.summary : nil
            self.engine?.attach(limits: limits, alerts: alerts, summary: summary)
            self.prefetchVoice(for: ready, limits: limits, alerts: alerts, summary: summary)
        }
    }

    /// Makes sure the natural voice's clips for everything the guidance can say on this route are on the phone (a no-op when they are, or when the server has no such voice).
    private func prefetchVoice(for ready: GuidanceRoute, limits: [LimitChange] = [], alerts: [RouteAlert] = [], summary: String? = nil) {
        guard let api, VoiceSettings.engine() == .natural else { return }
        let options = VoiceSettings.guidanceOptions()
        Task.detached(priority: .utility) {
            let parts = GuidancePreview.parts(for: ready, options: options, limits: limits, alerts: alerts, summary: summary)
            await VoiceClips.shared.prefetch(parts, api: api)
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
        engine = GuidanceEngine(route: route, options: VoiceSettings.guidanceOptions())
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
