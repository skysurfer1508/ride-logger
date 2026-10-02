import Charts
import Combine
import MapKit
import SwiftUI

/// One run of the route in one colour, ready for the map.
struct ColoredRoute: Identifiable {
    let id: Int
    let bucket: Int
    /// The fixes this run covers (both ends included).
    let range: ClosedRange<Int>
    let coordinates: [CLLocationCoordinate2D]
}

enum SpeedColors {
    /// Slow to fast: cyan, green, yellow, amber, red. Matches TrackMath.bucketLimitsKmh.
    static let all: [Color] = [Color(hex: 0x4FC3F7), Color(hex: 0x66BB6A), Color(hex: 0xFFD54F), Color(hex: 0xFF9D2E), Color(hex: 0xE0574A)]
    static let labels = ["< 15", "15-40", "40-70", "70-100", "100+"]

    static func color(_ bucket: Int) -> Color { all[min(max(bucket, 0), all.count - 1)] }
}

/// The state of the ride screen: the track, and the moment the person is looking at (set by the slider, a tap on the map, the chart or a stop).
@MainActor
final class TrackModel: ObservableObject {
    let track: TrackResponse
    let coords: [CLLocationCoordinate2D]
    let routes: [ColoredRoute]
    let startDate: Date?
    let duration: Double
    /// At most ~400 points for the speed chart, however long the ride is.
    let chartPoints: [TrackPoint]
    @Published var cursor: Double = 0

    // MARK: replay
    /// True from the first press of Play until "Done": the route is dimmed and the part already ridden is drawn in colour behind the bike.
    @Published var replayActive = false
    @Published var isPlaying = false
    @Published var rate = Replay.defaultRate
    @Published var follow = true
    private var timer: Timer?
    private var lastTick = Date()

    init(track: TrackResponse) {
        self.track = track
        coords = track.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        routes = TrackMath.segments(track.points).enumerated().map { index, segment in
            ColoredRoute(id: index, bucket: segment.bucket, range: segment.range, coordinates: Array(track.points[segment.range].map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }))
        }
        startDate = track.start.flatMap { Format.parseISO($0) }
        duration = track.points.last?.t ?? 0
        let stride = max(1, track.points.count / 400)
        chartPoints = track.points.enumerated().filter { $0.offset % stride == 0 || $0.offset == track.points.count - 1 }.map { $0.element }
    }

    var sample: TrackMath.Sample? { TrackMath.sample(at: cursor, in: track.points) }

    func select(time: Double) { cursor = min(max(0, time), duration) }

    func play() {
        guard duration > 0 else { return }
        cursor = Replay.startPosition(cursor: cursor, duration: duration)
        replayActive = true
        isPlaying = true
        lastTick = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)         // .common: keeps ticking while the person drags the slider or the map
        timer = t
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        cursor = 0
        if replayActive && !isPlaying { play() }
    }

    /// Leaves replay mode: the route is drawn normally again.
    func finishReplay() {
        pause()
        replayActive = false
    }

    private func tick() {
        guard isPlaying else { return }
        let now = Date()
        let step = Replay.advance(cursor: cursor, elapsed: now.timeIntervalSince(lastTick), rate: rate, duration: duration)
        lastTick = now
        cursor = step.cursor
        if step.finished { pause() }
    }

    /// The part of the route already ridden, in its speed colours, ending at the bike.
    func trail(upTo s: TrackMath.Sample) -> [ColoredRoute] {
        var out: [ColoredRoute] = []
        for route in routes {
            if route.range.upperBound <= s.index {
                out.append(route)
            } else if route.range.lowerBound <= s.index {
                var part = Array(coords[route.range.lowerBound...s.index])
                part.append(CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon))
                out.append(ColoredRoute(id: route.id, bucket: route.bucket, range: route.range, coordinates: part))
                break
            } else {
                break
            }
        }
        return out
    }

    func wallClock(_ seconds: Double) -> String? {
        startDate.map { Format.time($0.addingTimeInterval(seconds)) }
    }
}

