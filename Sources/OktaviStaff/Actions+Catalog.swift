import Foundation

/// Actions for Finanzen, Inventar & Logistik, Rechtliches and Benutzerkonten. Every guard mirrors the
/// documented route preconditions; the server still decides.
extension WorkflowActions {
    static let instrumentConditions = ["new", "good", "used", "needs_repair"]
    static let instrumentStatuses = ["available", "maintenance", "in_use"]
    static let staffRoles = ["admin", "staff", "support"]

    // MARK: Create (list level)

    static func createActions(for resource: StaffResource) -> [WorkflowAction] {
        let path = resource.listPath
        switch resource {
        case .currencies:
            return [.init("create-currency", "Neue Währung", path: path, fields: [
                .init("currency_code", "Code", required: true, hint: "Drei Buchstaben, z. B. EUR."),
                .init("name", "Name", required: true), .init("symbol", "Symbol", required: true),
                .init("minor_units", "Nachkommastellen", .integer, required: true, defaultValue: "2"),
                .init("is_active", "Aktiv", .toggle, defaultValue: "true")
            ], confirmation: "Währung anlegen?", systemImage: "plus", effect: .openCreated(.currencies))]
        case .instrumentTypes:
            return [.init("create-type", "Neuer Instrumententyp", path: path, fields: instrumentTypeFields(nil), confirmation: "Instrumententyp anlegen?", systemImage: "plus", effect: .openCreated(.instrumentTypes))]
        case .instruments:
            return [addInstruments(typeID: nil, sizes: [], currency: nil)]
        case .deliveryOptions:
            return [.init("create-delivery-option", "Neue Lieferoption", path: path, fields: deliveryOptionFields(nil), confirmation: "Lieferoption anlegen?", systemImage: "plus", effect: .openCreated(.deliveryOptions))]
        case .deliveryAreas:
            return [.init("create-delivery-area", "Neues Liefergebiet", path: path, fields: deliveryAreaFields(nil), confirmation: "Liefergebiet anlegen?", systemImage: "plus", effect: .openCreated(.deliveryAreas))]
        case .returnOptions:
            return [.init("create-return-option", "Neue Rückgabeoption", path: path, fields: returnOptionFields(nil), confirmation: "Rückgabeoption anlegen?", systemImage: "plus", effect: .openCreated(.returnOptions))]
        case .legalDocuments:
            return [legalVersion(type: "", content: "", title: "Neuer Rechtstext")]
        default:
            return []
        }
    }

    // MARK: Finanzen

    static func invoice(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = []
        let type = record["type"]?.string ?? record["invoice_type"]?.string ?? ""
        let paid = record["paid_cents"]?.int ?? record["amount_paid_cents"]?.int ?? 0
        let due = amountDue(record)
        if status == "draft" {
            actions.append(.init("issue-invoice", "Rechnung stellen", path: "\(root)/issue", fields: [
                .init("due_at", "Fällig am", .dateTime, dateMode: .future, emptyLabel: "Fälligkeit: in 14 Tagen")
            ], confirmation: "Rechnung verbindlich stellen? Danach ist sie für den Kunden sichtbar.", systemImage: "paperplane"))
        }
        if ["issued", "partially_paid"].contains(status) && type != "deposit" {
            actions.append(.init("record-payment", "Zahlung erfassen", path: "\(root)/payments", fields: [
                .init("provider", "Zahlungsweg", .choice(["manual_bank_transfer", "cash"]), required: true, defaultValue: "manual_bank_transfer"),
                .init("amount_cents", "Betrag in Euro", .money, required: true, defaultValue: due.map(StaffLabels.moneyInput) ?? "", hint: due.map { "Offen: \(StaffLabels.money($0, currency: record["currency_code"]?.string))" }, maxCents: due),
                .init("paid_at", "Bezahlt am", .dateTime),
                .init("external_reference", "Referenz", hint: "z. B. Verwendungszweck der Überweisung"),
                .init("notes", "Notiz", .multiline)
            ], confirmation: "Zahlungseingang verbindlich buchen?", systemImage: "banknote"))
        }
        if ["draft", "issued"].contains(status) && paid == 0 {
            actions.append(.init("void-invoice", "Stornieren", path: "\(root)/void", confirmation: "Rechnung stornieren? Das geht nur, solange keine Zahlung läuft oder eingegangen ist.", destructive: true, systemImage: "xmark.circle"))
        }
        if ["issued", "partially_paid"].contains(status) {
            actions.append(.init("uncollectible", "Als uneinbringlich abschreiben", path: "\(root)/uncollectible", confirmation: "Offenen Betrag als uneinbringlich abschreiben?", destructive: true, systemImage: "minus.circle"))
        }
        return actions
    }

