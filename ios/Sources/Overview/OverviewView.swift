import Charts
import SwiftUI

/// Totals, weekly distance, records and the 90-day heatmap. Pushed from Home (so it uses Home's navigation stack, which also opens a record's ride).
struct OverviewScreen: View {
    let api: APIClient

    var body: some View {
        LoaderScreen(api: api, path: "overview") { (overview: OverviewResponse) in
            OverviewContent(overview: overview)
        }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OverviewContent: View {
    let overview: OverviewResponse
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(spacing: 14) {
            Panel {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    StatTile(value: overview.totalDistanceDisplay, unit: "km", label: "Total distance")
                    StatTile(value: "\(overview.rideCount)", label: "Rides logged")
                    StatTile(value: overview.avgSpeedDisplay, unit: "km/h", label: "Avg speed")
                    StatTile(value: overview.longestRideDisplay, unit: "km", label: "Longest ride")
                }
            }

            if !overview.weekly.isEmpty {
                Panel(title: "Distance / week") {
                    WeeklyChart(weeks: Array(overview.weekly.suffix(12)))
                }
            }

            RecordsSection(records: overview.records)

            Panel(title: "Last 90 days") {
                HeatmapView(cells: overview.calendar)
            }
        }
    }
}

private struct WeeklyChart: View {
    let weeks: [WeekTotal]

    var body: some View {
        Chart(weeks) { week in
            BarMark(x: .value("Week", week.week), y: .value("Kilometres", week.km))
                .foregroundStyle(Theme.accent)
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let week = value.as(String.self) { Text(Format.weekLabel(week)).foregroundStyle(Theme.muted) }
                }
            }
        }
        .frame(height: 170)
        .accessibilityLabel("Distance per week, last \(weeks.count) weeks with rides")
    }
}

private struct RecordItem: Identifiable {
    let label: String
    let value: String
    let unit: String
    let ride: RideSummary
    var id: String { label }
}

private struct RecordsSection: View {
    let records: Records

    private var items: [RecordItem] {
        var out: [RecordItem] = []
        if let r = records.longest { out.append(RecordItem(label: "Longest ride", value: String(format: "%.1f", r.distanceKm), unit: "km", ride: r)) }
        if let r = records.fastestAvg { out.append(RecordItem(label: "Best avg speed", value: "\(r.avgKmh)", unit: "km/h", ride: r)) }
        if let r = records.fastestTop { out.append(RecordItem(label: "Top speed", value: "\(r.maxKmh)", unit: "km/h", ride: r)) }
        if let r = records.mostClimb { out.append(RecordItem(label: "Most elevation", value: "\(r.elevationGainM)", unit: "m", ride: r)) }
        if let r = records.longestTime { out.append(RecordItem(label: "Longest duration", value: r.durationHm, unit: "", ride: r)) }
        return out
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PERSONAL RECORDS").font(Theme.label).tracking(1.4).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(items) { item in
                        NavigationLink(value: item.ride) {
                            Panel { StatTile(value: item.value, unit: item.unit, label: item.label) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// One square per day, oldest first, seven to a column, darker amber = further that day (the website's heatmap).
private struct HeatmapView: View {
    let cells: [CalendarCell]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(16), spacing: 4), count: 7), spacing: 4) {
                ForEach(cells) { cell in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: cell.level))
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("\(cell.date): \(String(format: "%.1f", cell.km)) km")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func color(for level: Int) -> Color {
        switch level {
        case 1: return Theme.accent.opacity(0.3)
        case 2: return Theme.accent.opacity(0.55)
        case 3: return Theme.accent.opacity(0.8)
        case 4: return Theme.accent
        default: return Theme.border.opacity(0.6)
        }
    }
}
