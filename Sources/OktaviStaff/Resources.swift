import Foundation

/// The admin app's managing domains (`src/admin/domains.ts`), limited to those with staff routes.
enum StaffDomain: String, CaseIterable, Identifiable {
    case operations, finance, inventory, customerService, legal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .operations: "Betrieb"
        case .finance: "Finanzen"
        case .inventory: "Inventar & Logistik"
        case .customerService: "Kundenservice"
        case .legal: "Rechtliches"
        }
    }
    var resources: [StaffResource] { StaffResource.allCases.filter { $0.domain == self } }
}

struct FilterSpec: Hashable {
    let param: String
    let title: String
    let options: [String]
    var defaultValue: String = ""
}

enum StaffResource: String, CaseIterable, Identifiable, Hashable {
    case orders, rentals, returns, cancellations
    case deposits, invoices, payments, paymentAttempts, currencies
    case instrumentTypes, instruments, deliveryOptions, deliveryAreas, returnOptions, media
    case customers, users
    case legalDocuments

    var id: String { rawValue }

    var domain: StaffDomain {
        switch self {
        case .orders, .rentals, .returns, .cancellations: .operations
        case .deposits, .invoices, .payments, .paymentAttempts, .currencies: .finance
        case .instrumentTypes, .instruments, .deliveryOptions, .deliveryAreas, .returnOptions, .media: .inventory
        case .customers, .users: .customerService
        case .legalDocuments: .legal
        }
    }

    var title: String {
        switch self {
        case .orders: "Bestellungen"
        case .rentals: "Mieten"
        case .returns: "Rückgaben"
        case .cancellations: "Kündigungen"
        case .deposits: "Kautionen"
        case .invoices: "Rechnungen"
        case .payments: "Zahlungen"
        case .paymentAttempts: "Zahlungsversuche"
        case .currencies: "Währungen"
        case .instrumentTypes: "Instrumententypen"
        case .instruments: "Instrumente"
        case .deliveryOptions: "Lieferoptionen"
        case .deliveryAreas: "Liefergebiete"
        case .returnOptions: "Rückgabeoptionen"
        case .media: "Mediathek"
        case .customers: "Kunden"
        case .users: "Benutzerkonten"
        case .legalDocuments: "Rechtstexte"
        }
    }

    var singular: String {
        switch self {
        case .orders: "Bestellung"
        case .rentals: "Miete"
        case .returns: "Rückgabe"
        case .cancellations: "Kündigung"
        case .deposits: "Kaution"
        case .invoices: "Rechnung"
        case .payments: "Zahlung"
        case .paymentAttempts: "Zahlungsversuch"
        case .currencies: "Währung"
        case .instrumentTypes: "Instrumententyp"
        case .instruments: "Instrument"
        case .deliveryOptions: "Lieferoption"
        case .deliveryAreas: "Liefergebiet"
        case .returnOptions: "Rückgabeoption"
        case .media: "Bild"
        case .customers: "Kunde"
        case .users: "Benutzerkonto"
        case .legalDocuments: "Rechtstext"
        }
    }

    var systemImage: String {
        switch self {
        case .orders: "shippingbox"
        case .rentals: "music.note.house"
        case .returns: "arrow.uturn.backward.circle"
        case .cancellations: "doc.badge.ellipsis"
        case .deposits: "eurosign.circle"
        case .invoices: "doc.text"
        case .payments: "creditcard"
        case .paymentAttempts: "arrow.triangle.2.circlepath.circle"
        case .currencies: "coloncurrencysign.circle"
        case .instrumentTypes: "guitars"
        case .instruments: "barcode"
        case .deliveryOptions: "truck.box"
        case .deliveryAreas: "map"
        case .returnOptions: "arrow.uturn.left.square"
        case .media: "photo.on.rectangle"
        case .customers: "person.2"
        case .users: "person.badge.key"
        case .legalDocuments: "text.book.closed"
        }
    }

    var listPath: String {
        switch self {
        case .cancellations: "api/v1/admin/contract-cancellations"
        case .paymentAttempts: "api/v1/admin/payment-attempts"
        case .currencies: "api/v1/currencies"
        case .instrumentTypes: "api/v1/instrument-types"
        case .instruments: "api/v1/instruments"
        case .deliveryOptions: "api/v1/admin/delivery-options"
        case .deliveryAreas: "api/v1/admin/delivery-areas"
        case .returnOptions: "api/v1/admin/return-options"
        case .media: "api/v1/admin/media-files/instrument-type-images"
        case .users: "auth/users"
        case .legalDocuments: "api/v1/legal-documents"
        default: "api/v1/admin/\(rawValue)"
        }
    }

