import SwiftUI

// MARK: - Shared action handling

struct ActionRequest: Identifiable {
    let action: WorkflowAction
    var presets: [String: String] = [:]
    var id: String { action.id + presets.description }
}

/// Runs a write and applies its effect, the same way from lists and details.
@MainActor
struct ActionRunner {
    let model: AppModel
    let navigator: StaffNavigator

    func run(_ action: WorkflowAction, path: String, body: JSONValue?) async throws -> JSONValue? {
        do {
            let response = try await model.client.request(path, method: action.method, body: body)
            switch action.effect {
            case .stay: break
            case .closeRecord: navigator.selectedRecord = nil
            case .openCreated(let resource):
                let created = response?["products"]?.array?.first ?? response?["product_type"].flatMap { resource == .instrumentTypes ? $0 : nil } ?? response
                if let created, created.object != nil { navigator.openRecord(resource, id: resource.recordID(created)) }
            }
            navigator.refresh()
            return response
        } catch {
            model.handleAuthFailure(error)
            throw error
        }
    }
}

/// Builds picker options for forms from the reference cache and a record's own data.
@MainActor
enum FormOptions {
    static func lists(for resource: StaffResource) -> [StaffResource] {
        switch resource {
        case .instrumentTypes: [.currencies, .instrumentTypes]
        case .instruments: [.currencies, .instrumentTypes]
        case .deliveryOptions: [.currencies, .returnOptions, .deliveryAreas]
        case .returnOptions: [.currencies, .deliveryAreas, .instrumentTypes]
        case .legalDocuments: [.legalDocuments]
        default: []
        }
    }

    static func make(cache: ReferenceCache) -> [String: [ActionChoice]] {
        var result: [String: [ActionChoice]] = [:]
        result["currencies"] = cache.cached(.currencies).compactMap { currency in
            guard let code = currency["currency_code"]?.string ?? currency["code"]?.string else { return nil }
            let inactive = currency["is_active"]?.bool == false ? " (inaktiv)" : ""
            return ActionChoice(id: code, label: [code, currency["name"]?.string].compactMap { $0 }.joined(separator: " · ") + inactive)
        }
        result["instrument_types"] = cache.cached(.instrumentTypes).map { type in
            ActionChoice(id: StaffResource.instrumentTypes.recordID(type), label: [type["name"]?.string, type["category"]?.string].compactMap { $0 }.joined(separator: " · "))
        }
        result["categories"] = Array(Set(cache.cached(.instrumentTypes).compactMap { $0["category"]?.string })).sorted().map { ActionChoice(id: $0, label: $0) }
        result["delivery_areas"] = cache.cached(.deliveryAreas).map { ActionChoice(id: StaffResource.deliveryAreas.recordID($0), label: RecordPresentation.title($0, resource: .deliveryAreas) + " · " + RecordPresentation.detailLine($0, resource: .deliveryAreas)) }
        result["return_options"] = cache.cached(.returnOptions).map { ActionChoice(id: StaffResource.returnOptions.recordID($0), label: RecordPresentation.title($0, resource: .returnOptions) + " · " + StaffLabels.label($0["kind"]?.string)) }
        result["document_types"] = Array(Set(cache.cached(.legalDocuments).compactMap { $0["document_type"]?.string })).sorted().map { ActionChoice(id: $0, label: "\(StaffLabels.label($0)) (\($0))") }
        return result.filter { !$0.value.isEmpty }
    }
}

// MARK: - List

struct ResourceListView: View {
    @Environment(AppModel.self) private var model
    @Environment(StaffNavigator.self) private var navigator
    let resource: StaffResource
    @State private var records: [JSONValue] = []
    @State private var search = ""
    @State private var filterValues: [String: String]
    @State private var localValues: [String: String] = [:]
    @State private var orderTab: OrderTab = .new
    @State private var term = ""
    @State private var loading = false
    @State private var loadingMore = false
    @State private var hasMore = false
    @State private var error: String?
    @State private var request: ActionRequest?
    @State private var uploading = false
    @State private var importing = false

    init(resource: StaffResource) {
        self.resource = resource
        _filterValues = State(initialValue: Dictionary(uniqueKeysWithValues: resource.filters.map { ($0.param, $0.defaultValue) }))
    }

