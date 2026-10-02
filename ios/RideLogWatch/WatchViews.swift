import SwiftUI

struct WatchRootView: View {
    @ObservedObject var session: WatchSession
    @State private var confirmStop = false

    var body: some View {
        // redrawn every second so the "has the iPhone gone quiet" check below stays current
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let snapshot = session.snapshot, snapshot.recording {
                    recording(snapshot, now: context.date)
                } else {
                    idle(now: context.date)
                }
            }
        }
        .confirmationDialog("Finish this ride?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Finish and upload", role: .destructive) { session.send(.stop) }
            Button("Keep recording", role: .cancel) {}
        }
    }

    // MARK: recording

    private func recording(_ snapshot: WatchSnapshot, now: Date) -> some View {
        let stale = WatchPolicy.isStale(snapshot, now: now)
        return VStack(spacing: 2) {
            if stale {
                Text("Waiting for iPhone…").font(.caption2).foregroundStyle(.orange)
            } else if !snapshot.gpsOK {
                Text("Searching for GPS…").font(.caption2).foregroundStyle(.orange)
            }
            Text(stale ? "--" : "\(snapshot.speedKmh)")
                .font(.system(size: 62, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("KM/H").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.distanceText).font(.title3.weight(.bold).monospacedDigit())
                    Text("KM").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    if let started = snapshot.startedAt {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false).font(.title3.weight(.bold).monospacedDigit())
                    } else {
                        Text("--:--").font(.title3.weight(.bold))
                    }
                    Text("TIME").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            Button(role: .destructive) { confirmStop = true } label: { Text("Stop").frame(maxWidth: .infinity) }
                .disabled(session.busy)
            if let message = session.message { Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
    }

    // MARK: not recording

    private func idle(now: Date) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Button { session.send(.start) } label: {
                    Label("Start ride", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(session.busy)
                if let stats = session.stats {
                    VStack(spacing: 2) {
                        Text("\(WatchPolicy.kmText(stats.weekKm)) km this week").font(.footnote.weight(.semibold))
                        if let km = stats.lastRideKm, let at = stats.lastRideAt {
                            Text("Last ride \(WatchPolicy.kmText(km)) km, \(WatchPolicy.dayText(at, now: now))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let message = session.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if !session.reachable {
                    Text("iPhone not in reach").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
