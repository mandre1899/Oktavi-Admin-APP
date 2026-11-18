import SwiftUI

struct ActionFormView: View {
    @Environment(\.dismiss) private var dismiss
    let action: WorkflowAction
    let perform: (String, JSONValue?) async throws -> Void
    @State private var values: [String: String] = [:]
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(action.title).font(.title.bold())
            Form {
                ForEach(action.fields) { field in fieldView(field) }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Abbrechen") { dismiss() }; Button("Weiter") { confirming = true }.buttonStyle(.borderedProminent).disabled(working) }
        }
        .padding(24).frame(minWidth: 500, minHeight: action.fields.isEmpty ? 220 : 360)
        .onAppear {
            for field in action.fields {
                if case .dateTime = field.kind, field.required {
                    values[field.id] = ISO8601DateFormatter().string(from: .now)
                } else { values[field.id] = field.defaultValue }
            }
        }
        .alert(action.title, isPresented: $confirming) {
            Button("Abbrechen", role: .cancel) {}
            Button("Verbindlich ausführen", role: action.destructive ? .destructive : nil) { Task { await submit() } }
        } message: { Text(action.confirmation) }
    }

    @ViewBuilder private func fieldView(_ field: ActionField) -> some View {
        switch field.kind {
        case .text, .integer:
            TextField(field.title, text: binding(field.id))
        case .toggle:
            Toggle(field.title, isOn: Binding(get: { values[field.id] == "true" }, set: { values[field.id] = $0 ? "true" : "false" }))
        case .choice(let options):
            Picker(field.title, selection: binding(field.id)) { Text("Bitte wählen").tag(""); ForEach(options, id: \.self) { Text($0).tag($0) } }
        case .dateTime:
            DatePicker(field.title, selection: dateBinding(field.id), displayedComponents: [.date, .hourAndMinute])
        }
    }

    private func binding(_ key: String) -> Binding<String> { Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }) }
    private func dateBinding(_ key: String) -> Binding<Date> {
        Binding(
            get: { values[key].flatMap(ISO8601DateFormatter().date(from:)) ?? .now },
            set: { values[key] = ISO8601DateFormatter().string(from: $0) }
        )
    }

    private func submit() async {
        working = true; error = nil; defer { working = false }
        do {
            let (path, body) = try WorkflowActions.bodyAndPath(action: action, values: values)
            try await perform(path, body)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
