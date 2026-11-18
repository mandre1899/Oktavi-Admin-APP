import Foundation
import Observation

/// Loads the dashboard sources once and shares the result with the dashboard and the sidebar badges.
@MainActor @Observable
final class WorkQueue {
    private(set) var alerts: [StaffAlert] = []
    private(set) var agenda: [CalendarEventCandidate] = []
    private(set) var failedSources: [String] = []
    private(set) var badges: [StaffResource: Int] = [:]
    private(set) var loading = false
    private(set) var lastUpdated: Date?

    private static let sources: [(name: String, label: String, path: String, query: [URLQueryItem])] = [
        ("orders", "Bestellungen", "api/v1/admin/orders", [.init(name: "limit", value: "100")]),
        ("deposits", "Kautionen", "api/v1/admin/deposits", [.init(name: "limit", value: "100")]),
        ("returns", "Rückgaben", "api/v1/admin/returns", [.init(name: "limit", value: "100")]),
        ("rentals", "Mieten", "api/v1/admin/rentals", [.init(name: "limit", value: "100"), .init(name: "state", value: "cancellation_scheduled")]),
        ("privacy", "Datenschutz", "api/v1/admin/privacy-requests", [.init(name: "limit", value: "100")]),
        ("cancellations", "Kündigungen", "api/v1/admin/contract-cancellations", [.init(name: "limit", value: "100"), .init(name: "status", value: "open")]),
        ("system", "Systemstatus", "api/v1/admin/system-status", [])
    ]

    var dangerCount: Int { alerts.filter { $0.tone == .danger }.reduce(0) { $0 + $1.count } }

    func load(client: APIClient, onAuthFailure: (Error) -> Void) async {
        loading = true; defer { loading = false }
        var values: [String: JSONValue] = [:]
        var failures: [String] = []
        await withTaskGroup(of: (String, String, Result<JSONValue?, Error>).self) { group in
            for source in Self.sources {
                group.addTask {
                    do { return (source.name, source.label, .success(try await client.request(source.path, query: source.query))) }
                    catch { return (source.name, source.label, .failure(error)) }
                }
            }
            for await (name, label, result) in group {
                switch result {
                case .success(let value): values[name] = value
                case .failure(let error):
                    if (error as? APIError)?.status == 401 { onAuthFailure(error) }
                    if !(error is CancellationError) { failures.append(label) }
                }
            }
        }
        guard !Task.isCancelled else { return }
        let day = DayContext.now
        alerts = DashboardAlerts.build(sources: values, today: day.today)
        var badges: [StaffResource: Int] = [:]
        for resource in StaffResource.allCases {
            let count = DashboardAlerts.actionableCount(resource: resource, sources: values, day: day)
            if count > 0 { badges[resource] = count }
        }
        self.badges = badges
        let weekAhead = Date.now.addingTimeInterval(7 * 86_400)
        agenda = CalendarEventMapper.events(sources: [
            .orders: DashboardAlerts.list(values["orders"]),
            .returns: DashboardAlerts.list(values["returns"]),
            .rentals: DashboardAlerts.list(values["rentals"])
        ]).filter { $0.start <= weekAhead }
        failedSources = failures.sorted()
        lastUpdated = .now
    }
}