    enum OrderTab: String, CaseIterable, Identifiable {
        case new, processing, handedOver, closed, rejected, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .new: "Neu"
            case .processing: "In Bearbeitung"
            case .handedOver: "Übergeben"
            case .closed: "Abgeschlossen"
            case .rejected: "Abgelehnt/Storniert"
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

    private struct LoadKey: Hashable {
        let filters: [String: String], tab: OrderTab, term: String, focus: WorkFilter?, presets: [String: String], search: String, token: Int
    }

    private var loadKey: LoadKey {
        LoadKey(filters: filterValues, tab: orderTab, term: term, focus: navigator.focus, presets: navigator.listPresets,
                search: resource == .customers ? search : "", token: navigator.refreshToken)
    }

    private var filtered: [JSONValue] {
        var list = records
        let local = localValues.merging(navigator.listPresets) { _, preset in preset }
        for (key, value) in local where !value.isEmpty {
            list = list.filter { record in
                let nested: JSONValue? = key == "instrument_type_id" ? record.value(at: "instrument_type.instrument_type_id") : nil
                let field: JSONValue? = record[key] ?? nested
                if field?.string == value { return true }
                if let flag = field?.bool { return String(flag) == value }
                return false
            }
        }
        guard !search.isEmpty, resource != .customers else { return list }
        return list.filter { searchText($0).localizedCaseInsensitiveContains(search) }
    }

    private static let searchKeys = ["order_number", "tracking_number", "serial_number", "location", "invoice_number", "code"]

    private func searchText(_ record: JSONValue) -> String {
        var parts = [RecordPresentation.title(record, resource: resource), RecordPresentation.detailLine(record, resource: resource)]
        if let email = record["customer"]?["email"]?.string { parts.append(email) }
        for key in Self.searchKeys { if let value = record[key]?.string { parts.append(value) } }
        return parts.joined(separator: " ")
    }