    /// Path for reading one record; also the base for its write routes.
    func detailPath(id: String) -> String {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        return "\(listPath)/\(escaped)"
    }

    /// Resources without a `GET …/:id` route are read from their list.
    var hasDetailEndpoint: Bool {
        switch self {
        case .deliveryOptions, .deliveryAreas, .returnOptions, .legalDocuments, .media, .paymentAttempts: false
        default: true
        }
    }

    /// Page size for list requests (the auth API allows 200, every other list 100).
    var pageSize: Int { self == .users ? 200 : 100 }

    /// Whether the list route takes `limit`/`offset`.
    var isPaged: Bool {
        switch self {
        case .deliveryOptions, .deliveryAreas, .returnOptions, .legalDocuments: false
        default: true
        }
    }

    /// Primary key names in the order they are tried. Resource-specific so a rental that also
    /// carries `order_id` is never mistaken for its order.
    var primaryKeys: [String] {
        switch self {
        case .orders: ["order_id"]
        case .rentals: ["rental_id"]
        case .returns: ["return_id", "rental_return_id"]
        case .cancellations: ["cancellation_id", "contract_cancellation_id"]
        case .deposits: ["deposit_id"]
        case .invoices: ["invoice_id"]
        case .payments: ["payment_id"]
        case .paymentAttempts: ["payment_attempt_id"]
        case .currencies: ["currency_code", "code"]
        case .instrumentTypes: ["instrument_type_id", "product_type_id"]
        case .instruments: ["instrument_id"]
        case .deliveryOptions: ["delivery_option_id"]
        case .deliveryAreas: ["delivery_area_id"]
        case .returnOptions: ["return_option_id"]
        case .media: ["media_file_id"]
        case .customers, .users: ["user_id"]
        case .legalDocuments: ["legal_document_id", "document_id"]
        }
    }

    func recordID(_ record: JSONValue) -> String {
        for key in ["id"] + primaryKeys { if let value = record[key]?.string, !value.isEmpty { return value } }
        return record.id
    }

    var filters: [FilterSpec] {
        switch self {
        case .orders: []
        case .rentals: [.init(param: "state", title: "Zustand", options: ["active", "cancellation_scheduled", "ended"], defaultValue: "active")]
        case .returns: [.init(param: "status", title: "Status", options: ["requested", "scheduled", "received", "checkup", "completed"])]
        case .cancellations: [.init(param: "status", title: "Status", options: ["open", "resolved"], defaultValue: "open")]
        case .deposits: [.init(param: "status", title: "Status", options: ["pending", "submitted", "succeeded", "failed", "canceled", "returned"])]
        case .invoices: [
            .init(param: "status", title: "Status", options: ["draft", "issued", "partially_paid", "paid", "void", "uncollectible"]),
            .init(param: "type", title: "Art", options: ["rental", "deposit", "delivery", "return"])
        ]
        case .payments: [
            .init(param: "direction", title: "Richtung", options: ["inbound", "outbound"]),
            .init(param: "status", title: "Status", options: ["pending", "submitted", "succeeded", "failed", "canceled", "returned"]),
            .init(param: "provider", title: "Anbieter", options: ["stripe", "sepa_mandate", "manual_bank_transfer", "cash"])
        ]
        case .customers: [.init(param: "status", title: "Konto", options: ["active", "suspended", "deleted"])]
        default: []
        }
    }

    /// Filters the API does not offer but which help at the counter; applied on the device.
    var localFilters: [FilterSpec] {
        switch self {
        case .instruments: [.init(param: "status", title: "Status", options: ["available", "in_use", "maintenance"])]
        case .currencies, .deliveryOptions, .returnOptions: [.init(param: "is_active", title: "Aktiv", options: ["true", "false"])]
        case .legalDocuments: [.init(param: "is_active", title: "Aktiv", options: ["true", "false"])]
        default: []
        }
    }

    var searchPrompt: String {
        switch self {
        case .customers: "Name, E-Mail, Telefon oder ID"
        case .instruments: "Seriennummer, Typ, Lagerort"
        case .invoices: "Nummer, Kunde"
        default: "Suchen"
        }
    }
}

