import Foundation

enum ActionFieldKind: Hashable, Sendable {
    case text, multiline, integer, dateTime, toggle
    /// Euro input ("12,50") sent as integer minor units. Only converts the typed value, no calculation.
    case money
    case choice([String])
    case reference(String)
    /// One value per line (or comma separated), sent as a JSON string array.
    case list
    /// Several IDs from an options key, sent as a JSON string array.
    case multiSelect(String)
    /// "Kategorie = Betrag" per line, sent as `{category: cents}`.
    case priceMap
    /// Image URLs (one per line) with upload and media-library picker.
    case photos
    /// Free JSON object.
    case json
}

enum DateMode: Hashable, Sendable { case past, future, any }

struct ActionField: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: ActionFieldKind
    let required: Bool
    let defaultValue: String
    let hint: String?
    var dateMode: DateMode = .past
    /// Label of an optional date field while it is left empty (the server's default).
    var emptyLabel: String = "jetzt"
    /// Upper bound for money fields, taken from a server value (`refundable_cents`, amount due).
    var maxCents: Int? = nil

    init(_ id: String, _ title: String, _ kind: ActionFieldKind = .text, required: Bool = false, defaultValue: String = "", hint: String? = nil,
         dateMode: DateMode = .past, emptyLabel: String = "jetzt", maxCents: Int? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.required = required; self.defaultValue = defaultValue; self.hint = hint
        self.dateMode = dateMode; self.emptyLabel = emptyLabel; self.maxCents = maxCents
    }
}

struct WorkflowAction: Identifiable, Hashable, Sendable {
    enum Effect: Hashable, Sendable {
        case stay
        /// Opens the record the write returned (creates).
        case openCreated(StaffResource)
        /// The record is gone (deletes).
        case closeRecord
    }
    enum Custom: Hashable, Sendable {
        case conditionSnapshot(instrumentID: String, snapshot: JSONValue?)
    }

    let id: String
    let title: String
    let method: HTTPMethod
    let path: String
    let fields: [ActionField]
    let confirmation: String
    let destructive: Bool
    let systemImage: String
    /// Sent underneath the fields, for routes that expect the complete update DTO.
    var base: JSONValue? = nil
    /// Cleared optional fields are sent as `null` instead of being left out (full updates).
    var nullsEmpty = false
    var effect: Effect = .stay
    var custom: Custom? = nil

    init(_ id: String, _ title: String, method: HTTPMethod = .post, path: String, fields: [ActionField] = [], confirmation: String, destructive: Bool = false, systemImage: String = "arrow.right.circle",
         base: JSONValue? = nil, nullsEmpty: Bool = false, effect: Effect = .stay, custom: Custom? = nil) {
        self.id = id; self.title = title; self.method = method; self.path = path; self.fields = fields; self.confirmation = confirmation; self.destructive = destructive; self.systemImage = systemImage
        self.base = base; self.nullsEmpty = nullsEmpty; self.effect = effect; self.custom = custom
    }

    /// Actions shown inline next to an allocation or item instead of in the action bar.
    var isInline: Bool { id.hasPrefix("unassign-") || id.hasPrefix("remove-role-") || id.hasPrefix("edit-snapshot-") }
}

