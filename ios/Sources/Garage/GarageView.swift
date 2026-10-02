import SwiftUI
import UserNotifications

/// Your bikes, with the odometer and what is due. Reached from a row on Home.
struct GarageView: View {
    let api: APIClient
    @State private var bikes: [BikeSummary] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var showAdd = false
    @State private var notificationsAllowed = true

    private var somethingDue: Bool { bikes.contains { $0.overdue + $0.soon > 0 } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading) }
                if loaded && bikes.isEmpty {
                    Panel(title: "No bike yet") {
                        Text("Add your bike to keep its odometer, service reminders, fuel and costs. New rides count towards its odometer by themselves.")
                            .font(.subheadline).foregroundStyle(Theme.text)
                        Button("Add a bike") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                }
                if somethingDue && !notificationsAllowed {
                    Panel(title: "Reminders") {
                        Text("Something is due or coming up. Allow notifications to be reminded in the evening when you open the app.").font(.footnote).foregroundStyle(Theme.text)
                        Button("Allow notifications") {
                            AppServices.shared.autoStart.requestNotificationPermission()
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refreshNotificationState() }
                        }.buttonStyle(.bordered)
                    }
                }
                ForEach(bikes) { bike in
                    NavigationLink { BikeDetailView(api: api, bikeId: bike.id) } label: { BikeCard(bike: bike) }.buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Garage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add a bike")
            }
        }
        .sheet(isPresented: $showAdd) {
            FormSheet(title: "New bike", fields: [
                FormField(id: "name", label: "Name, e.g. Tuono"),
                FormField(id: "make", label: "Make (optional)"),
                FormField(id: "model", label: "Model (optional)"),
                FormField(id: "year", label: "Year (optional)", kind: .number),
                FormField(id: "start_odometer_km", label: "Odometer now (km)", kind: .number, footer: "New rides are added to this by themselves."),
            ]) { values in
                await send {
                    let _: BikeDetail = try await api.post("garage/bikes", form: values)
                }
            }
        }
        .task {
            await load()
            await refreshNotificationState()
        }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .ridesChanged)) { _ in Task { await load() } }
    }

    private func refreshNotificationState() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsAllowed = status == .authorized || status == .provisional
    }

    private func load() async {
        do {
            let overview: GarageOverview = try await api.get("garage")
            bikes = overview.bikes
            errorText = nil
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
        loaded = true
    }

    /// Runs a change, reloads the list, and turns a failure into the sentence to show in the form.
    private func send(_ change: () async throws -> Void) async -> String? {
        do {
            try await change()
            await load()
            return nil
        } catch APIError.unauthorized {
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }
}

struct BikeCard: View {
    let bike: BikeSummary

    var body: some View {
        Panel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bike.name).font(.headline).foregroundStyle(Theme.text)
                        if bike.isDefault { Text("DEFAULT").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(Theme.accent, in: Capsule()).foregroundStyle(Color.black) }
                    }
                    if !bike.subtitle.isEmpty { Text(bike.subtitle).font(.subheadline).foregroundStyle(Theme.muted) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.0f", bike.odometerKm)).font(Theme.readout(26)).foregroundStyle(Theme.text)
                    Text("KM").font(Theme.label).foregroundStyle(Theme.accent)
                }
            }
            if let due = bike.nextDue {
                Label("\(due.name): \(GarageLogic.dueText(ServiceStatus(state: due.state, dueKm: due.dueKm, dueDate: due.dueDate, remainingKm: due.remainingKm, remainingDays: due.remainingDays, limitedBy: due.limitedBy)))",
                      systemImage: due.state == "overdue" ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(due.state == "overdue" ? Theme.danger : Theme.accent)
            }
        }
    }
}