struct RecordPresentation {
    static func title(_ value: JSONValue, resource: StaffResource) -> String {
        let customer = value["customer"]?["name"]?.string ?? value["customer"]?["email"]?.string ?? value["customer_name"]?.string ?? value["customer_email"]?.string
        switch resource {
        case .orders, .rentals, .returns:
            return customer ?? value["email"]?.string ?? "Kunde"
        case .cancellations:
            return customer ?? value["email"]?.string ?? "Kündigung"
        case .deposits:
            return customer ?? ("Kaution " + StaffLabels.money(value["amount_cents"]?.int, currency: value["currency_code"]?.string))
        case .invoices:
            return value["invoice_number"]?.string ?? value["number"]?.string ?? "Rechnung (Entwurf)"
        case .payments:
            return customer ?? StaffLabels.label(value["provider"]?.string)
        case .paymentAttempts:
            return StaffLabels.money(value["amount_cents"]?.int, currency: value["currency_code"]?.string)
        case .currencies:
            return [value["currency_code"]?.string ?? value["code"]?.string, value["name"]?.string].compactMap { $0 }.joined(separator: " · ")
        case .instrumentTypes:
            return value["name"]?.string ?? "Instrumententyp"
        case .instruments:
            return value["serial_number"]?.string ?? value["instrument_type_name"]?.string ?? "Instrument"
        case .deliveryOptions, .deliveryAreas, .returnOptions:
            return value["name"]?.string ?? value["code"]?.string ?? resource.singular
        case .media:
            return value["used_by"]?.array?.compactMap(\.string).joined(separator: ", ").nilIfEmpty ?? "Nicht verwendet"
        case .customers:
            let name = [value["first_name"]?.string, value["last_name"]?.string].compactMap { $0 }.joined(separator: " ")
            return value["name"]?.string ?? name.nilIfEmpty ?? value["email"]?.string ?? "Kunde"
        case .users:
            return value["email"]?.string ?? "Benutzer"
        case .legalDocuments:
            return "\(StaffLabels.label(value["document_type"]?.string)) \(value["version"]?.string ?? "")"
        }
    }

