import Foundation

enum AlertTone: Int, Comparable, Sendable { case danger, warning; static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue } }

struct StaffAlert: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let count: Int
    let tone: AlertTone
    let destination: StaffResource?
    /// Opens the destination list filtered to exactly the records that produced this alert.
    var filter: WorkFilter? { destination == nil || DashboardAlerts.rule(id: id) == nil ? nil : WorkFilter(ruleID: id, title: title) }
}

/// A list filter derived from a dashboard rule ("Übergaben ohne Termin" etc.).
struct WorkFilter: Hashable, Sendable {
    let ruleID: String
    let title: String
}

struct DayContext: Sendable {
    let today: String
    let tomorrow: String

    init(today: String) {
        self.today = today
        let formatter = BerlinDay.formatter
        tomorrow = formatter.date(from: today).flatMap { formatter.calendar.date(byAdding: .day, value: 1, to: $0) }.map(formatter.string) ?? today
    }

    static var now: DayContext { DayContext(today: BerlinDay.today()) }
}

enum BerlinDay {
    static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    static func today(_ date: Date = .now) -> String { formatter.string(from: date) }
}

enum DashboardAlerts {
    /// One rule per record-based alert in `admin.alerts.ts`. The same predicate drives the dashboard
    /// count, the sidebar badge, the row hint and the filtered list, so all four always agree.
    struct RecordRule: Sendable {
        let id: String
        let title: String
        let detail: String
        let tone: AlertTone
        let resource: StaffResource
        let source: String
        let matches: @Sendable (JSONValue, DayContext) -> Bool
    }

    static func isDaily(_ order: JSONValue) -> Bool {
        (order["rental_term"]?.string ?? order["term"]?.string) == "short_term"
    }

    static let recordRules: [RecordRule] = [
        .init(id: "cancellations-open", title: "Offene Kündigungen", detail: "Auf eine Miete eintragen oder anderweitig schließen", tone: .danger, resource: .cancellations, source: "cancellations") { record, _ in
            record["status"]?.string == "open"
        },
        .init(id: "handover-declined", title: "Abgelehnte Übergabetermine", detail: "Kunde hat abgelehnt – neuen Termin vorschlagen", tone: .danger, resource: .orders, source: "orders") { order, _ in
            order["status"]?.string == "approved" && order["handover_proposal_status"]?.string == "declined"
        },
        .init(id: "daily-overdue", title: "Überfällige Tagesmieten", detail: "Instrument nicht zurückgegeben", tone: .danger, resource: .orders, source: "orders") { order, _ in
            isDaily(order) && order["overdue_since"]?.string != nil
        },
        .init(id: "orders-submitted", title: "Neue Bestellungen", detail: "Prüfen und genehmigen oder ablehnen", tone: .warning, resource: .orders, source: "orders") { order, _ in
            order["status"]?.string == "submitted"
        },
        .init(id: "daily-due", title: "Anstehende Tagesmieten", detail: "Abholung heute oder morgen", tone: .warning, resource: .orders, source: "orders") { order, day in
            isDaily(order) && order["status"]?.string == "approved" && (order["rental_start_date"]?.string ?? "9999-99-99") <= day.tomorrow
        },
        .init(id: "daily-hold-lost", title: "Verlorene Mietreservierungen", detail: "Miete bei Abholung bar kassieren", tone: .warning, resource: .orders, source: "orders") { order, _ in
            isDaily(order) && order["status"]?.string == "approved" && order["rent_hold_lost"]?.bool == true
        },
        .init(id: "handover-unscheduled", title: "Übergaben ohne Termin", detail: "Instrumente zuweisen und Termin vorschlagen", tone: .warning, resource: .orders, source: "orders") { order, _ in
            !isDaily(order) && order["status"]?.string == "approved" && !order["handover"].isPresent && order["handover_proposal_status"]?.string != "declined"
        },
        .init(id: "returns-requested", title: "Rückgaben zu planen", detail: "Termin oder Paketlabel erfassen", tone: .warning, resource: .returns, source: "returns") { item, _ in
            item["status"]?.string == "requested" && !item["appointment"].isPresent
        },
        .init(id: "returns-arrived", title: "Rückgaben zu prüfen", detail: "Instrument prüfen und Rückgabe abschließen", tone: .warning, resource: .returns, source: "returns") { item, _ in
            ["received", "checkup"].contains(item["status"]?.string ?? "")
        },
        .init(id: "deposits-open", title: "Offene Kautionen", detail: "Zahlungseingang prüfen und bestätigen", tone: .warning, resource: .deposits, source: "deposits") { deposit, _ in
            deposit["verification"]?.string == "manual" && ["pending", "submitted"].contains(deposit["status"]?.string ?? "")
        }
    ]