struct RideTrackContent: View {
    @StateObject private var model: TrackModel
    @State private var camera: MapCameraPosition
    @State private var selectedMinutes: Double?

    private var track: TrackResponse { model.track }
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    init(track: TrackResponse) {
        let model = TrackModel(track: track)
        _model = StateObject(wrappedValue: model)
        let fit = MapFit.rect(for: [model.coords])
        _camera = State(initialValue: fit.map { MapCameraPosition.rect($0) } ?? MapCameraPosition.automatic)
    }

    var body: some View {
        content.onDisappear { model.pause() }
    }

    private var content: some View {
        VStack(spacing: 14) {
            header
            if track.points.count < 2 {
                Text("No GPS points are stored for this ride.").foregroundStyle(Theme.muted)
            } else {
                mapPanel
                cursorPanel
                chartPanel
                stopsPanel
            }
        }
    }

    // MARK: header

    private var header: some View {
        let ride = track.ride
        return VStack(spacing: 14) {
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
                    StatTile(value: "\(track.stops.count)", label: "Stops")
                }
            }
        }
    }

    // MARK: map

    private var mapPanel: some View {
        VStack(spacing: 8) {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(model.routes) { route in
                        MapPolyline(coordinates: route.coordinates)
                            .stroke(SpeedColors.color(route.bucket).opacity(model.replayActive ? 0.25 : 1), lineWidth: 5)
                    }
                    if model.replayActive, let s = model.sample {
                        ForEach(model.trail(upTo: s)) { route in
                            MapPolyline(coordinates: route.coordinates).stroke(SpeedColors.color(route.bucket), lineWidth: 6)
                        }
                    }
                    ForEach(track.stops) { stop in
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon), anchor: .center) {
                            StopBadge(stop: stop).onTapGesture { jump(to: stop) }
                        }
                    }
                    if let top = track.maxSpeed {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon), anchor: .center) {
                            TopSpeedBadge(kmh: top.kmh).onTapGesture { model.select(time: top.t) }
                        }
                    }
                    if let s = model.sample {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), anchor: .bottom) {
                            CursorMarker(kmh: s.kmh)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    guard let coordinate = proxy.convert(location, from: .local),
                          let index = TrackMath.nearestIndex(lat: coordinate.latitude, lon: coordinate.longitude, in: track.points, maxMeters: 200)
                    else { return }
                    model.select(time: track.points[index].t)
                }
            }
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .overlay(alignment: .bottom) {
                if model.replayActive, let s = model.sample {
                    ReplayHUD(speed: s.kmh, clock: Format.clock(seconds: s.t), wallClock: model.wallClock(s.t), km: Format.km(fromMeters: s.dist),
                              stop: TrackMath.stop(at: s.t, in: track.stops))
                        .padding(8)
                }
            }
            .onReceive(model.$cursor.throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)) { _ in
                // the follow-camera: re-centre on the bike a few times a second (not every tick, which would fight the map's own animation)
                if model.isPlaying && model.follow, let s = model.sample { centre(on: s) }
            }

            HStack(spacing: 10) {
                ForEach(SpeedColors.all.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(SpeedColors.all[i]).frame(width: 8, height: 8)
                        Text(SpeedColors.labels[i]).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                Text("km/h").font(.caption2).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(model.replayActive ? "Replay: the colour behind the bike is the part already ridden." : "Tap the route to see the speed at that spot.")
                .font(.caption).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: the chosen moment

    private var cursorPanel: some View {
        Panel(title: "At this point") {
            if let s = model.sample {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(s.kmh)").font(Theme.readout(54, weight: .bold)).foregroundStyle(Theme.text)
                    Text("KM/H").font(Theme.label).tracking(1.5).foregroundStyle(Theme.accent)
                    Spacer()
                    if let clock = model.wallClock(s.t) {
                        Text(clock).font(Theme.readout(22)).foregroundStyle(Theme.text)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Speed \(s.kmh) kilometres per hour")
                HStack {
                    StatTile(value: Format.km(fromMeters: s.dist), unit: "km", label: "Ridden so far")
                    StatTile(value: Format.clock(seconds: s.t), label: "Into the ride")
                    StatTile(value: s.altitude.map { String(Int($0.rounded())) } ?? "-", unit: s.altitude == nil ? "" : "m", label: "Altitude")
                }
                if let stop = TrackMath.stop(at: s.t, in: track.stops) {
                    Label("Standing still here: \(stop.label)", systemImage: "pause.circle.fill")
                        .font(.footnote).foregroundStyle(Theme.accent)
                }
                replayControls
                Slider(value: $model.cursor, in: 0...max(1, model.duration)).tint(Theme.accent)
                    .accessibilityLabel("Position in the ride")
                HStack(spacing: 10) {
                    Button("Start") { model.select(time: 0) }
                    if let top = track.maxSpeed { Button("Top speed \(top.kmh)") { jumpToTop(top) } }
                    Button("End") { model.select(time: model.duration) }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
    }

    // MARK: replay

    private var replayControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { model.restart() } label: { Image(systemName: "backward.end.fill").frame(width: 34, height: 34) }
                    .accessibilityLabel("Back to the start")
                Button {
                    if model.isPlaying {
                        model.pause()
                    } else {
                        model.play()
                        if model.follow, let s = model.sample { centre(on: s) }
                    }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 54, height: 40)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Color.black)
                }
                .accessibilityLabel(model.isPlaying ? "Pause the replay" : "Replay the ride")
                HStack(spacing: 6) {
                    ForEach(Replay.rates, id: \.self) { rate in
                        Button(Replay.label(rate)) { model.rate = rate }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(model.rate == rate ? Theme.accent : Theme.border.opacity(0.5), in: Capsule())
                            .foregroundStyle(model.rate == rate ? Color.black : Theme.text)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.replayActive {
                HStack {
                    Toggle("Follow the bike", isOn: $model.follow).tint(Theme.accent).font(.footnote)
                    Button("Done") {
                        model.finishReplay()
                        resetCamera()
                    }
                    .buttonStyle(.bordered).font(.footnote)
                }
            }
        }
        .foregroundStyle(Theme.text)
    }

    // MARK: speed over time

    private var chartPanel: some View {
        Panel(title: "Speed over time") {
            Chart {
                ForEach(track.stops) { stop in
                    RectangleMark(xStart: .value("From", stop.tStart / 60), xEnd: .value("To", stop.tEnd / 60))
                        .foregroundStyle(Theme.accent.opacity(0.2))
                }
                ForEach(model.chartPoints, id: \.t) { p in
                    LineMark(x: .value("Minutes", p.t / 60), y: .value("km/h", p.kmh))
                        .foregroundStyle(Theme.accent)
                }
                RuleMark(x: .value("Now", model.cursor / 60))
                    .foregroundStyle(Theme.text.opacity(0.8))
            }
            .chartXSelection(value: $selectedMinutes)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel().foregroundStyle(Theme.muted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel().foregroundStyle(Theme.muted)
                }
            }
            .chartXAxisLabel("minutes", alignment: .trailing)
            .frame(height: 160)
            .onChange(of: selectedMinutes) { _, minutes in
                if let minutes { model.select(time: minutes * 60) }
            }
            if !track.stops.isEmpty {
                Text("Shaded: standing still").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: stops

    private var stopsPanel: some View {
        Panel(title: "Stops") {
            Text(TrackMath.stopsSummary(count: track.stops.count, standingSeconds: track.stoppedS))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            ForEach(track.stops) { stop in
                Button { jump(to: stop) } label: { StopRow(stop: stop, wallClock: model.wallClock(stop.tStart)) }
                    .buttonStyle(.plain)
                Divider().overlay(Theme.border)
            }
            if track.featuresStatus == "unavailable" {
                Text("Couldn't look up traffic lights just now, so stops are not matched to lights. Pull down to try again.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if track.stops.contains(where: { $0.stopKind != .unknown }) {
                Text("Traffic lights and signs: © OpenStreetMap contributors").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: moving around

    private func centre(on s: TrackMath.Sample) {
        camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), distance: 700))
    }

    private func resetCamera() {
        if let fit = MapFit.rect(for: [model.coords]) {
            withAnimation { camera = .rect(fit) }
        }
    }

    private func jump(to stop: RideStop) {
        model.select(time: (stop.tStart + stop.tEnd) / 2)
        withAnimation {
            camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon), distance: 700))
        }
    }

    private func jumpToTop(_ top: TopSpeed) {
        model.select(time: top.t)
        withAnimation {
            camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon), distance: 900))
        }
    }
}

