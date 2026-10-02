import SwiftUI

/// One input in a FormSheet. `id` is the name the server expects.
struct FormField: Identifiable {
    enum Kind { case text, number, date, toggle }

    let id: String
    let label: String
    var kind: Kind = .text
    var initial = ""
    /// For a date: whether it may be left out (the server then uses its own default or none).
    var optional = false
    var footer: String?
}

/// A small form that asks for a few values and hands them to `onSubmit` as strings, ready to post. `onSubmit` returns an error message to show in the
/// sheet, or nil when it worked (the sheet then closes). Used by every "add ..." in the garage, so each of them is only a list of fields.
struct FormSheet: View {
    let title: String
    let fields: [FormField]
    var submitTitle = "Save"
    let onSubmit: ([String: String]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: [String: String] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var dateOn: [String: Bool] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                ForEach(fields) { field in
                    Section(footer: footer(field)) { row(field) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle) { Task { await submit() } }.disabled(busy)
                }
            }
            .onAppear(perform: seed)
        }
    }

    @ViewBuilder
    private func footer(_ field: FormField) -> some View {
        if let note = field.footer { Text(note) }
    }

    @ViewBuilder
    private func row(_ field: FormField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.label, text: binding(field.id)).textInputAutocapitalization(.sentences)
        case .number:
            TextField(field.label, text: binding(field.id)).keyboardType(.decimalPad)
        case .toggle:
            Toggle(field.label, isOn: Binding(get: { flags[field.id] ?? false }, set: { flags[field.id] = $0 })).tint(Theme.accent)
        case .date:
            if field.optional {
                Toggle(field.label, isOn: Binding(get: { dateOn[field.id] ?? false }, set: { dateOn[field.id] = $0 })).tint(Theme.accent)
                if dateOn[field.id] ?? false {
                    DatePicker(field.label, selection: Binding(get: { dates[field.id] ?? Date() }, set: { dates[field.id] = $0 }), in: ...Date(), displayedComponents: .date)
                }
            } else {
                DatePicker(field.label, selection: Binding(get: { dates[field.id] ?? Date() }, set: { dates[field.id] = $0 }), in: ...Date(), displayedComponents: .date)
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { text[key] ?? "" }, set: { text[key] = $0 })
    }

    private func seed() {
        for field in fields {
            switch field.kind {
            case .text, .number: text[field.id] = field.initial
            case .toggle: flags[field.id] = field.initial == "1"
            case .date: dates[field.id] = Date(); dateOn[field.id] = !field.optional
            }
        }
    }

    private func submit() async {
        var values: [String: String] = [:]
        for field in fields {
            switch field.kind {
            case .text, .number: values[field.id] = text[field.id] ?? ""
            case .toggle: values[field.id] = (flags[field.id] ?? false) ? "1" : "0"
            case .date: values[field.id] = (dateOn[field.id] ?? false) ? FormSheet.day(dates[field.id] ?? Date()) : ""
            }
        }
        busy = true
        defer { busy = false }
        if let message = await onSubmit(values) {
            error = message
        } else {
            dismiss()
        }
    }

    /// "2026-10-02" in the phone's own calendar day (what the server expects for a date).
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
