import Foundation

/// A route with everything needed to guide along it: the full-resolution line and the turns. Built from what the server sends for a route asked for with directions.
struct GuidanceRoute {
    let line: RouteFollow.Line
    let maneuvers: [Maneuver]
    /// The stops that make the route, to ask the server for a new route to the same places.
    let waypoints: [RouteWaypoint]
    /// "ultra_fast", "fast", "relaxed", "twisty" or "loop".
    let mode: String
    let name: String
    /// The sharp corners and hairpins along the line (from the server), for warnings.
    let corners: [RouteCorner]
    /// The line as the server sent it (polyline6), to ask about it again (speed limits, weather); empty for a route built by hand.
    let encodedLine: String

    var lastLeg: Int { maneuvers.map(\.leg).max() ?? 0 }
    var totalM: Double { line.total }

    init(line: RouteFollow.Line, maneuvers: [Maneuver], waypoints: [RouteWaypoint], mode: String, name: String, corners: [RouteCorner] = [], encodedLine: String = "") {
        self.corners = corners.sorted { $0.alongM < $1.alongM }
        self.encodedLine = encodedLine
        self.line = line
        self.maneuvers = maneuvers
        self.waypoints = waypoints
        self.mode = mode
        self.name = name
    }

    /// nil when the route has no turns or no full line (it was not asked for with directions).
    init?(route: PlannedRoute, name: String) {
        guard let encoded = route.shape6, let maneuvers = route.maneuvers, maneuvers.count >= 2,
              let line = RouteFollow.line(Polyline6.decode(encoded).map { [$0.lat, $0.lon] }) else { return nil }
        self.init(line: line, maneuvers: maneuvers, waypoints: route.waypoints ?? [], mode: route.mode ?? "relaxed", name: name, corners: route.corners ?? [], encodedLine: encoded)
    }
}

/// What a wrist tap says: which way, or a corner.
enum TurnCue: String, Equatable {
    case left, right, uturn, curve, arrive
}

enum GuidanceOutput: Equatable {
    /// Say this, now.
    case say(Phrase)
    /// A turn or a corner is close: for the Watch to tap the wrist.
    case cue(TurnCue)
    /// The rider has left the route: ask the server for a new one from here.
    case needReroute
    /// The destination has been reached.
    case arrived
}

/// What the screen shows.
struct GuidanceStatus: Equatable {
    var alongM = 0.0
    var remainingM = 0.0
    var remainingS = 0.0
    /// Index into the route's maneuvers of the next turn, nil when there is none left.
    var nextIndex: Int?
    var distanceToNextM: Double?
    var isOffRoute = false
    /// The tagged speed limit of the road the rider is on; nil when the map has none (or it is not known yet).
    var limitKmh: Int?
}

