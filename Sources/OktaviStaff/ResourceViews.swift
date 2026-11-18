import SwiftUI

struct ResourceListView: View {
    @Environment(AppModel.self) private var model
    let resource: StaffResource
    @State private var records: [JSONValue] = []
    @State private var selection: JSONValue?
    @State private var search = ""
    @State private var status = ""
    @State private var orderTab: OrderTab = .new
    @State private var term = ""
    @State private var loading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    enum OrderTab: String, CaseIterable, Identifiable {
        case new, processing, handedOver, closed, rejected, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .new: "Neu"
            case .processing: "In Bearbeitung"
            case .handedOver: "Übergeben"
            case .closed: "Abgeschlossen"
            case .rejected: "Abgelehnt"
            case .all: "Alle"
            }
        }
        var statuses: [String]? {
            switch self {
            case .new: ["submitted"]
            case .processing: ["approved", "ready_for_fulfillment", "placed"]
            case .handedOver: ["fulfilled"]
            case .closed: ["closed"]
            case .rejected: ["rejected", "cancelled"]
            case .all: nil
            }
        }
    }

    private var filtered: [JSONValue] {
        guard !search.isEmpty else { return records }
        return records.filter {
            (RecordPresentation.title($0, resource: resource) + " " + RecordPresentation.detailLine($0, resource: resource) + " " + ($0["customer"]?["email"]?.string ?? ""))
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { record in
                RecordRow(record: record, resource: resource).tag(record)
            }
            .overlay {
                if loading { ProgressView() }
                else if filtered.isEmpty { ContentUnavailableView("Keine Einträge", systemImage: resource.systemImage, description: Text(search.isEmpty ? "In diesem Bereich gibt es aktuell nichts zu tun." : "Kein Treffer für „\(search)“.")) }
            }
            .searchable(text: $search, prompt: resource == .customers ? "Name oder E-Mail" : "Suchen")
            .navigationTitle(resource.title)
            .safeAreaInset(edge: .top, spacing: 0) {
                if resource == .orders {
                    VStack(spacing: 8) {
                        Picker("Tab", selection: $orderTab) {
                            ForEach(OrderTab.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        HStack {
                            Picker("Mietart", selection: $term) {
                                Text("Alle Mietarten").tag(""); Text("Monatsmiete").tag("long_term"); Text("Tagesmiete").tag("short_term")
                            }
                            Spacer()
                            Button { Task { await load() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                        }
                        Divider()
                    }
                    .padding(.horizontal, 12).padding(.top, 6).background(.bar)
                } else {
                    EmptyView()
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    if resource != .orders {
                        Picker("Status", selection: $status) {
                            Text("Alle").tag("")
                            ForEach(statusOptions, id: \.self) { Text(StaffLabels.label($0)).tag($0) }
                        }.frame(width: 160)
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .onChange(of: status) { Task { await load() } }
            .onChange(of: term) { Task { await load() } }
            .onChange(of: orderTab) { Task { await load() } }
            .onChange(of: search) { oldValue, newValue in
                guard resource == .customers else { return }
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await load()
                }
            }
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
        if resource == .orders {
            if orderTab.statuses?.count == 1 { query.append(.init(name: "status", value: orderTab.statuses!.first!)) }
        } else if !status.isEmpty {
            query.append(.init(name: resource == .rentals ? "state" : "status", value: status))
        }
        if !term.isEmpty { query.append(.init(name: "term", value: term)) }
        if resource == .customers, !search.isEmpty { query.append(.init(name: "search", value: search)) }
        do {
            let value = try await model.client.request(resource.listPath, query: query)
            var list = DashboardAlerts.list(value)
            if resource == .orders {
                if let statuses = orderTab.statuses { list = list.filter { statuses.contains($0["status"]?.string ?? "") } }
                else { list = list.filter { $0["status"]?.string != "draft" } }
            }
            records = list
            if let selectedID = selection?.id { selection = records.first { $0.id == selectedID } }
        } catch { self.error = error.localizedDescription; model.handle(error) }
    }
}

struct RecordRow: View {
    let record: JSONValue
    let resource: StaffResource

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(RecordPresentation.title(record, resource: resource)).font(.headline).lineLimit(1)
                Text(RecordPresentation.detailLine(record, resource: resource)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let status = RecordPresentation.statusRaw(record) { StatusBadge(raw: status) }
                if let amount = RecordPresentation.amount(record, resource: resource) {
                    Text(amount).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct RecordDetailView: View {
    @Environment(AppModel.self) private var model
    let resource: StaffResource
    let summary: JSONValue
    @State private var record: JSONValue?
    @State private var reference: [String: JSONValue] = [:]
    @State private var loading = true
    @State private var selectedAction: WorkflowAction?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            else if let record {
                VStack(alignment: .leading, spacing: 20) {
                    header(record)
                    OutOfStockWarning(record: record, resource: resource)
                    if resource == .orders {
                        CustomerCard(customer: record["customer"], billing: record["billing_address"])
                        OrderItemsSection(record: record)
                        DepositCard(deposit: record["deposit"])
                        DailyPreviewSection(reference: reference)
                    }
                    if resource == .rentals || resource == .returns {
                        CustomerCard(customer: record["customer"], billing: nil)
                    }
                    if resource == .customers, let history = reference["history"] {
                        DisclosureGroup("Kundenhistorie") { NestedJSONView(value: history).padding(.top, 8) }
                    }
                    let actions = WorkflowActions.available(for: record, resource: resource)
                    if !actions.isEmpty {
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
                    DisclosureGroup("Alle Details") {
                        RecordFieldsView(value: record)
                    }
                }.padding(28)
            }
        }
        .task(id: summary.id) { await load() }
        .sheet(item: $selectedAction) { action in
            ActionFormView(action: action, options: record.map(actionOptions) ?? [:]) { path, body in
                try await perform(action: action, path: path, body: body)
            }
        }
        .alert("Fehler", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private func header(_ record: JSONValue) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(RecordPresentation.title(record, resource: resource)).font(.largeTitle.bold())
                    if let status = RecordPresentation.statusRaw(record) { StatusBadge(raw: status) }
                }
                Text(RecordPresentation.detailLine(record, resource: resource)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = RecordPresentation.amount(record, resource: resource) {
                    Text(amount).font(.title2.weight(.semibold))
                }
                Text("Erstellt \(StaffLabels.shortDate(record["created_at"]?.string))").font(.caption).foregroundStyle(.secondary)
                Button { Task { await load() } } label: { Label("Neu laden", systemImage: "arrow.clockwise") }
            }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            var loaded = try await model.client.request(resource.detailPath(id: summary.id))
            var refs: [String: JSONValue] = [:]
            let requests = referenceRequests(for: loaded)
            if !requests.isEmpty {
                await withTaskGroup(of: (String, Result<JSONValue?, Error>).self) { group in
                    for (name, path) in requests {
                        group.addTask { [client = model.client] in
                            do { return (name, .success(try await client.request(path))) }
                            catch { return (name, .failure(error)) }
                        }
                    }
                    for await (name, result) in group {
                        if case .success(let value) = result, let value { refs[name] = value }
                    }
                }
            }
            reference = refs
            if var object = loaded?.object, let noShow = refs["no_show_preview"] {
                object["_no_show_preview"] = noShow
                loaded = .object(object)
            }
            record = loaded
        }
        catch { self.error = error.localizedDescription; model.handle(error) }
    }

    private func referenceRequests(for record: JSONValue?) -> [(String, String)] {
        guard let record else { return [] }
        let root = resource.detailPath(id: summary.id)
        switch resource {
        case .orders:
            if RecordPresentation.term(record) == "short_term" {
                return [("return_preview", "\(root)/return-preview"), ("no_show_preview", "\(root)/no-show-preview")]
            }
            return [("allocation_candidates", "\(root)/allocation-candidates")]
        case .rentals:
            var requests = [("return_options", "\(root)/return-options")]
            if record["instrument"] != nil {
                requests.append(("swap_candidates", "\(root)/swap-candidates"))
                requests.append(("swap_delivery_options", "\(root)/swap-delivery-options"))
            }
            return requests
        case .customers: return [("history", "\(root)/history")]
        default: return []
        }
    }

    private func actionOptions(for record: JSONValue) -> [String: [ActionChoice]] {
        var result: [String: [ActionChoice]] = [:]
        if resource == .orders {
            result["order_items"] = (record["items"]?.array ?? []).compactMap { item in
                guard let id = item["order_item_id"]?.string else { return nil }
                return ActionChoice(id: id, label: item["instrument_type_name"]?.string ?? "Position")
            }
            if let candidates = reference["allocation_candidates"]?.object {
                for (itemID, list) in candidates {
                    result["allocation_candidates:\(itemID)"] = (list.array ?? []).compactMap { instrument in
                        guard let id = instrument["instrument_id"]?.string else { return nil }
                        let label = [instrument["serial_number"]?.string, instrument["location"]?.string].compactMap { $0 }.joined(separator: " · ")
                        return ActionChoice(id: id, label: label.isEmpty ? id : label)
                    }
                }
            }
        }
        if resource == .rentals {
            result["return_options"] = (reference["return_options"]?.array ?? []).compactMap { option in
                guard let id = option["return_option_id"]?.string else { return nil }
                return ActionChoice(id: id, label: option["name"]?.string ?? id)
            }
            result["swap_candidates"] = (reference["swap_candidates"]?.array ?? []).compactMap { instrument in
                guard let id = instrument["instrument_id"]?.string else { return nil }
                let label = [instrument["serial_number"]?.string, instrument["location"]?.string].compactMap { $0 }.joined(separator: " · ")
                return ActionChoice(id: id, label: label.isEmpty ? id : label)
            }
            result["swap_delivery_options"] = (reference["swap_delivery_options"]?.array ?? []).compactMap { option in
                guard let id = option["delivery_option_id"]?.string else { return nil }
                let name = option["name"]?.string ?? id
                let price = option["price_cents"]?.int.map { StaffLabels.money($0, currency: option["currency_code"]?.string) }
                return ActionChoice(id: id, label: price.map { name + " (\($0))" } ?? name)
            }
        }
        return result
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

struct CustomerCard: View {
    let customer: JSONValue?
    let billing: JSONValue?

    var body: some View {
        if let customer, customer != .null {
            GroupBox {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(customer["name"]?.string ?? customer["email"]?.string ?? "Kunde").font(.headline)
                        if let email = customer["email"]?.string { Text(email).foregroundStyle(.secondary) }
                        if let phone = customer["phone"]?.string { Text(phone).foregroundStyle(.secondary) }
                        if let billing, let street = billing["street"]?.string {
                            Text("\(street), \(billing["postal_code"]?.string ?? "") \(billing["city"]?.string ?? "")").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } label: { Label("Kunde", systemImage: "person") }
        }
    }
}

struct OrderItemsSection: View {
    let record: JSONValue

    var body: some View {
        let items = record["items"]?.array ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Positionen").font(.title2.bold())
                ForEach(items) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item["instrument_type_name"]?.string ?? "Position").font(.headline)
                                Spacer()
                                Text("Anzahl \(item["quantity"]?.int ?? 1)").font(.callout).foregroundStyle(.secondary)
                                Text(StaffLabels.money(item["line_total_cents"]?.int, currency: record["currency_code"]?.string)).fontWeight(.medium)
                            }
                            let allocations = item["allocations"]?.array ?? []
                            ForEach(allocations) { allocation in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text(allocation["serial_number"]?.string ?? "Instrument")
                                    if let status = allocation["instrument_status"]?.string { StatusBadge(raw: status) }
                                }
                            }
                            if allocations.isEmpty {
                                if item["free_instruments"]?.int == 0 {
                                    Label("Nicht auf Lager", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                                } else {
                                    Label("Noch nicht zugewiesen · \(item["free_instruments"]?.int ?? 0) Instrumente verfügbar", systemImage: "clock").foregroundStyle(.secondary).font(.callout)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DepositCard: View {
    let deposit: JSONValue?

    var body: some View {
        if let deposit, deposit != .null {
            GroupBox {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StaffLabels.money(deposit["amount_cents"]?.int, currency: deposit["currency_code"]?.string)).font(.headline)
                        Text("\(StaffLabels.label(deposit["verification"]?.string)) · \(StaffLabels.label(deposit["deposit_payment_method"]?.string))").font(.caption).foregroundStyle(.secondary)
                        if let transferReference = deposit["transfer_reference"]?.string {
                            Text(transferReference).font(.caption).foregroundStyle(.secondary)
                        }
                        if deposit["settleable"]?.bool == true {
                            Label("Noch abrechenbar", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    StatusBadge(raw: deposit["status"]?.string ?? "")
                }
            } label: { Label("Kaution", systemImage: "eurosign.circle") }
        }
    }
}

struct DailyPreviewSection: View {
    let reference: [String: JSONValue]

    var body: some View {
        if let preview = reference["return_preview"] {
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow { Text("Letzter Miettag").foregroundStyle(.secondary); Text(StaffLabels.shortDate(preview["last_day"]?.string)) }
                    GridRow { Text("Verspätete Tage").foregroundStyle(.secondary); Text("\(preview["late_days"]?.int ?? 0)") }
                    GridRow {
                        Text("Verspätungsgebühr").foregroundStyle(.secondary)
                        Text(StaffLabels.money(preview["late_fee_cents"]?.int, currency: preview["currency_code"]?.string))
                    }
                    GridRow { Text("Karte hinterlegt").foregroundStyle(.secondary); Text(preview["card_on_file"]?.bool == true ? "Ja" : "Nein") }
                }
            } label: { Label("Rückgabevorschau", systemImage: "clock.badge.exclamationmark") }
        }
    }
}

struct RecordFieldsView: View {
    let value: JSONValue

    var body: some View {
        if let object = value.object {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(object.keys.sorted().filter { !["items", "allocations", "proposals"].contains($0) }, id: \.self) { key in
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
            return StaffLabels.money(cents)
        }
        if key.hasSuffix("_at"), let iso = value.string { return StaffLabels.dateTime(iso) }
        if key.hasSuffix("_date"), let day = value.string { return StaffLabels.shortDate(day) }
        if let bool = value.bool { return bool ? "Ja" : "Nein" }
        if let raw = value.string, ["status", "state", "verification", "instrument_status", "method", "provider"].contains(key) {
            return StaffLabels.label(raw)
        }
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
