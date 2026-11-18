import Foundation

struct CalendarEventCandidate: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let notes: String
    /// Delivery or pickup address, shown as the event's location.
    var location: String? = nil
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
        guard !["cancelled", "rejected", "draft"].contains(order["status"]?.string ?? "") else { return [] }
        let daily = (order["rental_term"]?.string ?? order["term"]?.string) == "short_term"
        let name = customerName(order) ?? order["order_number"]?.string ?? id
        let instruments = instrumentSummary(order)
        let suffix = instruments.map { " · \($0)" } ?? ""
        if daily {
            let notes = details(order, name: name, instruments: instruments, address: nil, header: "Oktavi Tagesmiete")
            var events: [CalendarEventCandidate] = []
            if let start = berlinDate(day: order["rental_start_date"]?.string, time: order["pickup_time"]?.string ?? order["rental_start_time"]?.string) {
                events.append(.init(id: "order-\(id)-pickup", title: "Tagesmiete \(name) abholen\(suffix)", start: start, end: start.addingTimeInterval(3600), isAllDay: false, notes: notes, kind: .pickup, resource: .orders, recordID: id))
            }
            if let start = berlinDate(day: order["rental_end_date"]?.string, time: order["return_time"]?.string ?? order["rental_end_time"]?.string) {
                events.append(.init(id: "order-\(id)-return", title: "Tagesmiete \(name) zurücknehmen\(suffix)", start: start, end: start.addingTimeInterval(3600), isAllDay: false, notes: notes, kind: .dailyReturn, resource: .orders, recordID: id))
            }
            return events
        }

        guard let slot = agreedHandover(order) else { return [] }
        let inPerson = isInPerson(order)
        let address = inPerson == true ? nil : deliveryAddress(order)
        let label = inPerson == true ? "Übergabe im Laden" : (inPerson == false || address != nil) ? "Lieferung" : "Übergabe"
        var notes = details(order, name: name, instruments: instruments, address: address, header: "Oktavi Monatsmiete · \(label)")
        if let note = slot.note, !note.isEmpty { notes += "\nNotiz zum Termin: \(note)" }
        return [.init(id: "order-\(id)-handover", title: "\(label): \(name)\(suffix)", start: slot.start, end: slot.end, isAllDay: false, notes: notes,
                      location: address, kind: .handover, resource: .orders, recordID: id)]
    }

    /// The handover slot the customer accepted. A slot that still waits for the customer, or one the
    /// customer declined, never reaches the calendar; a handover that already happened is left out.
    static func agreedHandover(_ order: JSONValue) -> (start: Date, end: Date, note: String?)? {
        guard (order["rental_term"]?.string ?? order["term"]?.string) != "short_term",
              ["approved", "ready_for_fulfillment"].contains(order["status"]?.string ?? ""),
              order.value(at: "handover.handed_over_at")?.string == nil else { return nil }
        let handover = order["handover"]
        let proposals = handover?["proposals"]?.array ?? order["proposals"]?.array ?? []
        let newest = proposals.first
        let accepted = newest?["status"]?.string == "accepted" ? newest : nil
        let scheduled = handover?["status"]?.string == "scheduled" || order["handover_proposal_status"]?.string == "accepted"
            || order["slot_status"]?.string == "accepted" || handover?["state"]?.string == "agreed"
        guard accepted != nil || (scheduled && newest?["status"]?.string != "pending" && newest?["status"]?.string != "declined") else { return nil }
        let appointment = order["appointment"] ?? handover?["appointment"]
        let startText = accepted?["start_at"]?.string ?? handover?["start_at"]?.string ?? handover?["scheduled_start_at"]?.string
            ?? appointment?["start_at"]?.string ?? order["handover_start_at"]?.string
        let endText = accepted?["end_at"]?.string ?? handover?["end_at"]?.string ?? handover?["scheduled_end_at"]?.string
            ?? appointment?["end_at"]?.string ?? order["handover_end_at"]?.string
        guard let start = timestamp(startText) else { return nil }
        return (start, timestamp(endText) ?? start.addingTimeInterval(3600), accepted?["note"]?.string)
    }

    private static func returnEvent(_ item: JSONValue) -> CalendarEventCandidate? {
        let id = StaffResource.returns.recordID(item)
        guard !["received", "checkup", "completed"].contains(item["status"]?.string ?? "") else { return nil }
        let name = customerName(item) ?? id
        guard let slot = returnAppointment(item) else { return nil }
        let method = item["method"]?.string ?? item["kind"]?.string
        let address = method == "pickup" ? addressLine(item["pickup_address"] ?? item["address"]) : nil
        let label = method == "pickup" ? "Rückgabe abholen" : method == "dropoff" ? "Rückgabe im Laden" : "Rückgabe"
        let instrument = [item.value(at: "instrument.instrument_type_name")?.string ?? item["instrument_type_name"]?.string,
                          item.value(at: "instrument.size")?.string, item.value(at: "instrument.serial_number")?.string.map { "Nr. \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty
        var lines = ["Oktavi \(label)", "Kunde: \(name)"]
        if let contact = contactLine(item) { lines.append(contact) }
        if let instrument { lines.append("Instrument: \(instrument)") }
        if let address { lines.append("Adresse: \(address)") }
        if let option = item["option_name"]?.string { lines.append("Option: \(option)") }
        if let note = item.value(at: "appointment.note")?.string ?? item["note"]?.string, !note.isEmpty { lines.append("Notiz: \(note)") }
        return .init(id: "return-\(id)-appointment", title: "\(label): \(name)\(instrument.map { " · \($0)" } ?? "")", start: slot.start, end: slot.end,
                     isAllDay: false, notes: lines.joined(separator: "\n"), location: address, kind: .returnAppointment, resource: .returns, recordID: id)
    }

    static func returnAppointment(_ item: JSONValue) -> (start: Date, end: Date)? {
        let appointment = item["appointment"]
        guard let start = timestamp(appointment?["start_at"]?.string ?? item["appointment_start_at"]?.string) else { return nil }
        return (start, timestamp(appointment?["end_at"]?.string ?? item["appointment_end_at"]?.string) ?? start.addingTimeInterval(3600))
    }

    // MARK: Details

    private static func customerName(_ record: JSONValue) -> String? {
        let customer = record["customer"]
        let full = [customer?["first_name"]?.string, customer?["last_name"]?.string].compactMap { $0 }.joined(separator: " ")
        return customer?["name"]?.string ?? full.nilIfEmpty ?? record["customer_name"]?.string ?? customer?["email"]?.string
    }

    private static func contactLine(_ record: JSONValue) -> String? {
        [record.value(at: "customer.phone")?.string ?? record.value(at: "customer.phone_number")?.string, record.value(at: "customer.email")?.string]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// "Violine 3/4, Cello 1/2" from the items, or the list's first instrument.
    static func instrumentSummary(_ order: JSONValue) -> String? {
        let items = (order["items"]?.array ?? []).compactMap { item -> String? in
            guard let name = item["instrument_type_name"]?.string ?? item["name"]?.string else { return nil }
            let size = item["size"]?.string.map { " \($0)" } ?? ""
            let quantity = (item["quantity"]?.int ?? 1) > 1 ? "\(item["quantity"]?.int ?? 1)× " : ""
            return quantity + name + size
        }
        if !items.isEmpty { return items.joined(separator: ", ") }
        let first = [order["first_instrument_name"]?.string ?? order["instrument_type_name"]?.string, order["first_instrument_size"]?.string]
            .compactMap { $0 }.joined(separator: " ")
        return first.nilIfEmpty
    }

    static func isInPerson(_ order: JSONValue) -> Bool? {
        order["in_person"]?.bool ?? order.value(at: "delivery_option.in_person")?.bool ?? order.value(at: "handover.in_person")?.bool
    }

    static func deliveryAddress(_ order: JSONValue) -> String? {
        addressLine(order["delivery_address"] ?? order["shipping_address"] ?? order.value(at: "delivery.address"))
    }

    static func addressLine(_ address: JSONValue?) -> String? {
        guard let address, address.object != nil else { return address?.string }
        let city = [address["postal_code"]?.string, address["city"]?.string].compactMap { $0 }.joined(separator: " ")
        let street = address["street"]?.string ?? [address["line1"]?.string, address["line2"]?.string].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        return [street, city.nilIfEmpty].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
    }

    private static func details(_ order: JSONValue, name: String, instruments: String?, address: String?, header: String) -> String {
        var lines = [header + (order["order_number"]?.string.map { " · Bestellung \($0)" } ?? "")]
        lines.append("Kunde: \(name)")
        if let contact = contactLine(order) { lines.append(contact) }
        if let instruments { lines.append("Instrument: \(instruments)") }
        let serials = (order["items"]?.array ?? []).flatMap { $0["allocations"]?.array ?? [] }.compactMap { $0["serial_number"]?.string }
        if !serials.isEmpty { lines.append("Zugewiesen: \(serials.joined(separator: ", "))") }
        if let option = order["delivery_option_name"]?.string { lines.append("Lieferart: \(option)") }
        if let address { lines.append("Adresse: \(address)") }
        return lines.joined(separator: "\n")
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