    static func amountDue(_ record: JSONValue) -> Int? {
        record["amount_due_cents"]?.int ?? record["balance_due_cents"]?.int ?? record["outstanding_cents"]?.int ?? record["open_cents"]?.int
    }

    static func payment(_ record: JSONValue, root: String, status: String) -> [WorkflowAction] {
        let inbound = (record["direction"]?.string ?? "inbound") == "inbound"
        let refundable = record["refundable_cents"]?.int
        guard inbound, status == "succeeded", refundable.map({ $0 > 0 }) ?? true else { return [] }
        let stripe = record["provider"]?.string == "stripe"
        return [.init("refund", "Erstatten", path: "\(root)/refunds", fields: [
            .init("amount_cents", "Betrag in Euro", .money, required: true, defaultValue: refundable.map(StaffLabels.moneyInput) ?? "",
                  hint: refundable.map { "Höchstens \(StaffLabels.money($0, currency: record["currency_code"]?.string)) erstattbar." }, maxCents: refundable),
            .init("paid_at", "Zurückgezahlt am", .dateTime),
            .init("external_reference", "Referenz"),
            .init("notes", "Notiz", .multiline)
        ], confirmation: stripe ? "Betrag über Stripe an den Kunden erstatten?" : "Erstattung als zurückgezahlt buchen? Das Geld muss separat überwiesen bzw. ausgezahlt werden.", destructive: true, systemImage: "arrow.uturn.left.circle")]
    }

    static func currency(_ record: JSONValue, root: String) -> [WorkflowAction] {
        let active = record["is_active"]?.bool ?? true
        return [
            .init("edit-currency", "Bearbeiten", method: .patch, path: root, fields: [
                .init("name", "Name", required: true, defaultValue: record["name"]?.string ?? ""),
                .init("symbol", "Symbol", required: true, defaultValue: record["symbol"]?.string ?? ""),
                .init("minor_units", "Nachkommastellen", .integer, required: true, defaultValue: record["minor_units"]?.string ?? "2"),
                .init("is_active", "Aktiv", .toggle, defaultValue: active ? "true" : "false")
            ], confirmation: "Änderungen speichern?", systemImage: "pencil"),
            .init(active ? "deactivate-currency" : "activate-currency", active ? "Deaktivieren" : "Aktivieren", method: .patch, path: "\(root)/active",
                  confirmation: active ? "Währung deaktivieren? Kunden sehen nur aktive Währungen." : "Währung aktivieren?", destructive: active,
                  systemImage: active ? "pause.circle" : "play.circle", base: .object(["is_active": .bool(!active)])),
            .init("delete-currency", "Löschen", method: .delete, path: root, confirmation: "Währung löschen? Wird sie noch verwendet, lehnt der Server ab.", destructive: true, systemImage: "trash", effect: .closeRecord)
        ]
    }

    // MARK: Inventar

    static func instrumentTypeFields(_ record: JSONValue?) -> [ActionField] {
        func value(_ key: String, _ kind: ActionFieldKind = .text) -> String { FormValue.string(record?[key], kind: kind) }
        return [
            .init("name", "Name", required: true, defaultValue: value("name")),
            .init("brand", "Marke", defaultValue: value("brand")),
            .init("model", "Modell", defaultValue: value("model")),
            .init("category", "Kategorie", .reference("categories"), required: true, defaultValue: value("category"), hint: "Bestimmt Preise je Kategorie und die Zustandsprüfpunkte."),
            .init("sizes", "Größen", .list, defaultValue: value("sizes", .list), hint: "Eine pro Zeile oder durch Komma, z. B. 1/2, 3/4, 4/4."),
            .init("photo_urls", "Fotos", .photos, defaultValue: value("photo_urls", .photos)),
            .init("description", "Beschreibung", .multiline, defaultValue: value("description")),
            .init("default_rental_price_cents", "Mietpreis / Monat", .money, required: true, defaultValue: value("default_rental_price_cents", .money)),
            .init("default_purchase_price_cents", "Kaufpreis", .money, defaultValue: value("default_purchase_price_cents", .money)),
            .init("deposit_cents", "Kaution", .money, required: true, defaultValue: value("deposit_cents", .money)),
            .init("currency_code", "Währung", .reference("currencies"), required: true, defaultValue: record?["currency_code"]?.string ?? "EUR")
        ]
    }

