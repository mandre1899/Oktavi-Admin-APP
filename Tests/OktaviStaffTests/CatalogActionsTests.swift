import Foundation
import Testing
@testable import OktaviStaff

@Suite("Finance, inventory, legal and user routes")
struct CatalogActionsTests {
    private func ids(_ record: [String: JSONValue], _ resource: StaffResource) -> [String] {
        WorkflowActions.available(for: .object(record), resource: resource).map(\.id)
    }
    private func action(_ id: String, _ record: [String: JSONValue], _ resource: StaffResource) throws -> WorkflowAction {
        try #require(WorkflowActions.available(for: .object(record), resource: resource).first { $0.id == id })
    }

    @Test func recordIDsAreResourceSpecific() {
        let rental: JSONValue = .object(["order_id": .string("o1"), "rental_id": .string("r1")])
        let item: JSONValue = .object(["order_id": .string("o1"), "rental_id": .string("r1"), "return_id": .string("x1")])
        #expect(StaffResource.rentals.recordID(rental) == "r1")
        #expect(StaffResource.returns.recordID(item) == "x1")
        #expect(StaffResource.currencies.recordID(.object(["currency_code": .string("EUR")])) == "EUR")
    }

    @Test func calendarUsesReturnIDNotOrderID() {
        let now = ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!
        let item: JSONValue = .object(["order_id": .string("o1"), "rental_id": .string("r1"), "return_id": .string("x1"),
                                       "appointment": .object(["start_at": .string("2026-11-20T09:00:00Z")])])
        let events = CalendarEventMapper.events(sources: [.returns: [item]], now: now)
        #expect(events.map(\.id) == ["return-x1-appointment"])
        #expect(events.first?.recordID == "x1")
    }

    @Test func invoiceGuards() {
        #expect(Set(ids(["invoice_id": .string("i"), "status": .string("draft")], .invoices)) == ["issue-invoice", "void-invoice"])
        let paidPart = ids(["invoice_id": .string("i"), "status": .string("partially_paid"), "paid_cents": .number(500)], .invoices)
        #expect(paidPart.contains("record-payment") && paidPart.contains("uncollectible") && !paidPart.contains("void-invoice"))
        let deposit = ids(["invoice_id": .string("i"), "status": .string("issued"), "type": .string("deposit")], .invoices)
        #expect(!deposit.contains("record-payment"))
    }