/// The words and symbols of turn-by-turn guidance, free of SwiftUI so they can be unit-tested.
enum GuidanceText {
    /// "Turn right onto Wannenweg. Then bear left." -> "Turn right onto Wannenweg."
    static func firstSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        let chars = Array(t)
        for i in chars.indices where chars[i] == "." && (i + 1 >= chars.count || chars[i + 1] == " ") {
            return String(chars[...i])
        }
        return t
    }

    /// "Turn right" -> "turn right"; "SBB station" stays.
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        let second = text.dropFirst().first
        if first.isUppercase, let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Valhalla reads road numbers into the name ("Berninaplatz, 4", "Schaffhauserstrasse/4"): left out, because "four" means nothing to a rider.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: " ,", with: ",").trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "/\\d+(?=[.,\\s]|$)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: ",\\s*\\d+(?=[.,\\s]|$)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// How far, as it is said: "1 kilometer", "2.5 kilometers", "600 meters", "100 meters".
    static func distancePhrase(_ metres: Double) -> String {
        if metres >= 1500 {
            let halves = (metres / 500).rounded() / 2
            if halves == 1 { return "1 kilometer" }
            return halves == halves.rounded() ? "\(Int(halves)) kilometers" : "\(halves) kilometers"
        }
        if metres >= 950 { return "1 kilometer" }
        let hundreds = metres < 150 ? 100 : max(100, Int((metres / 100).rounded()) * 100)
        return "\(hundreds) meters"
    }

    /// "4 kilometers" for a stretch of 1.5 km or more, else nil.
    static func spokenLength(_ metres: Double) -> String? {
        guard metres >= 1500 else { return nil }
        let km = Int((metres / 1000).rounded())
        return km == 1 ? "1 kilometer" : "\(km) kilometers"
    }

    /// For the banner: "300 m", "1.2 km".
    static func shortDistance(_ metres: Double) -> String {
        let m = max(0, metres)
        if m < 1000 { return "\(Int((m / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", m / 1000)
    }

    /// An SF Symbol for Valhalla's maneuver type code.
    static func symbol(forType type: Int) -> String {
        switch type {
        case 4, 5, 6: return "flag.checkered"
        case 9, 18, 20, 23, 37: return "arrow.up.right"
        case 10: return "arrow.turn.up.right"
        case 11: return "arrow.turn.down.right"
        case 12: return "arrow.uturn.right"
        case 13: return "arrow.uturn.left"
        case 14: return "arrow.turn.down.left"
        case 15: return "arrow.turn.up.left"
        case 16, 19, 21, 24, 38: return "arrow.up.left"
        case 26, 27: return "arrow.triangle.2.circlepath"
        case 28, 29: return "ferry.fill"
        default: return "arrow.up"
        }
    }

    /// Which way a wrist tap points for Valhalla's maneuver type code; nil for the ones that need none (continue, merge, roundabouts, ferries).
    static func cue(forType type: Int) -> TurnCue? {
        switch type {
        case 12, 13: return .uturn
        case 14, 15, 16, 19, 21, 24, 38: return .left
        case 9, 10, 11, 18, 20, 23, 37: return .right
        default: return nil
        }
    }

    /// The written line in the banner: the instruction's first sentence, without road numbers.
    static func banner(_ maneuver: Maneuver) -> String { clean(firstSentence(maneuver.instruction)) }
}

/// Where along a route its stops are, and which of them are still ahead.
enum RouteWaypoints {
    /// Metres along the line for each waypoint, in order. The first is the start and the last the end; each one in between is looked for only at or after the one before it,
    /// so on a loop (which ends where it starts) the end is not mistaken for the start.
    static func alongs(of waypoints: [RouteWaypoint], on line: RouteFollow.Line) -> [Double] {
        guard !waypoints.isEmpty else { return [] }
        var out: [Double] = []
        var cursor = 0.0
        for (k, waypoint) in waypoints.enumerated() {
            if k == 0 { out.append(0); continue }
            if k == waypoints.count - 1 { out.append(line.total); continue }
            var candidates: [(distance: Double, along: Double)] = []
            for i in 0..<line.segmentCount {
                let n = RouteFollow.nearest(on: line, segment: i, lat: waypoint.lat, lon: waypoint.lon)
                if n.along >= cursor - 5 { candidates.append(n) }
            }
            let nearest = candidates.map(\.distance).min() ?? .infinity
            let best = candidates.filter { $0.distance <= nearest + RouteFollow.tieMetres }.min { $0.along < $1.along }
            let along = best?.along ?? cursor
            out.append(along)
            cursor = along
        }
        return out
    }