    static func instrumentType(_ record: JSONValue, root: String) -> [WorkflowAction] {
        let typeID = StaffResource.instrumentTypes.recordID(record)
        let sizes = (record["sizes"]?.array ?? []).compactMap(\.string)
        return [
            addInstruments(typeID: typeID, sizes: sizes, currency: record["currency_code"]?.string),
            .init("edit-type", "Bearbeiten", method: .patch, path: root, fields: instrumentTypeFields(record), confirmation: "Änderungen am Instrumententyp speichern? Sie erscheinen sofort im Shop.", systemImage: "pencil", nullsEmpty: true),
            .init("delete-type", "Löschen", method: .delete, path: root, confirmation: "Instrumententyp löschen? Gibt es noch Instrumente oder Bestellungen dazu, lehnt der Server ab.", destructive: true, systemImage: "trash", effect: .closeRecord)
        ]
    }

    /// `POST /admin/products`: physical instruments for an existing type.
    static func addInstruments(typeID: String?, sizes: [String], currency: String?) -> WorkflowAction {
        var fields: [ActionField] = []
        if typeID == nil { fields.append(.init("product_type_id", "Instrumententyp", .reference("instrument_types"), required: true)) }
        fields += [
            .init("quantity", "Anzahl", .integer, required: true, defaultValue: "1"),
            .init("serial_numbers", "Seriennummern", .list, hint: "Eine pro Instrument – genauso viele wie die Anzahl, oder leer lassen."),
            sizes.isEmpty ? .init("size", "Größe") : .init("size", "Größe", .choice(sizes), required: true, defaultValue: sizes.count == 1 ? sizes[0] : ""),
            .init("condition", "Zustand", .choice(instrumentConditions), required: true, defaultValue: "new"),
            .init("status", "Status", .choice(["available", "maintenance"]), required: true, defaultValue: "available"),
            .init("location", "Lagerort"),
            .init("acquisition_cost_cents", "Anschaffungskosten je Stück", .money),
            .init("acquisition_currency_code", "Anschaffungswährung", .reference("currencies"), defaultValue: currency ?? "EUR"),
            .init("custom_rental_price_cents", "Eigener Mietpreis", .money, hint: "Leer lassen: Preis des Typs."),
            .init("custom_purchase_price_cents", "Eigener Kaufpreis", .money),
            .init("currency_code", "Währung", .reference("currencies"), defaultValue: currency ?? "EUR"),
            .init("notes", "Notiz", .multiline)
        ]
        return .init("add-instruments", "Instrumente hinzufügen", path: "api/v1/admin/products", fields: fields,
                     confirmation: "Instrumente verbindlich im Bestand anlegen?", systemImage: "plus.square.on.square",
                     base: typeID.map { .object(["product_type_id": .string($0)]) }, effect: typeID == nil ? .openCreated(.instruments) : .stay)
    }

    /// Writable keys of the instrument's full update DTO, taken from the current record.
    static func instrumentBase(_ record: JSONValue) -> JSONValue {
        let keys = ["instrument_type_id", "serial_number", "size", "condition", "status", "custom_rental_price_cents", "custom_purchase_price_cents",
                    "currency_code", "location", "notes"]
        var base: [String: JSONValue] = [:]
        for (key, value) in record.object ?? [:] where keys.contains(key) || key.hasPrefix("acquisition_") { base[key] = value }
        if base["instrument_type_id"] == nil, let typeID = record.value(at: "instrument_type.instrument_type_id") ?? record.value(at: "instrument_type.id") { base["instrument_type_id"] = typeID }
        return .object(base)
    }

