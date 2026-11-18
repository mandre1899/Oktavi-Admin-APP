import SwiftUI

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Two-column facts. Rows with an empty value are skipped so cards stay short.
struct FactGrid: View {
    let rows: [(String, String?)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 7) {
            ForEach(rows.filter { !($0.1 ?? "").isEmpty }, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    Text(row.1 ?? "").textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}

// MARK: - Lifecycle

struct LifecycleBar: View {
    let lifecycle: Lifecycle

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(lifecycle.stages.enumerated()), id: \.offset) { index, stage in
                let done = index < lifecycle.current || (index == lifecycle.current && index == lifecycle.stages.count - 1 && lifecycle.exit == nil)
                let current = index == lifecycle.current && lifecycle.exit == nil
                let exited = index == lifecycle.current && lifecycle.exit != nil
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Rectangle().fill(index == 0 ? .clear : (index <= lifecycle.current ? Color.accentColor : Color.secondary.opacity(0.25))).frame(height: 2)
                        ZStack {
                            Circle().fill(exited ? Color.red : done ? Color.accentColor : current ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15))
                                .frame(width: 22, height: 22)
                            if exited { Image(systemName: "xmark").font(.caption2.bold()).foregroundStyle(.white) }
                            else if done { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                            else if current { Circle().fill(Color.accentColor).frame(width: 9, height: 9) }
                        }
                        Rectangle().fill(index == lifecycle.stages.count - 1 ? .clear : (index < lifecycle.current ? Color.accentColor : Color.secondary.opacity(0.25))).frame(height: 2)
                    }
                    Text(exited ? StaffLabels.label(lifecycle.exit) : stage)
                        .font(.caption.weight(current || exited ? .semibold : .regular))
                        .foregroundStyle(exited ? Color.red : current ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(lifecycle.exit.map(StaffLabels.label) ?? lifecycle.stages[min(lifecycle.current, lifecycle.stages.count - 1)])")
    }
}

// MARK: - Next step

struct NextStepCard: View {
    let actions: [WorkflowAction]
    let start: (WorkflowAction, [String: String]) -> Void