    /// Stops for a way back onto the planned route: the rider's position, a point `aheadM` further along the line than where they left it (so the way back joins in the direction
    /// of travel), then points about every `spacingM` along the rest of the line (so the new route keeps to the planned roads rather than taking the quickest way to the next
    /// stop), and the stops still to come. At most `maxCount` (the server's limit): the spacing grows until it fits. Near the end of the route it is just the destination.
    static func rejoin(waypoints: [RouteWaypoint], alongM: Double, on line: RouteFollow.Line, current: (lat: Double, lon: Double),
                       aheadM: Double = 1000, spacingM: Double = 8000, maxCount: Int = 40) -> [RouteWaypoint] {
        let here = RouteWaypoint(lat: current.lat, lon: current.lon, type: "break")
        let sim = DriveSimulator(line: line)
        func point(_ along: Double, _ type: String) -> RouteWaypoint {
            let p = sim.position(at: along)
            return RouteWaypoint(lat: p.lat, lon: p.lon, type: type)
        }
        let end = waypoints.last.map { RouteWaypoint(lat: $0.lat, lon: $0.lon, type: "break") } ?? point(line.total, "break")
        let join = alongM + aheadM
        guard join < line.total - 300 else { return [here, end] }
        let positions = waypoints.count >= 2 ? alongs(of: waypoints, on: line) : []
        var stops: [(along: Double, waypoint: RouteWaypoint)] = []
        for (k, waypoint) in waypoints.enumerated().dropFirst() where k < waypoints.count - 1 && positions[k] > join + 50 { stops.append((positions[k], waypoint)) }
        stops.append((line.total, end))
        var spacing = spacingM
        while true {
            var out = [here, point(join, "through")]
            var cursor = join
            for stop in stops {
                var next = cursor + spacing
                while next < stop.along - spacing / 2 {
                    out.append(point(next, "through"))
                    next += spacing
                }
                out.append(stop.waypoint)
                cursor = stop.along
            }
            if out.count <= maxCount || spacing > line.total { return out }
            spacing *= 2
        }
    }

    /// The stops still to come, for asking the server for a new route from where the rider is: their own position first, then every stop that is more than 50 m ahead
    /// along the route (and always the last).
    static func remaining(waypoints: [RouteWaypoint], alongM: Double, on line: RouteFollow.Line, current: (lat: Double, lon: Double)) -> [RouteWaypoint] {
        let here = RouteWaypoint(lat: current.lat, lon: current.lon, type: "break")
        guard waypoints.count >= 2 else { return [here] + waypoints }
        let positions = alongs(of: waypoints, on: line)
        var ahead: [RouteWaypoint] = []
        for (k, waypoint) in waypoints.enumerated().dropFirst() where k == waypoints.count - 1 || positions[k] > alongM + 50 { ahead.append(waypoint) }
        return [here] + ahead
    }
}

/// Decides what to say, and when. Fed the rider's position about once a second; answers with phrases and events. Everything here is plain arithmetic on the route (its
/// behaviour was worked out first on a real captured Swiss route, with GPS noise, a tunnel gap, being off route and parking short of the destination: see Tests/GuidanceEngineTests.swift).
///
/// The turns come first. Everything else (a warning for the corner ahead, the speed limit of the road just entered, rain or the dark further on) is said only when
/// nothing is being said and no turn is about to be.
struct GuidanceEngine {
    // when to speak: the far heads-up this many seconds ahead (at least this far), the near cue closer to the turn
    static let farSeconds = 45.0, nearSeconds = 12.0, farMinM = 600.0, nearMinM = 120.0
    /// On a long straight, an early heads-up this far from the turn.
    static let earlyM = 2000.0, earlyAfterM = 3500.0
    /// Two turns closer together than this are said in one breath ("... Then turn right onto ...").
    static let chainM = 400.0
    static let sayRate = 15.0                  // characters a second, to know when a phrase is probably finished
    static let offRouteSeconds = 5.0, rerouteEvery = 15.0, offRouteMinSpeed = 3.0
    static let arriveM = 40.0, parkedM = 60.0, parkedSeconds = 4.0, passedM = 20.0
    /// A wrong turn is noticed long before the rider is 100 m from the route: more than `wrongTurnMetres` from the line and heading more than `wrongTurnDegrees` away from the way
    /// it runs, for `wrongTurnSeconds`, at `wrongTurnMinSpeed` or more (a heading means nothing at a crawl). Needs the phone's heading.
    static let wrongTurnMetres = 30.0, wrongTurnDegrees = 60.0, wrongTurnSeconds = 2.0, wrongTurnMinSpeed = 4.0
    /// Corner warnings: this many seconds ahead (at least this far), no two closer in time than `cornerGapS`; "slow to" is added when the rider is this much over the
    /// advisory speed (a bit more inside a series, where it would be said all the time otherwise).
    static let cornerSeconds = 8.0, cornerMinM = 150.0, cornerGapS = 8.0, advisoryMargin = 1.15, seriesMargin = 1.25
    /// Rain, ice and the like are told this far ahead, and not at all for a place nearer than `alertNearM` (the summary at the start has covered it).
    static let alertLookaheadM = 8000.0, alertNearM = 800.0
    /// A speed limit is called out within `limitWindowM` of where it starts, and never twice within `limitGapS`.
    static let limitWindowM = 300.0, limitGapS = 6.0
    /// Below this speed the rider is standing or crawling: only turns are said.
    static let movingMps = 3.0

