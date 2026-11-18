import Testing
@testable import OktaviStaff

@Suite("Workflow action guards")
struct WorkflowActionsTests {
    private func record(_ values: [String: JSONValue]) -> JSONValue {
        .object(["id": .string("record-id")].merging(values) { _, new in new })
    }

    @Test func submittedOrderCanApproveAndReject() {
        let actions = WorkflowActions.available(for: record(["status": .string("submitted"), "rental_term": .string("long_term")]), resource: .orders)
        #expect(actions.map(\.id).contains("approve"))
        #expect(actions.map(\.id).contains("reject"))
        #expect(!actions.map(\.id).contains("handover"))
    }

    @Test func dailyOrderDoesNotExposeMonthlyActions() {
        let actions = WorkflowActions.available(for: record([
            "status": .string("approved"), "rental_term": .string("short_term"),
            "rental_start_date": .string("2000-01-01"), "rental_end_date": .string("2999-12-31")
        ]), resource: .orders)
        #expect(actions.map(\.id).contains("handover"))
        #expect(!actions.map(\.id).contains("tracking"))
        #expect(!actions.map(\.id).contains("assign"))
    }

    @Test func dailyOrderReturnActionAfterHandover() {
        let actions = WorkflowActions.available(for: record([
            "status": .string("fulfilled"), "rental_term": .string("short_term"),
            "booking_status": .string("active"),
            "handover": .object(["handed_over_at": .string("2026-11-17T11:00:00Z"), "status": .string("completed")])
        ]), resource: .orders)
        #expect(actions.map(\.id).contains("return"))
    }

    @Test func assignRequiresUnallocatedUnits() {
        let withUnits = WorkflowActions.available(for: record([
            "status": .string("approved"), "rental_term": .string("long_term"), "unallocated_units": .number(1)
        ]), resource: .orders)
        let withoutUnits = WorkflowActions.available(for: record([
            "status": .string("approved"), "rental_term": .string("long_term"), "unallocated_units": .number(0)
        ]), resource: .orders)
        #expect(withUnits.map(\.id).contains("assign"))
        #expect(!withoutUnits.map(\.id).contains("assign"))
    }

    @Test func settleDepositRequiresSettleable() {
        let settleable = WorkflowActions.available(for: record([
            "status": .string("fulfilled"), "rental_term": .string("short_term"),
            "deposit": .object(["settleable": .bool(true)])
        ]), resource: .orders)
        #expect(settleable.map(\.id).contains("settle-deposit"))
    }

    @Test func returnLifecycleActions() {
        let requested = WorkflowActions.available(for: record(["status": .string("requested"), "method": .string("parcel")]), resource: .returns)
        #expect(Set(requested.map(\.id)) == Set(["appointment", "label", "receive"]))
        let dropoff = WorkflowActions.available(for: record(["status": .string("requested"), "method": .string("dropoff")]), resource: .returns)
        #expect(!dropoff.map(\.id).contains("label"))
        let checkup = WorkflowActions.available(for: record(["status": .string("checkup")]), resource: .returns)
        #expect(checkup.map(\.id) == ["complete"])
    }

    @Test func manualDepositCanBeConfirmed() {
        let manual = WorkflowActions.available(for: record(["status": .string("pending"), "verification": .string("manual")]), resource: .deposits)
        let card = WorkflowActions.available(for: record(["status": .string("pending"), "verification": .string("card")]), resource: .deposits)
        #expect(manual.map(\.id) == ["confirm"])
        #expect(card.isEmpty)
    }

    @Test func requiredFieldsAndSnakeCaseBody() throws {
        let action = WorkflowAction("test", "Test", path: "x/{rental_id}", fields: [
            .init("rental_id", "Miete", required: true), .init("retained_cents", "Betrag", .integer, required: true)
        ], confirmation: "Test")
        let (path, body) = try WorkflowActions.bodyAndPath(action: action, values: ["rental_id": "abc", "retained_cents": "500"])
        #expect(path == "x/abc")
        #expect(body?["retained_cents"]?.int == 500)
    }

    @Test func postWithoutFieldsSendsEmptyObject() throws {
        let action = WorkflowAction("approve", "Genehmigen", path: "x/approve", confirmation: "Test")
        let (_, body) = try WorkflowActions.bodyAndPath(action: action, values: [:])
        #expect(body == .object([:]))
    }
}
