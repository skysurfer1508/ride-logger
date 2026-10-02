import Charts
import SwiftUI

// The panels under the speed chart: weather, speed against the limit, elevation and smoothness. Each takes plain values (the model decoded in
// API/InsightsModels.swift) and says in words when its part is not available, so a failing service never leaves a blank or a broken screen.

/// Pink glow under a stretch ridden over the limit, in the map and its legend.
enum LimitColors {
    static let over = Color(hex: 0xFF2D6F)
}

struct InsightsLoadingPanel: View {
    var body: some View {
        Panel(title: "Insights") {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text("Looking up the weather and the speed limits…").font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct InsightsFailedPanel: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Panel(title: "Insights") {
            Text("Couldn't load the weather, speed limits and elevation. \(message)").font(.footnote).foregroundStyle(Theme.muted)
            Button("Try again", action: retry).buttonStyle(.bordered).font(.footnote)
        }
    }
}

struct WeatherPanel: View {
    let weather: WeatherInfo

    var body: some View {
        Panel(title: "Weather") {
            if weather.status == "ok" {
                HStack(spacing: 14) {
                    Image(systemName: InsightsLogic.weatherSymbol(weather)).font(.system(size: 34)).foregroundStyle(Theme.accent).frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weather.condition ?? "").font(.headline).foregroundStyle(Theme.text)
                        Text([InsightsLogic.temperatureText(weather), InsightsLogic.rainText(weather)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                HStack {
                    StatTile(value: weather.windMaxKmh.map { "\($0)" } ?? "-", unit: "km/h", label: "Wind")
                    StatTile(value: weather.gustMaxKmh.map { "\($0)" } ?? "-", unit: "km/h", label: "Gusts")
                    StatTile(value: weather.precipitationMm.map { String(format: "%.1f", $0) } ?? "-", unit: "mm", label: "Rain")
                }
                Text("The weather in the area where the ride started, hour by hour, not measured on your bike. " + (weather.attribution ?? ""))
                    .font(.caption2).foregroundStyle(Theme.muted)
            } else if weather.status == "disabled" {
                Text("The weather lookup is switched off on the server.").font(.footnote).foregroundStyle(Theme.muted)
            } else {
                Text(weather.message ?? "The weather is not available right now. Pull down to try again.").font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct LimitsPanel: View {
    let limits: LimitsInfo
    let jump: (LimitStretch) -> Void

    var body: some View {
        Panel(title: "Speed against the limit") {
            if let message = InsightsLogic.limitsStatusText(limits.status) {
                Text(message).font(.footnote).foregroundStyle(Theme.muted)
            } else if let tagged = limits.tagged {
                Text(InsightsLogic.overLimitSummary(tagged)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                if tagged.overSeconds > 0 {
                    HStack {
                        StatTile(value: Format.clock(seconds: Double(tagged.overSeconds)), label: "Over the limit")
                        StatTile(value: Format.clock(seconds: Double(tagged.notableSeconds)), label: "5+ km/h over")
                        StatTile(value: Format.km(fromMeters: Double(tagged.overMetres)), unit: "km", label: "Distance over")
                    }
                }
                if let worst = limits.worst {
                    Label(InsightsLogic.worstText(worst), systemImage: "gauge.high").font(.footnote.weight(.semibold)).foregroundStyle(LimitColors.over)
                }
                ForEach(limits.stretches ?? []) { stretch in
                    Button { jump(stretch) } label: { StretchRow(stretch: stretch) }.buttonStyle(.plain)
                    Divider().overlay(Theme.border)
                }
                if let estimated = limits.estimated, estimated.seconds > 0 {
                    Text("Roads without a limit on the map (\(estimated.seconds / 60) min): a typical limit for the road type is assumed, \(Format.clock(seconds: Double(estimated.overSeconds))) over it. This is a guess, and is not counted above.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Text("Your GPS speed against the limit written on the map (\(limits.taggedShare.map { String(format: "%.0f", $0) } ?? "-") % of the ride had one). Map limits can be missing or out of date, GPS speed can be off by a few km/h, and no tolerance is applied: this is for you, not a ticket. Roads © OpenStreetMap contributors.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct StretchRow: View {
    let stretch: LimitStretch

    var body: some View {
        HStack(spacing: 12) {
            Text("\(stretch.limitKmh)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white))
                .overlay(Circle().stroke(Theme.danger, lineWidth: 3))
                .foregroundStyle(Color.black)
            VStack(alignment: .leading, spacing: 2) {
                Text(stretch.name ?? "Road without a name").font(.subheadline).foregroundStyle(Theme.text)
                Text("at \(Format.km(fromMeters: stretch.distStartM)) km · up to \(stretch.maxKmh) km/h").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text("+\(stretch.maxOverKmh)").font(Theme.readout(18)).foregroundStyle(LimitColors.over)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stretch.maxOverKmh) kilometres per hour over a \(stretch.limitKmh) limit" + (stretch.name.map { " on \($0)" } ?? ""))
    }
}

struct ElevationPanel: View {
    let profile: ElevationProfile
    let cursorMetres: Double
    let select: (Double) -> Void
    @State private var selectedKm: Double?

    init(profile: ElevationProfile, cursorMetres: Double, select: @escaping (Double) -> Void) {
        self.profile = profile
        self.cursorMetres = cursorMetres
        self.select = select
    }

    var body: some View {
        Panel(title: "Elevation") {
            HStack {
                StatTile(value: "\(profile.ascentM)", unit: "m", label: "Climbed")
                StatTile(value: "\(profile.descentM)", unit: "m", label: "Descended")
                StatTile(value: "\(profile.maxM)", unit: "m", label: "Highest")
            }
            let low = Double(profile.minM) - 10, high = Double(profile.maxM) + 10
            Chart {
                ForEach(Array(profile.points.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("km", p.dist / 1000), yStart: .value("base", low), yEnd: .value("m", p.altitude))
                        .foregroundStyle(Theme.accent.opacity(0.18))
                    LineMark(x: .value("km", p.dist / 1000), y: .value("m", p.altitude))
                        .foregroundStyle(Theme.accent)
                }
                RuleMark(x: .value("Now", cursorMetres / 1000)).foregroundStyle(Theme.text.opacity(0.8))
            }
            .chartYScale(domain: low...high)
            .chartXSelection(value: $selectedKm)
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
            .chartXAxisLabel("km", alignment: .trailing)
            .frame(height: 140)
            .onChange(of: selectedKm) { _, km in
                if let km { select(km * 1000) }
            }
            Text("Altitude from the phone's GPS, smoothed. A barometer would be more exact.").font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}

struct SmoothnessPanel: View {
    let smoothness: Smoothness
    let jump: (SmoothnessEvent) -> Void

    var body: some View {
        Panel(title: "Smoothness") {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(smoothness.score)").font(Theme.readout(40, weight: .bold)).foregroundStyle(Theme.text)
                Text("/ 100").font(Theme.label).foregroundStyle(Theme.accent)
                Text(InsightsLogic.scoreWord(smoothness.score)).font(.subheadline).foregroundStyle(Theme.muted)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Smoothness \(smoothness.score) out of 100, \(InsightsLogic.scoreWord(smoothness.score))")
            HStack {
                StatTile(value: "\(smoothness.hardBraking)", label: "Hard braking")
                StatTile(value: "\(smoothness.hardAcceleration)", label: "Hard accel.")
                StatTile(value: String(format: "%.1f", smoothness.eventsPer10km), unit: "/10 km", label: "Rate")
            }
            ForEach(smoothness.events.prefix(12)) { event in
                Button { jump(event) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: event.isBraking ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(event.isBraking ? Theme.danger : Theme.accent)
                        Text(InsightsLogic.eventText(event)).font(.subheadline).foregroundStyle(Theme.text)
                        Spacer()
                        Text(String(format: "%.1f m/s²", abs(event.peakMps2))).font(.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if smoothness.events.count > 12 {
                Text("and \(smoothness.events.count - 12) more").font(.caption).foregroundStyle(Theme.muted)
            }
            Text("Worked out from your GPS speed once a second, which misses the sharpest peaks: use it to compare your own rides, not as a measurement of g.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}
