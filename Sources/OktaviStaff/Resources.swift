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
        case .orders: value["order_number"]?.string ?? value["number"]?.string ?? "Bestellung"
        case .rentals: value["order_number"]?.string ?? value["instrument"]?["name"]?.string ?? "Miete"
        case .returns: value["order_number"]?.string ?? "Rückgabe"
        case .cancellations: value["email"]?.string ?? "Kündigung"
        case .deposits: value["order_number"]?.string ?? "Kaution"
        case .customers: value["name"]?.string ?? [value["first_name"]?.string, value["last_name"]?.string].compactMap { $0 }.joined(separator: " ")
        }
    }

    static func subtitle(_ value: JSONValue) -> String {
        value["status"]?.string ?? value["state"]?.string ?? value["email"]?.string ?? ""
    }

    static func displayName(_ key: String) -> String {
        let names = [
            "status": "Status", "state": "Zustand", "email": "E-Mail", "order_number": "Bestellnummer",
            "created_at": "Erstellt", "updated_at": "Geändert", "rental_start_date": "Mietbeginn",
            "rental_end_date": "Mietende", "effective_end_date": "Wirksames Ende", "tracking_number": "Sendungsnummer",
            "note": "Notiz", "method": "Methode", "verification": "Prüfung", "paid_at": "Bezahlt am"
        ]
        return names[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
