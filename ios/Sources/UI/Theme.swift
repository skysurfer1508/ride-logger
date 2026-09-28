import SwiftUI

/// The website's "Instrument Cluster" look (static/style.css): a motorcycle's night-mode dash. Near-black, one gauge-amber accent,
/// tabular monospaced readouts, hairline dividers. Dark only, like a dash.
enum Theme {
    static let bg = Color(hex: 0x0B0C0E)
    static let surface = Color(hex: 0x101114)
    static let border = Color(hex: 0x2A2D33)
    static let text = Color(hex: 0xE8E6E1)
    static let muted = Color(hex: 0x8B8F96)
    static let accent = Color(hex: 0xFF9D2E)
    static let danger = Color(hex: 0xE0574A)
    static let success = Color(hex: 0x5FAE6B)

    /// A big readout number.
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// The small upper-case caption under or over a readout.
    static let label: Font = .system(size: 11, weight: .semibold).width(.condensed)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// One headline number with its unit and a caption: "88 km/h / AVG SPEED".
struct StatTile: View {
    let value: String
    var unit: String = ""
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(Theme.readout(26)).foregroundStyle(Theme.text).minimumScaleFactor(0.6).lineLimit(1)
                if !unit.isEmpty { Text(unit).font(Theme.label).foregroundStyle(Theme.accent) }
            }
            Text(label.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A bordered surface, like the website's panels.
struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased()).font(Theme.label).tracking(1.4).foregroundStyle(Theme.muted)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A one-line note above a screen that is showing saved data because the server couldn't be reached.
struct StaleNote: View {
    let message: String?

    var body: some View {
        if let message = message {
            Label(message, systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(message)
        }
    }
}

/// What a screen shows while it loads for the first time or when it has nothing to show but an error.
struct LoadFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.accent)
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.text)
            Button("Try again", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
