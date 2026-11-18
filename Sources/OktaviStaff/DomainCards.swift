import SwiftUI

// MARK: - Links

/// A compact link into another domain ("Instrument fehlt → Typ öffnen").
struct RecordLink: View {
    @Environment(StaffNavigator.self) private var navigator
    let title: String
    let resource: StaffResource
    let id: String
    var systemImage: String? = nil

    var body: some View {
        Button { navigator.openRecord(resource, id: id) } label: {
            Label(title, systemImage: systemImage ?? resource.systemImage)
        }
        .buttonStyle(.link)
        .help("\(resource.singular) öffnen")
    }
}

enum RelatedLinks {
    static func make(_ record: JSONValue, resource: StaffResource) -> [RelatedLink] {
        var links: [RelatedLink] = []
        func add(_ path: String, _ target: StaffResource, _ title: String) {
            guard target != resource, let id = record.value(at: path)?.string, !id.isEmpty,
                  !links.contains(where: { $0.resource == target && $0.id == id }) else { return }
            links.append(.init(title: title, resource: target, id: id))
        }
        add("source_order_id", .orders, "Ursprüngliche Bestellung")
        add("order_id", .orders, "Bestellung")
        add("deposit_order_id", .orders, "Bestellung")
        add("order.order_id", .orders, "Bestellung")
        add("rental_id", .rentals, "Miete")
        add("return_id", .returns, "Rückgabe")
        add("return.return_id", .returns, "Rückgabe")
        add("deposit_id", .deposits, "Kaution")
        add("deposit.deposit_id", .deposits, "Kaution")
        add("invoice_id", .invoices, "Rechnung")
        add("invoice.invoice_id", .invoices, "Rechnung")
        add("payment_id", .payments, "Zahlung")
        add("related_payment_id", .payments, "Ursprüngliche Zahlung")
        add("instrument.instrument_id", .instruments, "Instrument")
        add("instrument_id", .instruments, "Instrument")
        add("instrument_type_id", .instrumentTypes, "Instrumententyp")
        add("instrument.instrument_type_id", .instrumentTypes, "Instrumententyp")
        let userID = record["user_id"]?.string ?? record.value(at: "customer.user_id")?.string ?? record.value(at: "customer.id")?.string
        if let userID {
            if resource != .customers { links.append(.init(title: "Kundenkonto", resource: .customers, id: userID)) }
            if resource == .customers { links.append(.init(title: "Benutzerkonto & Rollen", resource: .users, id: userID)) }
        }
        for rental in record["rentals"]?.array ?? [] where resource == .orders {
            if let id = rental["rental_id"]?.string { links.append(.init(title: "Miete \(rental.value(at: "instrument.serial_number")?.string ?? "")", resource: .rentals, id: id)) }
        }
        return links
    }
}

/// Generic facts of a record: given keys in order, or every flat field.
struct FactsCard: View {
    let title: String
    let systemImage: String
    let record: JSONValue
    var keys: [String]? = nil

    var body: some View {
        let object = record.object ?? [:]
        let chosen = keys ?? object.keys.sorted().filter { object[$0]?.object == nil && object[$0]?.array == nil }
        Card(title: title, systemImage: systemImage) {
            FactGrid(rows: chosen.compactMap { key in
                guard let value = object[key], value != .null, !RecordFieldsView.isSecret(key) else { return nil }
                return (RecordPresentation.displayName(key), RecordFieldsView.format(value, key: key, currency: record["currency_code"]?.string))
            })
        }
    }
}

// MARK: - Betrieb additions

struct PaymentSetupCard: View {
    let record: JSONValue
    var body: some View {
        let setup = record["payment_setup"]
        let mandate = record["sepa_mandate"] ?? setup?["sepa_mandate"]
        if setup.isPresent || record["payment_method"]?.string != nil {
            Card(title: "Zahlung", systemImage: "creditcard") {
                FactGrid(rows: [
                    ("Zahlungsmethode", record["payment_method"]?.string.map(StaffLabels.label)),
                    ("Kaution über", record["deposit_payment_method"]?.string.map(StaffLabels.label)),
                    ("Einrichtung", setup?["status"]?.string.map(StaffLabels.label)),
                    ("Art", setup?["payment_method_type"]?.string.map(StaffLabels.label)),
                    ("Fehler", setup?["failure_reason"]?.string),
                    ("IBAN", mandate?["iban_masked"]?.string),
                    ("Mandatsreferenz", mandate?["mandate_reference"]?.string)
                ])
            }
        }
    }
}

