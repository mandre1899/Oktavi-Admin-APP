import Foundation

enum ActionFieldKind: Hashable, Sendable {
    case text, integer, dateTime, toggle
    case choice([String])
    case reference(String)
}

struct ActionField: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: ActionFieldKind
    let required: Bool
    let defaultValue: String

    init(_ id: String, _ title: String, _ kind: ActionFieldKind = .text, required: Bool = false, defaultValue: String = "") {
        self.id = id; self.title = title; self.kind = kind; self.required = required; self.defaultValue = defaultValue
    }
}

struct WorkflowAction: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let method: HTTPMethod
    let path: String
    let fields: [ActionField]
    let confirmation: String
    let destructive: Bool

    init(_ id: String, _ title: String, method: HTTPMethod = .post, path: String, fields: [ActionField] = [], confirmation: String, destructive: Bool = false) {
        self.id = id; self.title = title; self.method = method; self.path = path; self.fields = fields; self.confirmation = confirmation; self.destructive = destructive
    }
}

enum WorkflowActions {
    static func available(for record: JSONValue, resource: StaffResource) -> [WorkflowAction] {
        let root = resource.detailPath(id: record.id)
        let status = record["status"]?.string ?? ""
        let state = record["state"]?.string ?? ""
        switch resource {
        case .orders: return order(record, root: root, status: status)
        case .rentals: return rental(record, root: root, state: state)
        case .returns: return returnActions(record, root: root, status: status)
        case .cancellations: return cancellation(root: root, status: status)
        case .deposits: return deposit(record, root: root, status: status)
        case .customers: return []
        }
    }

