import MapKit
import SwiftUI

struct RecordView: View {
    @ObservedObject var recorder: RideRecorder
    @ObservedObject var uploader: RideUploader
    @ObservedObject var activeRoute: ActiveRouteModel
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Group {
                if recorder.isRecording {
                    RecordingDashboard(recorder: recorder, uploader: uploader, activeRoute: activeRoute, confirmStop: $confirmStop)
                } else {
                    IdleView(recorder: recorder, uploader: uploader, activeRoute: activeRoute)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Finish this ride?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Finish and upload") { recorder.stop() }
                if recorder.canDiscard {
                    Button("Discard this ride", role: .destructive) { recorder.stop(discard: true) }
                }
                Button("Keep recording", role: .cancel) {}
            } message: {
                Text(recorder.canDiscard ? "It hasn't been uploaded yet, so you can still discard it." : "Part of it is already on your server, so it will be finished, not discarded.")
            }
            .alert("Recording", isPresented: Binding(get: { recorder.errorMessage != nil }, set: { if !$0 { recorder.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(recorder.errorMessage ?? "")
            }
        }
    }
}

// MARK: - not recording

private struct IdleView: View {
    @ObservedObject var recorder: RideRecorder
    @ObservedObject var uploader: RideUploader
    @ObservedObject var activeRoute: ActiveRouteModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let record = recorder.interrupted { interruptedCard(record) }
                if let summary = recorder.summary { SummaryCard(summary: summary) { recorder.dismissSummary() } }
                permissionCards
                if let route = activeRoute.route { RouteReadyCard(route: route) { activeRoute.clear() } }

                Button {
                    recorder.start()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "record.circle").font(.system(size: 44))
                        Text("START").font(.system(size: 26, weight: .bold).width(.condensed)).tracking(3)
                    }
                    .foregroundStyle(Theme.bg)
                    .frame(width: 190, height: 190)
                    .background(Circle().fill(recorder.canStart ? Theme.accent : Theme.muted.opacity(0.4)))
                }
                .disabled(!recorder.canStart)
                .padding(.vertical, 12)
                .accessibilityLabel("Start recording a ride")

                UploadStatus(uploader: uploader)