/// Converts record values to the strings the form edits, and back.
enum FormValue {
    static func string(_ value: JSONValue?, kind: ActionFieldKind) -> String {
        guard let value, value != .null else { return "" }
        switch kind {
        case .money: return value.int.map(StaffLabels.moneyInput) ?? ""
        case .toggle: return value.bool == true ? "true" : "false"
        case .list, .photos: return (value.array ?? []).compactMap(\.string).joined(separator: "\n")
        case .multiSelect: return (value.array ?? []).compactMap(\.string).joined(separator: ",")
        case .priceMap:
            return (value.object ?? [:]).sorted { $0.key < $1.key }
                .compactMap { key, cents in cents.int.map { "\(key) = \(StaffLabels.moneyInput($0))" } }
                .joined(separator: "\n")
        case .json:
            guard value.object != nil || value.array != nil,
                  let data = try? JSONEncoder.pretty.encode(value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        default: return value.string ?? ""
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}

enum WorkflowActions {
    /// The order in which the business flow wants things done. The first available one is the
    /// "Nächster Schritt"; everything else is secondary.
    static let priority = [
        "approve", "assign", "proposal", "handover", "return", "no-show", "settle-deposit",
        "appointment", "label", "receive", "inspection", "complete",
        "confirm", "schedule", "start-return", "withdraw-cancellation",
        "issue-invoice", "record-payment", "add-instruments", "new-snapshot", "activate-document"
    ]

    static func available(for record: JSONValue, resource: StaffResource, today: String = BerlinDay.today()) -> [WorkflowAction] {
        let root = resource.detailPath(id: resource.recordID(record))
        let status = record["status"]?.string ?? ""
        let state = record["state"]?.string ?? ""
        switch resource {
        case .orders: return order(record, root: root, status: status, today: today)
        case .rentals: return rental(record, root: root, state: state, today: today)
        case .returns: return returnActions(record, root: root, status: status)
        case .cancellations: return cancellation(root: root, status: status)
        case .deposits: return deposit(record, root: root, status: status)
        case .invoices: return invoice(record, root: root, status: status)
        case .payments: return payment(record, root: root, status: status)
        case .currencies: return currency(record, root: root)
        case .instrumentTypes: return instrumentType(record, root: root)
        case .instruments: return instrument(record, root: root)
        case .deliveryOptions: return deliveryOption(record, root: root)
        case .deliveryAreas: return deliveryArea(record, root: root)
        case .returnOptions: return returnOption(record, root: root)
        case .legalDocuments: return legalDocument(record, root: root)
        case .users: return user(record, root: root)
        case .customers, .paymentAttempts, .media: return []
        }
    }

    static func primary(in actions: [WorkflowAction]) -> WorkflowAction? {
        for id in priority { if let action = actions.first(where: { $0.id == id && !$0.destructive }) { return action } }
        return nil
    }

    static func handedOverAt(_ record: JSONValue) -> String? {
        record.value(at: "handover.handed_over_at")?.string ?? record["booking_handed_over_at"]?.string ?? record["handed_over_at"]?.string
    }

    private static func order(_ record: JSONValue, root: String, status: String, today: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        let daily = DashboardAlerts.isDaily(record)
        let handedOver = handedOverAt(record)
        let editable = !daily && ["approved", "ready_for_fulfillment"].contains(status)
        if status == "submitted" {
            actions.append(.init("approve", "Genehmigen", path: "\(root)/approve", confirmation: "Diese Bestellung wirklich genehmigen?", systemImage: "checkmark.circle"))
            let text = daily ? "Die Tagesmiete wirklich ablehnen? Die Kartenreservierung wird freigegeben." : "Diese Bestellung wirklich ablehnen?"
            actions.append(.init("reject", "Ablehnen", path: "\(root)/reject", confirmation: text, destructive: true, systemImage: "xmark.circle"))
        }
        if ["draft", "approved", "ready_for_fulfillment"].contains(status) {
            actions.append(.init("cancel", "Stornieren", path: "\(root)/cancel", confirmation: "Diese Bestellung wirklich stornieren?", destructive: true, systemImage: "trash"))
        }
        if !daily && ["approved", "ready_for_fulfillment", "fulfilled"].contains(status) {
            actions.append(.init("tracking", record["tracking_number"]?.string == nil ? "Sendungsnummer erfassen" : "Sendungsnummer ändern", method: .put, path: "\(root)/tracking-number", fields: [.init("tracking_number", "Sendungsnummer", defaultValue: record["tracking_number"]?.string ?? "", hint: "Leer lassen, um die Sendungsnummer zu entfernen.")], confirmation: "Sendungsnummer speichern?", systemImage: "shippingbox"))
        }
        if editable {
            actions.append(.init("early-start", "Frühen Start erfassen", method: .put, path: "\(root)/early-start", fields: [.init("requested_at", "Gewünschter Beginn", .dateTime, required: true), .init("note", "Notiz")], confirmation: "Frühen Mietbeginn erfassen?", systemImage: "calendar.badge.clock"))
            if record["early_start"]?.object?.isEmpty == false {
                actions.append(.init("clear-early-start", "Frühen Start entfernen", method: .delete, path: "\(root)/early-start", confirmation: "Frühen Mietbeginn entfernen?", destructive: true, systemImage: "calendar.badge.minus"))
            }
            if unallocatedUnits(record) > 0 {
                actions.append(.init("assign", "Instrument zuweisen", path: "\(root)/allocations", fields: [.init("order_item_id", "Position", .reference("order_items"), required: true), .init("instrument_id", "Instrument", .reference("allocation_candidates"), required: true)], confirmation: "Instrument verbindlich zuweisen?", systemImage: "guitars"))
            }
            let newest = record.value(at: "handover.proposals")?.array?.first
            let slotScheduled = record.value(at: "handover.status")?.string == "scheduled"
            if newest?["status"]?.string != "pending" {
                let fields: [ActionField] = [
                    .init("start_at", "Beginn", .dateTime, required: true, hint: "Muss in der Zukunft liegen."),
                    .init("end_at", "Ende", .dateTime, required: true, hint: "Höchstens 24 Stunden nach Beginn."),
                    .init("note", "Notiz an den Kunden")
                ]
                if slotScheduled {
                    actions.append(.init("replace-slot", "Termin ersetzen", path: "\(root)/handover/proposals", fields: fields, confirmation: "Der vereinbarte Termin wird durch einen neuen Vorschlag ersetzt. Fortfahren?", destructive: true, systemImage: "calendar.badge.exclamationmark"))
                } else {
                    actions.append(.init("proposal", "Übergabetermin vorschlagen", path: "\(root)/handover/proposals", fields: fields, confirmation: "Diesen Übergabetermin vorschlagen?", systemImage: "calendar.badge.plus"))
                }
            }
            for allocation in (record["items"]?.array ?? []).flatMap({ $0["allocations"]?.array ?? [] }) where !allocation["rental_id"].isPresent {
                if let allocationID = allocation["allocation_id"]?.string ?? allocation["id"]?.string {
                    actions.append(.init("unassign-\(allocationID)", "Zuweisung entfernen", method: .delete, path: "\(root)/allocations/\(allocationID)", confirmation: "Zuweisung von \(allocation["serial_number"]?.string ?? "diesem Instrument") entfernen?", destructive: true, systemImage: "minus.circle"))
                }
            }
        }
        if let proposal = record.value(at: "handover.proposals")?.array?.first, proposal["status"]?.string == "pending", let proposalID = proposal["proposal_id"]?.string ?? proposal["id"]?.string {
            actions.append(.init("withdraw-proposal", "Terminvorschlag zurückziehen", method: .delete, path: "\(root)/handover/proposals/\(proposalID)", confirmation: "Terminvorschlag zurückziehen?", destructive: true, systemImage: "calendar.badge.minus"))
        }
        let withinBookedDays = today >= (record["rental_start_date"]?.string ?? "9999-99-99") && today <= (record["rental_end_date"]?.string ?? "0000-00-00")
        if (!daily && status == "ready_for_fulfillment") || (daily && status == "approved" && handedOver == nil && withinBookedDays) {
            let holdLost = record["rent_hold_lost"]?.bool == true
            let fields: [ActionField] = daily
                ? [.init("at", "Zeitpunkt", .dateTime),
                   .init("rent_in_cash", "Miete bar kassiert", .toggle, defaultValue: holdLost ? "true" : "false", hint: holdLost ? "Die Kartenreservierung ist verfallen – die Miete muss bar kassiert werden." : nil),
                   .init("deposit_in_cash", "Kaution bar kassiert", .toggle)]
                : [.init("at", "Zeitpunkt", .dateTime)]
            actions.append(.init("handover", daily ? "Abholung erfassen" : "Übergeben", path: "\(root)/handover/complete", fields: fields, confirmation: "Übergabe jetzt verbindlich erfassen?", systemImage: "hand.raised"))
        }
        if !daily, let handover = record["handover"], record["handover"].isPresent, handover["fulfillment_id"].isPresent, handover["status"]?.string != "completed" {
            actions.append(.init("handover-fail", "Übergabe fehlgeschlagen", path: "\(root)/handover/fail", fields: [.init("reason", "Grund", required: true)], confirmation: "Übergabe als fehlgeschlagen erfassen?", destructive: true, systemImage: "exclamationmark.triangle"))
        }
        if daily && handedOver != nil && record["returned_at"]?.string == nil && record["booking_status"]?.string != "returned" {
            actions.append(.init("return", "Rückgabe erfassen", path: "\(root)/return", fields: [.init("returned_at", "Rückgabezeit", .dateTime), .init("fee_in_cash", "Verspätungsgebühr bar kassiert", .toggle), .init("waive_note", "Gebühr erlassen – Grund", hint: "Nur ausfüllen, wenn die Verspätungsgebühr erlassen wird.")], confirmation: "Rückgabe und mögliche Gebühr verbindlich erfassen?", systemImage: "arrow.uturn.backward.circle"))
        }
        if daily && status == "approved" && handedOver == nil && record.value(at: "_no_show_preview.can_record")?.bool != false {
            actions.append(.init("no-show", "Nichtabholung erfassen", path: "\(root)/no-show", fields: [.init("waive_note", "Gebühr erlassen – Grund")], confirmation: "Nichtabholung und mögliche Gebühr verbindlich erfassen?", destructive: true, systemImage: "person.fill.xmark"))
        }
        if record.value(at: "deposit.settleable")?.bool == true {
            let held = record.value(at: "deposit.held_cents")?.int ?? record.value(at: "deposit.amount_cents")?.int
            let hint = held.map { "0 gibt die gesamte Kaution frei. Höchstens \(StaffLabels.money($0, currency: record.value(at: "deposit.currency_code")?.string))." } ?? "0 gibt die gesamte Kaution frei."
            actions.append(.init("settle-deposit", "Kaution abrechnen", path: "\(root)/deposit/settle", fields: [.init("retained_cents", "Einbehalt in Euro", .money, required: true, defaultValue: "0", hint: hint), .init("note", "Begründung", hint: "Pflicht, wenn etwas einbehalten wird.")], confirmation: "Kaution verbindlich abrechnen?", systemImage: "eurosign.circle"))
        }
        return actions
    }

    static func unallocatedUnits(_ record: JSONValue) -> Int {
        let fromItems = record["items"]?.array?.reduce(0) { count, item in
            count + max((item["quantity"]?.int ?? 1) - (item["allocations"]?.array?.count ?? 0), 0)
        } ?? 0
        return record["unallocated_units"]?.int ?? fromItems
    }

    private static func rental(_ record: JSONValue, root: String, state: String, today: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        let monthly = !DashboardAlerts.isDaily(record)
        let noReturn = !record["return_id"].isPresent
        if monthly && state == "active" {
            actions.append(.init("cancel-rental", "Kündigung planen", path: "\(root)/cancellation", fields: [.init("end_at", "Enddatum", .dateTime, required: true, hint: "Darf nicht in der Vergangenheit liegen. Mindestlaufzeit und Frist gelten nur für Kunden.")], confirmation: "Kündigung zu diesem Datum planen?", destructive: true, systemImage: "calendar.badge.minus"))
        }
        if monthly && state == "cancellation_scheduled" && noReturn {
            actions.append(.init("withdraw-cancellation", "Kündigung zurückziehen", method: .delete, path: "\(root)/cancellation", confirmation: "Kündigung zurückziehen?", systemImage: "arrow.uturn.left"))
        }
        let endDate = record["effective_end_date"]?.string ?? ""
        if monthly && state != "ended" && record["current_period"].isPresent && (endDate.isEmpty || endDate > today) {
            actions.append(.init("end-now", "Wegen Zahlungsverzug beenden", path: "\(root)/end-now", confirmation: "Miete wegen Zahlungsverzug sofort beenden? Der Server prüft den Zahlungsrückstand.", destructive: true, systemImage: "exclamationmark.octagon"))
        }
        if state != "ended" && noReturn && record["instrument"].isPresent {
            actions.append(.init("swap", "Instrument tauschen", path: "\(root)/instrument", fields: [.init("instrument_id", "Neues Instrument", .reference("swap_candidates"), required: true), .init("delivery_option_id", "Lieferoption", .reference("swap_delivery_options"), required: true), .init("reason", "Grund", .choice(["size_change", "defect_replacement"]), required: true), .init("previous_instrument_status", "Altes Instrument danach", .choice(["available", "maintenance"]), required: true)], confirmation: "Instrument verbindlich tauschen?", systemImage: "arrow.triangle.2.circlepath"))
        }
        if noReturn && state != "ended" {
            actions.append(.init("start-return", "Rückgabe starten", path: "\(root)/return", fields: [.init("return_option_id", "Rückgabeoption", .reference("return_options"), required: true, hint: "Keine Optionen? Unter Inventar & Logistik in der Admin-App anlegen."), .init("pickup_address_id", "Abholadresse", .reference("pickup_addresses"), hint: "Nur bei Abholung."), .init("note", "Notiz")], confirmation: "Rückgabe starten?", systemImage: "arrow.uturn.backward.circle"))
        }
        return actions
    }

    private static func returnActions(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        if status == "requested" {
            actions.append(.init("appointment", "Termin erfassen", path: "\(root)/appointment", fields: [.init("start_at", "Beginn", .dateTime, required: true), .init("end_at", "Ende", .dateTime, required: true), .init("note", "Notiz")], confirmation: "Rückgabetermin speichern?", systemImage: "calendar.badge.plus"))
            if record["method"]?.string == "parcel" {
                actions.append(.init("label", "Paketlabel erfassen", path: "\(root)/label", fields: [.init("tracking_number", "Sendungsnummer", required: true)], confirmation: "Paketlabel als gesendet erfassen?", systemImage: "shippingbox"))
            }
        }
        if ["requested", "scheduled"].contains(status) {
            actions.append(.init("receive", "Eingang erfassen", path: "\(root)/receive", fields: [.init("at", "Eingangszeit", .dateTime)], confirmation: "Instrument als eingegangen erfassen?", systemImage: "tray.and.arrow.down"))
        }
        if status == "received" { actions.append(.init("inspection", "Prüfung starten", path: "\(root)/inspection", confirmation: "Instrumentenprüfung starten?", systemImage: "magnifyingglass")) }
        if status == "checkup" {
            actions.append(.init("complete", "Rückgabe abschließen", path: "\(root)/complete", fields: [.init("instrument_status", "Instrument danach", .choice(["available", "maintenance"]), required: true)], confirmation: "Rückgabe verbindlich abschließen?", systemImage: "checkmark.seal"))
        }
        return actions
    }

    private static func cancellation(root: String, status: String) -> [WorkflowAction] {
        guard status == "open" else { return [] }
        return [
            .init("schedule", "Auf Miete eintragen", path: "\(root)/rentals/{rental_id}/schedule", fields: [.init("rental_id", "Miete", .reference("cancellation_rentals"), required: true)], confirmation: "Kündigung auf dieser Miete eintragen?", systemImage: "doc.badge.plus"),
            .init("resolve", "Anderweitig schließen", path: "\(root)/resolve", fields: [.init("note", "Begründung", required: true)], confirmation: "Kündigung ohne Mietzuordnung schließen?", destructive: true, systemImage: "archivebox")
        ]
    }

    private static func deposit(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        guard record["verification"]?.string == "manual", ["pending", "submitted"].contains(status) else { return [] }
        return [.init("confirm", "Eingang bestätigen", path: "\(root)/confirm", fields: [.init("paid_at", "Zahlungszeit", .dateTime, hint: "Nicht in der Zukunft und nicht vor der Bestellung."), .init("note", "Notiz")], confirmation: "Zahlungseingang verbindlich bestätigen?", systemImage: "checkmark.circle")]
    }

    static func bodyAndPath(action: WorkflowAction, values: [String: String], now: Date = .now) throws -> (String, JSONValue?) {
        var object: [String: JSONValue] = action.base?.object ?? [:]
        var path = action.path
        for field in action.fields {
            let raw = values[field.id] ?? field.defaultValue
            let value = field.kind == .multiline || field.kind == .json ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let blank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if field.required && blank { throw ValidationError("\(field.title) fehlt.") }
            if path.contains("{\(field.id)}") {
                guard let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { throw ValidationError("\(field.title) ist ungültig.") }
                path = path.replacingOccurrences(of: "{\(field.id)}", with: escaped)
                continue
            }
            if blank {
                switch field.kind {
                case .list, .multiSelect, .photos: object[field.id] = .array([])
                case .priceMap: object[field.id] = .object([:])
                case .toggle: object[field.id] = .bool(false)
                default:
                    if action.id == "tracking" { object[field.id] = .string("") }
                    else if action.nullsEmpty { object[field.id] = .null }
                    else { object.removeValue(forKey: field.id) }
                }
                continue
            }
            switch field.kind {
            case .toggle: object[field.id] = .bool(value == "true")
            case .integer:
                guard let number = Int(value) else { throw ValidationError("\(field.title) muss eine ganze Zahl sein.") }
                object[field.id] = .number(Double(number))
            case .money:
                guard let cents = parseCents(value) else { throw ValidationError("\(field.title) muss ein Betrag wie 12,50 sein.") }
                if let max = field.maxCents, cents > max { throw ValidationError("\(field.title) darf höchstens \(StaffLabels.money(max)) sein.") }
                object[field.id] = .number(Double(cents))
            case .list, .photos:
                object[field.id] = .array(splitList(value, commas: field.kind == .list).map(JSONValue.string))
            case .multiSelect:
                object[field.id] = .array(value.split(separator: ",").map { JSONValue.string(String($0)) })
            case .priceMap:
                var prices: [String: JSONValue] = [:]
                for line in value.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2, !parts[0].isEmpty, let cents = parseCents(parts[1]) else {
                        throw ValidationError("\(field.title): „\(line)“ bitte als „Kategorie = 12,50“ angeben.")
                    }
                    prices[parts[0]] = .number(Double(cents))
                }
                object[field.id] = .object(prices)
            case .json:
                guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)), parsed.object != nil else {
                    throw ValidationError("\(field.title) muss ein JSON-Objekt sein.")
                }
                object[field.id] = parsed
            default: object[field.id] = .string(value)
            }
        }
        try validate(action: action, object: &object, now: now)
        switch action.method {
        case .post, .patch: return (path, .object(object))
        case .put, .delete: return (path, object.isEmpty ? nil : .object(object))
        case .get: return (path, nil)
        }
    }