    static func detailLine(_ value: JSONValue, resource: StaffResource) -> String {
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        switch resource {
        case .orders:
            var dates: String?
            if let start = value["rental_start_date"]?.string {
                dates = "\(StaffLabels.relativeDay(start)) – \(StaffLabels.relativeDay(value["rental_end_date"]?.string))"
            } else if let created = value["created_at"]?.string {
                dates = "vom \(StaffLabels.shortDate(created))"
            }
            return join([value["order_number"]?.string, value["first_instrument_name"]?.string, value["delivery_option_name"]?.string, dates])
        case .rentals:
            let end = value["effective_end_date"]?.string.map { "Ende \(StaffLabels.shortDate($0))" }
            return join([value["instrument"]?["instrument_type_name"]?.string ?? value["instrument_name"]?.string, value["instrument"]?["serial_number"]?.string, end])
        case .returns:
            let appointment = value.value(at: "appointment.start_at")?.string.map { StaffLabels.timeRange($0, nil) }
            return join([value["instrument"]?["instrument_type_name"]?.string, value["method"]?.string.map(StaffLabels.label), appointment ?? value["option_name"]?.string])
        case .cancellations:
            return join([value["customer"]?["email"]?.string ?? value["email"]?.string, "eingegangen \(StaffLabels.relativeDay(value["created_at"]?.string))"])
        case .deposits:
            return join([value["order_number"]?.string, value["provider"]?.string.map(StaffLabels.label), value["verification"]?.string.map(StaffLabels.label), StaffLabels.shortDate(value["created_at"]?.string)])
        case .invoices:
            return join([value["type"]?.string.map(StaffLabels.label) ?? value["invoice_type"]?.string.map(StaffLabels.label),
                         value["customer"]?["name"]?.string ?? value["customer_name"]?.string ?? value["customer"]?["email"]?.string,
                         value["due_at"]?.string.map { "fällig \(StaffLabels.shortDate($0))" }])
        case .payments:
            return join([value["direction"]?.string.map(StaffLabels.label), value["provider"]?.string.map(StaffLabels.label),
                         value["invoice_number"]?.string ?? value.value(at: "invoice.invoice_number")?.string,
                         StaffLabels.shortDate(value["paid_at"]?.string ?? value["created_at"]?.string)])
        case .paymentAttempts:
            return join([value["invoice_number"]?.string, value["failure_code"]?.string, StaffLabels.dateTime(value["created_at"]?.string)])
        case .currencies:
            return join([value["symbol"]?.string, value["minor_units"]?.string.map { "\($0) Nachkommastellen" }])
        case .instrumentTypes:
            return join([value["category"]?.string, value["brand"]?.string, value["model"]?.string,
                         value["sizes"]?.array?.compactMap(\.string).joined(separator: ", ")])
        case .instruments:
            return join([value["instrument_type_name"]?.string ?? value.value(at: "instrument_type.name")?.string, value["size"]?.string,
                         value["condition"]?.string.map(StaffLabels.label), value["location"]?.string])
        case .deliveryOptions:
            return join([value["code"]?.string, money(value["price_cents"], value), (value["requires_address"]?.bool ?? value["requires_delivery_address"]?.bool) == true ? "mit Adresse" : nil])
        case .deliveryAreas:
            return join([value["code"]?.string, prefixes(value)])
        case .returnOptions:
            return join([value["kind"]?.string.map(StaffLabels.label), money(value["price_cents"], value), value["code"]?.string])
        case .media:
            return join([value["content_type"]?.string, value["width"]?.int.map { "\($0) × \(value["height"]?.int ?? 0)" },
                         value["size_bytes"]?.int.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }])
        case .customers:
            return join([value["email"]?.string, value["phone"]?.string ?? value["phone_number"]?.string])
        case .users:
            return join([(value["roles"]?.array ?? []).compactMap(\.string).map(StaffLabels.label).joined(separator: ", ").nilIfEmpty ?? "Keine Rolle",
                         value["last_login_at"]?.string.map { "zuletzt \(StaffLabels.relativeDay($0))" }])
        case .legalDocuments:
            return join([value["created_at"]?.string.map { "vom \(StaffLabels.shortDate($0))" }, value["document_hash"]?.string.map { String($0.prefix(12)) + "…" }])
        }
    }

    private static func prefixes(_ value: JSONValue) -> String? {
        let list = (value["postal_code_prefixes"]?.array ?? []).compactMap(\.string)
        return list.isEmpty ? nil : "PLZ " + list.joined(separator: ", ")
    }

    private static func money(_ cents: JSONValue?, _ record: JSONValue) -> String? {
        cents?.int.map { StaffLabels.money($0, currency: record["currency_code"]?.string) }
    }

    static func statusRaw(_ value: JSONValue, resource: StaffResource? = nil) -> String? {
        if let status = value["status"]?.string ?? value["state"]?.string { return status }
        switch resource {
        case .currencies, .deliveryOptions, .returnOptions, .legalDocuments, .instrumentTypes:
            return value["is_active"]?.bool.map { $0 ? "active" : "inactive" }
        default: return nil
        }
    }

    static func amount(_ value: JSONValue, resource: StaffResource) -> String? {
        let cents: Int?
        switch resource {
        case .orders: cents = value["total_cents"]?.int
        case .rentals: cents = value["rental_period_price_cents"]?.int ?? value["monthly_price_cents"]?.int
        case .deposits, .payments, .paymentAttempts: cents = value["amount_cents"]?.int
        case .invoices: cents = value["total_cents"]?.int ?? value["amount_cents"]?.int
        case .instrumentTypes: cents = value["default_rental_price_cents"]?.int ?? value["rental_price_cents"]?.int
        case .instruments: cents = value["custom_rental_price_cents"]?.int
        default: return nil
        }
        return cents.map { StaffLabels.money($0, currency: value["currency_code"]?.string) }
    }

    static func term(_ value: JSONValue) -> String {
        value["rental_term"]?.string ?? value["term"]?.string ?? ""
    }

    static func displayName(_ key: String) -> String {
        let names = [
            "status": "Status", "state": "Zustand", "email": "E-Mail", "name": "Name",
            "created_at": "Erstellt", "updated_at": "Geändert", "rental_start_date": "Mietbeginn (Tag)",
            "rental_end_date": "Mietende (Tag)", "pickup_time": "Abholzeit", "return_time": "Rückgabezeit",
            "effective_end_date": "Wirksames Ende", "tracking_number": "Sendungsnummer",
            "note": "Notiz", "notes": "Notizen", "method": "Art", "verification": "Prüfung",
            "paid_at": "Bezahlt am", "due_at": "Fällig am", "phone": "Telefon", "phone_number": "Telefon",
            "order_id": "Bestellung", "rental_id": "Miete", "return_id": "Rückgabe", "deposit_id": "Kaution",
            "user_id": "Kunde", "source_order_id": "Quellbestellung", "customer": "Kunde",
            "billing_address": "Rechnungsadresse", "deposit": "Kaution", "handover": "Übergabe",
            "early_start": "Früher Start", "items": "Positionen", "terms": "AGB", "payment_setup": "Zahlung",
            "rentals": "Mieten", "orders": "Bestellungen", "delivery_option_name": "Lieferart", "total_cents": "Gesamt",
            "subtotal_cents": "Zwischensumme", "deposit_cents": "Kaution", "instrument_type_name": "Instrumententyp",
            "serial_number": "Seriennummer", "anchor_date": "Ankerdatum", "booked_end_date": "Gebuchtes Ende",
            "minimum_term_end_date": "Mindestlaufzeit bis", "current_period": "Aktuelle Periode",
            "fulfillment_status": "Übergabestatus", "booking_status": "Buchungsstatus",
            "instrument_status": "Instrumentstatus", "free_instruments": "Freie Instrumente",
            "unallocated_units": "Nicht zugewiesen", "quantity": "Anzahl", "unit_price_cents": "Einzelpreis",
            "line_total_cents": "Zeilensumme", "amount_cents": "Betrag", "held_cents": "Eingehalten",
            "retained_cents": "Einbehalten", "refunded_cents": "Erstattet", "settleable": "Abrechenbar",
            "settled": "Abgerechnet", "transfer_reference": "Überweisungsreferenz", "option_name": "Option",
            "fee_cents": "Gebühr", "rent_payment": "Mietzahlung", "deposit_payment": "Kautionszahlung",
            "deposit_hold_status": "Kautionsstatus", "earliest_handover_at": "Früheste Übergabe",
            "instrument": "Instrument", "instruments": "Instrumente", "invoices": "Rechnungen",
            "provider": "Anbieter", "currency_code": "Währung", "in_person": "Persönlich",
            "source": "Quelle", "requested_at": "Angefragt am", "handed_over_at": "Übergeben am",
            "proposals": "Vorschläge", "allocations": "Zuweisungen", "payment_method_type": "Zahlungsmethode",
            "order_count": "Bestellungen", "running_rental_count": "Laufende Mieten",
            "open_invoice_count": "Offene Rechnungen", "last_login_at": "Letzte Anmeldung",
            "street": "Straße", "postal_code": "PLZ", "city": "Stadt", "country": "Land",
            "start": "Beginn", "end": "Ende", "number": "Nummer", "kind": "Art",
            "requires_address": "Adresse nötig", "requires_delivery_address": "Lieferadresse nötig",
            "customer_booking_url": "Kundenbuchung", "rental_period_price_cents": "Mietpreis",
            "invoice_number": "Rechnungsnummer", "type": "Art", "invoice_type": "Art", "issued_at": "Gestellt am",
            "amount_due_cents": "Offen", "paid_cents": "Bezahlt", "lines": "Positionen", "payments": "Zahlungen",
            "refunds": "Erstattungen", "direction": "Richtung", "external_reference": "Referenz",
            "refundable_cents": "Erstattbar", "related_payment_id": "Ursprüngliche Zahlung",
            "symbol": "Symbol", "minor_units": "Nachkommastellen", "is_active": "Aktiv", "code": "Code",
            "brand": "Marke", "model": "Modell", "category": "Kategorie", "sizes": "Größen", "size": "Größe",
            "description": "Beschreibung", "photo_urls": "Fotos", "default_rental_price_cents": "Mietpreis",
            "default_purchase_price_cents": "Kaufpreis", "condition": "Zustand", "location": "Lagerort",
            "custom_rental_price_cents": "Eigener Mietpreis", "custom_purchase_price_cents": "Eigener Kaufpreis",
            "acquisition_cost_cents": "Anschaffungskosten", "acquisition_currency_code": "Anschaffungswährung",
            "price_cents": "Preis", "sort_order": "Reihenfolge", "postal_code_prefixes": "PLZ-Präfixe",
            "category_prices": "Preise je Kategorie", "delivery_area_ids": "Liefergebiete", "return_option_ids": "Rückgabeoptionen",
            "document_type": "Dokumentart", "version": "Version", "content": "Inhalt", "document_hash": "Hash",
            "metadata": "Metadaten", "roles": "Rollen", "content_type": "Dateityp", "size_bytes": "Größe",
            "width": "Breite", "height": "Höhe", "used_by": "Verwendet von", "url": "Adresse",
            "addresses": "Adressen", "birthdate": "Geburtsdatum", "first_name": "Vorname", "last_name": "Nachname",
            "two_factor_enabled": "Zwei-Faktor aktiv", "email_verified": "E-Mail bestätigt"
        ]
        return names[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