    static func instrument(_ record: JSONValue, root: String) -> [WorkflowAction] {
        let id = StaffResource.instruments.recordID(record)
        let status = record["status"]?.string ?? ""
        let base = instrumentBase(record)
        func choices(_ list: [String], current: String?) -> [String] { current.map { list.contains($0) ? list : list + [$0] } ?? list }
        var actions: [WorkflowAction] = [
            .init("new-snapshot", "Zustand erfassen", path: "api/v1/instruments/\(id)/condition-snapshots", confirmation: "", systemImage: "checklist", custom: .conditionSnapshot(instrumentID: id, snapshot: nil))
        ]
        if status == "available" {
            actions.append(.init("set-maintenance", "In Wartung geben", method: .patch, path: root, confirmation: "Instrument in die Wartung geben? Es kann dann nicht zugewiesen werden.", systemImage: "wrench.and.screwdriver",
                                 base: base.merging(["status": .string("maintenance")])))
        }
        if status == "maintenance" {
            actions.append(.init("set-available", "Wieder verfügbar", method: .patch, path: root, confirmation: "Instrument wieder als verfügbar markieren?", systemImage: "checkmark.circle",
                                 base: base.merging(["status": .string("available")])))
        }
        actions.append(.init("edit-instrument", "Stammdaten bearbeiten", method: .patch, path: root, fields: [
            .init("instrument_type_id", "Instrumententyp", .reference("instrument_types"), required: true, defaultValue: base["instrument_type_id"]?.string ?? ""),
            .init("serial_number", "Seriennummer", required: true, defaultValue: record["serial_number"]?.string ?? ""),
            .init("size", "Größe", defaultValue: record["size"]?.string ?? ""),
            .init("condition", "Zustand", .choice(choices(instrumentConditions, current: record["condition"]?.string)), required: true, defaultValue: record["condition"]?.string ?? ""),
            .init("status", "Status", .choice(choices(instrumentStatuses, current: record["status"]?.string)), required: true, defaultValue: status,
                  hint: "„In Benutzung“ setzt normalerweise die Übergabe."),
            .init("location", "Lagerort", defaultValue: record["location"]?.string ?? ""),
            .init("custom_rental_price_cents", "Eigener Mietpreis", .money, defaultValue: FormValue.string(record["custom_rental_price_cents"], kind: .money), hint: "Leer lassen: Preis des Typs."),
            .init("custom_purchase_price_cents", "Eigener Kaufpreis", .money, defaultValue: FormValue.string(record["custom_purchase_price_cents"], kind: .money)),
            .init("currency_code", "Währung", .reference("currencies"), defaultValue: record["currency_code"]?.string ?? "EUR"),
            .init("acquisition_cost_cents", "Anschaffungskosten", .money, defaultValue: FormValue.string(record["acquisition_cost_cents"], kind: .money)),
            .init("acquisition_currency_code", "Anschaffungswährung", .reference("currencies"), defaultValue: record["acquisition_currency_code"]?.string ?? ""),
            .init("notes", "Notiz", .multiline, defaultValue: record["notes"]?.string ?? "")
        ], confirmation: "Stammdaten speichern?", systemImage: "pencil", base: base, nullsEmpty: true))
        actions.append(.init("delete-instrument", "Löschen", method: .delete, path: root, confirmation: "Instrument löschen? Hat es Mieten oder Zuweisungen, lehnt der Server ab.", destructive: true, systemImage: "trash", effect: .closeRecord))
        return actions
    }

    /// The record without its identity and timestamps, for "domain fields, path ID wins" PATCH routes.
    static func editableBase(_ record: JSONValue, dropping extra: [String] = []) -> JSONValue {
        let readOnly = ["id", "created_at", "updated_at", "delivery_option_id", "delivery_area_id", "return_option_id"] + extra
        return .object((record.object ?? [:]).filter { !readOnly.contains($0.key) && !$0.key.hasPrefix("_") })
    }

    static func deliveryOptionFields(_ record: JSONValue?) -> [ActionField] {
        let addressKey = record?["requires_delivery_address"] != nil ? "requires_delivery_address" : "requires_address"
        return [
            .init("code", "Code", required: true, defaultValue: record?["code"]?.string ?? ""),
            .init("name", "Name", required: true, defaultValue: record?["name"]?.string ?? ""),
            .init("description", "Beschreibung", .multiline, defaultValue: record?["description"]?.string ?? ""),
            .init("price_cents", "Preis", .money, required: true, defaultValue: FormValue.string(record?["price_cents"], kind: .money)),
            .init("currency_code", "Währung", .reference("currencies"), required: true, defaultValue: record?["currency_code"]?.string ?? "EUR"),
            .init(addressKey, "Lieferadresse nötig", .toggle, defaultValue: FormValue.string(record?[addressKey], kind: .toggle)),
            .init("is_active", "Aktiv", .toggle, defaultValue: record.map { FormValue.string($0["is_active"], kind: .toggle) } ?? "true"),
            .init("sort_order", "Reihenfolge", .integer, defaultValue: record?["sort_order"]?.string ?? "0")
        ]
    }