    private enum Stage { case early, far, near, passed }
    private static let skipTypes: Set<Int> = [27]            // roundabout exit: said as part of entering it
    private static let departTypes: Set<Int> = [1, 2, 3]
    private static let destinationTypes: Set<Int> = [4, 5, 6]

    let route: GuidanceRoute
    var muted = false
    var options: GuidanceOptions
    /// False while the rider has chosen to explore: being off the route is then neither announced nor asked about.
    var watchesOffRoute = true
    private(set) var status = GuidanceStatus()
    private(set) var arrived = false
    private var hint: Int?
    private var stages: [Set<Stage>]
    private var started: Bool
    private var busyUntil = -Double.infinity
    private var offSince: Double?
    private var lastReroute = -Double.infinity
    private var slowSince: Double?
    private var cornerCursor = 0
    private var lastCornerAt = -Double.infinity
    private var limits: [LimitChange] = []
    private var limitSpokenZone: Int?
    private var lastLimitAt = -Double.infinity
    private var alerts: [RouteAlert] = []
    private var alertSaid: Set<Int> = []
    private var pendingSummary: String?

    init(route: GuidanceRoute, announceStart: Bool = true, options: GuidanceOptions = GuidanceOptions()) {
        self.route = route
        self.options = options
        stages = Array(repeating: [], count: route.maneuvers.count)
        started = !announceStart
    }

    /// What the server worked out for the route after navigation began: the speed limits along it, the weather and light alerts, and one sentence to say about them.
    mutating func attach(limits newLimits: [LimitChange], alerts newAlerts: [RouteAlert], summary: String?) {
        limits = newLimits.sorted { $0.alongM < $1.alongM }
        alerts = newAlerts.sorted { $0.alongM < $1.alongM }
        limitSpokenZone = nil
        alertSaid = []
        pendingSummary = nil
        if let summary, !summary.isEmpty {
            pendingSummary = summary
            if !alerts.isEmpty { alertSaid.insert(0) }                          // the summary names the first one
        }
    }

    private mutating func say(_ phrase: Phrase, at now: Double, into out: inout [GuidanceOutput]) {
        busyUntil = now + 1.0 + Double(phrase.text.count) / Self.sayRate
        if !muted { out.append(.say(phrase)) }
    }

    private mutating func say(_ text: String, at now: Double, into out: inout [GuidanceOutput]) {
        say(Phrase(text), at: now, into: &out)
    }

