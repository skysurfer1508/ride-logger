import ActivityKit
import SwiftUI
import WidgetKit

// The website's "Instrument Cluster" colours (static/style.css). Written out here because the widget extension does not share the app's Theme.
private let amber = Color(red: 1.0, green: 0.616, blue: 0.180)
private let dash = Color(red: 0.043, green: 0.047, blue: 0.055)
private let muted = Color(red: 0.545, green: 0.561, blue: 0.588)
private let danger = Color(red: 0.878, green: 0.341, blue: 0.290)

/// The speed, or dashes when the app has stopped updating (the system marks the activity stale) so a frozen number is never shown as live.
private func speedText(_ context: ActivityViewContext<RideActivityAttributes>) -> String {
    context.isStale ? "--" : "\(context.state.speedKmh)"
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RideActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(speedText(context))
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("KM/H").font(.caption2.weight(.semibold)).foregroundColor(amber)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(context.state.distanceKm)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("km").font(.caption2.weight(.semibold)).foregroundColor(amber)
                }
                HStack(spacing: 5) {
                    Image(systemName: "timer").foregroundColor(amber)
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
                .font(.subheadline)
                if context.isStale {
                    Label("Waiting for RideLog", systemImage: "exclamationmark.triangle").font(.caption2).foregroundColor(danger)
                } else if !context.state.gpsOK {
                    Label("GPS signal weak", systemImage: "location.slash").font(.caption2).foregroundColor(danger)
                } else {
                    Text("Top \(context.state.maxKmh) km/h").font(.caption2).foregroundColor(muted)
                }
            }
        }
        .padding(16)
    }
}

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(dash)
                .activitySystemActionForegroundColor(amber)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(speedText(context))
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("KM/H").font(.caption2.weight(.semibold)).foregroundColor(amber)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(context.state.distanceKm)
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("KM").font(.caption2.weight(.semibold)).foregroundColor(amber)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                        .font(.headline)
                        .foregroundColor(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("Top \(context.state.maxKmh) km/h", systemImage: "gauge.high").foregroundColor(muted)
                        Spacer()
                        if context.isStale {
                            Label("Waiting for RideLog", systemImage: "exclamationmark.triangle").foregroundColor(danger)
                        } else if !context.state.gpsOK {
                            Label("GPS weak", systemImage: "location.slash").foregroundColor(danger)
                        }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Text(speedText(context))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundColor(amber)
            } compactTrailing: {
                Text(context.state.distanceCompact)
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 48)
            } minimal: {
                Text(speedText(context))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundColor(amber)
                    .minimumScaleFactor(0.6)
            }
            .keylineTint(amber)
        }
    }
}