    private static func order(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        let daily = (record["rental_term"]?.string ?? record["term"]?.string) == "short_term"
        let handedOver = record.value(at: "handover.handed_over_at")?.string ?? record["booking_handed_over_at"]?.string ?? record["handed_over_at"]?.string
        if status == "submitted" {
            actions.append(.init("approve", "Genehmigen", path: "\(root)/approve", confirmation: "Diese Bestellung wirklich genehmigen?"))
            let text = daily ? "Die Tagesmiete wirklich ablehnen? Die Kartenreservierung wird freigegeben." : "Diese Bestellung wirklich ablehnen?"
            actions.append(.init("reject", "Ablehnen", path: "\(root)/reject", confirmation: text, destructive: true))
        }
        if ["draft", "approved", "ready_for_fulfillment"].contains(status) {
            actions.append(.init("cancel", "Stornieren", path: "\(root)/cancel", confirmation: "Diese Bestellung wirklich stornieren?", destructive: true))
        }
        if !daily && ["approved", "ready_for_fulfillment", "fulfilled"].contains(status) {
            actions.append(.init("tracking", "Sendungsnummer", method: .put, path: "\(root)/tracking-number", fields: [.init("tracking_number", "Sendungsnummer")], confirmation: "Sendungsnummer speichern?"))
        }
        if !daily && ["approved", "ready_for_fulfillment"].contains(status) {
            actions.append(.init("early-start", "Frühen Start erfassen", method: .put, path: "\(root)/early-start", fields: [.init("requested_at", "Gewünschter Beginn", .dateTime, required: true), .init("note", "Notiz")], confirmation: "Frühen Mietbeginn erfassen?"))
            if record["early_start"]?.object?.isEmpty == false {
                actions.append(.init("clear-early-start", "Frühen Start entfernen", method: .delete, path: "\(root)/early-start", confirmation: "Frühen Mietbeginn entfernen?", destructive: true))
            }
            let unallocatedFromItems = record["items"]?.array?.reduce(0) { count, item in
                count + max((item["quantity"]?.int ?? 1) - (item["allocations"]?.array?.count ?? 0), 0)
            } ?? 0
            let unallocated = record["unallocated_units"]?.int ?? unallocatedFromItems
            if unallocated > 0 {
                actions.append(.init("assign", "Instrument zuweisen", path: "\(root)/allocations", fields: [.init("order_item_id", "Position", .reference("order_items"), required: true), .init("instrument_id", "Instrument", .reference("allocation_candidates"), required: true)], confirmation: "Instrument verbindlich zuweisen?"))
            }
            if record.value(at: "handover.proposals")?.array?.first?["status"]?.string != "pending" {
                actions.append(.init("proposal", "Übergabetermin vorschlagen", path: "\(root)/handover/proposals", fields: [.init("start_at", "Beginn", .dateTime, required: true), .init("end_at", "Ende", .dateTime, required: true), .init("note", "Notiz")], confirmation: "Diesen Übergabetermin vorschlagen?"))
            }
        }
        if let proposal = record.value(at: "handover.proposals")?.array?.first, proposal["status"]?.string == "pending", let proposalID = proposal["proposal_id"]?.string ?? proposal["id"]?.string {
            actions.append(.init("withdraw-proposal", "Terminvorschlag zurückziehen", method: .delete, path: "\(root)/handover/proposals/\(proposalID)", confirmation: "Terminvorschlag zurückziehen?", destructive: true))
        }
        if !daily && ["approved", "ready_for_fulfillment"].contains(status) {
            for allocation in (record["items"]?.array ?? []).flatMap({ $0["allocations"]?.array ?? [] }) where allocation["rental_id"] == nil {
                if let allocationID = allocation["allocation_id"]?.string ?? allocation["id"]?.string {
                    actions.append(.init("unassign-\(allocationID)", "Zuweisung entfernen", method: .delete, path: "\(root)/allocations/\(allocationID)", confirmation: "Instrumentenzuweisung entfernen?", destructive: true))
                }
            }
        }
        let berlinDate = Self.berlinDay()
        let withinBookedDays = berlinDate >= (record["rental_start_date"]?.string ?? "9999-99-99") && berlinDate <= (record["rental_end_date"]?.string ?? "0000-00-00")
        if (!daily && status == "ready_for_fulfillment") || (daily && status == "approved" && handedOver == nil && withinBookedDays) {
            let fields: [ActionField] = daily ? [.init("at", "Zeitpunkt", .dateTime), .init("rent_in_cash", "Miete bar bezahlt", .toggle, defaultValue: record["rent_hold_lost"]?.bool == true ? "true" : "false"), .init("deposit_in_cash", "Kaution bar bezahlt", .toggle)] : [.init("at", "Zeitpunkt", .dateTime)]
            actions.append(.init("handover", "Übergeben", path: "\(root)/handover/complete", fields: fields, confirmation: "Übergabe jetzt verbindlich erfassen?"))
        }
        if !daily, let handover = record["handover"], handover["fulfillment_id"] != nil, handover["status"]?.string != "completed" {
            actions.append(.init("handover-fail", "Übergabe fehlgeschlagen", path: "\(root)/handover/fail", fields: [.init("reason", "Grund", required: true)], confirmation: "Übergabe als fehlgeschlagen erfassen?", destructive: true))
        }
        if daily && handedOver != nil && record["returned_at"]?.string == nil && record["booking_status"]?.string != "returned" {
            actions.append(.init("return", "Rückgabe erfassen", path: "\(root)/return", fields: [.init("returned_at", "Rückgabezeit", .dateTime), .init("fee_in_cash", "Verspätungsgebühr bar", .toggle), .init("waive_note", "Erlassgrund")], confirmation: "Rückgabe und mögliche Gebühr verbindlich erfassen?"))
        }
        if daily && status == "approved" && handedOver == nil && record.value(at: "_no_show_preview.can_record")?.bool != false {
            actions.append(.init("no-show", "Nichtabholung erfassen", path: "\(root)/no-show", fields: [.init("waive_note", "Erlassgrund")], confirmation: "Nichtabholung und mögliche Gebühr verbindlich erfassen?", destructive: true))
        }
        if record.value(at: "deposit.settleable")?.bool == true {
            actions.append(.init("settle-deposit", "Kaution abrechnen", path: "\(root)/deposit/settle", fields: [.init("retained_cents", "Einbehalt in Cent", .integer, required: true, defaultValue: "0"), .init("note", "Begründung")], confirmation: "Kaution verbindlich abrechnen?"))
        }
        return actions
    }