    /// The rider is at (lat, lon) going `speedMps`, at time `now` (seconds, only differences matter).
    /// `course` is the rider's heading in degrees (nil when not known): with it a wrong turn is noticed in a couple of seconds.
    mutating func update(lat: Double, lon: Double, speedMps: Double, now: Double, course: Double? = nil) -> [GuidanceOutput] {
        var out: [GuidanceOutput] = []
        if arrived { return out }
        let p = RouteFollow.progress(lat: lat, lon: lon, on: route.line, hint: hint)
        if !p.isOffRoute { hint = p.segment }
        let along = p.alongM
        refreshStatus(along: along, off: p.isOffRoute)

        let wrongTurn = !p.isOffRoute && isWrongTurn(p, speedMps: speedMps, course: course)
        if p.isOffRoute || wrongTurn {
            if watchesOffRoute, speedMps >= Self.offRouteMinSpeed {
                if offSince == nil { offSince = now }
                if let since = offSince, now - since >= (wrongTurn ? Self.wrongTurnSeconds : Self.offRouteSeconds), now - lastReroute >= Self.rerouteEvery {
                    lastReroute = now
                    out.append(.needReroute)
                    say(options.offRouteLine, at: now, into: &out)
                }
            }
            return out
        }
        offSince = nil

        if !started && now >= busyUntil, let first = route.maneuvers.first {
            started = true
            if first.pre.contains("Then"), route.maneuvers.count > 1 { stages[1].insert(.far) }
            say("Starting navigation. " + GuidanceText.clean(first.pre), at: now, into: &out)
        }

        if speedMps < 1.0 { if slowSince == nil { slowSince = now } } else { slowSince = nil }
        let parked = slowSince.map { now - $0 >= Self.parkedSeconds } ?? false

        // behind us: passed, silently, or with a word for a stop, the arrival and a long stretch ahead
        for (i, m) in route.maneuvers.enumerated().dropFirst() {
            let destination = Self.destinationTypes.contains(m.type)
            var reach = destination ? Self.arriveM : Self.passedM
            if parked && destination { reach = Self.parkedM }
            if stages[i].contains(.passed) || m.alongM - along > reach { continue }
            stages[i].formUnion([.passed, .far, .near, .early])
            if destination && m.leg >= route.lastLeg {
                arrived = true
                refreshStatus(along: route.line.total, off: false)
                say("You have arrived at your destination.", at: now, into: &out)
                out.append(.arrived)
                return out
            }
            if destination {
                say("You have reached your stop.", at: now, into: &out)
            } else if !Self.departTypes.contains(m.type), !Self.skipTypes.contains(m.type), m.lengthM >= 3000, let length = GuidanceText.spokenLength(m.lengthM) {
                say("Continue for \(length).", at: now, into: &out)
            }
        }

        refreshStatus(along: along, off: false)                                 // the turns just passed no longer count as the next one
        // ahead of us: only the next turn is spoken about
        let next = nextIndex()
        if let next, now >= busyUntil {
            let m = route.maneuvers[next]
            let remaining = m.alongM - along
            let v = max(speedMps, 8.0)
            let farD = max(Self.farMinM, v * Self.farSeconds)
            let nearD = max(Self.nearMinM, v * Self.nearSeconds)
            let destination = Self.destinationTypes.contains(m.type)
            let previousLength = route.maneuvers[max(0, next - 1)].lengthM
            let heading = GuidanceText.lowerFirst(GuidanceText.clean(GuidanceText.firstSentence(m.pre)))

            if remaining <= nearD && !stages[next].contains(.near) {
                stages[next].formUnion([.far, .near, .early])
                if destination {
                    say(m.leg >= route.lastLeg ? "You will arrive at your destination." : "Your stop is ahead.", at: now, into: &out)
                } else {
                    let sentence = GuidanceText.clean(GuidanceText.firstSentence(m.alert ?? m.pre))
                    say(PhraseBook.spoken(sentence, street: m.street, speedMps: speedMps, streetNames: options.streetNames), at: now, into: &out)
                    if let cue = GuidanceText.cue(forType: m.type) { out.append(.cue(cue)) }
                }
            } else if remaining <= farD && !stages[next].contains(.far) {
                stages[next].formUnion([.far, .early])
                if remaining - nearD < 150 { stages[next].insert(.near) }
                if !destination {
                    say(headsUp(heading, for: m, remaining: remaining, speedMps: speedMps), at: now, into: &out)
                    if m.pre.contains("Then"), next + 1 < route.maneuvers.count, route.maneuvers[next + 1].alongM - m.alongM <= Self.chainM { stages[next + 1].insert(.far) }
                }
            } else if remaining <= Self.earlyM && !stages[next].contains(.early) && previousLength >= Self.earlyAfterM && !destination {
                stages[next].insert(.early)
                say(headsUp(heading, for: m, remaining: remaining, speedMps: speedMps), at: now, into: &out)
            }
        }
        speakExtras(along: along, speedMps: speedMps, now: now, next: next, into: &out)
        return out
    }