    private var selection: Binding<String?> {
        Binding(
            get: { navigator.selectedRecord?.resource == resource ? navigator.selectedRecord?.id : nil },
            set: { id in navigator.selectedRecord = id.map { RecordRef(resource: resource, id: $0) } }
        )
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(filtered, id: \.self) { record in
                RecordRow(record: record, resource: resource).tag(resource.recordID(record))
            }
            if hasMore && search.isEmpty {
                HStack {
                    Spacer()
                    Button(loadingMore ? "Lädt …" : "Weitere laden") { Task { await load(more: true) } }.disabled(loadingMore)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if records.isEmpty && loading {
            ProgressView()
        } else if filtered.isEmpty && error == nil {
            ContentUnavailableView("Keine Einträge", systemImage: resource.systemImage, description: Text(emptyText))
        }
    }

    private var emptyText: String {
        if !search.isEmpty { return "Kein Treffer für „\(search)“." }
        if navigator.focus != nil { return "Für diesen Hinweis ist nichts mehr offen." }
        return "In diesem Bereich gibt es aktuell nichts."
    }

    private var subtitle: String {
        if loading { return "Lädt …" }
        return "\(filtered.count)\(hasMore ? "+" : "") \(filtered.count == 1 ? "Eintrag" : "Einträge")"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            if resource == .media {
                Button { importing = true } label: { Label("Bilder hochladen", systemImage: uploading ? "hourglass" : "plus") }
                    .disabled(uploading).help("Shop-Bilder hochladen")
            } else if let create = WorkflowActions.createActions(for: resource).first {
                Button { Task { await start(create) } } label: { Label(create.title, systemImage: "plus") }
                    .help("\(create.title) (⌘N)").keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    var body: some View {
        list
        .overlay { emptyState }
        .searchable(text: $search, placement: .sidebar, prompt: resource == .orders ? "Kunde, Nummer, Sendung" : resource.searchPrompt)
        .navigationTitle(resource.title)
        .navigationSubtitle(subtitle)
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .toolbar { toolbarContent }
        .task(id: loadKey) {
            if resource == .customers, !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await load(more: false)
        }
        .sheet(item: $request) { request in
            ActionFormView(action: request.action, presets: request.presets, options: FormOptions.make(cache: model.references)) { path, body in
                _ = try await ActionRunner(model: model, navigator: navigator).run(request.action, path: path, body: body)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImageUpload.types, allowsMultipleSelection: true) { result in
            guard case .success(let files) = result else { return }
            Task { await upload(files) }
        }
    }

    @ViewBuilder private var filterBar: some View {
        let presets = navigator.listPresets
        let showBar = navigator.focus != nil || !presets.isEmpty || resource == .orders || !resource.filters.isEmpty || !resource.localFilters.isEmpty || error != nil
        if showBar {
            VStack(alignment: .leading, spacing: 8) {
                if let focus = navigator.focus {
                    activeFilter(focus.title) { navigator.focus = nil }
                } else if !presets.isEmpty {
                    activeFilter(presetTitle(presets)) { navigator.open(resource) }
                } else if resource == .orders {
                    ChipRow(options: OrderTab.allCases.map { ($0.rawValue, $0.title) }, selection: Binding(get: { orderTab.rawValue }, set: { orderTab = OrderTab(rawValue: $0) ?? .new }))
                    Picker("Mietart", selection: $term) {
                        Text("Alle Mietarten").tag(""); Text("Monatsmiete").tag("long_term"); Text("Tagesmiete").tag("short_term")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                } else {
                    let all = resource.filters + resource.localFilters
                    if let first = all.first {
                        ChipRow(options: [("", "Alle")] + first.options.map { ($0, StaffLabels.label(first.param == "is_active" ? ($0 == "true" ? "active" : "inactive") : $0)) },
                                selection: binding(for: first))
                    }
                    if all.count > 1 {
                        HStack {
                            ForEach(all.dropFirst(), id: \.self) { spec in
                                Picker(spec.title, selection: binding(for: spec)) {
                                    Text("\(spec.title): alle").tag("")
                                    ForEach(spec.options, id: \.self) { Text(StaffLabels.label($0)).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                            }
                            Spacer()
                        }
                    }
                }
                if let error { InlineBanner(tone: .danger, text: error, retry: navigator.refresh) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func activeFilter(_ title: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor).lineLimit(1)
            Spacer()
            Button("Filter aufheben", action: clear).controlSize(.small)
        }
    }

    private func presetTitle(_ presets: [String: String]) -> String {
        if let typeID = presets["instrument_type_id"] { return "Typ: \(model.references.name(of: typeID, in: .instrumentTypes) ?? "ausgewählt")" }
        return presets.map { "\(RecordPresentation.displayName($0.key)): \(StaffLabels.label($0.value))" }.joined(separator: ", ")
    }

    private func binding(for spec: FilterSpec) -> Binding<String> {
        let isLocal = resource.localFilters.contains(spec)
        return Binding(
            get: { (isLocal ? localValues[spec.param] : filterValues[spec.param]) ?? "" },
            set: { if isLocal { localValues[spec.param] = $0 } else { filterValues[spec.param] = $0 } }
        )
    }

    private func start(_ action: WorkflowAction) async {
        for list in FormOptions.lists(for: resource) { _ = await model.references.list(list, client: model.client, token: navigator.refreshToken) }
        request = ActionRequest(action: action)
    }

    private func load(more: Bool) async {
        if more { loadingMore = true } else { loading = true }
        defer { loading = false; loadingMore = false }
        var query: [URLQueryItem] = []
        if resource.isPaged {
            query.append(.init(name: "limit", value: String(resource.pageSize)))
            if more { query.append(.init(name: "offset", value: String(records.count))) }
        }
        let focusRule = navigator.focus.flatMap { DashboardAlerts.rule(id: $0.ruleID) }
        if focusRule == nil {
            if resource == .orders {
                if let only = orderTab.statuses, only.count == 1 { query.append(.init(name: "status", value: only[0])) }
                if !term.isEmpty { query.append(.init(name: "term", value: term)) }
            }
            for (param, value) in filterValues where !value.isEmpty { query.append(.init(name: param, value: value)) }
        }
        for (param, value) in navigator.listPresets { query.append(.init(name: param, value: value)) }
        if resource == .customers, !search.isEmpty { query.append(.init(name: "search", value: search)) }
        do {
            let value = try await model.client.request(resource.listPath, query: query)
            var list = DashboardAlerts.list(value)
            let pageCount = list.count
            if let focusRule {
                let day = DayContext.now
                list = list.filter { focusRule.matches($0, day) }
            } else if resource == .orders {
                if let statuses = orderTab.statuses { list = list.filter { statuses.contains($0["status"]?.string ?? "") } }
                else { list = list.filter { $0["status"]?.string != "draft" } }
            }
            records = more ? records + list : list
            hasMore = resource.isPaged && pageCount >= resource.pageSize
            if resource == .instruments { _ = await model.references.list(.instrumentTypes, client: model.client, token: navigator.refreshToken) }
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = StaffError.message(error)
            model.handleAuthFailure(error)
        }
    }

    private func upload(_ files: [URL]) async {
        uploading = true; defer { uploading = false }
        var failures: [String] = []
        for file in files {
            do { _ = try await ImageUpload.upload(file, to: ImageUpload.shopImagesPath, client: model.client) }
            catch { failures.append(StaffError.message(error)); model.handleAuthFailure(error) }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        navigator.refresh()
    }
}

struct ChipRow: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { option in
                    let selected = selection == option.0
                    Button { selection = option.0 } label: {
                        Text(option.1)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct RecordRow: View {
    @Environment(AppModel.self) private var model
    let record: JSONValue
    let resource: StaffResource

    private var thumbnail: String? {
        switch resource {
        case .instrumentTypes: record["photo_url"]?.string ?? record["photo_urls"]?.array?.first?.string
        case .media: record["url"]?.string
        default: nil
        }
    }

    private var detailLine: String {
        let line = RecordPresentation.detailLine(record, resource: resource)
        if resource == .instruments, record["instrument_type_name"] == nil, let typeID = record["instrument_type_id"]?.string,
           let name = model.references.name(of: typeID, in: .instrumentTypes) {
            return [name, line].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return line
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let thumbnail {
                RemoteImage(reference: thumbnail).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(RecordPresentation.title(record, resource: resource)).font(.headline).lineLimit(1)
                    if resource == .orders || resource == .rentals { TermBadge(daily: DashboardAlerts.isDaily(record)) }
                }
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let rule = DashboardAlerts.matchingRules(record, resource: resource).first {
                    Label(rule.detail, systemImage: "arrow.turn.down.right")
                        .font(.caption.weight(.medium)).foregroundStyle(rule.tone.color).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                if let status = RecordPresentation.statusRaw(record, resource: resource) { StatusBadge(raw: status) }
                if let amount = RecordPresentation.amount(record, resource: resource) {
                    Text(amount).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct RecordDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(StaffNavigator.self) private var navigator
    let resource: StaffResource
    let recordID: String
    @State private var record: JSONValue?
    @State private var reference: [String: JSONValue] = [:]
    @State private var loading = true
    @State private var request: ActionRequest?
    @State private var snapshotRequest: SnapshotRequest?
    @State private var error: String?
    @State private var success: String?

    struct SnapshotRequest: Identifiable {
        let instrumentID: String
        let snapshot: JSONValue?
        var id: String { snapshot?.id ?? "new" }
    }

    var body: some View {
        Group {
            if let record {
                ScrollView { content(record).padding(24).frame(maxWidth: 860, alignment: .leading) }
            } else if loading {
                ProgressView("\(resource.singular) wird geladen …")
            } else {
                ContentUnavailableView {
                    Label("\(resource.singular) nicht geladen", systemImage: "exclamationmark.triangle")
                } description: { Text(error ?? "") } actions: { Button("Erneut versuchen") { Task { await load() } } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: navigator.refreshToken) { await load() }
        .sheet(item: $request) { request in
            ActionFormView(action: request.action, presets: request.presets, options: record.map(actionOptions) ?? [:], notes: record.map { notes(for: request.action, record: $0) } ?? []) { path, body in
                try await perform(action: request.action, path: path, body: body)
            }
        }
        .sheet(item: $snapshotRequest) { request in
            ConditionSnapshotForm(instrumentID: request.instrumentID, snapshot: request.snapshot,
                                  template: ConditionReport.template(from: DashboardAlerts.list(reference["snapshots"]))) {
                showSuccess(request.snapshot == nil ? "Zustandsbericht gespeichert." : "Zustandsbericht aktualisiert.")
                navigator.refresh()
            }
        }
    }

    private func start(_ action: WorkflowAction, _ presets: [String: String]) {
        if case .conditionSnapshot(let instrumentID, let snapshot) = action.custom {
            snapshotRequest = SnapshotRequest(instrumentID: instrumentID, snapshot: snapshot)
        } else {
            request = ActionRequest(action: action, presets: presets)
        }
    }

    @ViewBuilder private func content(_ record: JSONValue) -> some View {
        let actions = WorkflowActions.available(for: record, resource: resource)
        VStack(alignment: .leading, spacing: 18) {
            header(record)
            if let success {
                Label(success, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.green)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error { InlineBanner(tone: .danger, text: error) }
            if let lifecycle = Lifecycle.of(record, resource: resource) { LifecycleBar(lifecycle: lifecycle) }
            RecordWarnings(record: record, resource: resource)
            NextStepCard(actions: actions.filter { !$0.isInline }, start: start)
            sections(record, actions: actions)
            RelatedRecordsCard(links: RelatedLinks.make(record, resource: resource))
            DisclosureGroup("Alle Felder") { RecordFieldsView(value: record).padding(.top, 8) }
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func sections(_ record: JSONValue, actions: [WorkflowAction]) -> some View {
        switch resource {
        case .orders:
            if DashboardAlerts.isDaily(record) { DailyBookingCard(record: record, reference: reference) }
            else { HandoverProgressCard(record: record) }
            OrderItemsSection(record: record, actions: actions, start: start)
            CustomerCard(customer: record["customer"], billing: record["billing_address"])
            DepositCard(deposit: record["deposit"])
            PaymentSetupCard(record: record)
            if let fulfillments = reference["fulfillments"] { FulfillmentsCard(fulfillments: DashboardAlerts.list(fulfillments)) }
        case .rentals:
            RentalContractCard(record: record)
            RentalInstrumentsCard(record: record)
            InvoiceListCard(title: "Rechnungen", invoices: record["invoices"]?.array ?? [])
            CustomerCard(customer: record["customer"], billing: nil)
        case .returns:
            ReturnCard(record: record)
            CustomerCard(customer: record["customer"], billing: nil)
        case .deposits:
            DepositCard(deposit: record)
            CustomerCard(customer: record["customer"], billing: nil)
        case .cancellations:
            CancellationCard(record: record)
            CustomerCard(customer: record["customer"], billing: nil)
        case .customers:
            CustomerCard(customer: record, billing: nil)
            AddressesCard(addresses: record["addresses"]?.array ?? [])
            if let history = reference["history"] { CustomerHistoryCard(history: history) }
        case .invoices:
            InvoiceSummaryCard(record: record)
            InvoiceLinesCard(record: record)
            PaymentListCard(title: "Zahlungen", payments: record["payments"]?.array ?? [])
            PaymentListCard(title: "Erstattungen", payments: record["refunds"]?.array ?? [])
            CustomerCard(customer: record["customer"], billing: nil)
        case .payments:
            PaymentSummaryCard(record: record)
            PaymentListCard(title: "Erstattungen", payments: record["refunds"]?.array ?? [])
            CustomerCard(customer: record["customer"], billing: nil)
        case .paymentAttempts:
            FactsCard(title: "Zahlungsversuch", systemImage: "arrow.triangle.2.circlepath.circle", record: record)
        case .currencies:
            FactsCard(title: "Währung", systemImage: "coloncurrencysign.circle", record: record, keys: ["currency_code", "code", "name", "symbol", "minor_units", "is_active", "updated_at"])
        case .instrumentTypes:
            InstrumentTypeCard(record: record)
            InstrumentsOfTypeCard(typeID: recordID, instruments: DashboardAlerts.list(reference["instruments"]))
        case .instruments:
            InstrumentCard(record: record)
            SnapshotsCard(snapshots: DashboardAlerts.list(reference["snapshots"]), edit: { snapshot in
                snapshotRequest = SnapshotRequest(instrumentID: recordID, snapshot: snapshot)
            })
        case .deliveryOptions:
            DeliveryOptionCard(record: record)
        case .deliveryAreas:
            FactsCard(title: "Liefergebiet", systemImage: "map", record: record, keys: ["code", "name", "postal_code_prefixes", "updated_at"])
        case .returnOptions:
            ReturnOptionCard(record: record)
        case .media:
            MediaCard(record: record)
        case .users:
            UserCard(record: record, actions: actions, start: start)
        case .legalDocuments:
            LegalDocumentCard(record: record)
        }
    }

    private func header(_ record: JSONValue) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(resource.singular.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(RecordPresentation.title(record, resource: resource)).font(.title.bold()).textSelection(.enabled).lineLimit(2)
                    if let status = RecordPresentation.statusRaw(record, resource: resource) { StatusBadge(raw: status) }
                    if resource == .orders || resource == .rentals { TermBadge(daily: DashboardAlerts.isDaily(record)) }
                }
                Text(RecordPresentation.detailLine(record, resource: resource)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = RecordPresentation.amount(record, resource: resource) {
                    Text(amount).font(.title2.weight(.semibold).monospacedDigit())
                }
                if let created = record["created_at"]?.string {
                    Text("Erstellt \(StaffLabels.shortDate(created))").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small) }
            }
        }
    }

    private func showSuccess(_ text: String) {
        success = text
        error = nil
        Task { try? await Task.sleep(for: .seconds(6)); if success == text { success = nil } }
    }

    // MARK: Loading

    private func fetchRecord() async throws -> JSONValue? {
        if resource.hasDetailEndpoint { return try await model.client.request(resource.detailPath(id: recordID)) }
        // No GET …/:id route: read the list (page by page where paged) and pick the record.
        var offset = 0
        for _ in 0..<5 {
            var query: [URLQueryItem] = []
            if resource.isPaged { query = [.init(name: "limit", value: String(resource.pageSize)), .init(name: "offset", value: String(offset))] }
            let page = DashboardAlerts.list(try await model.client.request(resource.listPath, query: query))
            if let match = page.first(where: { resource.recordID($0) == recordID }) { return match }
            guard resource.isPaged, page.count >= resource.pageSize else { break }
            offset += page.count
        }
        throw APIError(status: 404, code: "not_found", message: "")
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            var loaded = try await fetchRecord()
            for list in FormOptions.lists(for: resource) + extraLists { _ = await model.references.list(list, client: model.client, token: navigator.refreshToken) }
            var refs: [String: JSONValue] = [:]
            let requests = referenceRequests(for: loaded)
            if !requests.isEmpty {
                await withTaskGroup(of: (String, JSONValue?).self) { group in
                    for (name, path, query) in requests {
                        group.addTask { [client = model.client] in (name, try? await client.request(path, query: query)) }
                    }
                    for await (name, value) in group { if let value { refs[name] = value } }
                }
            }
            reference = refs
            if var object = loaded?.object, let noShow = refs["no_show_preview"] {
                object["_no_show_preview"] = noShow
                loaded = .object(object)
            }
            record = loaded
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = StaffError.message(error)
            model.handleAuthFailure(error)
        }
    }

    /// Lists only used for showing names (not for forms).
    private var extraLists: [StaffResource] {
        switch resource {
        case .deliveryOptions, .returnOptions: [.deliveryAreas, .returnOptions]
        case .instruments: [.instrumentTypes]
        default: []
        }
    }

    private func referenceRequests(for record: JSONValue?) -> [(String, String, [URLQueryItem])] {
        guard let record else { return [] }
        let root = resource.detailPath(id: recordID)
        let userID = record["user_id"]?.string ?? record.value(at: "customer.user_id")?.string ?? record.value(at: "customer.id")?.string
        switch resource {
        case .orders:
            var requests: [(String, String, [URLQueryItem])] = [("fulfillments", "api/v1/orders/\(recordID)/fulfillments", [])]
            if DashboardAlerts.isDaily(record) {
                if WorkflowActions.handedOverAt(record) != nil { requests.append(("return_preview", "\(root)/return-preview", [])) }
                else if record["status"]?.string == "approved" { requests.append(("no_show_preview", "\(root)/no-show-preview", [])) }
            } else if ["approved", "ready_for_fulfillment"].contains(record["status"]?.string ?? "") {
                requests.append(("allocation_candidates", "\(root)/allocation-candidates", []))
            }
            return requests
        case .rentals:
            guard record["state"]?.string != "ended" else { return [] }
            var requests: [(String, String, [URLQueryItem])] = [("return_options", "\(root)/return-options", [])]
            if record["instrument"].isPresent {
                requests.append(("swap_candidates", "\(root)/swap-candidates", []))
                requests.append(("swap_delivery_options", "\(root)/swap-delivery-options", []))
            }
            if let userID, !record["return_id"].isPresent { requests.append(("customer", StaffResource.customers.detailPath(id: userID), [])) }
            return requests
        case .customers: return [("history", "\(root)/history", [])]
        case .cancellations:
            guard record["status"]?.string == "open", record["rentals"]?.array == nil, let userID else { return [] }
            return [("customer_history", StaffResource.customers.detailPath(id: userID) + "/history", [])]
        case .instrumentTypes:
            return [("instruments", StaffResource.instruments.listPath, [.init(name: "limit", value: "100"), .init(name: "instrument_type_id", value: recordID)])]
        case .instruments:
            return [("snapshots", "\(root)/condition-snapshots", [.init(name: "limit", value: "100")])]
        default: return []
        }
    }

    private func actionOptions(for record: JSONValue) -> [String: [ActionChoice]] {
        var result = FormOptions.make(cache: model.references)
        func instrumentLabel(_ instrument: JSONValue) -> String {
            [instrument["serial_number"]?.string, instrument["instrument_type_name"]?.string, instrument["size"]?.string, instrument["location"]?.string]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        switch resource {
        case .orders:
            result["order_items"] = (record["items"]?.array ?? []).compactMap { item in
                guard let id = item["order_item_id"]?.string else { return nil }
                let open = max((item["quantity"]?.int ?? 1) - (item["allocations"]?.array?.count ?? 0), 0)
                return ActionChoice(id: id, label: "\(item["instrument_type_name"]?.string ?? "Position") (\(open) offen)")
            }
            for (itemID, list) in reference["allocation_candidates"]?.object ?? [:] {
                result["allocation_candidates:\(itemID)"] = (list.array ?? []).compactMap { instrument in
                    guard let id = instrument["instrument_id"]?.string else { return nil }
                    let label = instrumentLabel(instrument)
                    return ActionChoice(id: id, label: label.isEmpty ? id : label)
                }
            }
        case .rentals:
            result["return_options"] = (reference["return_options"]?.array ?? []).compactMap { option in
                guard let id = option["return_option_id"]?.string else { return nil }
                let price = option["price_cents"]?.int.map { StaffLabels.money($0, currency: option["currency_code"]?.string) }
                return ActionChoice(id: id, label: [option["name"]?.string ?? id, option["kind"]?.string.map(StaffLabels.label), price].compactMap { $0 }.joined(separator: " · "))
            }
            result["swap_candidates"] = (reference["swap_candidates"]?.array ?? []).compactMap { instrument in
                guard let id = instrument["instrument_id"]?.string else { return nil }
                let label = instrumentLabel(instrument)
                return ActionChoice(id: id, label: label.isEmpty ? id : label)
            }
            result["swap_delivery_options"] = (reference["swap_delivery_options"]?.array ?? []).compactMap { option in
                guard let id = option["delivery_option_id"]?.string else { return nil }
                let name = option["name"]?.string ?? id
                let price = option["price_cents"]?.int.map { StaffLabels.money($0, currency: option["currency_code"]?.string) }
                return ActionChoice(id: id, label: price.map { name + " (\($0))" } ?? name)
            }
            result["pickup_addresses"] = (reference["customer"]?["addresses"]?.array ?? []).compactMap { address in
                guard let id = address["address_id"]?.string ?? address["id"]?.string else { return nil }
                return ActionChoice(id: id, label: AddressFormat.line(address))
            }
        case .cancellations:
            let rentals = record["rentals"]?.array ?? reference["customer_history"]?["rentals"]?.array ?? []
            result["cancellation_rentals"] = rentals.compactMap { rental in
                guard let id = rental["rental_id"]?.string ?? rental["id"]?.string, rental["state"]?.string != "ended" else { return nil }
                let label = [rental.value(at: "instrument.instrument_type_name")?.string ?? rental["instrument_name"]?.string, rental.value(at: "instrument.serial_number")?.string, rental["state"]?.string.map(StaffLabels.label)]
                    .compactMap { $0 }.joined(separator: " · ")
                return ActionChoice(id: id, label: label.isEmpty ? id : label)
            }
        default: break
        }
        return result
    }

    /// Server-provided facts shown inside the form so the decision is made with the numbers in view.
    private func notes(for action: WorkflowAction, record: JSONValue) -> [String] {
        let currency = record["currency_code"]?.string
        switch action.id {
        case "return":
            guard let preview = reference["return_preview"] else { return ["Die Verspätungsgebühr berechnet der Server beim Erfassen."] }
            var lines = ["Verspätete Tage: \(preview["late_days"]?.int ?? 0)",
                         "Verspätungsgebühr: \(StaffLabels.money(preview["late_fee_cents"]?.int, currency: preview["currency_code"]?.string ?? currency))"]
            if (preview["late_fee_cents"]?.int ?? 0) > 0 {
                lines.append(preview["card_on_file"]?.bool == true ? "Ohne Bar-Zahlung oder Erlass wird die hinterlegte Karte belastet." : "Keine Karte hinterlegt – Gebühr bar kassieren oder mit Grund erlassen.")
            }
            if preview["next_booking_at_risk"]?.bool == true { lines.append("⚠︎ Die nächste Buchung dieses Instruments ist gefährdet.") }
            return lines
        case "no-show":
            guard let preview = reference["no_show_preview"] else { return [] }
            return ["Gebühr: \(StaffLabels.money(preview["fee_cents"]?.int, currency: preview["currency_code"]?.string ?? currency))",
                    "Einzug: \(StaffLabels.label(preview["collection"]?.string))"]
        case "settle-deposit":
            let deposit = record["deposit"]
            return ["Kaution: \(StaffLabels.money(deposit?["held_cents"]?.int ?? deposit?["amount_cents"]?.int, currency: deposit?["currency_code"]?.string ?? currency))"]
        case "approve":
            if record["items"]?.array?.contains(where: { ($0["allocations"]?.array?.isEmpty ?? true) && $0["free_instruments"]?.int == 0 }) == true {
                return ["⚠︎ Mindestens eine Position ist aktuell nicht auf Lager."]
            }
            return []
        case "handover":
            if DashboardAlerts.isDaily(record) {
                var lines = ["Abholung: \(StaffLabels.relativeDay(record["rental_start_date"]?.string)) \(record["pickup_time"]?.string ?? "")"]
                if let deposit = record["deposit"], deposit.isPresentObject { lines.append("Kaution: \(StaffLabels.money(deposit["amount_cents"]?.int, currency: deposit["currency_code"]?.string)) · \(StaffLabels.label(deposit["status"]?.string))") }
                return lines
            }
            return ["Alle Instrumente sind zugewiesen und der Termin ist bestätigt."]
        case "refund":
            return [record["amount_cents"]?.int.map { "Ursprünglicher Betrag: \(StaffLabels.money($0, currency: currency))" },
                    record["refundable_cents"]?.int.map { "Erstattbar: \(StaffLabels.money($0, currency: currency))" }].compactMap { $0 }
        case "record-payment":
            return [record["total_cents"]?.int.map { "Rechnungsbetrag: \(StaffLabels.money($0, currency: currency))" },
                    WorkflowActions.amountDue(record).map { "Offen: \(StaffLabels.money($0, currency: currency))" }].compactMap { $0 }
        case "add-role":
            return ["Rollen gelten für Sitzungen und API-Schlüssel der Person. Admins brauchen Zwei-Faktor."]
        default:
            return []
        }
    }

    private func perform(action: WorkflowAction, path: String, body: JSONValue?) async throws {
        do {
            let response = try await ActionRunner(model: model, navigator: navigator).run(action, path: path, body: body)
            if let response, response.object != nil, action.effect == .stay, action.method != .delete,
               resource.recordID(response) == recordID, response["condition_snapshot_id"] == nil {
                record = response
            }
            showSuccess("\(action.title): erledigt.")
        } catch {
            if let apiError = error as? APIError, apiError.status == 422 { await load() }
            throw error
        }
    }
}

extension JSONValue {
    var isPresentObject: Bool { object.map { !$0.isEmpty } ?? false }
}

enum AddressFormat {
    static func line(_ address: JSONValue) -> String {
        let city = [address["postal_code"]?.string, address["city"]?.string].compactMap { $0 }.joined(separator: " ")
        return [address["label"]?.string, address["street"]?.string ?? address["line1"]?.string, city.nilIfEmpty, address["country"]?.string]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
