import SwiftUI

struct ResourceListView: View {
    @Environment(AppModel.self) private var model
    let resource: StaffResource
    @State private var records: [JSONValue] = []
    @State private var selection: JSONValue?
    @State private var search = ""
    @State private var status = ""
    @State private var term = ""
    @State private var loading = false
    @State private var error: String?

    private var filtered: [JSONValue] {
        guard !search.isEmpty else { return records }
        return records.filter {
            (RecordPresentation.title($0, resource: resource) + " " + RecordPresentation.subtitle($0) + " " + ($0["email"]?.string ?? ""))
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(RecordPresentation.title(record, resource: resource)).font(.headline)
                    Text(RecordPresentation.subtitle(record)).font(.caption).foregroundStyle(.secondary)
                }.tag(record)
            }
            .overlay {
                if loading { ProgressView() }
                else if filtered.isEmpty { ContentUnavailableView("Keine Einträge", systemImage: resource.systemImage) }
            }
            .searchable(text: $search, prompt: resource == .customers ? "Name oder E-Mail" : "Suchen")
            .navigationTitle(resource.title)
            .toolbar {
                ToolbarItemGroup {
                    if resource == .orders {
                        Picker("Mietart", selection: $term) { Text("Alle").tag(""); Text("Monat").tag("long_term"); Text("Tag").tag("short_term") }
                            .frame(width: 120)
                    }
                    Picker("Status", selection: $status) {
                        Text("Alle").tag("")
                        ForEach(statusOptions, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 150)
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onChange(of: status) { Task { await load() } }
            .onChange(of: term) { Task { await load() } }
        } detail: {
            if let selection { RecordDetailView(resource: resource, summary: selection) }
            else { ContentUnavailableView("Eintrag auswählen", systemImage: resource.systemImage) }
        }
        .task { await load() }
        .alert("Laden fehlgeschlagen", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private var statusOptions: [String] {
        switch resource {
        case .orders: ["submitted", "approved", "ready_for_fulfillment", "fulfilled", "closed", "rejected", "cancelled", "draft"]
        case .rentals: ["active", "cancellation_scheduled", "ended"]
        case .returns: ["requested", "scheduled", "received", "checkup", "completed"]
        case .cancellations: ["open", "resolved"]
        case .deposits: ["pending", "submitted", "succeeded", "failed", "canceled", "returned"]
        case .customers: ["active", "suspended", "deleted"]
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        var query = [URLQueryItem(name: "limit", value: "100")]
        if !status.isEmpty { query.append(.init(name: resource == .rentals ? "state" : "status", value: status)) }
        if !term.isEmpty { query.append(.init(name: "term", value: term)) }
        if resource == .customers, !search.isEmpty { query.append(.init(name: "search", value: search)) }
        do {
            let value = try await model.client.request(resource.listPath, query: query)
            records = DashboardAlerts.list(value)
            if let selectedID = selection?.id { selection = records.first { $0.id == selectedID } }
        } catch { self.error = error.localizedDescription; model.handle(error) }
    }
}

struct RecordDetailView: View {
    @Environment(AppModel.self) private var model
    let resource: StaffResource
    let summary: JSONValue
    @State private var record: JSONValue?
    @State private var loading = true
    @State private var selectedAction: WorkflowAction?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            else if let record {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading) {
                            Text(RecordPresentation.title(record, resource: resource)).font(.largeTitle.bold())
                            Text(RecordPresentation.subtitle(record)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await load() } } label: { Label("Neu laden", systemImage: "arrow.clockwise") }
                    }
                    OutOfStockWarning(record: record, resource: resource)
                    RecordFieldsView(value: record)
                    ReferenceDataView(resource: resource, record: record)
                    let actions = WorkflowActions.available(for: record, resource: resource)
                    if !actions.isEmpty {
                        Divider()
                        Text("Aktionen").font(.title2.bold())
                        FlowLayout(spacing: 10) {
                            ForEach(actions) { action in
                                if action.destructive {
                                    Button(action.title, role: .destructive) { selectedAction = action }
                                        .buttonStyle(.bordered)
                                } else {
                                    Button(action.title) { selectedAction = action }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }.padding(28)
            }
        }
        .task(id: summary.id) { await load() }
        .sheet(item: $selectedAction) { action in
            ActionFormView(action: action) { path, body in
                try await perform(action: action, path: path, body: body)
            }
        }
        .alert("Fehler", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            var loaded = try await model.client.request(resource.detailPath(id: summary.id))
            let daily = loaded?["term"]?.string == "short_term" || loaded?["rental_term"]?.string == "short_term"
            if resource == .orders, daily, var object = loaded?.object,
               let preview = try? await model.client.request("\(resource.detailPath(id: summary.id))/no-show-preview") {
                object["_no_show_preview"] = preview
                loaded = .object(object)
            }
            record = loaded
        }
        catch { self.error = error.localizedDescription; model.handle(error) }
    }

    private func perform(action: WorkflowAction, path: String, body: JSONValue?) async throws {
        do {
            if let response = try await model.client.request(path, method: action.method, body: body) { record = response }
            else { await load() }
        } catch {
            if let apiError = error as? APIError, apiError.status == 422 { await load() }
            model.handle(error)
            throw error
        }
    }
}

struct RecordFieldsView: View {
    let value: JSONValue

    var body: some View {
        if let object = value.object {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(object.keys.sorted().filter { !["id", "items", "allocations", "proposals"].contains($0) }, id: \.self) { key in
                    if let field = object[key], field.array == nil, field.object == nil, field != .null {
                        GridRow {
                            Text(RecordPresentation.displayName(key)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(format(field, key: key)).textSelection(.enabled).gridColumnAlignment(.leading)
                        }
                    }
                }
            }
            ForEach(object.keys.sorted(), id: \.self) { key in
                if let nested = object[key], nested.object != nil || nested.array != nil {
                    DisclosureGroup(RecordPresentation.displayName(key)) { NestedJSONView(value: nested).padding(.top, 8) }
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func format(_ value: JSONValue, key: String) -> String {
        if key.hasSuffix("_cents"), let cents = value.int {
            return (Double(cents) / 100).formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE")))
        }
        if let bool = value.bool { return bool ? "Ja" : "Nein" }
        return value.string ?? "–"
    }
}

struct NestedJSONView: View {
    let value: JSONValue
    var body: some View {
        switch value {
        case .array(let values): ForEach(values) { value in HStack(alignment: .top) { Text("•"); RecordFieldsView(value: value) }.padding(.bottom, 8) }
        case .object: RecordFieldsView(value: value)
        default: Text(value.string ?? "–")
        }
    }
}

struct OutOfStockWarning: View {
    let record: JSONValue
    let resource: StaffResource
    var body: some View {
        if resource == .orders,
           ["submitted", "approved", "ready_for_fulfillment"].contains(record["status"]?.string ?? ""),
           record["items"]?.array?.contains(where: { ($0["allocations"]?.array?.isEmpty ?? true) && $0["free_instruments"]?.int == 0 }) == true {
            Label("Mindestens eine Position ist nicht zugewiesen und aktuell nicht auf Lager.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    init(spacing: CGFloat, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View { HStack(spacing: spacing) { content }.frame(maxWidth: .infinity, alignment: .leading) }
}