    /// Clearly leaving the route's line in a different direction from the route: a wrong turn at a junction, noticed before the rider is far from the route.
    private func isWrongTurn(_ p: RouteFollow.Progress, speedMps: Double, course: Double?) -> Bool {
        guard let course, course >= 0, speedMps >= Self.wrongTurnMinSpeed, p.offRouteM > Self.wrongTurnMetres else { return false }
        return RouteFollow.angleBetween(course, RouteFollow.bearing(on: route.line, segment: p.segment)) > Self.wrongTurnDegrees
    }

    /// "In 600 meters, turn right onto Schaffhauserplatz."
    private func headsUp(_ heading: String, for m: Maneuver, remaining: Double, speedMps: Double) -> Phrase {
        PhraseBook.spoken(heading, street: m.street, speedMps: speedMps, streetNames: options.streetNames, distance: GuidanceText.distancePhrase(remaining))
    }

    /// Corner warnings, speed limits and what the weather and the light will do: only while nothing is being said, only while riding, and never close before a turn.
    private mutating func speakExtras(along: Double, speedMps: Double, now: Double, next: Int?, into out: inout [GuidanceOutput]) {
        while cornerCursor < route.corners.count && route.corners[cornerCursor].alongM < along + 20 { cornerCursor += 1 }
        guard started, now >= busyUntil else { return }

        if let words = pendingSummary {
            pendingSummary = nil
            say(words, at: now, into: &out)
            return
        }
        let nearD = max(Self.nearMinM, max(speedMps, 8.0) * Self.nearSeconds)
        let quiet = next.map { route.maneuvers[$0].alongM - along > nearD + 120 } ?? true
        guard speedMps >= Self.movingMps, quiet else { return }

        if options.curveWarnings, cornerCursor < route.corners.count {
            let c = route.corners[cornerCursor]
            if c.alongM - along <= max(Self.cornerMinM, speedMps * Self.cornerSeconds), now - lastCornerAt >= Self.cornerGapS {
                cornerCursor += 1
                let tooFast = speedMps * 3.6 > Double(c.advisoryKmh) * (c.series == "in" ? Self.seriesMargin : Self.advisoryMargin)
                var phrase: Phrase?
                if c.series == "start" {
                    phrase = Phrase.alert(GuidanceLines.curvesAhead)
                } else if c.series != "in" || tooFast {
                    var parts = [SpokenPart(kind: .alert, text: (c.kind == "hairpin" ? "Hairpin " : "Sharp ") + c.dir)]
                    if tooFast { parts.append(SpokenPart(kind: .alert, text: "slow to \(c.advisoryKmh)")) }
                    phrase = Phrase(parts: parts)
                }
                if let phrase {
                    lastCornerAt = now
                    say(phrase, at: now, into: &out)
                    out.append(.cue(.curve))
                    return
                }
            }
        }

        if options.limitCallouts != .off, let zone = limitZone(at: along), zone != limitSpokenZone {
            if let kmh = limits[zone].kmh {
                if options.limitCallouts == .changes && along - limits[zone].alongM > Self.limitWindowM {
                    limitSpokenZone = zone                                      // too late to be news
                } else if now - lastLimitAt >= Self.limitGapS, options.limitCallouts == .changes || speedMps * 3.6 > Double(kmh) + 5 {
                    limitSpokenZone = zone
                    lastLimitAt = now
                    say(Phrase.alert("Limit \(kmh)"), at: now, into: &out)
                    return
                }
            } else {
                limitSpokenZone = zone
            }
        }

        for (i, alert) in alerts.enumerated() where !alertSaid.contains(i) {
            let remaining = alert.alongM - along
            if remaining < Self.alertNearM {
                alertSaid.insert(i)
            } else if remaining <= Self.alertLookaheadM {
                alertSaid.insert(i)
                say(Phrase(parts: [SpokenPart(kind: .distance, text: "In " + GuidanceText.distancePhrase(remaining)), SpokenPart(kind: .alert, text: alert.label)]), at: now, into: &out)
                return
            }
        }
    }