    var body: some View {
        let primary = WorkflowActions.primary(in: actions)
        let secondary = actions.filter { $0.id != primary?.id && !$0.destructive }
        let destructive = actions.filter(\.destructive)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let primary {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: primary.systemImage).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nächster Schritt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(primary.title).font(.title3.weight(.semibold))
                            if let explanation = ActionCopy.explanation(primary.id) {
                                Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Button { start(primary, [:]) } label: { Text(primary.title).padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else {
                    Text("Kein Standard-Schritt offen. Weitere Aktionen:").font(.callout).foregroundStyle(.secondary)
                }
                if !secondary.isEmpty || !destructive.isEmpty {
                    if primary != nil { Divider() }
                    HStack(spacing: 8) {
                        ForEach(secondary) { action in
                            Button { start(action, [:]) } label: { Label(action.title, systemImage: action.systemImage) }
                        }
                        Spacer()
                        if !destructive.isEmpty {
                            Menu {
                                ForEach(destructive) { action in
                                    Button(role: .destructive) { start(action, [:]) } label: { Label(action.title, systemImage: action.systemImage) }
                                }
                            } label: { Label("Weitere Aktionen", systemImage: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(Color.accentColor.opacity(primary == nil ? 0.03 : 0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25)))
        }
    }
}

enum ActionCopy {
    static func explanation(_ id: String) -> String? {
        [
            "approve": "Bestellung prüfen und freigeben. Der Kunde wird benachrichtigt.",
            "assign": "Jeder Position ein konkretes Instrument aus dem Bestand zuweisen.",
            "proposal": "Dem Kunden einen Übergabetermin vorschlagen. Er bestätigt oder lehnt im Shop ab.",
            "handover": "Instrument ist beim Kunden – Übergabe verbindlich erfassen.",
            "return": "Instrument ist zurück. Eine mögliche Verspätungsgebühr berechnet der Server.",
            "settle-deposit": "Kaution freigeben oder einen begründeten Betrag einbehalten.",
            "appointment": "Termin für Abholung oder Abgabe im Laden festhalten.",
            "label": "Paketlabel wurde an den Kunden gesendet.",
            "receive": "Das Instrument ist im Laden angekommen.",
            "inspection": "Zustand des Instruments prüfen.",
            "complete": "Prüfung abgeschlossen – Instrument wieder verfügbar machen oder in Wartung geben.",
            "confirm": "Überweisung ist auf dem Konto eingegangen.",
            "schedule": "Kündigung auf die passende Miete eintragen. Das Enddatum berechnet der Server.",
            "start-return": "Rückgabe für diese Miete anlegen.",
            "withdraw-cancellation": "Die geplante Kündigung zurücknehmen – die Miete läuft weiter.",
            "issue-invoice": "Entwurf verbindlich stellen. Ohne Datum ist die Rechnung in 14 Tagen fällig.",
            "record-payment": "Bar- oder Überweisungseingang buchen. Der Status folgt aus dem offenen Betrag.",
            "refund": "Erstattet höchstens den erstattbaren Betrag. Stripe-Zahlungen laufen über Stripe.",
            "add-instruments": "Physische Instrumente dieses Typs im Bestand anlegen.",
            "new-snapshot": "Zustand je Prüfpunkt mit Fotos festhalten.",
            "activate-document": "Diese Version im Checkout verlangen.",
            "set-maintenance": "Instrument sperren, bis es repariert ist.",
            "set-available": "Instrument wieder für Zuweisungen freigeben.",
            "set-return-options": "Welche Rückgabeoptionen Kunden mit dieser Lieferoption wählen dürfen.",
            "set-delivery-areas": "Auf welche Postleitzahlen die Option beschränkt ist.",
            "set-return-areas": "Auf welche Postleitzahlen die Option beschränkt ist.",
            "add-role": "Rechte für Admin-App, Staff-App und API-Schlüssel vergeben.",
            "reset-2fa": "Für verlorene Authenticator: die Person richtet Zwei-Faktor neu ein."
        ][id]
    }
}

// MARK: - Warnings

struct RecordWarnings: View {
    @Environment(StaffNavigator.self) private var navigator
    let record: JSONValue
    let resource: StaffResource

    private struct Warning: Hashable {
        let tone: AlertTone
        let text: String
        var link: RelatedLink? = nil
    }

    var body: some View {
        let warnings = items
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(warnings, id: \.self) { warning in
                    if let link = warning.link {
                        InlineBanner(tone: warning.tone, text: warning.text, retry: { navigator.openRecord(link.resource, id: link.id) }, retryTitle: link.title)
                    } else {
                        InlineBanner(tone: warning.tone, text: warning.text)
                    }
                }
            }
        }
    }

    private var items: [Warning] {
        var result: [Warning] = []
        let status = record["status"]?.string ?? ""
        if resource == .orders {
            if ["submitted", "approved", "ready_for_fulfillment"].contains(status),
               let missing = record["items"]?.array?.first(where: { ($0["allocations"]?.array?.isEmpty ?? true) && $0["free_instruments"]?.int == 0 }) {
                let name = missing["instrument_type_name"]?.string ?? "Eine Position"
                let link = missing["instrument_type_id"]?.string.map { RelatedLink(title: "Bestand anlegen", resource: .instrumentTypes, id: $0) }
                result.append(Warning(tone: .warning, text: "\(name)\(missing["size"]?.string.map { " (\($0))" } ?? ""): kein freies Instrument im Bestand.", link: link))
            }
            if let since = record["overdue_since"]?.string {
                result.append(Warning(tone: .danger, text: "Überfällig seit \(StaffLabels.relativeDay(since)) – Instrument wurde nicht zurückgegeben."))
            }
            if DashboardAlerts.isDaily(record), status == "approved", record["rent_hold_lost"]?.bool == true {
                result.append(Warning(tone: .warning, text: "Die Kartenreservierung für die Miete ist verfallen. Miete bei Abholung bar kassieren."))
            }
            if record["handover_proposal_status"]?.string == "declined" || record.value(at: "handover.proposals")?.array?.first?["status"]?.string == "declined" {
                let note = record.value(at: "handover.proposals")?.array?.first?["decline_note"]?.string
                result.append(Warning(tone: .danger, text: "Der Kunde hat den Übergabetermin abgelehnt\(note.map { ": „\($0)“" } ?? "."). Bitte einen neuen Termin vorschlagen."))
            }
        }
        if resource == .rentals, record["state"]?.string != "ended", record["return_id"].isPresent {
            result.append(Warning(tone: .warning, text: "Für diese Miete läuft bereits eine Rückgabe.", link: record["return_id"]?.string.map { RelatedLink(title: "Rückgabe öffnen", resource: .returns, id: $0) }))
        }
        if resource == .returns, record["status"]?.string == "checkup", let instrumentID = record.value(at: "instrument.instrument_id")?.string ?? record["instrument_id"]?.string {
            result.append(Warning(tone: .warning, text: "Instrument in Prüfung: Zustandsbericht am Instrument erfassen, dann die Rückgabe abschließen.", link: RelatedLink(title: "Zustand erfassen", resource: .instruments, id: instrumentID)))
        }
        if resource == .invoices, (record["type"]?.string ?? record["invoice_type"]?.string) == "deposit", ["issued", "partially_paid"].contains(status) {
            let link = (record["deposit_id"]?.string).map { RelatedLink(title: "Kaution öffnen", resource: .deposits, id: $0) }
                ?? record["deposit_order_id"]?.string.map { RelatedLink(title: "Bestellung öffnen", resource: .orders, id: $0) }
            result.append(Warning(tone: .warning, text: "Kautionsrechnungen werden über „Eingang bestätigen“ an der Kaution bezahlt, nicht hier.", link: link))
        }
        return result
    }
}

// MARK: - Orders

struct HandoverProgressCard: View {
    let record: JSONValue

    var body: some View {
        let status = record["status"]?.string ?? ""
        if ["approved", "ready_for_fulfillment", "fulfilled", "closed"].contains(status) {
            let units = (record["items"]?.array ?? []).reduce(0) { $0 + ($1["quantity"]?.int ?? 1) }
            let open = WorkflowActions.unallocatedUnits(record)
            let handover = record["handover"]
            let newest = handover?["proposals"]?.array?.first
            let handedOver = WorkflowActions.handedOverAt(record)
            Card(title: "Übergabe", systemImage: "hand.raised") {
                VStack(alignment: .leading, spacing: 10) {
                    step(done: open == 0 && units > 0, title: "Instrumente zuweisen", detail: units == 0 ? nil : open == 0 ? "Alle \(units) zugewiesen" : "\(units - open) von \(units) zugewiesen")
                    step(done: slotDone(handover, newest), warning: newest?["status"]?.string == "declined", title: "Termin vereinbaren", detail: slotDetail(handover, newest))
                    step(done: handedOver != nil, title: "Übergeben", detail: handedOver.map { "am \(StaffLabels.dateTime($0))" } ?? (status == "ready_for_fulfillment" ? "Bereit zur Übergabe" : nil))
                    if let tracking = record["tracking_number"]?.string {
                        Label("Sendungsnummer \(tracking)", systemImage: "shippingbox").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let early = record["early_start"], early.isPresentObject {
                        Label("Früher Start gewünscht: \(StaffLabels.dateTime(early["requested_at"]?.string))\(early["note"]?.string.map { " – \($0)" } ?? "")", systemImage: "calendar.badge.clock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func slotDone(_ handover: JSONValue?, _ newest: JSONValue?) -> Bool {
        ["scheduled", "completed"].contains(handover?["status"]?.string ?? "") || newest?["status"]?.string == "accepted"
    }

    private func slotDetail(_ handover: JSONValue?, _ newest: JSONValue?) -> String? {
        guard let newest else { return "Noch kein Vorschlag" }
        let range = StaffLabels.timeRange(newest["start_at"]?.string, newest["end_at"]?.string)
        switch newest["status"]?.string {
        case "pending": return "\(range) · wartet auf Kunde"
        case "accepted": return "\(range) · bestätigt"
        case "declined": return "\(range) · abgelehnt\(newest["decline_note"]?.string.map { ": „\($0)“" } ?? "")"
        default: return range
        }
    }

    private func step(done: Bool, warning: Bool = false, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: warning ? "exclamationmark.circle.fill" : done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(warning ? Color.red : done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if let detail { Text(detail).font(.callout).foregroundStyle(warning ? Color.red : .secondary) }
            }
        }
    }
}

struct DailyBookingCard: View {
    let record: JSONValue
    let reference: [String: JSONValue]

    var body: some View {
        Card(title: "Tagesmiete", systemImage: "sun.max") {
            VStack(alignment: .leading, spacing: 12) {
                FactGrid(rows: [
                    ("Abholung", "\(StaffLabels.relativeDay(record["rental_start_date"]?.string)) \(record["pickup_time"]?.string ?? "")"),
                    ("Rückgabe", "\(StaffLabels.relativeDay(record["rental_end_date"]?.string)) \(record["return_time"]?.string ?? "")"),
                    ("Abgeholt", WorkflowActions.handedOverAt(record).map(StaffLabels.dateTime)),
                    ("Zurückgegeben", record["returned_at"]?.string.map(StaffLabels.dateTime)),
                    ("Buchung", record["booking_status"]?.string.map(StaffLabels.label)),
                    ("Miete", record.value(at: "rent_payment.status")?.string.map(StaffLabels.label))
                ])
                if let preview = reference["return_preview"] {
                    Divider()
                    Text("Rückgabe jetzt").font(.subheadline.weight(.semibold))
                    FactGrid(rows: [
                        ("Letzter Miettag", StaffLabels.shortDate(preview["last_day"]?.string)),
                        ("Verspätete Tage", "\(preview["late_days"]?.int ?? 0)"),
                        ("Verspätungsgebühr", StaffLabels.money(preview["late_fee_cents"]?.int, currency: preview["currency_code"]?.string)),
                        ("Karte hinterlegt", preview["card_on_file"]?.bool == true ? "Ja" : "Nein"),
                        ("Nächste Buchung", preview["next_booking_at_risk"]?.bool == true ? "⚠︎ gefährdet" : nil)
                    ])
                }
                if let preview = reference["no_show_preview"], preview["can_record"]?.bool == true {
                    Divider()
                    Label("Nichtabholung möglich – Gebühr \(StaffLabels.money(preview["fee_cents"]?.int, currency: preview["currency_code"]?.string)) (\(StaffLabels.label(preview["collection"]?.string)))", systemImage: "person.fill.xmark")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct OrderItemsSection: View {
    @Environment(StaffNavigator.self) private var navigator
    let record: JSONValue
    let actions: [WorkflowAction]
    let start: (WorkflowAction, [String: String]) -> Void

    var body: some View {
        let items = record["items"]?.array ?? []
        let assign = actions.first { $0.id == "assign" }
        if !items.isEmpty {
            Card(title: "Positionen", systemImage: "music.note.list") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        itemRow(item, assign: assign)
                    }
                }
            }
        }
    }

    @ViewBuilder private func itemRow(_ item: JSONValue, assign: WorkflowAction?) -> some View {
        let allocations = item["allocations"]?.array ?? []
        let open = max((item["quantity"]?.int ?? 1) - allocations.count, 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["instrument_type_name"]?.string ?? "Position").font(.body.weight(.semibold))
                if (item["quantity"]?.int ?? 1) > 1 { Text("× \(item["quantity"]?.int ?? 1)").foregroundStyle(.secondary) }
                Spacer()
                Text(StaffLabels.money(item["line_total_cents"]?.int, currency: record["currency_code"]?.string)).monospacedDigit()
            }
            ForEach(allocations) { allocation in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    if let instrumentID = allocation["instrument_id"]?.string {
                        RecordLink(title: allocation["serial_number"]?.string ?? "Instrument", resource: .instruments, id: instrumentID, systemImage: "barcode")
                    } else {
                        Text(allocation["serial_number"]?.string ?? "Instrument").textSelection(.enabled)
                    }
                    if let status = allocation["instrument_status"]?.string { StatusBadge(raw: status) }
                    Spacer()
                    if let id = allocation["allocation_id"]?.string ?? allocation["id"]?.string,
                       let unassign = actions.first(where: { $0.id == "unassign-\(id)" }) {
                        Button("Entfernen", role: .destructive) { start(unassign, [:]) }.controlSize(.small)
                    }
                }
                .font(.callout)
            }
            if open > 0 && !DashboardAlerts.isDaily(record) {
                HStack(spacing: 8) {
                    if item["free_instruments"]?.int == 0 {
                        if let typeID = item["instrument_type_id"]?.string {
                            Button { navigator.openRecord(.instrumentTypes, id: typeID) } label: {
                                Label("\(open) offen · nicht auf Lager – Bestand anlegen", systemImage: "exclamationmark.triangle.fill")
                            }
                            .buttonStyle(.link).foregroundStyle(.orange).help("Instrumententyp im Inventar öffnen")
                        } else {
                            Label("\(open) offen · nicht auf Lager", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } else {
                        Label("\(open) offen · \(item["free_instruments"]?.int ?? 0) frei im Bestand", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let assign, let itemID = item["order_item_id"]?.string {
                        Button("Zuweisen") { start(assign, ["order_item_id": itemID]) }.controlSize(.small).buttonStyle(.borderedProminent)
                    }
                }
                .font(.callout)
            }
        }
    }
}

// MARK: - Other resources

struct RentalContractCard: View {
    let record: JSONValue

    var body: some View {
        Card(title: "Vertrag", systemImage: "doc.text", accessory: instrumentLink(record)) {
            FactGrid(rows: [
                ("Instrument", [record.value(at: "instrument.instrument_type_name")?.string, record.value(at: "instrument.serial_number")?.string].compactMap { $0 }.joined(separator: " · ")),
                ("Mietpreis", record["rental_period_price_cents"]?.int.map { StaffLabels.money($0, currency: record["currency_code"]?.string) + (DashboardAlerts.isDaily(record) ? "" : " / Monat") }),
                ("Beginn", (record["anchor_date"]?.string ?? record["start_date"]?.string).map(StaffLabels.shortDate)),
                ("Aktuelle Periode", record["current_period"].isPresent ? "\(StaffLabels.shortDate(record.value(at: "current_period.start")?.string)) – \(StaffLabels.shortDate(record.value(at: "current_period.end")?.string))" : nil),
                ("Mindestlaufzeit bis", record["minimum_term_end_date"]?.string.map(StaffLabels.shortDate)),
                ("Gebuchtes Ende", record["booked_end_date"]?.string.map(StaffLabels.shortDate)),
                ("Wirksames Ende", record["effective_end_date"]?.string.map(StaffLabels.shortDate))
            ])
        }
    }
}

func instrumentLink(_ record: JSONValue) -> AnyView? {
    guard let id = record.value(at: "instrument.instrument_id")?.string ?? record["instrument_id"]?.string else { return nil }
    return AnyView(RecordLink(title: record.value(at: "instrument.serial_number")?.string ?? "Instrument", resource: .instruments, id: id, systemImage: "barcode"))
}

struct ReturnCard: View {
    let record: JSONValue

    var body: some View {
        Card(title: "Rückgabe", systemImage: "arrow.uturn.backward.circle", accessory: instrumentLink(record)) {
            FactGrid(rows: [
                ("Art", record["method"]?.string.map(StaffLabels.label)),
                ("Option", record["option_name"]?.string),
                ("Instrument", [record.value(at: "instrument.instrument_type_name")?.string, record.value(at: "instrument.serial_number")?.string].compactMap { $0 }.joined(separator: " · ")),
                ("Termin", record["appointment"].isPresent ? StaffLabels.timeRange(record.value(at: "appointment.start_at")?.string, record.value(at: "appointment.end_at")?.string) : nil),
                ("Sendungsnummer", record["tracking_number"]?.string),
                ("Eingegangen", record["received_at"]?.string.map(StaffLabels.dateTime)),
                ("Notiz", record["note"]?.string)
            ])
        }
    }
}

struct CancellationCard: View {
    let record: JSONValue

    var body: some View {
        Card(title: "Kündigungseingang", systemImage: "doc.badge.ellipsis") {
            VStack(alignment: .leading, spacing: 10) {
                FactGrid(rows: [
                    ("Eingegangen", record["created_at"]?.string.map(StaffLabels.dateTime)),
                    ("E-Mail", record["email"]?.string),
                    ("Gewünschtes Ende", (record["requested_end_date"]?.string ?? record["desired_end_date"]?.string).map(StaffLabels.shortDate)),
                    ("Erledigt", record["resolved_at"]?.string.map(StaffLabels.dateTime)),
                    ("Begründung", record["resolution_note"]?.string)
                ])
                if let message = record["message"]?.string ?? record["reason"]?.string ?? record["note"]?.string {
                    Text(message).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).textSelection(.enabled)
                }
            }
        }
    }
}

struct CustomerCard: View {
    let customer: JSONValue?
    let billing: JSONValue?

    var body: some View {
        if let customer, customer.isPresentObject {
            Card(title: "Kunde", systemImage: "person") {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RecordPresentation.title(customer, resource: .customers)).font(.body.weight(.semibold)).textSelection(.enabled)
                        if let email = customer["email"]?.string {
                            Link(email, destination: URL(string: "mailto:\(email)") ?? URL(string: "mailto:")!).font(.callout)
                        }
                        if let phone = customer["phone"]?.string ?? customer["phone_number"]?.string { Text(phone).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let billing, let street = billing["street"]?.string {
                            Text("\(street), \(billing["postal_code"]?.string ?? "") \(billing["city"]?.string ?? "")").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    FactGrid(rows: [
                        ("Bestellungen", customer["order_count"]?.string),
                        ("Laufende Mieten", customer["running_rental_count"]?.string),
                        ("Offene Rechnungen", customer["open_invoice_count"]?.string)
                    ])
                }
            }
        }
    }
}

struct DepositCard: View {
    let deposit: JSONValue?

    var body: some View {
        if let deposit, deposit.isPresentObject {
            Card(title: "Kaution", systemImage: "eurosign.circle", accessory: AnyView(StatusBadge(raw: deposit["status"]?.string ?? ""))) {
                VStack(alignment: .leading, spacing: 8) {
                    FactGrid(rows: [
                        ("Betrag", StaffLabels.money(deposit["amount_cents"]?.int, currency: deposit["currency_code"]?.string)),
                        ("Prüfung", deposit["verification"]?.string.map(StaffLabels.label)),
                        ("Zahlungsart", (deposit["deposit_payment_method"]?.string ?? deposit["provider"]?.string).map(StaffLabels.label)),
                        ("Verwendungszweck", deposit["transfer_reference"]?.string),
                        ("Bezahlt am", deposit["paid_at"]?.string.map(StaffLabels.dateTime)),
                        ("Einbehalten", deposit["retained_cents"]?.int.map { StaffLabels.money($0, currency: deposit["currency_code"]?.string) }),
                        ("Erstattet", deposit["refunded_cents"]?.int.map { StaffLabels.money($0, currency: deposit["currency_code"]?.string) })
                    ])
                    if deposit["settleable"]?.bool == true {
                        Label("Noch abzurechnen", systemImage: "hourglass").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

struct RelatedLink: Hashable {
    let title: String
    let resource: StaffResource
    let id: String
}

struct RelatedRecordsCard: View {
    @Environment(StaffNavigator.self) private var navigator
    let links: [RelatedLink]

    var body: some View {
        if !links.isEmpty {
            HStack(spacing: 8) {
                Text("Verknüpft:").font(.callout).foregroundStyle(.secondary)
                ForEach(links, id: \.self) { link in
                    Button { navigator.openRecord(link.resource, id: link.id) } label: {
                        Label(link.title, systemImage: link.resource.systemImage)
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
        }
    }
}

struct CustomerHistoryCard: View {
    @Environment(StaffNavigator.self) private var navigator
    let history: JSONValue

    private static let sections: [(key: String, resource: StaffResource?)] = [
        ("orders", .orders), ("rentals", .rentals), ("returns", .returns), ("deposits", .deposits), ("invoices", .invoices), ("events", nil)
    ]

    var body: some View {
        let object = history.object ?? (history.array.map { ["events": .array($0)] } ?? [:])
        let keys = Self.sections.map(\.key).filter { object[$0]?.array?.isEmpty == false }
            + object.keys.sorted().filter { key in !Self.sections.contains { $0.key == key } && object[key]?.array?.isEmpty == false }
        Card(title: "Kundenhistorie", systemImage: "clock.arrow.circlepath") {
            if keys.isEmpty { Text("Keine Einträge.").font(.callout).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(keys, id: \.self) { key in
                    let resource = Self.sections.first { $0.key == key }?.resource
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RecordPresentation.displayName(key)).font(.subheadline.weight(.semibold))
                        ForEach(object[key]?.array ?? []) { entry in row(entry, resource: resource) }
                    }
                }
            }
        }
    }

    private func entryTitle(_ entry: JSONValue, resource: StaffResource?) -> String {
        if let resource {
            let line = RecordPresentation.detailLine(entry, resource: resource)
            if !line.isEmpty { return line }
        }
        return entry["title"]?.string ?? entry["number"]?.string ?? entry["type"]?.string ?? entry.id
    }

    private func entryLabel(_ entry: JSONValue, resource: StaffResource?) -> some View {
        let date = entry["created_at"]?.string ?? entry["at"]?.string
        return HStack(spacing: 8) {
            Text(entryTitle(entry, resource: resource)).lineLimit(1)
            Spacer()
            if let status = RecordPresentation.statusRaw(entry) { StatusBadge(raw: status) }
            if let date { Text(StaffLabels.shortDate(date)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.callout)
    }

    @ViewBuilder private func row(_ entry: JSONValue, resource: StaffResource?) -> some View {
        if let resource {
            Button { navigator.openRecord(resource, id: resource.recordID(entry)) } label: { entryLabel(entry, resource: resource).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .help("\(resource.singular) öffnen")
        } else {
            entryLabel(entry, resource: nil).padding(.vertical, 2)
        }
    }
}

// MARK: - Raw fields

struct RecordFieldsView: View {
    let value: JSONValue

    var body: some View {
        if let object = value.object {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    ForEach(visibleKeys(object), id: \.self) { key in
                        if let field = object[key], field.array == nil, field.object == nil, field != .null {
                            GridRow {
                                Text(RecordPresentation.displayName(key)).foregroundStyle(.secondary)
                                Text(Self.format(field, key: key, currency: object["currency_code"]?.string)).textSelection(.enabled).foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .font(.callout)
                ForEach(visibleKeys(object), id: \.self) { key in
                    if let nested = object[key], nested.object != nil || nested.array != nil {
                        DisclosureGroup(RecordPresentation.displayName(key)) { NestedJSONView(value: nested).padding(.top, 6) }
                    }
                }
            }
        }
    }

    private func visibleKeys(_ object: [String: JSONValue]) -> [String] {
        object.keys.sorted().filter { !$0.hasPrefix("_") && !Self.isSecret($0) }
    }

    /// Stripe client secrets and similar never reach the screen (§ 7.4).
    static func isSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("secret") || lower.contains("iban_encrypted") || lower == "iban" || lower.contains("token") || lower.hasSuffix("_digest")
    }

    static func format(_ value: JSONValue, key: String, currency: String? = nil) -> String {
        if key.hasSuffix("_cents"), let cents = value.int { return StaffLabels.money(cents, currency: currency) }
        if let array = value.array, array.allSatisfy({ $0.string != nil }) { return array.compactMap(\.string).joined(separator: ", ") }
        if key.hasSuffix("_at"), let iso = value.string { return StaffLabels.dateTime(iso) }
        if key.hasSuffix("_date"), let day = value.string { return StaffLabels.shortDate(day) }
        if let bool = value.bool { return bool ? "Ja" : "Nein" }
        if let raw = value.string, ["status", "state", "verification", "instrument_status", "method", "provider", "rental_term", "term", "booking_status",
                                    "type", "invoice_type", "direction", "condition", "kind", "document_type", "payment_method", "deposit_payment_method"].contains(key) {
            return StaffLabels.label(raw)
        }
        return value.string ?? "–"
    }
}

struct NestedJSONView: View {
    let value: JSONValue
    var body: some View {
        switch value {
        case .array(let values):
            ForEach(values) { value in
                HStack(alignment: .top) { Text("•").foregroundStyle(.secondary); RecordFieldsView(value: value) }.padding(.bottom, 6)
            }
        case .object: RecordFieldsView(value: value)
        default: Text(value.string ?? "–")
        }
    }
}
