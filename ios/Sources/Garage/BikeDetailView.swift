import Charts
import SwiftUI

/// One bike: odometer, services (with what is due), fuel and consumption, other costs.
struct BikeDetailView: View {
    let api: APIClient
    let bikeId: Int
    @Environment(\.dismiss) private var dismiss
    @State private var detail: BikeDetail?
    @State private var errorText: String?
    @State private var sheet: Sheet?
    @State private var confirmDelete = false

    enum Sheet: Identifiable {
        case odometer, addService, fuel, expense, edit
        case done(ServiceItem)

        var id: String {
            switch self {
            case .odometer: return "odometer"
            case .addService: return "addService"
            case .fuel: return "fuel"
            case .expense: return "expense"
            case .edit: return "edit"
            case .done(let item): return "done-\(item.id)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading) }
                if let detail {
                    header(detail)
                    servicePanel(detail)
                    fuelPanel(detail)
                    costPanel(detail)
                    actions(detail)
                } else if errorText == nil {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(detail?.bike.name ?? "Bike")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { sheet in sheetView(sheet) }
        .confirmationDialog("Delete this bike?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete bike and its records", role: .destructive) { Task { await deleteBike() } }
        } message: {
            Text("Its services, fuel and costs are deleted. Your rides stay.")
        }
        .task { await load() }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .ridesChanged)) { _ in Task { await load() } }
    }

    // MARK: sections

    private func header(_ d: BikeDetail) -> some View {
        Panel {
            HStack(alignment: .lastTextBaseline) {
                Text(String(format: "%.0f", d.bike.odometerKm)).font(Theme.readout(44, weight: .bold)).foregroundStyle(Theme.text)
                Text("KM").font(Theme.label).foregroundStyle(Theme.accent)
                Spacer()
                Button("Set odometer") { sheet = .odometer }.buttonStyle(.bordered).font(.footnote)
            }
            Text("\(String(format: "%.0f", d.bike.riddenKm)) km ridden in RideLog since \(d.bike.startDate). New rides are added by themselves.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private func servicePanel(_ d: BikeDetail) -> some View {
        Panel(title: "Service") {
            if d.items.isEmpty {
                Text("Add what you want to be reminded about: oil, chain, tyres, brake fluid, the yearly inspection.").font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(d.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Done") { sheet = .done(item) }.buttonStyle(.bordered).font(.footnote)
                    }
                    Text(GarageLogic.dueText(item.status))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(color(for: item.status.serviceState))
                    HStack(spacing: 6) {
                        Text(item.intervalText)
                        if let more = GarageLogic.dueDetail(item.status) { Text("· \(more)") }
                        if let date = item.lastDoneDate { Text("· last \(date)") }
                    }
                    .font(.caption).foregroundStyle(Theme.muted)
                }
                .contextMenu { Button("Delete this service", role: .destructive) { Task { await remove("garage/items/\(item.id)") } } }
                Divider().overlay(Theme.border)
            }
            Button("Add a service") { sheet = .addService }.buttonStyle(.bordered)
            if !d.serviceLog.isEmpty {
                Text("DONE").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted).padding(.top, 6)
                ForEach(d.serviceLog.prefix(8)) { log in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(log.itemName).font(.footnote).foregroundStyle(Theme.text)
                            Text([log.doneDate, log.odometerKm.map { GarageLogic.odometer($0) }, log.note.isEmpty ? nil : log.note].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if let cost = log.cost { Text(GarageLogic.money(cost)).font(.footnote).foregroundStyle(Theme.text) }
                        Button(role: .destructive) { Task { await remove("garage/service-log/\(log.id)") } } label: { Image(systemName: "trash") }
                            .font(.footnote).accessibilityLabel("Delete this entry")
                    }
                }
            }
        }
    }

