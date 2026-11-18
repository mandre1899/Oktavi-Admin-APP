import SwiftUI

struct ActionFormView: View {
    @Environment(\.dismiss) private var dismiss
    let action: WorkflowAction
    var presets: [String: String] = [:]
    let options: [String: [ActionChoice]]
    var notes: [String] = []
    let perform: (String, JSONValue?) async throws -> Void
    @State private var values: [String: String] = [:]
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: action.systemImage).font(.title).foregroundStyle(action.destructive ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.title2.bold())
                    if let explanation = ActionCopy.explanation(action.id) { Text(explanation).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding([.horizontal, .top], 22).padding(.bottom, 12)

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { Text($0).font(.callout) }
                    Text("Werte vom Server").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 22)
            }

            if !action.fields.isEmpty {
                Form { ForEach(action.fields) { field in fieldView(field) } }
                    .formStyle(.grouped)
                    .scrollDisabled(!isLong)
            } else {
                Spacer(minLength: 16)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .padding(.horizontal, 22).padding(.bottom, 8)
            }

            Divider()
            HStack {
                if confirming {
                    Label(action.confirmation, systemImage: "questionmark.circle").font(.callout.weight(.medium))
                        .foregroundStyle(action.destructive ? Color.red : .primary).lineLimit(3)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(confirming ? "Zurück" : "Abbrechen") { if confirming { confirming = false } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                if confirming {
                    Button(action.destructive ? "Ja, \(action.title.lowercasedFirst)" : "Verbindlich ausführen", role: action.destructive ? .destructive : nil) { Task { await submit() } }
                        .buttonStyle(.borderedProminent).tint(action.destructive ? .red : .accentColor)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                } else {
                    Button("Weiter") { validateAndConfirm() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: action.fields.contains { $0.id == "content" || $0.kind == .photos } ? 720 : 560)
        .frame(minHeight: action.fields.isEmpty ? 200 : 300)
        .modifier(SheetHeight(long: isLong))
        .interactiveDismissDisabled(working)
        .onAppear(perform: prefill)
        .onChange(of: values) { if confirming { confirming = false } }
    }

    private var isLong: Bool {
        action.fields.count > 5 || action.fields.contains { [.multiline, .photos, .json].contains($0.kind) }
    }

    /// Reference keys whose options are suggestions; any value may be typed.
    private static let freeTextKeys: Set<String> = ["categories", "document_types"]

    @ViewBuilder private func fieldView(_ field: ActionField) -> some View {
        Group {
            switch field.kind {
            case .text, .integer:
                TextField(field.required ? field.title : "\(field.title) (optional)", text: binding(field.id))
            case .multiline:
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.title)
                    TextEditor(text: binding(field.id))
                        .font(.body).frame(minHeight: field.id == "content" ? 260 : 70)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            case .json:
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.title)
                    TextEditor(text: binding(field.id))
                        .font(.body.monospaced()).frame(minHeight: 80)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            case .list, .priceMap:
                TextField(field.title, text: binding(field.id), axis: .vertical).lineLimit(2...8)
            case .money:
                TextField(field.title, text: binding(field.id), prompt: Text("0,00"))
                    .multilineTextAlignment(.trailing)
            case .toggle:
                Toggle(field.title, isOn: Binding(get: { values[field.id] == "true" }, set: { values[field.id] = $0 ? "true" : "false" }))
            case .choice(let options):
                Picker(field.title, selection: binding(field.id)) {
                    Text("Bitte wählen").tag("")
                    ForEach(options, id: \.self) { Text(StaffLabels.label($0)).tag($0) }
                }
            case .dateTime:
                if field.required {
                    datePicker(field)
                } else {
                    Toggle("\(field.title): \(field.emptyLabel)", isOn: Binding(
                        get: { (values[field.id] ?? "").isEmpty },
                        set: { values[field.id] = $0 ? "" : ISO8601DateFormatter().string(from: field.dateMode == .future ? .now.addingTimeInterval(14 * 86_400) : .now) }
                    ))
                    if !(values[field.id] ?? "").isEmpty { datePicker(field) }
                }
            case .photos:
                PhotoField(title: field.title, value: binding(field.id))
            case .multiSelect(let key):
                let choices = options[key] ?? []
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.title)
                    if choices.isEmpty { Text("Keine Einträge vorhanden.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(choices) { choice in
                        Toggle(choice.label, isOn: Binding(
                            get: { selectedIDs(field.id).contains(choice.id) },
                            set: { on in
                                var ids = selectedIDs(field.id).filter { $0 != choice.id }
                                if on { ids.append(choice.id) }
                                values[field.id] = ids.joined(separator: ",")
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            case .reference(let key):
                let choices = self.choices(key: key)
                if Self.freeTextKeys.contains(key) {
                    HStack {
                        TextField(field.title, text: binding(field.id))
                        if !choices.isEmpty {
                            Menu {
                                ForEach(choices) { choice in Button(choice.label) { values[field.id] = choice.id } }
                            } label: { Image(systemName: "chevron.down.circle") }
                            .menuStyle(.borderlessButton).fixedSize().help("Vorhandene Werte")
                        }
                    }
                } else if choices.isEmpty {
                    TextField("\(field.title) (ID)", text: binding(field.id))
                } else {
                    Picker(field.title, selection: binding(field.id)) {
                        Text(field.required ? "Bitte wählen" : "Keine Angabe").tag("")
                        ForEach(choices) { choice in Text(choice.label).tag(choice.id) }
                        if let current = values[field.id], !current.isEmpty, !choices.contains(where: { $0.id == current }) {
                            Text(current).tag(current)
                        }
                    }
                }
            }
        }
        .modifier(FieldHint(hint: hint(for: field)))
    }

    @ViewBuilder private func datePicker(_ field: ActionField) -> some View {
        switch field.dateMode {
        case .past where !field.required: DatePicker(field.title, selection: dateBinding(field.id), in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
        case .past: DatePicker(field.title, selection: dateBinding(field.id), displayedComponents: [.date, .hourAndMinute])
        case .future: DatePicker(field.title, selection: dateBinding(field.id), in: Date.now..., displayedComponents: [.date, .hourAndMinute])
        case .any: DatePicker(field.title, selection: dateBinding(field.id), displayedComponents: [.date, .hourAndMinute])
        }
    }

    private func selectedIDs(_ key: String) -> [String] {
        (values[key] ?? "").split(separator: ",").map(String.init)
    }

    private func hint(for field: ActionField) -> String? {
        if case .reference(let key) = field.kind, choices(key: key).isEmpty {
            if key == "allocation_candidates" && (values["order_item_id"] ?? "").isEmpty { return "Zuerst eine Position wählen." }
            if key == "allocation_candidates" { return "Keine freien Instrumente für diese Position." }
            return field.hint ?? "Keine Auswahl vom Server – ID eingeben."
        }
        return field.hint
    }

    private func choices(key: String) -> [ActionChoice] {
        if key == "allocation_candidates" {
            return options["allocation_candidates:\(values["order_item_id"] ?? "")"] ?? []
        }
        return options[key] ?? []
    }

    private func prefill() {
        let nextHour = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        let iso = ISO8601DateFormatter()
        for field in action.fields {
            if let preset = presets[field.id] { values[field.id] = preset; continue }
            if case .dateTime = field.kind, field.required {
                switch field.id {
                case "end_at": values[field.id] = iso.string(from: nextHour.addingTimeInterval(3600))
                default: values[field.id] = iso.string(from: ["start_at", "end_at"].contains(field.id) ? nextHour : .now)
                }
            } else {
                values[field.id] = field.defaultValue
            }
            if case .reference(let key) = field.kind, let only = choices(key: key).first, choices(key: key).count == 1, (values[field.id] ?? "").isEmpty {
                values[field.id] = only.id
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { newValue in
            values[key] = newValue
            if key == "order_item_id" { values["instrument_id"] = "" }
            if key == "start_at", let start = values["start_at"].flatMap(ISO8601DateFormatter().date(from:)),
               let end = values["end_at"].flatMap(ISO8601DateFormatter().date(from:)), end <= start {
                values["end_at"] = ISO8601DateFormatter().string(from: start.addingTimeInterval(3600))
            }
        })
    }

    private func dateBinding(_ key: String) -> Binding<Date> {
        Binding(
            get: { values[key].flatMap(ISO8601DateFormatter().date(from:)) ?? .now },
            set: { binding(key).wrappedValue = ISO8601DateFormatter().string(from: $0) }
        )
    }

    private func validateAndConfirm() {
        do {
            _ = try WorkflowActions.bodyAndPath(action: action, values: values)
            error = nil
            confirming = true
        } catch { self.error = StaffError.message(error) }
    }

    private func submit() async {
        working = true; error = nil; defer { working = false }
        do {
            let (path, body) = try WorkflowActions.bodyAndPath(action: action, values: values)
            try await perform(path, body)
            dismiss()
        } catch {
            confirming = false
            self.error = StaffError.message(error)
        }
    }
}

private struct SheetHeight: ViewModifier {
    let long: Bool
    func body(content: Content) -> some View {
        if long { content.frame(height: 680) } else { content.fixedSize(horizontal: false, vertical: true) }
    }
}

private struct FieldHint: ViewModifier {
    let hint: String?
    func body(content: Content) -> some View {
        if let hint {
            VStack(alignment: .leading, spacing: 3) {
                content
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            content
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
