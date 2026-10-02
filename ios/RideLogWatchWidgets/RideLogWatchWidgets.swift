import SwiftUI
import WidgetKit

/// The complication: kilometres this week and the last ride, from what the Watch app last received from the iPhone.
struct RideLogEntry: TimelineEntry {
    let date: Date
    let stats: WatchStats?
}

struct RideLogProvider: TimelineProvider {
    func placeholder(in context: Context) -> RideLogEntry {
        RideLogEntry(date: Date(), stats: WatchStats(weekKm: 120, lastRideKm: 45, lastRideAt: Date(), updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (RideLogEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RideLogEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func current() -> RideLogEntry {
        RideLogEntry(date: Date(), stats: WatchStatsStore.shared()?.load())
    }
}

struct RideLogComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RideLogEntry

    private var week: String { entry.stats.map { WatchPolicy.kmText($0.weekKm) } ?? "--" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text(week).font(.system(.title3, design: .rounded).weight(.bold)).minimumScaleFactor(0.6).lineLimit(1)
                Text("km").font(.caption2)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("RideLog").font(.headline)
                Text("\(week) km this week").font(.caption)
                if let stats = entry.stats, let km = stats.lastRideKm, let at = stats.lastRideAt {
                    Text("Last: \(WatchPolicy.kmText(km)) km, \(WatchPolicy.dayText(at, now: entry.date))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .accessoryCorner:
            Text(week).font(.system(.title3, design: .rounded).weight(.bold)).widgetLabel("km this week")
        default:
            Text("\(week) km this week")
        }
    }
}

struct RideLogComplication: Widget {
    let kind = "RideLogComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RideLogProvider()) { entry in
            RideLogComplicationView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("RideLog")
        .description("Kilometres this week and your last ride.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct RideLogWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RideLogComplication()
    }
}
