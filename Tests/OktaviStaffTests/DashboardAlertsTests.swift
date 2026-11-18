import Testing
@testable import OktaviStaff

@Suite("Dashboard alerts")
struct DashboardAlertsTests {
    @Test func dangerAlertsSortBeforeWarnings() {
        let sources: [String: JSONValue] = [
            "orders": .array([
                .object(["id": .string("1"), "status": .string("submitted")]),
                .object(["id": .string("2"), "term": .string("short_term"), "overdue_since": .string("2026-01-01")])
            ])
        ]
        let alerts = DashboardAlerts.build(sources: sources, today: "2026-11-18")
        #expect(alerts.first?.id == "daily-overdue")
        #expect(alerts.contains { $0.id == "orders-submitted" && $0.count == 1 })
    }

    @Test func ignoresZeroCounts() {
        #expect(DashboardAlerts.build(sources: [:], today: "2026-11-18").isEmpty)
    }
}
