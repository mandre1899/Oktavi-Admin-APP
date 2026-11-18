import SwiftUI

enum StaffLabels {
    private static let labels: [String: String] = [
        "draft": "Entwurf",
        "submitted": "Eingegangen",
        "approved": "Genehmigt",
        "ready_for_fulfillment": "Übergabe bereit",
        "fulfilled": "Übergeben",
        "closed": "Abgeschlossen",
        "rejected": "Abgelehnt",
        "cancelled": "Storniert",
        "placed": "Bestellt",
        "active": "Aktiv",
        "cancellation_scheduled": "Kündigung geplant",
        "ended": "Beendet",
        "requested": "Angefragt",
        "scheduled": "Termin gesetzt",
        "received": "Eingegangen",
        "checkup": "In Prüfung",
        "completed": "Abgeschlossen",
        "pending": "Ausstehend",
        "succeeded": "Erfolgreich",
        "failed": "Fehlgeschlagen",
        "canceled": "Storniert",
        "returned": "Zurückgezahlt",
        "open": "Offen",
        "resolved": "Erledigt",
        "suspended": "Gesperrt",
        "deleted": "Gelöscht",
        "manual": "Manuell",
        "card": "Karte",
        "cash": "Bar",
        "parcel": "Paket",
        "dropoff": "Abgabe im Laden",
        "pickup": "Abholung",
        "size_change": "Größenwechsel",
        "defect_replacement": "Defekt-Ersatz",
        "available": "Verfügbar",
        "maintenance": "Wartung",
        "in_use": "In Benutzung",
        "accepted": "Angenommen",
        "declined": "Abgelehnt",
        "manual_bank_transfer": "Überweisung",
        "manual_sepa_transfer": "SEPA-Überweisung"
    ]

    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "–" }
        return labels[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func badgeColor(_ raw: String) -> Color {
        switch raw {
        case "rejected", "cancelled", "failed", "declined", "deleted", "suspended": .red
        case "approved", "succeeded", "active", "completed", "accepted", "resolved", "available": .green
        case "submitted", "requested", "pending", "open", "scheduled": .blue
        case "ready_for_fulfillment", "checkup", "received": .purple
        case "cancellation_scheduled", "fulfilled": .orange
        default: .gray
        }
    }

    static func money(_ cents: Int?, currency: String? = "EUR") -> String {
        (Double(cents ?? 0) / 100).formatted(.currency(code: currency ?? "EUR").locale(Locale(identifier: "de_DE")))
    }

    static func shortDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: iso) ?? formatter.date(from: iso.prefix(10) + "T12:00:00Z")
        guard let date else { return String(iso.prefix(10)) }
        return date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "de_DE")))
    }

    static func dateTime(_ iso: String?) -> String {
        guard let iso else { return "" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return String(iso.prefix(16)) }
        return date.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "de_DE")))
    }
}

struct StatusBadge: View {
    let raw: String

    var body: some View {
        Text(StaffLabels.label(raw))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(StaffLabels.badgeColor(raw).opacity(0.18), in: Capsule())
            .foregroundStyle(StaffLabels.badgeColor(raw))
    }
}

struct ActionChoice: Identifiable, Hashable {
    let id: String
    let label: String
}