    static func rule(id: String) -> RecordRule? { recordRules.first { $0.id == id } }

    /// Rules a single record currently matches, most urgent first. Used for row hints.
    static func matchingRules(_ record: JSONValue, resource: StaffResource, day: DayContext = .now) -> [RecordRule] {
        recordRules.filter { $0.resource == resource && $0.matches(record, day) }.sorted { $0.tone < $1.tone }
    }

    /// Unique records of a resource that need attention (sidebar badge).
    static func actionableCount(resource: StaffResource, sources: [String: JSONValue], day: DayContext) -> Int {
        let rules = recordRules.filter { $0.resource == resource }
        guard let source = rules.first?.source else { return 0 }
        return Set(list(sources[source]).filter { record in rules.contains { $0.matches(record, day) } }.map(resource.recordID)).count
    }

    static func build(sources: [String: JSONValue], today: String) -> [StaffAlert] {
        let day = DayContext(today: today)
        var alerts: [StaffAlert] = []
        func add(_ id: String, _ title: String, _ detail: String, _ count: Int, _ tone: AlertTone, _ destination: StaffResource? = nil) {
            if count > 0 { alerts.append(StaffAlert(id: id, title: title, detail: detail, count: count, tone: tone, destination: destination)) }
        }
        let status = sources["system"]
        let systemDown = ["database.ok", "auth_api.ok", "worker.connected"].contains { status?.value(at: $0)?.bool == false }
        add("system-down", "Systemstörung", "Datenbank, Auth-API oder Worker nicht erreichbar", systemDown ? 1 : 0, .danger)
        let automation = (status?.value(at: "automation.counts.requires_review")?.int ?? 0) + (status?.value(at: "automation.counts.handed_to_admin")?.int ?? 0)
        add("automation-tasks", "Automatisierung prüfen", "In der Admin-App bearbeiten", automation, .danger)
        add("webhooks-failed", "Fehlgeschlagene Webhooks", "In der Admin-App bearbeiten", status?.value(at: "webhooks.counts.failed")?.int ?? 0, .danger)
        let activePrivacy = list(sources["privacy"]).filter { ["received", "identity_verified", "in_progress"].contains($0["status"]?.string ?? "") }
        let overdue = activePrivacy.contains { String(($0["due_at"]?.string ?? "").prefix(10)) < today }
        add("privacy-requests", "Datenschutzanfragen", overdue ? "Mindestens eine Frist ist überschritten" : "In der Admin-App bearbeiten", activePrivacy.count, overdue ? .danger : .warning)
        for rule in recordRules {
            add(rule.id, rule.title, rule.detail, list(sources[rule.source]).filter { rule.matches($0, day) }.count, rule.tone, rule.resource)
        }
        return alerts.sorted { $0.tone == $1.tone ? $0.id < $1.id : $0.tone < $1.tone }
    }

    static func list(_ value: JSONValue?) -> [JSONValue] {
        value?.array ?? value?["items"]?.array ?? value?["data"]?.array ?? []
    }
}
