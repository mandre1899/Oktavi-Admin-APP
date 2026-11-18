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

    func synchronize(client: APIClient) async throws -> Int {
        guard !isSyncing else { return lastEventCount }
        isSyncing = true
        defer { isSyncing = false }
        guard try await requestAccess() else { throw ValidationError("Kalenderzugriff wurde nicht erlaubt.") }

        let resources: [StaffResource] = [.orders, .returns, .rentals]
        var sources: [StaffResource: [JSONValue]] = [:]
        try await withThrowingTaskGroup(of: (StaffResource, [JSONValue]).self) { group in
            for resource in resources {
                group.addTask {
                    let response = try await client.request(resource.listPath, query: [.init(name: "limit", value: "100")])
                    return (resource, DashboardAlerts.list(response))
                }
            }
            for try await (resource, values) in group { sources[resource] = values }
        }

        let candidates = CalendarEventMapper.events(sources: sources)
        let calendar = try oktaviCalendar()
        let start = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        let end = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
        let existing = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
        let candidateURLs = Set(candidates.map { eventURL(id: $0.id) })

        for candidate in candidates {
            let url = eventURL(id: candidate.id)
            let event = existing.first { $0.url?.absoluteString == url } ?? EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = candidate.title
            event.startDate = candidate.start
            event.endDate = candidate.end
            event.isAllDay = candidate.isAllDay
            event.notes = candidate.notes
            event.url = URL(string: url)
            try store.save(event, span: .thisEvent, commit: false)
        }
        for event in existing where event.url?.scheme == "oktavi-staff" && !candidateURLs.contains(event.url!.absoluteString) {
            try store.remove(event, span: .thisEvent, commit: false)
        }
        try store.commit()
        lastSync = .now
        lastEventCount = candidates.count
        return candidates.count
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