    static func splitList(_ value: String, commas: Bool) -> [String] {
        value.split { $0.isNewline || (commas && $0 == ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Checks the API documents for a route, so mistakes surface before the request.
    private static func validate(action: WorkflowAction, object: inout [String: JSONValue], now: Date) throws {
        if action.id == "settle-deposit", (object["retained_cents"]?.int ?? 0) > 0,
           (object["note"]?.string ?? "").isEmpty {
            throw ValidationError("Für einen Einbehalt ist eine Begründung erforderlich.")
        }
        if ["proposal", "replace-slot", "appointment"].contains(action.id),
           let start = object["start_at"]?.string.flatMap(StaffLabels.parseTimestamp),
           let end = object["end_at"]?.string.flatMap(StaffLabels.parseTimestamp) {
            if action.id != "appointment" && start <= now { throw ValidationError("Der Termin muss in der Zukunft beginnen.") }
            if end <= start { throw ValidationError("Das Ende muss nach dem Beginn liegen.") }
            if action.id != "appointment" && end.timeIntervalSince(start) > 86_400 { throw ValidationError("Ein Übergabetermin darf höchstens 24 Stunden dauern.") }
        }
        if let prefixes = object["postal_code_prefixes"]?.array {
            if prefixes.isEmpty { throw ValidationError("Mindestens ein PLZ-Präfix angeben.") }
            if let bad = prefixes.compactMap(\.string).first(where: { !(1...5).contains($0.count) || !$0.allSatisfy(\.isASCIIDigit) }) {
                throw ValidationError("„\(bad)“ ist kein PLZ-Präfix (1–5 Ziffern).")
            }
        }
        if action.id == "add-instruments", let quantity = object["quantity"]?.int {
            if quantity < 1 { throw ValidationError("Anzahl muss mindestens 1 sein.") }
            let serials = object["serial_numbers"]?.array?.count ?? 0
            if serials > 0 && serials != quantity { throw ValidationError("Bitte genau \(quantity) Seriennummer(n) angeben oder das Feld leer lassen.") }
        }
        if action.id.hasPrefix("legal-"), (object["document_hash"]?.string ?? "").isEmpty, let content = object["content"]?.string {
            object["document_hash"] = .string(StaffLabels.sha256(content))
        }
        if let code = object["currency_code"]?.string, action.id == "create-currency" {
            object["currency_code"] = .string(code.uppercased())
            if code.count != 3 || !code.allSatisfy(\.isLetter) { throw ValidationError("Der Währungscode besteht aus drei Buchstaben, z. B. EUR.") }
        }
    }

    /// Parses "12", "12,5", "12,50", "1.234,50" or "12.50" into minor units without floating point.
    static func parseCents(_ input: String) -> Int? {
        var text = input.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
        if text.contains(",") { text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let euros = Int(parts[0].isEmpty ? "0" : parts[0]), euros >= 0 else { return nil }
        var cents = 0
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard fraction.count <= 2, fraction.allSatisfy(\.isNumber) else { return nil }
            cents = Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        return euros * 100 + cents
    }
}

/// Where a record stands in its lifecycle (§ 7.3). Display only – the server owns every transition.
struct Lifecycle: Equatable {
    let stages: [String]
    let current: Int
    let exit: String?

    static func of(_ record: JSONValue, resource: StaffResource) -> Lifecycle? {
        let status = record["status"]?.string ?? ""
        switch resource {
        case .orders:
            if DashboardAlerts.isDaily(record) {
                let stages = ["Eingegangen", "Genehmigt", "Abgeholt", "Zurückgegeben", "Abgeschlossen"]
                if ["rejected", "cancelled"].contains(status) { return .init(stages: stages, current: 1, exit: status) }
                let returned = record["returned_at"]?.string != nil || record["booking_status"]?.string == "returned"
                let current = status == "closed" ? 4 : returned ? 3 : WorkflowActions.handedOverAt(record) != nil ? 2 : status == "submitted" || status == "draft" ? 0 : 1
                return .init(stages: stages, current: current, exit: nil)
            }
            let flow = ["submitted", "approved", "ready_for_fulfillment", "fulfilled", "closed"]
            let stages = ["Eingegangen", "Genehmigt", "Übergabe bereit", "Übergeben", "Abgeschlossen"]
            if ["rejected", "cancelled"].contains(status) { return .init(stages: stages, current: status == "rejected" ? 0 : 1, exit: status) }
            return .init(stages: stages, current: flow.firstIndex(of: status == "placed" ? "approved" : status) ?? 0, exit: nil)
        case .rentals:
            let flow = ["active", "cancellation_scheduled", "ended"]
            return .init(stages: flow.map(StaffLabels.label), current: flow.firstIndex(of: record["state"]?.string ?? "") ?? 0, exit: nil)
        case .returns:
            let flow = ["requested", "scheduled", "received", "checkup", "completed"]
            let stages = ["Angefragt", record["method"]?.string == "parcel" ? "Label gesendet" : "Termin gesetzt", "Eingegangen", "In Prüfung", "Abgeschlossen"]
            return .init(stages: stages, current: flow.firstIndex(of: status) ?? 0, exit: nil)
        case .deposits:
            let flow = ["pending", "submitted", "succeeded"]
            if ["failed", "canceled", "returned"].contains(status) { return .init(stages: flow.map(StaffLabels.label), current: 1, exit: status) }
            return .init(stages: flow.map(StaffLabels.label), current: flow.firstIndex(of: status) ?? 0, exit: nil)
        case .cancellations:
            let flow = ["open", "resolved"]
            return .init(stages: flow.map(StaffLabels.label), current: flow.firstIndex(of: status) ?? 0, exit: nil)
        case .invoices:
            let flow = ["draft", "issued", "partially_paid", "paid"]
            let stages = ["Entwurf", "Gestellt", "Teilweise bezahlt", "Bezahlt"]
            if ["void", "uncollectible"].contains(status) { return .init(stages: stages, current: status == "void" ? 1 : 2, exit: status) }
            return .init(stages: stages, current: flow.firstIndex(of: status) ?? 0, exit: nil)
        case .payments, .paymentAttempts:
            let flow = ["pending", "submitted", "succeeded"]
            guard !status.isEmpty else { return nil }
            if ["failed", "canceled", "returned"].contains(status) { return .init(stages: flow.map(StaffLabels.label), current: 1, exit: status) }
            guard let index = flow.firstIndex(of: status) else { return nil }
            return .init(stages: flow.map(StaffLabels.label), current: index, exit: nil)
        case .customers, .users, .currencies, .instrumentTypes, .instruments, .deliveryOptions, .deliveryAreas, .returnOptions, .media, .legalDocuments:
            return nil
        }
    }
}
