import Foundation

enum StaffResource: String, CaseIterable, Identifiable, Hashable {
    case orders, rentals, returns, cancellations, deposits, customers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orders: "Bestellungen"
        case .rentals: "Mieten"
        case .returns: "Rückgaben"
        case .cancellations: "Kündigungen"
        case .deposits: "Kautionen"
        case .customers: "Kunden"
        }
    }
    var systemImage: String {
        switch self {
        case .orders: "shippingbox"
        case .rentals: "music.note.house"
        case .returns: "arrow.uturn.backward.circle"
        case .cancellations: "doc.badge.ellipsis"
        case .deposits: "eurosign.circle"
        case .customers: "person.2"
        }
    }
    var listPath: String {
        switch self {
        case .cancellations: "api/v1/admin/contract-cancellations"
        default: "api/v1/admin/\(rawValue)"
        }
    }
    func detailPath(id: String) -> String { "\(listPath)/\(id)" }
}

struct RecordPresentation {
    static func title(_ value: JSONValue, resource: StaffResource) -> String {
        switch resource {
        case .orders, .rentals, .returns:
            value["customer"]?["name"]?.string ?? value["customer"]?["email"]?.string ?? value["email"]?.string ?? "Kunde"
        case .cancellations:
            value["customer"]?["name"]?.string ?? value["email"]?.string ?? "Kündigung"
        case .deposits:
            "Kaution " + StaffLabels.money(value["amount_cents"]?.int, currency: value["currency_code"]?.string)
        case .customers:
            value["name"]?.string ?? value["email"]?.string ?? "Kunde"
        }
    }

    static func detailLine(_ value: JSONValue, resource: StaffResource) -> String {
        switch resource {
        case .orders:
            var parts: [String] = []
            parts.append(term(value) == "short_term" ? "Tagesmiete" : "Monatsmiete")
            if let option = value["delivery_option_name"]?.string { parts.append(option) }
            if let start = value["rental_start_date"]?.string {
                parts.append("\(StaffLabels.shortDate(start)) – \(StaffLabels.shortDate(value["rental_end_date"]?.string))")
            } else if let created = value["created_at"]?.string {
                parts.append(StaffLabels.shortDate(created))
            }
            return parts.joined(separator: " · ")
        case .rentals:
            return [value["instrument"]?["instrument_type_name"]?.string, value["instrument"]?["serial_number"]?.string]
                .compactMap { $0 }.joined(separator: " · ")
        case .returns:
            return [value["instrument"]?["instrument_type_name"]?.string, value["instrument"]?["serial_number"]?.string, value["option_name"]?.string]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .cancellations:
            return StaffLabels.shortDate(value["created_at"]?.string)
        case .deposits:
            return [value["provider"]?.string.map(StaffLabels.label), StaffLabels.shortDate(value["created_at"]?.string)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .customers:
            return value["email"]?.string ?? ""
        }
    }

    static func statusRaw(_ value: JSONValue) -> String? {
        value["status"]?.string ?? value["state"]?.string
    }

    static func amount(_ value: JSONValue, resource: StaffResource) -> String? {
        let cents: Int?
        switch resource {
        case .orders: cents = value["total_cents"]?.int
        case .rentals: cents = value["rental_period_price_cents"]?.int
        case .deposits: cents = value["amount_cents"]?.int
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
            "paid_at": "Bezahlt am", "due_at": "Fällig am", "phone": "Telefon",
            "order_id": "Bestellung", "rental_id": "Miete", "return_id": "Rückgabe", "deposit_id": "Kaution",
            "user_id": "Kunde", "source_order_id": "Quellbestellung", "customer": "Kunde",
            "billing_address": "Rechnungsadresse", "deposit": "Kaution", "handover": "Übergabe",
            "early_start": "Früher Start", "items": "Positionen", "terms": "AGB", "payment_setup": "Zahlung",
            "rentals": "Mieten", "delivery_option_name": "Lieferart", "total_cents": "Gesamt",
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
            "customer_booking_url": "Kundenbuchung", "rental_period_price_cents": "Mietpreis"
        ]
        return names[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