struct FulfillmentsCard: View {
    let fulfillments: [JSONValue]
    var body: some View {
        if !fulfillments.isEmpty {
            Card(title: "Übergabevorgänge", systemImage: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fulfillments) { item in
                        HStack {
                            Text(StaffLabels.label(item["fulfillment_type"]?.string ?? item["type"]?.string))
                            Spacer()
                            if let at = item["completed_at"]?.string ?? item["scheduled_at"]?.string ?? item["created_at"]?.string {
                                Text(StaffLabels.dateTime(at)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            StatusBadge(raw: item["status"]?.string ?? "")
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct RentalInstrumentsCard: View {
    let record: JSONValue
    var body: some View {
        let instruments = record["instruments"]?.array ?? []
        if instruments.count > 1 {
            Card(title: "Instrumente dieser Miete", systemImage: "barcode") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(instruments) { instrument in
                        HStack {
                            if let id = instrument["instrument_id"]?.string {
                                RecordLink(title: instrument["serial_number"]?.string ?? id, resource: .instruments, id: id)
                            }
                            Text(instrument["size"]?.string ?? "").foregroundStyle(.secondary)
                            Spacer()
                            if let from = instrument["allocated_at"]?.string ?? instrument["from"]?.string { Text("ab \(StaffLabels.shortDate(from))").foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct AddressesCard: View {
    let addresses: [JSONValue]
    var body: some View {
        if !addresses.isEmpty {
            Card(title: "Adressen", systemImage: "house") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(addresses) { address in
                        HStack(alignment: .firstTextBaseline) {
                            Text(AddressFormat.line(address)).textSelection(.enabled)
                            Spacer()
                            if address["is_active"]?.bool == false { StatusBadge(raw: "inactive") }
                            if let type = address["type"]?.string ?? address["kind"]?.string { Text(StaffLabels.label(type)).foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

// MARK: - Finanzen

struct InvoiceSummaryCard: View {
    let record: JSONValue
    private var currency: String? { record["currency_code"]?.string }
    private func money(_ key: String) -> String? { record[key]?.int.map { StaffLabels.money($0, currency: currency) } }
    var body: some View {
        Card(title: "Rechnung", systemImage: "doc.text") {
            FactGrid(rows: [
                ("Art", (record["type"]?.string ?? record["invoice_type"]?.string).map(StaffLabels.label)),
                ("Zeitraum", record["period_start"]?.string.map { "\(StaffLabels.shortDate($0)) – \(StaffLabels.shortDate(record["period_end"]?.string))" }),
                ("Gestellt am", record["issued_at"]?.string.map(StaffLabels.shortDate)),
                ("Fällig am", record["due_at"]?.string.map(StaffLabels.shortDate)),
                ("Gesamt", money("total_cents")),
                ("davon MwSt.", money("vat_cents") ?? money("tax_cents")),
                ("Bezahlt", money("paid_cents") ?? money("amount_paid_cents")),
                ("Erstattet", money("refunded_cents")),
                ("Offen", WorkflowActions.amountDue(record).map { StaffLabels.money($0, currency: currency) })
            ])
        }
    }
}

struct InvoiceLinesCard: View {
    let record: JSONValue
    var body: some View {
        let lines = record["lines"]?.array ?? []
        if !lines.isEmpty {
            Card(title: "Positionen", systemImage: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line["description"]?.string ?? line["name"]?.string ?? "Position")
                            if let quantity = line["quantity"]?.int, quantity > 1 { Text("× \(quantity)").foregroundStyle(.secondary) }
                            Spacer()
                            Text(StaffLabels.money(line["total_cents"]?.int ?? line["amount_cents"]?.int ?? line["line_total_cents"]?.int, currency: record["currency_code"]?.string)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct InvoiceListCard: View {
    let title: String
    let invoices: [JSONValue]
    var body: some View {
        if !invoices.isEmpty {
            Card(title: title, systemImage: "doc.text") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(invoices) { invoice in
                        HStack {
                            RecordLink(title: RecordPresentation.title(invoice, resource: .invoices), resource: .invoices, id: StaffResource.invoices.recordID(invoice), systemImage: "doc.text")
                            if let start = invoice["period_start"]?.string { Text("\(StaffLabels.shortDate(start)) – \(StaffLabels.shortDate(invoice["period_end"]?.string))").foregroundStyle(.secondary) }
                            Spacer()
                            if let amount = RecordPresentation.amount(invoice, resource: .invoices) { Text(amount).monospacedDigit() }
                            if let status = invoice["status"]?.string { StatusBadge(raw: status) }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct PaymentListCard: View {
    let title: String
    let payments: [JSONValue]
    var body: some View {
        if !payments.isEmpty {
            Card(title: title, systemImage: "creditcard") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(payments) { payment in
                        HStack {
                            RecordLink(title: StaffLabels.money(payment["amount_cents"]?.int, currency: payment["currency_code"]?.string), resource: .payments, id: StaffResource.payments.recordID(payment), systemImage: "creditcard")
                            Text(StaffLabels.label(payment["provider"]?.string)).foregroundStyle(.secondary)
                            Spacer()
                            if let at = payment["paid_at"]?.string ?? payment["created_at"]?.string { Text(StaffLabels.shortDate(at)).foregroundStyle(.secondary).monospacedDigit() }
                            if let status = payment["status"]?.string { StatusBadge(raw: status) }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct PaymentSummaryCard: View {
    let record: JSONValue
    var body: some View {
        let currency = record["currency_code"]?.string
        let details = record["stripe"] ?? record["stripe_details"]
        let sepa = record["sepa"] ?? record["sepa_details"] ?? record["sepa_mandate"]
        Card(title: "Zahlung", systemImage: "creditcard") {
            VStack(alignment: .leading, spacing: 10) {
                FactGrid(rows: [
                    ("Richtung", record["direction"]?.string.map(StaffLabels.label)),
                    ("Anbieter", record["provider"]?.string.map(StaffLabels.label)),
                    ("Betrag", record["amount_cents"]?.int.map { StaffLabels.money($0, currency: currency) }),
                    ("Erstattbar", record["refundable_cents"]?.int.map { StaffLabels.money($0, currency: currency) }),
                    ("Bezahlt am", record["paid_at"]?.string.map(StaffLabels.dateTime)),
                    ("Referenz", record["external_reference"]?.string),
                    ("Erfasst von", record["recorded_by_email"]?.string ?? record["recorded_by"]?.string),
                    ("Notiz", record["notes"]?.string),
                    ("Fehler", record["failure_reason"]?.string ?? record["failure_message"]?.string)
                ])
                if let details, details.isPresentObject {
                    Divider(); FactsCardBody(record: details)
                }
                if let sepa, sepa.isPresentObject {
                    Divider(); FactsCardBody(record: sepa)
                }
            }
        }
    }
}

/// Flat fields of a nested object, secrets left out.
struct FactsCardBody: View {
    let record: JSONValue
    var body: some View {
        let object = record.object ?? [:]
        FactGrid(rows: object.keys.sorted().compactMap { key in
            guard let value = object[key], value.object == nil, value.array == nil, value != .null, !RecordFieldsView.isSecret(key) else { return nil }
            return (RecordPresentation.displayName(key), RecordFieldsView.format(value, key: key, currency: record["currency_code"]?.string))
        })
    }
}

// MARK: - Inventar

struct PhotoStrip: View {
    let references: [String]
    var body: some View {
        if !references.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(references, id: \.self) { RemoteImage(reference: $0).frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 10)) }
                }
            }
        }
    }
}

struct InstrumentTypeCard: View {
    let record: JSONValue
    private var currency: String? { record["currency_code"]?.string }
    private func money(_ key: String) -> String? { record[key]?.int.map { StaffLabels.money($0, currency: currency) } }
    var body: some View {
        let photos = (record["photo_urls"]?.array ?? []).compactMap(\.string) + (record["photo_url"]?.string.map { [$0] } ?? [])
        VStack(alignment: .leading, spacing: 12) {
            PhotoStrip(references: photos.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
            Card(title: "Instrumententyp", systemImage: "guitars") {
                VStack(alignment: .leading, spacing: 10) {
                    FactGrid(rows: [
                        ("Kategorie", record["category"]?.string),
                        ("Marke / Modell", [record["brand"]?.string, record["model"]?.string].compactMap { $0 }.joined(separator: " ")),
                        ("Größen", (record["sizes"]?.array ?? []).compactMap(\.string).joined(separator: ", ")),
                        ("Mietpreis / Monat", money("default_rental_price_cents") ?? money("rental_price_cents")),
                        ("Kaufpreis", money("default_purchase_price_cents")),
                        ("Kaution", money("deposit_cents")),
                        ("Währung", currency)
                    ])
                    if let description = record["description"]?.string, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct InstrumentsOfTypeCard: View {
    @Environment(StaffNavigator.self) private var navigator
    let typeID: String
    let instruments: [JSONValue]

    var body: some View {
        let own = instruments.filter { ($0["instrument_type_id"]?.string ?? $0.value(at: "instrument_type.instrument_type_id")?.string ?? typeID) == typeID }
        let counts = Dictionary(grouping: own) { $0["status"]?.string ?? "" }.mapValues(\.count)
        Card(title: "Bestand", systemImage: "barcode",
             accessory: AnyView(Button("Alle im Inventar zeigen") { navigator.open(.instruments, presets: ["instrument_type_id": typeID]) }.buttonStyle(.link))) {
            VStack(alignment: .leading, spacing: 8) {
                if own.isEmpty {
                    Text("Keine Instrumente dieses Typs. Mit „Instrumente hinzufügen“ den Bestand anlegen.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(counts.keys.sorted(), id: \.self) { status in
                            Text("\(counts[status] ?? 0) \(StaffLabels.label(status))").font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(StaffLabels.badgeColor(status).opacity(0.15), in: Capsule()).foregroundStyle(StaffLabels.badgeColor(status))
                        }
                    }
                    ForEach(own.prefix(12)) { instrument in
                        HStack {
                            RecordLink(title: instrument["serial_number"]?.string ?? "Instrument", resource: .instruments, id: StaffResource.instruments.recordID(instrument), systemImage: "barcode")
                            Text([instrument["size"]?.string, instrument["location"]?.string].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            Spacer()
                            if let status = instrument["status"]?.string { StatusBadge(raw: status) }
                        }
                        .font(.callout)
                    }
                    if own.count > 12 { Text("… und \(own.count - 12) weitere").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct InstrumentCard: View {
    @Environment(AppModel.self) private var model
    let record: JSONValue
    private func money(_ key: String, _ currencyKey: String = "currency_code") -> String? {
        record[key]?.int.map { StaffLabels.money($0, currency: record[currencyKey]?.string ?? record["currency_code"]?.string) }
    }
    var body: some View {
        let typeID = record["instrument_type_id"]?.string ?? record.value(at: "instrument_type.instrument_type_id")?.string
        Card(title: "Instrument", systemImage: "barcode") {
            VStack(alignment: .leading, spacing: 10) {
                if let typeID {
                    RecordLink(title: record["instrument_type_name"]?.string ?? model.references.name(of: typeID, in: .instrumentTypes) ?? "Instrumententyp", resource: .instrumentTypes, id: typeID)
                }
                FactGrid(rows: [
                    ("Seriennummer", record["serial_number"]?.string),
                    ("Größe", record["size"]?.string),
                    ("Zustand", record["condition"]?.string.map(StaffLabels.label)),
                    ("Lagerort", record["location"]?.string),
                    ("Eigener Mietpreis", money("custom_rental_price_cents")),
                    ("Eigener Kaufpreis", money("custom_purchase_price_cents")),
                    ("Anschaffung", money("acquisition_cost_cents", "acquisition_currency_code")),
                    ("Angeschafft am", (record["acquired_at"]?.string ?? record["acquisition_date"]?.string).map(StaffLabels.shortDate)),
                    ("Notiz", record["notes"]?.string)
                ])
            }
        }
    }
}

struct SnapshotsCard: View {
    let snapshots: [JSONValue]
    let edit: (JSONValue) -> Void

    var body: some View {
        Card(title: "Zustandsberichte", systemImage: "checklist") {
            if snapshots.isEmpty {
                Text("Noch kein Zustandsbericht. Mit „Zustand erfassen“ den ersten anlegen.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshots.enumerated()), id: \.offset) { index, snapshot in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    snapshotRow(snapshot, latest: index == 0)
                }
            }
        }
    }

    @ViewBuilder private func snapshotRow(_ snapshot: JSONValue, latest: Bool) -> some View {
        let condition = snapshot["condition"]
        let points = ConditionReport.points(in: snapshot)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(StaffLabels.dateTime(snapshot["created_at"]?.string ?? snapshot["recorded_at"]?.string)).fontWeight(.medium)
                if let grade = condition?["grade"]?.string { StatusBadge(raw: grade) }
                if latest { Text("aktuell").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if condition?["version"]?.int == 2 || points.isEmpty == false {
                    Button("Bearbeiten") { edit(snapshot) }.controlSize(.small)
                }
            }
            if points.isEmpty {
                // Earlier format: {grade, playable, cosmetic_damage, accessories_complete}
                FactGrid(rows: [
                    ("Spielbar", condition?["playable"]?.bool.map { $0 ? "Ja" : "Nein" }),
                    ("Optische Schäden", condition?["cosmetic_damage"]?.bool.map { $0 ? "Ja" : "Nein" } ?? condition?["cosmetic_damage"]?.string),
                    ("Zubehör vollständig", condition?["accessories_complete"]?.bool.map { $0 ? "Ja" : "Nein" })
                ])
            }
            ForEach(points) { point in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(point.label)
                        StatusBadge(raw: point.rating)
                        if !point.note.isEmpty { Text(point.note).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .font(.callout)
                    if !point.mediaIDs.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(point.mediaIDs, id: \.self) { RemoteImage(reference: $0, privateMedia: true).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5)) }
                        }
                    }
                }
            }
            if let notes = snapshot["notes"]?.string, !notes.isEmpty { Text(notes).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct DeliveryOptionCard: View {
    @Environment(AppModel.self) private var model
    let record: JSONValue
    var body: some View {
        let returnIDs = (record["return_option_ids"]?.array ?? []).compactMap(\.string)
        let areaIDs = (record["delivery_area_ids"]?.array ?? []).compactMap(\.string)
        Card(title: "Lieferoption", systemImage: "truck.box") {
            VStack(alignment: .leading, spacing: 10) {
                FactGrid(rows: [
                    ("Code", record["code"]?.string),
                    ("Preis", record["price_cents"]?.int.map { StaffLabels.money($0, currency: record["currency_code"]?.string) }),
                    ("Lieferadresse nötig", (record["requires_address"]?.bool ?? record["requires_delivery_address"]?.bool).map { $0 ? "Ja" : "Nein" }),
                    ("Persönlich", record["in_person"]?.bool.map { $0 ? "Ja" : "Nein" }),
                    ("Reihenfolge", record["sort_order"]?.string),
                    ("Rückgabeoptionen", returnIDs.isEmpty ? "Alle aktiven" : returnIDs.map { model.references.name(of: $0, in: .returnOptions) ?? $0 }.joined(separator: ", ")),
                    ("Liefergebiete", areaIDs.isEmpty ? "Überall" : areaIDs.map { model.references.name(of: $0, in: .deliveryAreas) ?? $0 }.joined(separator: ", "))
                ])
                if let description = record["description"]?.string, !description.isEmpty { Text(description).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ReturnOptionCard: View {
    @Environment(AppModel.self) private var model
    let record: JSONValue
    var body: some View {
        let currency = record["currency_code"]?.string
        let areaIDs = (record["delivery_area_ids"]?.array ?? []).compactMap(\.string)
        let prices = (record["category_prices"]?.object ?? [:]).sorted { $0.key < $1.key }
        Card(title: "Rückgabeoption", systemImage: "arrow.uturn.left.square") {
            VStack(alignment: .leading, spacing: 10) {
                FactGrid(rows: [
                    ("Art", record["kind"]?.string.map(StaffLabels.label)),
                    ("Code", record["code"]?.string),
                    ("Preis", record["price_cents"]?.int.map { StaffLabels.money($0, currency: currency) }),
                    ("Adresse nötig", record["requires_address"]?.bool.map { $0 ? "Ja" : "Nein" }),
                    ("Reihenfolge", record["sort_order"]?.string),
                    ("Liefergebiete", record["kind"]?.string == "dropoff" ? "Abgabe – nie eingeschränkt" : areaIDs.isEmpty ? "Überall" : areaIDs.map { model.references.name(of: $0, in: .deliveryAreas) ?? $0 }.joined(separator: ", "))
                ])
                if !prices.isEmpty {
                    Divider()
                    Text("Preise je Kategorie").font(.subheadline.weight(.semibold))
                    FactGrid(rows: prices.map { ($0.key, $0.value.int.map { StaffLabels.money($0, currency: currency) }) })
                }
            }
        }
    }
}

struct MediaCard: View {
    let record: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = record["url"]?.string {
                RemoteImage(reference: url, contentMode: .fit).frame(maxWidth: .infinity, minHeight: 240, maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Card(title: "Bild", systemImage: "photo") {
                FactGrid(rows: [
                    ("Verwendet von", (record["used_by"]?.array ?? []).compactMap(\.string).joined(separator: ", ").nilIfEmpty ?? "Noch keinem Instrumententyp"),
                    ("Adresse", record["url"]?.string),
                    ("Dateityp", record["content_type"]?.string),
                    ("Abmessungen", record["width"]?.int.map { "\($0) × \(record["height"]?.int ?? 0) px" }),
                    ("Größe", record["size_bytes"]?.int.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }),
                    ("Hochgeladen", record["created_at"]?.string.map(StaffLabels.dateTime))
                ])
            }
        }
    }
}

// MARK: - Kundenservice & Rechtliches

struct UserCard: View {
    let record: JSONValue
    let actions: [WorkflowAction]
    let start: (WorkflowAction, [String: String]) -> Void

    var body: some View {
        let roles = (record["roles"]?.array ?? []).compactMap(\.string)
        Card(title: "Benutzerkonto", systemImage: "person.badge.key") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Rollen").foregroundStyle(.secondary)
                    if roles.isEmpty { Text("Keine").foregroundStyle(.secondary) }
                    ForEach(roles, id: \.self) { role in
                        HStack(spacing: 4) {
                            Text(StaffLabels.label(role)).font(.callout.weight(.medium))
                            if let remove = actions.first(where: { $0.id == "remove-role-\(role)" }) {
                                Button { start(remove, [:]) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("\(StaffLabels.label(role)) entziehen")
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                .font(.callout)
                FactGrid(rows: [
                    ("E-Mail", record["email"]?.string),
                    ("Name", [record["first_name"]?.string, record["last_name"]?.string].compactMap { $0 }.joined(separator: " ")),
                    ("Status", record["status"]?.string.map(StaffLabels.label)),
                    ("Zwei-Faktor", (record["two_factor_enabled"]?.bool ?? record.value(at: "two_factor.enabled")?.bool).map { $0 ? "Eingerichtet" : "Nicht eingerichtet" }),
                    ("Letzte Anmeldung", record["last_login_at"]?.string.map(StaffLabels.dateTime)),
                    ("Angelegt", record["created_at"]?.string.map(StaffLabels.dateTime))
                ])
            }
        }
    }
}

struct LegalDocumentCard: View {
    let record: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(title: "Version", systemImage: "text.book.closed") {
                FactGrid(rows: [
                    ("Dokumentart", record["document_type"]?.string.map { "\(StaffLabels.label($0)) (\($0))" }),
                    ("Version", record["version"]?.string),
                    ("Aktiv", record["is_active"]?.bool.map { $0 ? "Ja – wird im Checkout verlangt" : "Nein" }),
                    ("Hash", record["document_hash"]?.string),
                    ("Aktiviert am", record["activated_at"]?.string.map(StaffLabels.dateTime))
                ])
            }
            if let content = record["content"]?.string {
                Card(title: "Inhalt", systemImage: "doc.plaintext") {
                    Text(content).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let metadata = record["metadata"], metadata.isPresentObject {
                Card(title: "Metadaten", systemImage: "curlybraces") {
                    Text(FormValue.string(metadata, kind: .json)).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}