    private static func rental(_ record: JSONValue, root: String, state: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        let monthly = (record["rental_term"]?.string ?? record["term"]?.string) != "short_term"
        if monthly && state == "active" {
            actions.append(.init("cancel-rental", "Kündigung planen", path: "\(root)/cancellation", fields: [.init("end_at", "Enddatum", .dateTime, required: true)], confirmation: "Kündigung zu diesem Datum planen?", destructive: true))
        }
        if monthly && state == "cancellation_scheduled" && record["return_id"] == nil {
            actions.append(.init("withdraw-cancellation", "Kündigung zurückziehen", method: .delete, path: "\(root)/cancellation", confirmation: "Kündigung zurückziehen?"))
        }
        if monthly && state != "ended" && record["current_period"] != nil {
            actions.append(.init("end-now", "Wegen Zahlungsverzug beenden", path: "\(root)/end-now", confirmation: "Miete wegen Zahlungsverzug sofort beenden?", destructive: true))
        }
        if state != "ended" && record["return_id"] == nil && record["instrument"] != nil {
            actions.append(.init("swap", "Instrument tauschen", path: "\(root)/instrument", fields: [.init("instrument_id", "Neues Instrument", .reference("swap_candidates"), required: true), .init("delivery_option_id", "Lieferoption", .reference("swap_delivery_options"), required: true), .init("reason", "Grund", .choice(["size_change", "defect_replacement"]), required: true), .init("previous_instrument_status", "Status des alten Instruments", .choice(["available", "maintenance"]), required: true)], confirmation: "Instrument verbindlich tauschen?"))
        }
        if record["return_id"] == nil {
            actions.append(.init("start-return", "Rückgabe starten", path: "\(root)/return", fields: [.init("return_option_id", "Rückgabeoption", .reference("return_options"), required: true), .init("pickup_address_id", "Abholadresse (ID)"), .init("note", "Notiz")], confirmation: "Rückgabe starten?"))
        }
        return actions
    }

    private static func returnActions(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        if status == "requested" {
            actions.append(.init("appointment", "Termin erfassen", path: "\(root)/appointment", fields: [.init("start_at", "Beginn", .dateTime, required: true), .init("end_at", "Ende", .dateTime, required: true), .init("note", "Notiz")], confirmation: "Rückgabetermin speichern?"))
            if record["method"]?.string == "parcel" {
                actions.append(.init("label", "Paketlabel erfassen", path: "\(root)/label", fields: [.init("tracking_number", "Sendungsnummer", required: true)], confirmation: "Paketlabel als gesendet erfassen?"))
            }
        }
        if ["requested", "scheduled"].contains(status) {
            actions.append(.init("receive", "Eingang erfassen", path: "\(root)/receive", fields: [.init("at", "Eingangszeit", .dateTime)], confirmation: "Instrument als eingegangen erfassen?"))
        }
        if status == "received" { actions.append(.init("inspection", "Prüfung starten", path: "\(root)/inspection", confirmation: "Instrumentenprüfung starten?")) }
        if status == "checkup" {
            actions.append(.init("complete", "Rückgabe abschließen", path: "\(root)/complete", fields: [.init("instrument_status", "Instrumentstatus", .choice(["available", "maintenance"]), required: true)], confirmation: "Rückgabe verbindlich abschließen?"))
        }
        return actions
    }

    private static func cancellation(root: String, status: String) -> [WorkflowAction] {
        guard status == "open" else { return [] }
        return [
            .init("schedule", "Auf Miete eintragen", path: "\(root)/rentals/{rental_id}/schedule", fields: [.init("rental_id", "Miet-ID", required: true)], confirmation: "Kündigung auf dieser Miete eintragen?"),
            .init("resolve", "Anderweitig schließen", path: "\(root)/resolve", fields: [.init("note", "Begründung", required: true)], confirmation: "Kündigung ohne Mietzuordnung schließen?", destructive: true)
        ]
    }

    private static func deposit(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        guard record["verification"]?.string == "manual", ["pending", "submitted"].contains(status) else { return [] }
        return [.init("confirm", "Eingang bestätigen", path: "\(root)/confirm", fields: [.init("paid_at", "Zahlungszeit", .dateTime), .init("note", "Notiz")], confirmation: "Zahlungseingang verbindlich bestätigen?")]
    }

    static func bodyAndPath(action: WorkflowAction, values: [String: String]) throws -> (String, JSONValue?) {
        var object: [String: JSONValue] = [:]
        var path = action.path
        for field in action.fields {
            let value = values[field.id] ?? field.defaultValue
            if field.required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("\(field.title) fehlt.") }
            if path.contains("{\(field.id)}") {
                path = path.replacingOccurrences(of: "{\(field.id)}", with: value)
                continue
            }
            if value.isEmpty && action.id != "tracking" { continue }
            switch field.kind {
            case .toggle: object[field.id] = .bool(value == "true")
            case .integer:
                guard let number = Double(value) else { throw ValidationError("\(field.title) muss eine Zahl sein.") }
                object[field.id] = .number(number)
            default: object[field.id] = .string(value)
            }
        }
        if action.id == "settle-deposit", (object["retained_cents"]?.int ?? 0) > 0,
           (object["note"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Für einen Einbehalt ist eine Begründung erforderlich.")
        }
        switch action.method {
        case .post: return (path, .object(object))
        case .put: return (path, object.isEmpty ? nil : .object(object))
        case .delete, .get: return (path, nil)
        }
    }

    private static func berlinDay() -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
