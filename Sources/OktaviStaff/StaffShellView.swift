import SwiftUI

enum SidebarItem: Hashable {
    case dashboard, resource(StaffResource), settings
}

struct StaffShellView: View {
    @Environment(AppModel.self) private var model
    let metadata: VaultMetadata
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Das steht an", systemImage: "bell.badge").tag(SidebarItem.dashboard)
                Section("Betrieb") {
                    ForEach(StaffResource.allCases.filter { $0 != .deposits && $0 != .customers }) { resource in
                        Label(resource.title, systemImage: resource.systemImage).tag(SidebarItem.resource(resource))
                    }
                }
                Section("Service") {
                    ForEach([StaffResource.deposits, .customers]) { resource in
                        Label(resource.title, systemImage: resource.systemImage).tag(SidebarItem.resource(resource))
                    }
                }
                Section {
                    Label("Einstellungen", systemImage: "gear").tag(SidebarItem.settings)
                }
            }
            .navigationTitle("Oktavi Staff")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(metadata.email).lineLimit(1)
                        Text(model.server.domain).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.lock() } label: { Image(systemName: "lock") }.help("App sperren")
                }.padding()
            }
        } detail: {
            switch selection {
            case .dashboard: DashboardView(open: { selection = .resource($0) })
            case .resource(let resource): ResourceListView(resource: resource)
            case .settings: SettingsView(metadata: metadata)
            case nil: ContentUnavailableView("Bereich auswählen", systemImage: "sidebar.left")
            }
        }
    }
}
