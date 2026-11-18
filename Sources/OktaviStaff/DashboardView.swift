import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let open: (StaffResource) -> Void
    @State private var alerts: [StaffAlert] = []
    @State private var failedSources: [String] = []
    @State private var loading = true

    private let sources: [(String, String)] = [
        ("orders", "api/v1/admin/orders"), ("deposits", "api/v1/admin/deposits"),
        ("returns", "api/v1/admin/returns"), ("privacy", "api/v1/admin/privacy-requests"),
        ("cancellations", "api/v1/admin/contract-cancellations"), ("system", "api/v1/admin/system-status")
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Das steht an").font(.largeTitle.bold())
                    Spacer()
                    Button { Task { await load() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                }
                if !failedSources.isEmpty {
                    Label("Einige Quellen konnten nicht geladen werden: \(failedSources.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .padding().frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else if alerts.isEmpty { ContentUnavailableView("Alles erledigt", systemImage: "checkmark.circle", description: Text("Aktuell gibt es keine offenen Hinweise.")) }
                ForEach(alerts) { alert in
                    Button { if let destination = alert.destination { open(destination) } } label: {
                        HStack(spacing: 16) {
                            Image(systemName: alert.tone == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.title).foregroundStyle(alert.tone == .danger ? .red : .orange)
                            VStack(alignment: .leading) { Text(alert.title).font(.headline); Text("\(alert.count) offen").foregroundStyle(.secondary) }
                            Spacer(); if alert.destination != nil { Image(systemName: "chevron.right") }
                        }.padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }.padding(28)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        var values: [String: JSONValue] = [:]
        var failures: [String] = []
        await withTaskGroup(of: (String, Result<JSONValue?, Error>).self) { group in
            for (name, path) in sources {
                group.addTask { [client = model.client] in
                    do { return (name, .success(try await client.request(path, query: name == "cancellations" ? [URLQueryItem(name: "status", value: "open")] : []))) }
                    catch { return (name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result { case .success(let value): values[name] = value; case .failure: failures.append(name) }
            }
        }
        let berlin = DateFormatter(); berlin.calendar = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin"); berlin.dateFormat = "yyyy-MM-dd"
        alerts = DashboardAlerts.build(sources: values, today: berlin.string(from: .now))
        failedSources = failures.sorted(); loading = false
    }
}