    private func fuelPanel(_ d: BikeDetail) -> some View {
        Panel(title: "Fuel") {
            HStack {
                StatTile(value: d.fuel.averageLPer100km.map { String(format: "%.1f", $0) } ?? "-", unit: d.fuel.averageLPer100km == nil ? "" : "L/100 km", label: "Average")
                StatTile(value: d.fuel.averagePricePerLitre.map { String(format: "%.2f", $0) } ?? "-", label: "Price per litre")
            }
            if d.fuel.averageLPer100km == nil {
                Text("Consumption needs two full-tank fill-ups. Fill up, enter it here, and again next time.").font(.footnote).foregroundStyle(Theme.muted)
            }
            let measured = d.fuel.fills.filter { $0.lPer100km != nil }.reversed().map { $0 }
            if measured.count >= 2 {
                Chart(measured) { fill in
                    LineMark(x: .value("Date", fill.date), y: .value("L/100 km", fill.lPer100km ?? 0)).foregroundStyle(Theme.accent)
                    PointMark(x: .value("Date", fill.date), y: .value("L/100 km", fill.lPer100km ?? 0)).foregroundStyle(Theme.accent)
                }
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.border); AxisValueLabel().foregroundStyle(Theme.muted) } }
                .chartXAxis(.hidden)
                .frame(height: 120)
            }
            ForEach(d.fuel.fills.prefix(6)) { fill in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(fill.date) · \(GarageLogic.odometer(fill.odometerKm))").font(.footnote).foregroundStyle(Theme.text)
                        Text(String(format: "%.1f L", fill.litres) + (fill.fullTank ? "" : " · part fill") + (fill.lPer100km.map { " · " + GarageLogic.consumption($0) } ?? ""))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let price = fill.price { Text(GarageLogic.money(price)).font(.footnote).foregroundStyle(Theme.text) }
                    Button(role: .destructive) { Task { await remove("garage/fuel/\(fill.id)") } } label: { Image(systemName: "trash") }
                        .font(.footnote).accessibilityLabel("Delete this fill-up")
                }
            }
            Button("Add a fill-up") { sheet = .fuel }.buttonStyle(.bordered)
        }
    }

    private func costPanel(_ d: BikeDetail) -> some View {
        Panel(title: "Costs") {
            HStack {
                StatTile(value: GarageLogic.money(d.totals.all), label: "Total")
                StatTile(value: d.totals.perKm.map { String(format: "%.2f", $0) } ?? "-", label: "Per km ridden")
            }
            HStack {
                StatTile(value: GarageLogic.money(d.totals.fuel), label: "Fuel")
                StatTile(value: GarageLogic.money(d.totals.service), label: "Service")
                StatTile(value: GarageLogic.money(d.totals.other), label: "Other")
            }
            ForEach(d.expenses.prefix(6)) { expense in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(expense.category.isEmpty ? "Expense" : expense.category).font(.footnote).foregroundStyle(Theme.text)
                        Text([expense.date, expense.note.isEmpty ? nil : expense.note].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(GarageLogic.money(expense.amount)).font(.footnote).foregroundStyle(Theme.text)
                    Button(role: .destructive) { Task { await remove("garage/expenses/\(expense.id)") } } label: { Image(systemName: "trash") }
                        .font(.footnote).accessibilityLabel("Delete this expense")
                }
            }
            Button("Add an expense") { sheet = .expense }.buttonStyle(.bordered)
        }
    }

    private func actions(_ d: BikeDetail) -> some View {
        Panel(title: "This bike") {
            Button("Edit name and details") { sheet = .edit }.buttonStyle(.bordered)
            if !d.bike.isDefault {
                Button("Make it my default bike") { Task { await run { try await post("garage/bikes/\(bikeId)/default") } } }.buttonStyle(.bordered)
                Text("New rides count towards the default bike unless you put them on another one (on the ride screen).").font(.caption).foregroundStyle(Theme.muted)
            }
            Button("Delete this bike", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
        }
    }

    // MARK: sheets

    @ViewBuilder
    private func sheetView(_ sheet: Sheet) -> some View {
        switch sheet {
        case .odometer:
            FormSheet(title: "Odometer", fields: [FormField(id: "km", label: "Reading now (km)", kind: .number, initial: String(format: "%.0f", detail?.bike.odometerKm ?? 0))]) { values in
                await submit { try await post("garage/bikes/\(bikeId)/odometer", form: values) }
            }
        case .addService:
            FormSheet(title: "New service", fields: [
                FormField(id: "name", label: "What, e.g. Oil change"),
                FormField(id: "interval_km", label: "Every ... km (optional)", kind: .number),
                FormField(id: "interval_months", label: "Every ... months (optional)", kind: .number, footer: "It is due at whichever comes first."),
                FormField(id: "last_done_date", label: "I know when it was last done", kind: .date, optional: true),
                FormField(id: "last_done_km", label: "Odometer then (km, optional)", kind: .number),
                FormField(id: "count_from_now", label: "Otherwise start counting from today", kind: .toggle, initial: "1"),
            ]) { values in
                await submit { try await post("garage/bikes/\(bikeId)/items", form: values) }
            }
        case .done(let item):
            FormSheet(title: item.name, fields: [
                FormField(id: "date", label: "Date", kind: .date),
                FormField(id: "odometer_km", label: "Odometer (km, empty = now)", kind: .number),
                FormField(id: "cost", label: "Cost (optional)", kind: .number),
                FormField(id: "note", label: "Note (optional)"),
            ], submitTitle: "Done") { values in
                await submit { try await post("garage/items/\(item.id)/done", form: values) }
            }
        case .fuel:
            FormSheet(title: "Fill-up", fields: [
                FormField(id: "date", label: "Date", kind: .date),
                FormField(id: "odometer_km", label: "Odometer (km)", kind: .number, initial: String(format: "%.0f", detail?.bike.odometerKm ?? 0)),
                FormField(id: "litres", label: "Litres", kind: .number),
                FormField(id: "price", label: "Total paid (optional)", kind: .number),
                FormField(id: "full_tank", label: "Filled to the top", kind: .toggle, initial: "1", footer: "Consumption is worked out between two full tanks."),
            ]) { values in
                await submit { try await post("garage/bikes/\(bikeId)/fuel", form: values) }
            }
        case .expense:
            FormSheet(title: "Expense", fields: [
                FormField(id: "date", label: "Date", kind: .date),
                FormField(id: "category", label: "Category, e.g. Tyres"),
                FormField(id: "amount", label: "Amount", kind: .number),
                FormField(id: "note", label: "Note (optional)"),
            ]) { values in
                await submit { try await post("garage/bikes/\(bikeId)/expenses", form: values) }
            }
        case .edit:
            FormSheet(title: "Edit bike", fields: [
                FormField(id: "name", label: "Name", initial: detail?.bike.name ?? ""),
                FormField(id: "make", label: "Make", initial: detail?.bike.make ?? ""),
                FormField(id: "model", label: "Model", initial: detail?.bike.model ?? ""),
                FormField(id: "year", label: "Year", kind: .number, initial: detail?.bike.year.map { String($0) } ?? ""),
            ]) { values in
                await submit { try await post("garage/bikes/\(bikeId)", form: values) }
            }
        }
    }

    // MARK: talking to the server

    private func color(for state: ServiceState) -> Color {
        switch state {
        case .overdue: return Theme.danger
        case .soon: return Theme.accent
        case .ok: return Theme.success
        case .neverDone: return Theme.muted
        }
    }

    private func load() async {
        do {
            let loaded: BikeDetail = try await api.get("garage/bikes/\(bikeId)")
            detail = loaded
            errorText = nil
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch APIError.server(404) {
            dismiss()                                     // the bike was deleted
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    /// A change that answers with the whole bike again: shown at once.
    private func post(_ path: String, form: [String: String] = [:]) async throws {
        let changed: BikeDetail = try await api.post(path, form: form)
        detail = changed
        errorText = nil
    }

    /// For the forms: the message to show in the sheet, or nil when it worked.
    private func submit(_ change: () async throws -> Void) async -> String? {
        do {
            try await change()
            return nil
        } catch APIError.unauthorized {
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    /// For buttons on the screen itself: a failure goes to the line at the top.
    private func run(_ change: () async throws -> Void) async {
        if let message = await submit(change) { errorText = message }
    }

    private func remove(_ path: String) async {
        await run {
            let changed: BikeDetail = try await api.delete(path)
            detail = changed
        }
    }

    private func deleteBike() async {
        do {
            let _: DeletedResponse = try await api.delete("garage/bikes/\(bikeId)")
            dismiss()
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }
}