    static func deliveryOption(_ record: JSONValue, root: String) -> [WorkflowAction] {
        [
            .init("edit-delivery-option", "Bearbeiten", method: .patch, path: root, fields: deliveryOptionFields(record), confirmation: "Lieferoption speichern?", systemImage: "pencil",
                  base: editableBase(record, dropping: ["return_option_ids", "delivery_area_ids"])),
            .init("set-return-options", "Rückgabeoptionen festlegen", method: .put, path: "\(root)/return-options", fields: [
                .init("return_option_ids", "Erlaubte Rückgabeoptionen", .multiSelect("return_options"), defaultValue: FormValue.string(record["return_option_ids"], kind: .multiSelect("")),
                      hint: "Keine Auswahl: alle aktiven Rückgabeoptionen sind erlaubt.")
            ], confirmation: "Erlaubte Rückgabeoptionen ersetzen?", systemImage: "arrow.uturn.left.square"),
            .init("set-delivery-areas", "Liefergebiete festlegen", method: .put, path: "\(root)/delivery-areas", fields: [
                .init("delivery_area_ids", "Liefergebiete", .multiSelect("delivery_areas"), defaultValue: FormValue.string(record["delivery_area_ids"], kind: .multiSelect("")),
                      hint: "Keine Auswahl: überall verfügbar.")
            ], confirmation: "Liefergebiete der Option ersetzen?", systemImage: "map")
        ]
    }

    static func deliveryAreaFields(_ record: JSONValue?) -> [ActionField] {
        [
            .init("code", "Code", required: true, defaultValue: record?["code"]?.string ?? ""),
            .init("name", "Name", required: true, defaultValue: record?["name"]?.string ?? ""),
            .init("postal_code_prefixes", "PLZ-Präfixe", .list, required: true, defaultValue: FormValue.string(record?["postal_code_prefixes"], kind: .list),
                  hint: "1–5 Ziffern je Präfix, z. B. 10, 12, 13 für Berlin.")
        ]
    }

    static func deliveryArea(_ record: JSONValue, root: String) -> [WorkflowAction] {
        [.init("edit-delivery-area", "Bearbeiten", method: .patch, path: root, fields: deliveryAreaFields(record), confirmation: "Liefergebiet speichern?", systemImage: "pencil", base: editableBase(record))]
    }

    static func returnOptionFields(_ record: JSONValue?) -> [ActionField] {
        [
            .init("code", "Code", required: true, defaultValue: record?["code"]?.string ?? ""),
            .init("name", "Name", required: true, defaultValue: record?["name"]?.string ?? ""),
            .init("description", "Beschreibung", .multiline, defaultValue: record?["description"]?.string ?? ""),
            .init("kind", "Art", .choice(["pickup", "dropoff", "parcel"]), required: true, defaultValue: record?["kind"]?.string ?? "", hint: "Abholung braucht eine Adresse, Abgabe und Paket nicht."),
            .init("price_cents", "Preis", .money, required: true, defaultValue: FormValue.string(record?["price_cents"], kind: .money)),
            .init("category_prices", "Preise je Kategorie", .priceMap, defaultValue: FormValue.string(record?["category_prices"], kind: .priceMap),
                  hint: "Optional, eine Zeile je Kategorie: „Streicher = 15,00“. Sonst gilt der Preis oben."),
            .init("currency_code", "Währung", .reference("currencies"), required: true, defaultValue: record?["currency_code"]?.string ?? "EUR"),
            .init("is_active", "Aktiv", .toggle, defaultValue: record.map { FormValue.string($0["is_active"], kind: .toggle) } ?? "true"),
            .init("sort_order", "Reihenfolge", .integer, defaultValue: record?["sort_order"]?.string ?? "0")
        ]
    }

    static func returnOption(_ record: JSONValue, root: String) -> [WorkflowAction] {
        var actions: [WorkflowAction] = [
            .init("edit-return-option", "Bearbeiten", method: .patch, path: root, fields: returnOptionFields(record), confirmation: "Rückgabeoption speichern?", systemImage: "pencil",
                  base: editableBase(record, dropping: ["delivery_area_ids", "requires_address"]))
        ]
        if record["kind"]?.string != "dropoff" {
            actions.append(.init("set-return-areas", "Liefergebiete festlegen", method: .put, path: "\(root)/delivery-areas", fields: [
                .init("delivery_area_ids", "Liefergebiete", .multiSelect("delivery_areas"), defaultValue: FormValue.string(record["delivery_area_ids"], kind: .multiSelect("")),
                      hint: "Keine Auswahl: überall verfügbar.")
            ], confirmation: "Liefergebiete der Rückgabeoption ersetzen?", systemImage: "map"))
        }
        return actions
    }