                Text("Mount the phone, press Start and lock the screen. RideLog keeps recording in the background; the blue location indicator shows it is running. Press Stop when you arrive.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var permissionCards: some View {
        if recorder.authorization == .notDetermined {
            Panel(title: "Location access") {
                Text("RideLog needs your location to record a ride. It is only used while you are recording, and only sent to your own server.")
                    .font(.subheadline).foregroundStyle(Theme.text)
                Button("Allow location") { recorder.requestPermission() }.buttonStyle(.borderedProminent)
            }
        } else if recorder.isDenied {
            Panel(title: "Location is off") {
                Text("Turn on location for RideLog in Settings (Location → While Using the App) to record rides.")
                    .font(.subheadline).foregroundStyle(Theme.text)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if !recorder.isPrecise {
            Panel(title: "Precise location is off") {
                Text("With approximate location a ride's route and speed would be inaccurate.").font(.subheadline).foregroundStyle(Theme.text)
                Button("Turn on precise location") { recorder.requestPreciseLocation() }.buttonStyle(.borderedProminent)
            }
        }
        if uploader.credentials == nil {
            Panel(title: "Linking this phone") {
                Text("RideLog has to link this phone to your account once, and needs a connection for that.").font(.subheadline).foregroundStyle(Theme.text)
                Button("Try again") { Task { await uploader.refreshCredentials() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func interruptedCard(_ record: TripRecord) -> some View {
        Panel(title: "A ride was cut off") {
            Text("The app was closed while a ride from \(record.startedAt.formatted(date: .abbreviated, time: .shortened)) was being recorded. Nothing recorded so far is lost.")
                .font(.subheadline).foregroundStyle(Theme.text)
            if recorder.interruptedCanResume {
                Button("Resume recording") { recorder.resumeInterrupted() }.buttonStyle(.borderedProminent)
            } else {
                Text("It stopped too long ago to carry on without drawing a false line across the gap.").font(.footnote).foregroundStyle(Theme.muted)
            }
            Button("Finish and upload it") { recorder.finishInterrupted() }
            if record.uploadedCount == 0 {
                Button("Discard it", role: .destructive) { recorder.discardInterrupted() }
            }
        }
    }
}

private struct SummaryCard: View {
    let summary: RideRecorder.Summary
    let dismiss: () -> Void

    var body: some View {
        Panel(title: summary.discarded ? "Ride discarded" : "Ride finished") {
            if summary.discarded {
                Text("That one was too short to keep.").font(.subheadline).foregroundStyle(Theme.text)
            } else {
                HStack {
                    StatTile(value: Format.km(fromMeters: summary.distanceM), unit: "km", label: "Distance")
                    StatTile(value: Format.clock(seconds: summary.durationS), label: "Time")
                }
                HStack {
                    StatTile(value: "\(summary.avgKmh)", unit: "km/h", label: "Avg")
                    StatTile(value: "\(summary.maxKmh)", unit: "km/h", label: "Top")
                }
                Text("It appears under Rides once it has uploaded.").font(.footnote).foregroundStyle(Theme.muted)
            }
            Button("Dismiss", action: dismiss)
        }
    }
}

/// "All rides uploaded" / "12 points waiting" / the last problem, in one line.
struct UploadStatus: View {
    @ObservedObject var uploader: RideUploader

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if uploader.isSending {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Uploading…")
                } else if uploader.unsentPoints > 0 || uploader.unsentRides > 0 {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("\(uploader.unsentPoints) points waiting to upload")
                } else {
                    Image(systemName: "checkmark.circle")
                    Text("Everything is uploaded")
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.muted)
            if let problem = uploader.lastError {
                Text(problem).font(.caption).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
            }
            if uploader.unsentPoints > 0 && !uploader.isSending {
                Button("Upload now") { Task { await uploader.syncAll() } }.font(.footnote)
            }
        }
    }
}

// MARK: - recording

private struct RecordingDashboard: View {
    @ObservedObject var recorder: RideRecorder
    @ObservedObject var uploader: RideUploader
    @ObservedObject var activeRoute: ActiveRouteModel
    @Binding var confirmStop: Bool

    var body: some View {
        // `elapsed` changes every second, so this view is redrawn each second and the "how old is the last fix" checks below stay current.
        let now = Date()
        let speed = RecordingLogic.displayedSpeedKmh(latest: recorder.latest, now: now)
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Theme.danger).frame(width: 10, height: 10)
                    Text(Format.clock(seconds: recorder.elapsed)).font(Theme.readout(30))
                }
                Spacer()
                GPSChip(quality: RecordingLogic.quality(of: recorder.latest, now: now), accuracy: recorder.latest?.horizontalAccuracy)
            }
            .foregroundStyle(Theme.text)

            VStack(spacing: 0) {
                Text("\(speed)")
                    .font(Theme.readout(112, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("KM/H").font(Theme.label).tracking(2).foregroundStyle(Theme.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speed \(speed) kilometres per hour")

            HStack {
                StatTile(value: Format.km(fromMeters: recorder.stats.distanceM), unit: "km", label: "Distance")
                StatTile(value: "\(RecordingLogic.averageKmh(distanceM: recorder.stats.distanceM, elapsed: recorder.elapsed))", unit: "km/h", label: "Average")
                StatTile(value: "\(Format.kmh(fromMps: recorder.stats.maxSpeedMps))", unit: "km/h", label: "Top")
            }

            if activeRoute.route != nil { FollowCard(activeRoute: activeRoute, latest: recorder.latest) }

            LiveMap(route: recorder.route, planned: activeRoute.coordinates)
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            UploadStatus(uploader: uploader)

            Button {
                confirmStop = true
            } label: {
                Text("STOP")
                    .font(.system(size: 22, weight: .bold).width(.condensed)).tracking(3)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
        }
        .padding(16)
    }
}

private struct GPSChip: View {
    let quality: RecordingLogic.GPSQuality
    let accuracy: Double?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "location.fill")
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
        .accessibilityLabel("GPS \(text)")
    }

    private var text: String {
        switch quality {
        case .none: return "Searching…"
        case .good, .fair, .weak: return "GPS ±\(Int((accuracy ?? 0).rounded())) m"
        }
    }

    private var color: Color {
        switch quality {
        case .good: return Theme.success
        case .fair: return Theme.accent
        case .weak, .none: return Theme.danger
        }
    }
}

/// The route so far, following the bike.
private struct LiveMap: View {
    let route: [CLLocationCoordinate2D]
    var planned: [CLLocationCoordinate2D] = []
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            UserAnnotation()
            if planned.count > 1 {
                MapPolyline(coordinates: planned).stroke(Color(hex: 0x3478F6).opacity(0.8), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if route.count > 1 {
                MapPolyline(coordinates: route).stroke(Theme.accent, lineWidth: 4)
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }
}

/// A planned route is set but the ride has not started.
private struct RouteReadyCard: View {
    let route: ActiveRoute
    let clear: () -> Void

    var body: some View {
        Panel(title: "Route ready") {
            Text(route.name).font(.headline).foregroundStyle(Theme.text)
            Text("\(PlannerLogic.kmText(route.distanceKm)). Start the ride and this shows how far along you are and how far off the line, in blue on the map. No turn-by-turn.")
                .font(.footnote).foregroundStyle(Theme.muted)
            Button("Clear route", role: .destructive, action: clear).buttonStyle(.bordered)
        }
    }
}

/// How far along the planned route the rider is, and how far off its line. Distances only.
private struct FollowCard: View {
    @ObservedObject var activeRoute: ActiveRouteModel
    let latest: LocationSample?

    var body: some View {
        if let route = activeRoute.route {
            let progress = latest.flatMap { activeRoute.progress(lat: $0.latitude, lon: $0.longitude) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "location.north.line.fill").foregroundStyle(Color(hex: 0x3478F6))
                    Text(route.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    if let progress {
                        Text(PlannerLogic.offRouteText(progress)).font(.caption.weight(.bold)).foregroundStyle(progress.isOffRoute ? Theme.accent : Theme.success)
                    } else {
                        Text("Waiting for GPS").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if let progress {
                    ProgressView(value: progress.fraction).tint(progress.isOffRoute ? Theme.accent : Color(hex: 0x3478F6))
                    HStack {
                        Text(PlannerLogic.progressText(progress, totalKm: route.distanceKm)).font(.caption).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(PlannerLogic.kmText(progress.remainingM / 1000)) to go").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }
}
