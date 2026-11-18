import Foundation

enum AlertTone: Int, Comparable, Sendable { case danger, warning; static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue } }

struct StaffAlert: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let count: Int
    let tone: AlertTone
    let destination: StaffResource?
}

enum DashboardAlerts {
    static func build(sources: [String: JSONValue], today: String) -> [StaffAlert] {
        var alerts: [StaffAlert] = []
        func add(_ id: String, _ title: String, _ count: Int, _ tone: AlertTone, _ destination: StaffResource? = nil) {
            if count > 0 { alerts.append(StaffAlert(id: id, title: title, count: count, tone: tone, destination: destination)) }
        }
        let orders = list(sources["orders"])
        let deposits = list(sources["deposits"])
        let returns = list(sources["returns"])
        let privacy = list(sources["privacy"])
        let cancellations = list(sources["cancellations"])
        let status = sources["system"]
        let systemDown = ["database.ok", "auth_api.ok", "worker.connected"].contains { status?.value(at: $0)?.bool == false }
        add("system-down", "Systemstörung", systemDown ? 1 : 0, .danger)
        let automation = (status?.value(at: "automation.counts.requires_review")?.int ?? 0) + (status?.value(at: "automation.counts.handed_to_admin")?.int ?? 0)
        add("automation-tasks", "Automatisierung prüfen", automation, .danger)
        add("webhooks-failed", "Fehlgeschlagene Webhooks", status?.value(at: "webhooks.counts.failed")?.int ?? 0, .danger)
        let activePrivacy = privacy.filter { ["received", "identity_verified", "in_progress"].contains($0["status"]?.string ?? "") }
        let privacyTone: AlertTone = activePrivacy.contains { String(($0["due_at"]?.string ?? "").prefix(10)) < today } ? .danger : .warning
        add("privacy-requests", "Datenschutzanfragen", activePrivacy.count, privacyTone)
        add("cancellations-open", "Offene Kündigungen", cancellations.filter { $0["status"]?.string == "open" }.count, .danger, .cancellations)
        add("handover-declined", "Abgelehnte Übergabetermine", orders.filter { $0["status"]?.string == "approved" && $0["handover_proposal_status"]?.string == "declined" }.count, .danger, .orders)
        add("daily-overdue", "Überfällige Tagesmieten", orders.filter { $0["term"]?.string == "short_term" && $0["overdue_since"]?.string != nil }.count, .danger, .orders)
        add("orders-submitted", "Neue Bestellungen", orders.filter { $0["status"]?.string == "submitted" }.count, .warning, .orders)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: "Europe/Berlin"); formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = formatter.date(from: today).flatMap { formatter.calendar.date(byAdding: .day, value: 1, to: $0) }.map(formatter.string) ?? today
        add("daily-due", "Anstehende Tagesmieten", orders.filter { $0["term"]?.string == "short_term" && $0["status"]?.string == "approved" && ($0["rental_start_date"]?.string ?? "9999-99-99") <= tomorrow }.count, .warning, .orders)
        add("daily-hold-lost", "Verlorene Mietreservierungen", orders.filter { $0["term"]?.string == "short_term" && $0["status"]?.string == "approved" && $0["rent_hold_lost"]?.bool == true }.count, .warning, .orders)
        add("handover-unscheduled", "Übergaben ohne Termin", orders.filter { $0["term"]?.string != "short_term" && $0["status"]?.string == "approved" && $0["handover"] == nil && $0["handover_proposal_status"]?.string != "declined" }.count, .warning, .orders)
        add("returns-requested", "Rückgaben zu planen", returns.filter { $0["status"]?.string == "requested" && $0["appointment"] == nil }.count, .warning, .returns)
        add("returns-arrived", "Rückgaben zu prüfen", returns.filter { ["received", "checkup"].contains($0["status"]?.string ?? "") }.count, .warning, .returns)
        add("deposits-open", "Offene Kautionen", deposits.filter { $0["verification"]?.string == "manual" && ["pending", "submitted"].contains($0["status"]?.string ?? "") }.count, .warning, .deposits)
        return alerts.sorted { $0.tone == $1.tone ? $0.id < $1.id : $0.tone < $1.tone }
    }

    static func list(_ value: JSONValue?) -> [JSONValue] {
        value?.array ?? value?["items"]?.array ?? value?["data"]?.array ?? []
    }
}