    // MARK: Rechtliches

    static func legalVersion(type: String, content: String, title: String) -> WorkflowAction {
        .init("legal-create", title, path: StaffResource.legalDocuments.listPath, fields: [
            .init("document_type", "Dokumentart", .reference("document_types"), required: true, defaultValue: type, hint: "z. B. rental_terms"),
            .init("version", "Version", required: true, hint: "Neue, eindeutige Versionsbezeichnung."),
            .init("content", "Inhalt", .multiline, required: true, defaultValue: content),
            .init("document_hash", "Hash", hint: "Leer lassen: SHA-256 des Inhalts wird verwendet."),
            .init("is_active", "Sofort aktivieren", .toggle, defaultValue: "false", hint: "Je Dokumentart ist nur eine Version aktiv; Kunden müssen sie beim nächsten Checkout akzeptieren."),
            .init("metadata", "Metadaten (JSON)", .json)
        ], confirmation: "Neue Version anlegen?", systemImage: "doc.badge.plus", effect: .openCreated(.legalDocuments))
    }

    static func legalDocument(_ record: JSONValue, root: String) -> [WorkflowAction] {
        let active = record["is_active"]?.bool == true
        var actions: [WorkflowAction] = []
        if !active {
            actions.append(.init("activate-document", "Aktivieren", path: "\(root)/activate", confirmation: "Diese Version aktivieren? Die bisher aktive Version derselben Art wird abgelöst; der Checkout verlangt ab sofort diese Version.", systemImage: "checkmark.seal"))
        } else {
            actions.append(.init("deactivate-document", "Deaktivieren", path: "\(root)/deactivate", confirmation: "Version deaktivieren? Ohne aktive Version ist kein Checkout möglich, der sie verlangt.", destructive: true, systemImage: "pause.circle"))
        }
        actions.append(legalVersion(type: record["document_type"]?.string ?? "", content: record["content"]?.string ?? "", title: "Neue Version"))
        actions.append(.init("legal-edit", "Bearbeiten", method: .patch, path: root, fields: [
            .init("content", "Inhalt", .multiline, required: true, defaultValue: record["content"]?.string ?? ""),
            .init("document_hash", "Hash", hint: "Leer lassen: SHA-256 des neuen Inhalts wird verwendet."),
            .init("metadata", "Metadaten (JSON)", .json, defaultValue: FormValue.string(record["metadata"], kind: .json))
        ], confirmation: active ? "Die aktive Version ändern? Bereits erteilte Zustimmungen verweisen auf den alten Hash." : "Änderungen speichern?", destructive: active, systemImage: "pencil"))
        return actions
    }

    // MARK: Benutzerkonten

    static func user(_ record: JSONValue, root: String) -> [WorkflowAction] {
        let roles = (record["roles"]?.array ?? []).compactMap(\.string)
        var actions: [WorkflowAction] = []
        let missing = staffRoles.filter { !roles.contains($0) }
        if !missing.isEmpty {
            actions.append(.init("add-role", "Rolle vergeben", path: "\(root)/roles", fields: [
                .init("role", "Rolle", .choice(missing), required: true, defaultValue: missing.count == 1 ? missing[0] : "")
            ], confirmation: "Rolle vergeben? Die Person erhält sofort die zugehörigen Rechte.", systemImage: "person.badge.plus"))
        }
        for role in roles where staffRoles.contains(role) {
            actions.append(.init("remove-role-\(role)", "\(StaffLabels.label(role)) entziehen", method: .delete, path: "\(root)/roles",
                                 confirmation: "Rolle „\(StaffLabels.label(role))“ entziehen? API-Schlüssel der Person verlieren diese Rechte sofort.", destructive: true,
                                 systemImage: "person.badge.minus", base: .object(["role": .string(role)])))
        }
        actions.append(.init("reset-2fa", "Zwei-Faktor zurücksetzen", method: .delete, path: "\(root)/2fa",
                             confirmation: "Authenticator und Wiederherstellungscodes entfernen und alle Sitzungen beenden? Die Person muss Zwei-Faktor neu einrichten.", destructive: true, systemImage: "lock.rotation"))
        return actions
    }
}

extension JSONValue {
    func merging(_ values: [String: JSONValue]) -> JSONValue {
        .object((object ?? [:]).merging(values) { _, new in new })
    }
}