    @Test func recordPaymentCapsAtAmountDue() throws {
        let invoice = try action("record-payment", ["invoice_id": .string("i"), "status": .string("issued"), "amount_due_cents": .number(4900)], .invoices)
        #expect(invoice.path == "api/v1/admin/invoices/i/payments")
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: invoice, values: ["provider": "cash", "amount_cents": "50,00"]) }
        let (_, body) = try WorkflowActions.bodyAndPath(action: invoice, values: ["provider": "cash", "amount_cents": "49,00"])
        #expect(body?["amount_cents"]?.int == 4900)
        #expect(body?["provider"]?.string == "cash")
        #expect(body?["paid_at"] == nil)
    }

    @Test func refundOnlyWhenRefundable() throws {
        #expect(ids(["payment_id": .string("p"), "status": .string("succeeded"), "direction": .string("inbound"), "refundable_cents": .number(0)], .payments).isEmpty)
        #expect(ids(["payment_id": .string("p"), "status": .string("succeeded"), "direction": .string("outbound")], .payments).isEmpty)
        let refund = try action("refund", ["payment_id": .string("p"), "status": .string("succeeded"), "direction": .string("inbound"), "refundable_cents": .number(1000)], .payments)
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: refund, values: ["amount_cents": "10,01"]) }
    }

    @Test func instrumentStatusChangeSendsFullDTO() throws {
        let record: [String: JSONValue] = ["instrument_id": .string("in1"), "instrument_type_id": .string("t1"), "serial_number": .string("VL-1"),
                                           "size": .string("3/4"), "condition": .string("good"), "status": .string("available"), "location": .string("Regal 2"),
                                           "acquisition_cost_cents": .number(12000), "created_at": .string("2026-01-01T00:00:00Z")]
        let maintenance = try action("set-maintenance", record, .instruments)
        let (path, body) = try WorkflowActions.bodyAndPath(action: maintenance, values: [:])
        #expect(path == "api/v1/instruments/in1")
        #expect(maintenance.method == .patch)
        #expect(body?["status"]?.string == "maintenance")
        #expect(body?["serial_number"]?.string == "VL-1")
        #expect(body?["acquisition_cost_cents"]?.int == 12000)
        #expect(body?["created_at"] == nil)
        #expect(!ids(record.merging(["status": .string("in_use")]) { _, new in new }, .instruments).contains("set-maintenance"))
    }

    @Test func editInstrumentClearsOptionalPriceWithNull() throws {
        let edit = try action("edit-instrument", ["instrument_id": .string("in1"), "instrument_type_id": .string("t1"), "serial_number": .string("VL-1"),
                                                   "condition": .string("good"), "status": .string("available"), "custom_rental_price_cents": .number(900)], .instruments)
        var values = Dictionary(uniqueKeysWithValues: edit.fields.map { ($0.id, $0.defaultValue) })
        #expect(values["custom_rental_price_cents"] == "9,00")
        values["custom_rental_price_cents"] = ""
        let (_, body) = try WorkflowActions.bodyAndPath(action: edit, values: values)
        #expect(body?["custom_rental_price_cents"] == .null)
    }

    @Test func addInstrumentsChecksSerialCount() throws {
        let add = WorkflowActions.addInstruments(typeID: "t1", sizes: ["4/4"], currency: "EUR")
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: add, values: ["quantity": "2", "serial_numbers": "A1", "condition": "new", "status": "available", "size": "4/4"]) }
        let (path, body) = try WorkflowActions.bodyAndPath(action: add, values: ["quantity": "2", "serial_numbers": "A1, A2", "condition": "new", "status": "available", "size": "4/4"])
        #expect(path == "api/v1/admin/products")
        #expect(body?["product_type_id"]?.string == "t1")
        #expect(body?["serial_numbers"]?.array?.count == 2)
    }

    @Test func deliveryAreaPrefixesValidated() throws {
        let create = try #require(WorkflowActions.createActions(for: .deliveryAreas).first)
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: create, values: ["code": "B", "name": "Berlin", "postal_code_prefixes": "10, 1234567"]) }
        let (_, body) = try WorkflowActions.bodyAndPath(action: create, values: ["code": "B", "name": "Berlin", "postal_code_prefixes": "10\n12, 13"])
        #expect(body?["postal_code_prefixes"]?.array == [.string("10"), .string("12"), .string("13")])
    }

    @Test func returnOptionCategoryPrices() throws {
        let create = try #require(WorkflowActions.createActions(for: .returnOptions).first)
        let (_, body) = try WorkflowActions.bodyAndPath(action: create, values: ["code": "P", "name": "Paket", "kind": "parcel", "price_cents": "9,90", "currency_code": "EUR", "category_prices": "Streicher = 15\nBlas = 12,50"])
        #expect(body?["category_prices"]?["Streicher"]?.int == 1500)
        #expect(body?["category_prices"]?["Blas"]?.int == 1250)
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: create, values: ["code": "P", "name": "P", "kind": "parcel", "price_cents": "1", "currency_code": "EUR", "category_prices": "Streicher"]) }
        #expect(!ids(["return_option_id": .string("r"), "kind": .string("dropoff")], .returnOptions).contains("set-return-areas"))
    }

    @Test func emptyAssignmentSendsEmptyArray() throws {
        let set = try action("set-delivery-areas", ["delivery_option_id": .string("d1")], .deliveryOptions)
        let (path, body) = try WorkflowActions.bodyAndPath(action: set, values: [:])
        #expect(path == "api/v1/admin/delivery-options/d1/delivery-areas")
        #expect(body?["delivery_area_ids"]?.array == [])
    }

    @Test func removeRoleSendsBodyWithDelete() throws {
        let remove = try action("remove-role-staff", ["user_id": .string("u1"), "roles": .array([.string("staff")])], .users)
        let (path, body) = try WorkflowActions.bodyAndPath(action: remove, values: [:])
        #expect(remove.method == .delete && path == "auth/users/u1/roles")
        #expect(body?["role"]?.string == "staff")
        let add = try action("add-role", ["user_id": .string("u1"), "roles": .array([.string("staff")])], .users)
        if case .choice(let roles) = add.fields[0].kind { #expect(!roles.contains("staff")) }
    }

    @Test func legalHashDefaultsToContentDigest() throws {
        let create = try #require(WorkflowActions.createActions(for: .legalDocuments).first)
        let (_, body) = try WorkflowActions.bodyAndPath(action: create, values: ["document_type": "rental_terms", "version": "2026-12", "content": "abc"])
        #expect(body?["document_hash"]?.string == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: create, values: ["document_type": "x", "version": "1", "content": "a", "metadata": "[1]"]) }
        #expect(ids(["legal_document_id": .string("l"), "is_active": .bool(true)], .legalDocuments).contains("deactivate-document"))
    }

    @Test func currencyCodeValidatedAndUppercased() throws {
        let create = try #require(WorkflowActions.createActions(for: .currencies).first)
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: create, values: ["currency_code": "EU", "name": "E", "symbol": "€", "minor_units": "2"]) }
        let (_, body) = try WorkflowActions.bodyAndPath(action: create, values: ["currency_code": "chf", "name": "Franken", "symbol": "CHF", "minor_units": "2"])
        #expect(body?["currency_code"]?.string == "CHF")
        let toggle = try action("deactivate-currency", ["currency_code": .string("CHF"), "is_active": .bool(true)], .currencies)
        #expect(try WorkflowActions.bodyAndPath(action: toggle, values: [:]).1?["is_active"]?.bool == false)
    }

    @Test func conditionReportLimitsAndShape() throws {
        var point = ConditionPoint(key: "body", label: "Korpus & Lack", rating: "wear", note: "Kratzer", mediaIDs: ["m1"])
        let body = try ConditionReport.body(grade: "used", points: [point], notes: "")
        #expect(body.value(at: "condition.version")?.int == 2)
        #expect(body.value(at: "condition.points")?.array?.first?["media_ids"]?.array == [.string("m1")])
        point.mediaIDs = (1...11).map { "m\($0)" }
        #expect(throws: ValidationError.self) { try ConditionReport.body(grade: "used", points: [point], notes: "") }
        #expect(throws: ValidationError.self) { try ConditionReport.body(grade: "", points: [], notes: "") }
    }

    @Test func templateReusesLastCheckPoints() {
        let snapshot: JSONValue = .object(["condition": .object(["version": .number(2), "points": .array([.object(["key": .string("neck"), "label": .string("Hals"), "rating": .string("damaged")])])])])
        let template = ConditionReport.template(from: [snapshot])
        #expect(template.map(\.key) == ["neck"])
        #expect(template.first?.rating == "ok")
    }

    @Test func moneyInputRoundTrips() {
        #expect(StaffLabels.moneyInput(1250) == "12,50")
        #expect(StaffLabels.moneyInput(5) == "0,05")
        #expect(WorkflowActions.parseCents(StaffLabels.moneyInput(123456)) == 123456)
    }
}