// MARK: - pieces

struct StopRow: View {
    let stop: RideStop
    let wallClock: String?

    var body: some View {
        HStack(spacing: 12) {
            StopIcon(kind: stop.stopKind).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.label).font(.subheadline).foregroundStyle(Theme.text)
                Text("at \(Format.km(fromMeters: stop.distFromStartM)) km" + (wallClock.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(Format.clock(seconds: stop.durationS)).font(Theme.readout(18)).foregroundStyle(Theme.text)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stop.label), stood still for \(Int(stop.durationS)) seconds")
    }
}

struct StopBadge: View {
    let stop: RideStop

    var body: some View {
        VStack(spacing: 2) {
            StopIcon(kind: stop.stopKind)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            Text(Format.clock(seconds: stop.durationS))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.surface, in: Capsule())
                .foregroundStyle(Theme.text)
        }
    }
}

struct StopIcon: View {
    let kind: StopKind

    var body: some View {
        switch kind {
        case .trafficLight:
            VStack(spacing: 1.5) {
                Circle().fill(Theme.danger).frame(width: 5, height: 5)
                Circle().fill(Color(hex: 0xFFD54F)).frame(width: 5, height: 5)
                Circle().fill(Theme.success).frame(width: 5, height: 5)
            }
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 3))
        case .stopSign: Image(systemName: "octagon.fill").foregroundStyle(Theme.danger)
        case .railCrossing: Image(systemName: "tram.fill").foregroundStyle(Theme.text)
        case .crossing: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        case .traffic: Image(systemName: "car.fill").foregroundStyle(Theme.accent)
        case .unknown: Image(systemName: "pause.fill").foregroundStyle(Theme.muted)
        }
    }
}

struct TopSpeedBadge: View {
    let kmh: Int

    var body: some View {
        Label("\(kmh)", systemImage: "gauge.high")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(Color.black)
            .accessibilityLabel("Top speed \(kmh) kilometres per hour")
    }
}

/// The spot being inspected: a dot with its speed above it.
struct CursorMarker: View {
    let kmh: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(kmh)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.bg, in: Capsule())
                .overlay(Capsule().stroke(Theme.accent, lineWidth: 1.5))
                .foregroundStyle(Theme.text)
            Circle().fill(Theme.accent).frame(width: 14, height: 14).overlay(Circle().stroke(Color.white, lineWidth: 2.5))
        }
    }
}

/// Speed, time and distance over the bottom of the map while replaying.
struct ReplayHUD: View {
    let speed: Int
    let clock: String
    let wallClock: String?
    let km: String
    let stop: RideStop?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text("\(speed)").font(Theme.readout(40, weight: .bold)).foregroundStyle(Theme.text)
                Text("km/h").font(Theme.label).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(wallClock.map { "\($0) · \(clock)" } ?? clock).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("\(km) km").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            if let stop {
                Label(stop.label, systemImage: "pause.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replay: \(speed) kilometres per hour, \(km) kilometres ridden")
    }
}
