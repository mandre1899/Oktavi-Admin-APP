import CryptoKit
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
        "manual_sepa_transfer": "SEPA-Überweisung",
        "long_term": "Monatsmiete",
        "short_term": "Tagesmiete",
        "stripe": "Stripe",
        "bank_transfer": "Überweisung",
        "no_show": "Nicht abgeholt",
        "inactive": "Inaktiv",
        "issued": "Gestellt",
        "partially_paid": "Teilweise bezahlt",
        "paid": "Bezahlt",
        "void": "Storniert",
        "uncollectible": "Uneinbringlich",
        "refunded": "Erstattet",
        "partially_refunded": "Teilweise erstattet",
        "inbound": "Eingang",
        "outbound": "Erstattung",
        "sepa_mandate": "SEPA-Lastschrift",
        "sepa_debit": "SEPA-Lastschrift",
        "internal_sepa": "SEPA (intern)",
        "rental": "Miete",
        "deposit": "Kaution",
        "delivery": "Lieferung",
        "return": "Rückgabe",
        "new": "Neu",
        "good": "Gut",
        "used": "Gebraucht",
        "needs_repair": "Reparaturbedürftig",
        "ok": "In Ordnung",
        "wear": "Gebrauchsspuren",
        "damaged": "Beschädigt",
        "missing": "Fehlt",
        "not_applicable": "Entfällt",
        "admin": "Admin",
        "staff": "Team",
        "support": "Support",
        "rental_terms": "Mietbedingungen",
        "off_session_payment_authorization": "Zahlungsermächtigung",
        "privacy_policy": "Datenschutzerklärung",
        "terms_of_service": "AGB",
        "imprint": "Impressum",
        "withdrawal_policy": "Widerrufsbelehrung",
        "requires_payment_method": "Zahlungsmittel fehlt",
        "requires_confirmation": "Bestätigung nötig",
        "requires_action": "Aktion nötig",
        "processing": "In Bearbeitung",
        "first_invoice": "Mit erster Rechnung",
        "debit_card": "Debitkarte",
        "credit_card": "Kreditkarte",
        "in_progress": "In Bearbeitung",
        "reserved": "Reserviert",
        "retired": "Ausgemustert"
    ]

    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "–" }
        return labels[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func badgeColor(_ raw: String) -> Color {
        switch raw {
        case "rejected", "cancelled", "failed", "declined", "deleted", "suspended", "uncollectible", "needs_repair", "damaged", "missing": .red
        case "approved", "succeeded", "active", "completed", "accepted", "resolved", "available", "paid", "new", "good", "ok": .green
        case "submitted", "requested", "pending", "open", "scheduled", "issued", "processing": .blue
        case "ready_for_fulfillment", "checkup", "received", "in_use": .purple
        case "cancellation_scheduled", "fulfilled", "partially_paid", "maintenance", "wear", "used", "requires_action", "requires_payment_method": .orange
        default: .gray
        }
    }

    /// Cents as the text a money field edits ("12,50"). Formatting only.
    static func moneyInput(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let value = abs(cents)
        return "\(sign)\(value / 100),\(String(format: "%02d", value % 100))"
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func money(_ cents: Int?, currency: String? = "EUR") -> String {
        (Double(cents ?? 0) / 100).formatted(.currency(code: currency ?? "EUR").locale(Locale(identifier: "de_DE")))
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// "Heute", "Morgen", "Gestern" or a weekday + date for Berlin day strings / timestamps.
    static func relativeDay(_ iso: String?, day: DayContext = .now) -> String {
        guard let iso else { return "" }
        let key = iso.count == 10 ? iso : parseTimestamp(iso).map { BerlinDay.today($0) } ?? String(iso.prefix(10))
        if key == day.today { return "Heute" }
        if key == day.tomorrow { return "Morgen" }
        let formatter = BerlinDay.formatter
        if let today = formatter.date(from: day.today), let yesterday = formatter.calendar.date(byAdding: .day, value: -1, to: today), formatter.string(from: yesterday) == key { return "Gestern" }
        guard let date = formatter.date(from: key) else { return shortDate(iso) }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month().locale(Locale(identifier: "de_DE")))
    }

    static func time(_ iso: String?) -> String {
        guard let iso, let date = parseTimestamp(iso) else { return "" }
        var style = Date.FormatStyle.dateTime.hour().minute().locale(Locale(identifier: "de_DE"))
        style.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return date.formatted(style)
    }

    static func timeRange(_ start: String?, _ end: String?) -> String {
        guard let start else { return "" }
        let from = "\(relativeDay(start)) \(time(start))"
        let until = time(end)
        return until.isEmpty ? from : "\(from) – \(until)"
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
        guard let date = parseTimestamp(iso) else { return String(iso.prefix(16)) }
        var style = Date.FormatStyle.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "de_DE"))
        style.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return date.formatted(style)
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

struct TermBadge: View {
    let daily: Bool
    var body: some View {
        Label(daily ? "Tag" : "Monat", systemImage: daily ? "sun.max" : "calendar")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(daily ? Color.teal : Color.indigo)
            .background((daily ? Color.teal : Color.indigo).opacity(0.14), in: Capsule())
            .help(daily ? "Tagesmiete" : "Monatsmiete")
    }
}

extension AlertTone {
    var color: Color { self == .danger ? .red : .orange }
    var systemImage: String { self == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill" }
}

enum StaffError {
    /// German, user-facing text for any error a request can throw.
    static func message(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Offline – keine Daten. Bitte Verbindung prüfen."
            case .timedOut: return "Der Server hat nicht rechtzeitig geantwortet."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Der Server ist nicht erreichbar."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed: return "Die sichere Verbindung zum Server ist fehlgeschlagen."
            case .cancelled: return "Die Anfrage wurde abgebrochen."
            default: return "Netzwerkfehler (\(urlError.code.rawValue))."
            }
        }
        if error is DecodingError { return "Die Antwort des Servers konnte nicht gelesen werden." }
        return error.localizedDescription
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
