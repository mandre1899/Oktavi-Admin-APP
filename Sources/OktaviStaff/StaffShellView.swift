import SwiftUI

struct StaffShellView: View {
    @Environment(AppModel.self) private var model
    let metadata: VaultMetadata
    private var navigator: StaffNavigator { model.navigator }
    private var queue: WorkQueue { model.queue }

    var body: some View {
        NavigationSplitView {
            StaffSidebar(metadata: metadata)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            Group {
                switch navigator.section {
                case .dashboard: DashboardView()
                case .resource(let resource): ResourceListView(resource: resource).id(resource)
                case nil: ContentUnavailableView("Bereich auswählen", systemImage: "sidebar.left")
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        } detail: {
            if let ref = navigator.selectedRecord {
                RecordDetailView(resource: ref.resource, recordID: ref.id).id(ref)
            } else {
                DetailPlaceholder()
            }
        }
        .environment(navigator)
        .environment(queue)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { navigator.goBack() } label: { Label("Zurück", systemImage: "chevron.backward") }
                    .disabled(!navigator.canGoBack).help("Zurück (⌘[)")
                Button { navigator.goForward() } label: { Label("Vor", systemImage: "chevron.forward") }
                    .disabled(!navigator.canGoForward).help("Vor (⌘])")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { navigator.refresh() } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Alles neu laden (⌘R)")
            }
        }
        .task(id: navigator.refreshToken) {
            // Keeps badges and the dashboard current while the app stays open.
            while !Task.isCancelled {
                await queue.load(client: model.client, onAuthFailure: model.handleAuthFailure)
                // A slot the customer accepted in the shop shows up here at the latest after one refresh.
                if model.calendarSynchronizer.canSyncSilently, let sources = queue.calendarSources {
                    _ = try? await model.calendarSynchronizer.synchronize(client: model.client, sources: sources, interactive: false)
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

private struct StaffSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(StaffNavigator.self) private var navigator
    @Environment(WorkQueue.self) private var queue
    let metadata: VaultMetadata

    var body: some View {
        List(selection: Binding(get: { navigator.section }, set: { navigator.select($0) })) {
            Label("Das steht an", systemImage: "checklist")
                .badge(queue.dangerCount)
                .tag(SidebarItem.dashboard)
            ForEach(StaffDomain.allCases) { domain in
                Section(domain.title, isExpanded: expanded(domain)) {
                    ForEach(domain.resources) { row($0) }
                }
            }
        }
        .navigationTitle("Oktavi Staff")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metadata.email).font(.callout).lineLimit(1)
                    Text(model.server.domain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Einstellungen (⌘,)")
                Button { model.lock() } label: { Image(systemName: "lock") }.buttonStyle(.borderless).help("App sperren (⇧⌘L)")
            }
            .padding(12)
            .background(.bar)
        }
    }

    @AppStorage("collapsedDomains") private var collapsed = ""

    /// Domains fold away; a domain with something to do stays open.
    private func expanded(_ domain: StaffDomain) -> Binding<Bool> {
        Binding(
            get: { !collapsed.split(separator: ",").contains(Substring(domain.rawValue)) || domain.resources.contains { (queue.badges[$0] ?? 0) > 0 } },
            set: { open in
                var set = Set(collapsed.split(separator: ",").map(String.init))
                if open { set.remove(domain.rawValue) } else { set.insert(domain.rawValue) }
                collapsed = set.sorted().joined(separator: ",")
            }
        )
    }

    private func row(_ resource: StaffResource) -> some View {
        Label(resource.title, systemImage: resource.systemImage)
            .badge(queue.badges[resource] ?? 0)
            .tag(SidebarItem.resource(resource))
    }
}

private struct DetailPlaceholder: View {
    @Environment(StaffNavigator.self) private var navigator
    var body: some View {
        if case .resource(let resource) = navigator.section {
            ContentUnavailableView("Eintrag auswählen", systemImage: resource.systemImage, description: Text("Wähle links einen Eintrag, um Details und den nächsten Schritt zu sehen."))
        } else {
            ContentUnavailableView("Hinweis oder Termin auswählen", systemImage: "checklist", description: Text("Ein Hinweis öffnet die passende gefilterte Liste, ein Termin direkt den Vorgang."))
        }
    }
}

/// "Gehe zu": every area one shortcut away, plus back/forward.
struct NavigationCommands: Commands {
    let model: AppModel

    private static let shortcuts: [(StaffResource, KeyEquivalent)] = [
        (.orders, "2"), (.rentals, "3"), (.returns, "4"), (.deposits, "5"), (.invoices, "6"), (.instruments, "7"), (.customers, "8")
    ]

    var body: some Commands {
        CommandMenu("Gehe zu") {
            Button("Das steht an") { model.navigator.select(.dashboard) }.keyboardShortcut("1")
            ForEach(StaffDomain.allCases) { domain in
                Section(domain.title) {
                    ForEach(domain.resources) { resource in
                        if let key = Self.shortcuts.first(where: { $0.0 == resource })?.1 {
                            Button(resource.title) { model.navigator.select(.resource(resource)) }.keyboardShortcut(key)
                        } else {
                            Button(resource.title) { model.navigator.select(.resource(resource)) }
                        }
                    }
                }
            }
            Divider()
            Button("Zurück") { model.navigator.goBack() }.keyboardShortcut("[")
            Button("Vor") { model.navigator.goForward() }.keyboardShortcut("]")
        }
    }
}
