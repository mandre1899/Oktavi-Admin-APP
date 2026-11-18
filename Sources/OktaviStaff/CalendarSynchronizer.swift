import EventKit
import Foundation
import Observation

@MainActor @Observable
final class CalendarSynchronizer {
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastEventCount = 0
    private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    var automaticSync: Bool {
        didSet { UserDefaults.standard.set(automaticSync, forKey: "calendarAutomaticSync") }
    }

    private let store = EKEventStore()
    private let calendarTitle = "Oktavi Staff"

    init() {
        automaticSync = UserDefaults.standard.object(forKey: "calendarAutomaticSync") as? Bool ?? false
    }

    /// Whether a background sync may run without asking: automatic sync is on and access was granted.
    var canSyncSilently: Bool {
        automaticSync && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Writes the upcoming Oktavi appointments to the "Oktavi Staff" calendar.
    /// - Parameters:
    ///   - sources: lists already loaded (the dashboard's); fetched when `nil`.
    ///   - interactive: may ask for calendar access. Background syncs never prompt.
    func synchronize(client: APIClient, sources provided: [StaffResource: [JSONValue]]? = nil, interactive: Bool = true) async throws -> Int {
        guard !isSyncing else { return lastEventCount }
        isSyncing = true
        defer { isSyncing = false }
        if interactive {
            guard try await requestAccess() else { throw ValidationError("Kalenderzugriff wurde nicht erlaubt.") }
        } else {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return lastEventCount }
        }

        var sources = provided ?? [:]
        if provided == nil {
            try await withThrowingTaskGroup(of: (StaffResource, [JSONValue]).self) { group in
                for resource in [StaffResource.orders, .returns, .rentals] {
                    group.addTask {
                        var query = [URLQueryItem(name: "limit", value: "100")]
                        if resource == .rentals { query.append(.init(name: "state", value: "cancellation_scheduled")) }
                        return (resource, DashboardAlerts.list(try await client.request(resource.listPath, query: query)))
                    }
                }
                for try await (resource, values) in group { sources[resource] = values }
            }
        }
        sources = await Self.withDetails(sources, client: client)

        let candidates = CalendarEventMapper.events(sources: sources)
        let calendar = try oktaviCalendar()
        let start = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        let end = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
        let existing = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
        let candidateURLs = Set(candidates.map { eventURL(id: $0.id) })
        var changed = false

        for candidate in candidates {
            let url = eventURL(id: candidate.id)
            let current = existing.first { $0.url?.absoluteString == url }
            if let current, current.title == candidate.title, current.startDate == candidate.start, current.endDate == candidate.end,
               current.isAllDay == candidate.isAllDay, current.notes == candidate.notes, (current.location ?? "") == (candidate.location ?? "") {
                continue
            }
            let event = current ?? EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = candidate.title
            event.startDate = candidate.start
            event.endDate = candidate.end
            event.isAllDay = candidate.isAllDay
            event.notes = candidate.notes
            event.location = candidate.location
            event.url = URL(string: url)
            try store.save(event, span: .thisEvent, commit: false)
            changed = true
        }
        for event in existing where event.url?.scheme == "oktavi-staff" && !candidateURLs.contains(event.url!.absoluteString) {
            try store.remove(event, span: .thisEvent, commit: false)
            changed = true
        }
        if changed { try store.commit() }
        lastSync = .now
        lastEventCount = candidates.count
        return candidates.count
    }

    /// List rows lack items and addresses. For the few upcoming agreed handovers and return
    /// appointments, the detail view is loaded so the event can name the instrument and address.
    nonisolated static func withDetails(_ sources: [StaffResource: [JSONValue]], client: APIClient, limit: Int = 40) async -> [StaffResource: [JSONValue]] {
        let now = Date.now
        var targets: [(StaffResource, String)] = []
        for order in sources[.orders] ?? [] {
            if let slot = CalendarEventMapper.agreedHandover(order), slot.end >= now, order["items"]?.array == nil {
                targets.append((.orders, StaffResource.orders.recordID(order)))
            }
        }
        for item in sources[.returns] ?? [] {
            if let slot = CalendarEventMapper.returnAppointment(item), slot.end >= now, item["instrument"] == nil || (item["method"]?.string == "pickup" && item["pickup_address"] == nil) {
                targets.append((.returns, StaffResource.returns.recordID(item)))
            }
        }
        guard !targets.isEmpty else { return sources }
        var details: [String: JSONValue] = [:]
        await withTaskGroup(of: (String, JSONValue?).self) { group in
            for (resource, id) in targets.prefix(limit) {
                group.addTask { ("\(resource.rawValue):\(id)", try? await client.request(resource.detailPath(id: id))) }
            }
            for await (key, value) in group { if let value, value.object != nil { details[key] = value } }
        }
        var result = sources
        for resource in [StaffResource.orders, .returns] {
            result[resource] = (sources[resource] ?? []).map { record in
                guard let detail = details["\(resource.rawValue):\(resource.recordID(record))"] else { return record }
                return record.merging(detail.object ?? [:])
            }
        }
        return result
    }

    private func requestAccess() async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        authorization = EKEventStore.authorizationStatus(for: .event)
        return granted
    }

    private func oktaviCalendar() throws -> EKCalendar {
        if let calendar = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) { return calendar }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle
        calendar.cgColor = CGColor(red: 0.18, green: 0.42, blue: 0.86, alpha: 1)
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV }) else {
            throw ValidationError("Es wurde kein beschreibbarer Kalender-Account gefunden.")
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func eventURL(id: String) -> String { "oktavi-staff://event/\(id)" }
}
