import SwiftUI

/// A ride as a card: date, big distance, and the numbers under it.
struct RideCard: View {
    let ride: RideSummary
    var prominent = false

    var body: some View {
        Panel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.shortDay(iso: ride.startTime)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(Format.time(iso: ride.startTime)).font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", ride.distanceKm)).font(Theme.readout(prominent ? 34 : 26)).foregroundStyle(Theme.text)
                    Text("km").font(Theme.label).foregroundStyle(Theme.accent)
                }
            }
            HStack {
                StatTile(value: ride.durationHm, label: "Duration")
                StatTile(value: "\(ride.avgKmh)", unit: "km/h", label: "Avg")
                StatTile(value: "\(ride.maxKmh)", unit: "km/h", label: "Top")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One line in the rides list.
struct RideRow: View {
    let ride: RideSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.shortDay(iso: ride.startTime)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text("\(Format.time(iso: ride.startTime)) · \(ride.durationHm) h · \(ride.avgKmh) avg · \(ride.maxKmh) top km/h")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", ride.distanceKm)).font(Theme.readout(20)).foregroundStyle(Theme.text)
                Text("km").font(Theme.label).foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
