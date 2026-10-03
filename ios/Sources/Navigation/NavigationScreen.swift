import MapKit
import SwiftUI

/// The navigation display: big, dark and quiet. Everything that matters is spoken; the screen shows the next turn, the way, and how far is left.
struct NavigationScreen: View {
    @ObservedObject var nav: NavigationModel
    @ObservedObject private var speech = SpeechOutput.shared
    @ObservedObject private var recorder = AppServices.shared.recorder
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var confirmEnd = false
    @State private var simulatedKmh = 50.0
    private let blue = Color(hex: 0x3478F6)

    var body: some View {
        ZStack {
            map
            VStack(spacing: 0) {
                banner
                Spacer()
                if let offer = nav.rerouteOffer { rerouteCard(offer) }
                bottomBar
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .confirmationDialog("End navigation?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End navigation", role: .destructive) { nav.end() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("A ride that is being recorded keeps recording: stop it on the Record tab.")
        }
        .onChange(of: nav.simulatedPosition?.latitude) { _, _ in
            if let position = nav.simulatedPosition {
                camera = .camera(MapCamera(centerCoordinate: position, distance: 900, heading: 0, pitch: 0))
            }
        }
    }

    // MARK: map

    private var map: some View {
        Map(position: $camera) {
            if nav.isSimulating, let position = nav.simulatedPosition {
                Annotation("", coordinate: position, anchor: .center) {
                    Circle().fill(Theme.accent).frame(width: 18, height: 18).overlay(Circle().stroke(Color.white, lineWidth: 3))
                }
            } else {
                UserAnnotation()
            }
            if nav.coordinates.count > 1 {
                MapPolyline(coordinates: nav.coordinates).stroke(Color.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: nav.coordinates).stroke(blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let end = nav.destination {
                Annotation("", coordinate: end, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.danger).background(Circle().fill(Color.white))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {}
        .ignoresSafeArea()
    }

    // MARK: the next turn

    private var banner: some View {
        VStack(spacing: 6) {
            if nav.arrived {
                HStack(spacing: 14) {
                    Image(systemName: "flag.checkered").font(.system(size: 44, weight: .bold))
                    Text("You have arrived").font(.system(size: 28, weight: .bold))
                    Spacer()
                }
            } else if let maneuver = nav.nextManeuver {
                HStack(spacing: 16) {
                    Image(systemName: GuidanceText.symbol(forType: maneuver.type)).font(.system(size: 54, weight: .bold)).frame(width: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(GuidanceText.shortDistance(nav.status.distanceToNextM ?? 0)).font(Theme.readout(40, weight: .bold))
                        Text(GuidanceText.banner(maneuver)).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.up").font(.system(size: 44, weight: .bold))
                    Text(nav.loading ? "Getting the route…" : "Starting…").font(.title3.weight(.semibold))
                    Spacer()
                }
            }
            if nav.rerouting || nav.status.isOffRoute {
                Label(nav.rerouting ? "Recalculating…" : "Off the route", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.bold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.accent, in: Capsule())
            }
            if nav.exploring {
                HStack(spacing: 10) {
                    Label("Exploring: not rerouting", systemImage: "binoculars.fill").font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                    Button("Resume") { nav.stopExploring() }.buttonStyle(.bordered).font(.footnote.weight(.semibold))
                }
            }
            if nav.isSimulating {
                Label("SIMULATION: nothing is recorded", systemImage: "play.circle.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: the way left

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let problem = nav.problem { Text(problem).font(.footnote).foregroundStyle(Theme.accent) }
            if nav.isSimulating { simulationControls }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(nav.speedKmh)").font(Theme.readout(56, weight: .bold)).foregroundStyle(isOverLimit ? Theme.danger : Theme.text)
                    Text("KM/H").font(Theme.label).foregroundStyle(Theme.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Speed \(nav.speedKmh) kilometres per hour")
                if let limit = nav.status.limitKmh { limitSign(limit) }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    if let start = elapsedStart {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false).font(Theme.readout(30, weight: .bold)).foregroundStyle(Theme.text).monospacedDigit()
                    } else {
                        Text("0:00").font(Theme.readout(30, weight: .bold)).foregroundStyle(Theme.text)
                    }
                    Text("ELAPSED").font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Format.km(fromMeters: nav.status.remainingM)).font(Theme.readout(30, weight: .bold))
                    Text("KM LEFT").font(Theme.label).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.clock(seconds: nav.status.remainingS)).font(Theme.readout(30, weight: .bold))
                    Text("TIME · ARRIVE \(Format.time(Date().addingTimeInterval(nav.status.remainingS)))").font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
            .foregroundStyle(Theme.text)
            HStack(spacing: 12) {
                Button { nav.muted.toggle() } label: {
                    Label(nav.muted ? "Voice off" : "Voice on", systemImage: nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.bordered).tint(nav.muted ? Theme.accent : Theme.text)
                Button { if nav.arrived { nav.end() } else { confirmEnd = true } } label: {
                    Label(nav.arrived ? "Done" : "End", systemImage: "xmark").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(Theme.danger)
            }
            if speech.lastRoute.isEmpty == false {
                Text("Voice to: \(speech.lastRoute)").font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(14)
        .background(Theme.bg.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Where the elapsed time counts from: the start of the ride being recorded, otherwise the start of navigation.
    private var elapsedStart: Date? { (recorder.isRecording ? recorder.rideStartedAt : nil) ?? nav.startedAt }

    /// Over the limit of the road, with a little allowance for the GPS speed jittering.
    private var isOverLimit: Bool {
        guard let limit = nav.status.limitKmh else { return false }
        return nav.speedKmh > limit + 2
    }

    private func limitSign(_ kmh: Int) -> some View {
        Text("\(kmh)").font(.system(size: 24, weight: .bold)).foregroundStyle(Color.black).minimumScaleFactor(0.7)
            .frame(width: 54, height: 54)
            .background(Circle().fill(Color.white))
            .overlay(Circle().stroke(Color.red, lineWidth: 5))
            .accessibilityLabel("Speed limit \(kmh)")
    }

    /// Asked when the rider has left the route and Settings says to ask: big buttons for gloves. No answer picks the way back onto the route.
    private func rerouteCard(_ offer: RerouteOffer) -> some View {
        VStack(spacing: 12) {
            Text("You left the route").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(NavigationModel.offerSeconds - context.date.timeIntervalSince(offer.startedAt)) + 1)
                Text("Back onto your route in \(left) s unless you choose").font(.footnote).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 10) {
                Button { nav.choose(.rejoin) } label: { Text("Rejoin route").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button { nav.choose(.destination) } label: { Text("New route").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14) }
                    .buttonStyle(.bordered).tint(Theme.text)
            }
            Button { nav.choose(.explore) } label: { Label("Keep exploring", systemImage: "binoculars.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10) }
                .buttonStyle(.bordered).tint(Theme.muted)
        }
        .padding(14)
        .background(Theme.bg.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var simulationControls: some View {
        HStack(spacing: 10) {
            ForEach([50.0, 90.0], id: \.self) { kmh in
                Button("\(Int(kmh)) km/h") { simulatedKmh = kmh; nav.setSimulationSpeed(kmh: kmh) }
                    .buttonStyle(.bordered).tint(simulatedKmh == kmh ? Theme.accent : Theme.muted)
            }
            Button("Skip 2 km") { nav.skipAhead() }.buttonStyle(.bordered)
            Spacer()
        }
        .font(.footnote.weight(.semibold))
    }
}