    /// The index of the speed limit stretch the rider is on.
    private func limitZone(at along: Double) -> Int? {
        var found: Int?
        for (i, limit) in limits.enumerated() {
            if limit.alongM <= along { found = i } else { break }
        }
        return found
    }

    /// The next turn worth speaking about: not behind us, and not a roundabout exit or the start of a stretch.
    private func nextIndex() -> Int? {
        route.maneuvers.indices.first { i in
            i > 0 && !stages[i].contains(.passed) && !Self.skipTypes.contains(route.maneuvers[i].type) && !Self.departTypes.contains(route.maneuvers[i].type)
        }
    }

    private mutating func refreshStatus(along: Double, off: Bool) {
        let next = nextIndex()
        var remainingS = 0.0
        if let k = route.maneuvers.lastIndex(where: { $0.alongM <= along }) {
            let m = route.maneuvers[k]
            let left = m.lengthM > 0 ? max(0, (m.alongM + m.lengthM - along) / m.lengthM) : 0
            remainingS = left * m.timeS + route.maneuvers[(k + 1)...].reduce(0) { $0 + $1.timeS }
        }
        status = GuidanceStatus(alongM: along, remainingM: max(0, route.line.total - along), remainingS: remainingS, nextIndex: next,
                                distanceToNextM: next.map { max(0, route.maneuvers[$0].alongM - along) }, isOffRoute: off,
                                limitKmh: limitZone(at: along).flatMap { limits[$0].kmh })
    }
}

/// A pretend rider on a route: its position after riding so far at a steady speed. For the "Simulate drive" button and for the tests.
struct DriveSimulator {
    let line: RouteFollow.Line
    var alongM = 0.0

    var isFinished: Bool { alongM >= line.total }

    /// (lat, lon) at the given distance along the line.
    func position(at metres: Double) -> (lat: Double, lon: Double) {
        let along = min(max(0, metres), line.total)
        var lo = 0, hi = line.cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if line.cumulative[mid] <= along { lo = mid } else { hi = mid - 1 }
        }
        let i = min(lo, line.segmentCount - 1)
        let span = line.cumulative[i + 1] - line.cumulative[i]
        let t = span > 0 ? min(1, max(0, (along - line.cumulative[i]) / span)) : 0
        return (line.lat[i] + (line.lat[i + 1] - line.lat[i]) * t, line.lon[i] + (line.lon[i + 1] - line.lon[i]) * t)
    }

    /// Rides `seconds` at `speedMps` and says where that is.
    mutating func step(seconds: Double, speedMps: Double) -> (lat: Double, lon: Double) {
        alongM = min(line.total, alongM + seconds * speedMps)
        return position(at: alongM)
    }

    /// Jumps ahead (to hear the later part of a route without riding all of it).
    mutating func skip(metres: Double) { alongM = min(line.total, alongM + metres) }
}
