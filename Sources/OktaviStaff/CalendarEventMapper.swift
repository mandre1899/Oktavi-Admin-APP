import Foundation

struct CalendarEventCandidate: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let notes: String
    var kind: Kind = .handover
    var resource: StaffResource = .orders
    var recordID: String = ""

    enum Kind: Sendable {
        case handover, pickup, dailyReturn, returnAppointment, rentalEnd
        var systemImage: String {
            switch self {
            case .handover: "hand.raised"
            case .pickup: "bag"
            case .dailyReturn: "arrow.uturn.backward"
            case .returnAppointment: "arrow.uturn.backward.circle"
            case .rentalEnd: "calendar.badge.minus"
            }
        }
    }
}

enum CalendarEventMapper {
    static func events(sources: [StaffResource: [JSONValue]], now: Date = .now) -> [CalendarEventCandidate] {
        let cutoff = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
        var result: [CalendarEventCandidate] = []
        for order in sources[.orders] ?? [] { result += orderEvents(order) }
        for item in sources[.returns] ?? [] { if let event = returnEvent(item) { result.append(event) } }
        for rental in sources[.rentals] ?? [] { if let event = rentalEndEvent(rental) { result.append(event) } }
        return Dictionary(grouping: result.filter { $0.end >= now && $0.start <= cutoff }, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.start < $1.start }
    }

    private static func orderEvents(_ order: JSONValue) -> [CalendarEventCandidate] {
        let id = StaffResource.orders.recordID(order)
        guard !["cancelled", "rejected"].contains(order["status"]?.string ?? "") else { return [] }
        let daily = (order["rental_term"]?.string ?? order["term"]?.string) == "short_term"
        let name = order["customer"]?["name"]?.string ?? order["order_number"]?.string ?? id
        if daily {
            var events: [CalendarEventCandidate] = []
            if let start = berlinDate(day: order["rental_start_date"]?.string, time: order["pickup_time"]?.string ?? order["rental_start_time"]?.string) {
                events.append(.init(id: "order-\(id)-pickup", title: "Tagesmiete \(name) abholen", start: start, end: start.addingTimeInterval(3600), isAllDay: false, notes: "Oktavi Tagesmiete · Bestellung \(id)\nKunde: \(name)", kind: .pickup, resource: .orders, recordID: id))
            }
            if let start = berlinDate(day: order["rental_end_date"]?.string, time: order["return_time"]?.string ?? order["rental_end_time"]?.string) {
                events.append(.init(id: "order-\(id)-return", title: "Tagesmiete \(name) zurücknehmen", start: start, end: start.addingTimeInterval(3600), isAllDay: false, notes: "Oktavi Tagesmiete · Bestellung \(id)\nKunde: \(name)", kind: .dailyReturn, resource: .orders, recordID: id))
            }
            return events
        }

        let handover = order["handover"]
        let acceptedProposal = handover?["proposals"]?.array?.first { $0["status"]?.string == "accepted" }
        let startText = handover?["start_at"]?.string ?? handover?["scheduled_start_at"]?.string ?? acceptedProposal?["start_at"]?.string ?? order["handover_start_at"]?.string
        let endText = handover?["end_at"]?.string ?? handover?["scheduled_end_at"]?.string ?? acceptedProposal?["end_at"]?.string ?? order["handover_end_at"]?.string
        guard let start = timestamp(startText) else { return [] }
        let end = timestamp(endText) ?? start.addingTimeInterval(3600)
        return [.init(id: "order-\(id)-handover", title: "Übergabe \(name)", start: start, end: end, isAllDay: false, notes: "Oktavi Monatsmiete · Bestellung \(id)\nKunde: \(name)", kind: .handover, resource: .orders, recordID: id)]
    }

    private static func returnEvent(_ item: JSONValue) -> CalendarEventCandidate? {
        let id = StaffResource.returns.recordID(item)
        let name = item["customer"]?["name"]?.string ?? id
        let appointment = item["appointment"]
        guard let start = timestamp(appointment?["start_at"]?.string ?? item["appointment_start_at"]?.string) else { return nil }
        let end = timestamp(appointment?["end_at"]?.string ?? item["appointment_end_at"]?.string) ?? start.addingTimeInterval(3600)
        return .init(id: "return-\(id)-appointment", title: "Rückgabe \(name)", start: start, end: end, isAllDay: false, notes: "Oktavi Rückgabetermin · \(name)", kind: .returnAppointment, resource: .returns, recordID: id)
    }

    private static func rentalEndEvent(_ rental: JSONValue) -> CalendarEventCandidate? {
        let monthly = (rental["rental_term"]?.string ?? rental["term"]?.string) != "short_term"
        guard monthly, rental["state"]?.string == "cancellation_scheduled",
              let day = rental["effective_end_date"]?.string,
              let start = berlinDate(day: day, time: nil) else { return nil }
        let rentalID = StaffResource.rentals.recordID(rental)
        let name = rental["customer"]?["name"]?.string ?? rentalID
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return .init(id: "rental-\(rentalID)-end", title: "Mietende \(name)", start: start, end: end, isAllDay: true, notes: "Oktavi geplantes Mietende · \(name)", kind: .rentalEnd, resource: .rentals, recordID: rentalID)
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func berlinDate(day: String?, time: String?) -> Date? {
        guard let day else { return nil }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "de_DE_POSIX"); formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = time == nil ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.date(from: time.map { "\(day) \($0)" } ?? day)
    }
}
