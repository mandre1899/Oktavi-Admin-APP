import Foundation
import Testing
@testable import OktaviStaff

@Suite("Business flow")
struct BusinessFlowTests {
    private func record(_ values: [String: JSONValue]) -> JSONValue {
        .object(["id": .string("record-id")].merging(values) { _, new in new })
    }

    @Test func nullReturnIDStillAllowsStartingReturn() {
        let rental = record(["state": .string("active"), "rental_term": .string("long_term"), "return_id": .null, "instrument": .object(["serial_number": .string("V-1")])])
        let ids = WorkflowActions.available(for: rental, resource: .rentals).map(\.id)
        #expect(ids.contains("start-return"))
        #expect(ids.contains("swap"))
    }

    @Test func nullInstrumentHidesSwap() {
        let rental = record(["state": .string("active"), "instrument": .null])
        #expect(!WorkflowActions.available(for: rental, resource: .rentals).map(\.id).contains("swap"))
    }

    @Test func endNowRespectsEffectiveEndDate() {
        let base: [String: JSONValue] = ["state": .string("active"), "rental_term": .string("long_term"), "current_period": .object(["start": .string("2026-11-01")])]
        let future = record(base.merging(["effective_end_date": .string("2027-01-31")]) { _, new in new })
        let past = record(base.merging(["effective_end_date": .string("2026-11-18")]) { _, new in new })
        #expect(WorkflowActions.available(for: future, resource: .rentals, today: "2026-11-18").map(\.id).contains("end-now"))
        #expect(!WorkflowActions.available(for: past, resource: .rentals, today: "2026-11-18").map(\.id).contains("end-now"))
    }

    @Test func scheduledSlotOffersReplaceInsteadOfPropose() {
        let order = record(["status": .string("approved"), "rental_term": .string("long_term"), "unallocated_units": .number(0),
                            "handover": .object(["status": .string("scheduled"), "fulfillment_id": .string("f1"), "proposals": .array([.object(["status": .string("accepted")])])])])
        let actions = WorkflowActions.available(for: order, resource: .orders)
        #expect(actions.map(\.id).contains("replace-slot"))
        #expect(!actions.map(\.id).contains("proposal"))
        #expect(actions.first { $0.id == "replace-slot" }?.destructive == true)
    }

    @Test func allocationWithNullRentalCanBeUnassigned() {
        let order = record(["status": .string("approved"), "rental_term": .string("long_term"), "items": .array([.object([
            "order_item_id": .string("i1"), "quantity": .number(1),
            "allocations": .array([.object(["allocation_id": .string("a1"), "rental_id": .null])])
        ])])])
        let actions = WorkflowActions.available(for: order, resource: .orders)
        #expect(actions.contains { $0.id == "unassign-a1" && $0.isInline })
    }

    @Test func primaryFollowsWorkflowOrder() {
        let submitted = WorkflowActions.available(for: record(["status": .string("submitted")]), resource: .orders)
        #expect(WorkflowActions.primary(in: submitted)?.id == "approve")
        let approved = WorkflowActions.available(for: record(["status": .string("approved"), "rental_term": .string("long_term"), "unallocated_units": .number(2)]), resource: .orders)
        #expect(WorkflowActions.primary(in: approved)?.id == "assign")
        let checkup = WorkflowActions.available(for: record(["status": .string("checkup")]), resource: .returns)
        #expect(WorkflowActions.primary(in: checkup)?.id == "complete")
    }

    @Test func parsesEuroInputToCents() {
        #expect(WorkflowActions.parseCents("0") == 0)
        #expect(WorkflowActions.parseCents("12,5") == 1250)
        #expect(WorkflowActions.parseCents("12,50 €") == 1250)
        #expect(WorkflowActions.parseCents("1.234,56") == 123456)
        #expect(WorkflowActions.parseCents("12.05") == 1205)
        #expect(WorkflowActions.parseCents("12,505") == nil)
        #expect(WorkflowActions.parseCents("-3") == nil)
        #expect(WorkflowActions.parseCents("abc") == nil)
    }

    @Test func settleDepositSendsCentsAndNeedsReason() throws {
        let order = record(["status": .string("fulfilled"), "rental_term": .string("short_term"), "deposit": .object(["settleable": .bool(true), "held_cents": .number(10000)])])
        let action = try #require(WorkflowActions.available(for: order, resource: .orders).first { $0.id == "settle-deposit" })
        let (_, release) = try WorkflowActions.bodyAndPath(action: action, values: ["retained_cents": "0"])
        #expect(release?["retained_cents"]?.int == 0)
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: action, values: ["retained_cents": "25,00"]) }
        let (_, keep) = try WorkflowActions.bodyAndPath(action: action, values: ["retained_cents": "25,00", "note": "Kratzer"])
        #expect(keep?["retained_cents"]?.int == 2500)
    }

    @Test func proposalMustBeFutureAndAtMostOneDay() throws {
        let action = try #require(WorkflowActions.available(for: record(["status": .string("approved"), "rental_term": .string("long_term")]), resource: .orders).first { $0.id == "proposal" })
        let now = ISO8601DateFormatter().date(from: "2026-11-18T10:00:00Z")!
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: action, values: ["start_at": "2026-11-18T09:00:00Z", "end_at": "2026-11-18T11:00:00Z"], now: now) }
        #expect(throws: ValidationError.self) { try WorkflowActions.bodyAndPath(action: action, values: ["start_at": "2026-11-19T09:00:00Z", "end_at": "2026-11-20T10:00:00Z"], now: now) }
        let (_, body) = try WorkflowActions.bodyAndPath(action: action, values: ["start_at": "2026-11-19T09:00:00Z", "end_at": "2026-11-19T10:00:00Z"], now: now)
        #expect(body?["start_at"]?.string == "2026-11-19T09:00:00Z")
    }

    @Test func cancellationScheduleEscapesRentalID() throws {
        let action = try #require(WorkflowActions.available(for: record(["status": .string("open")]), resource: .cancellations).first { $0.id == "schedule" })
        let (path, _) = try WorkflowActions.bodyAndPath(action: action, values: ["rental_id": "abc/../x"])
        #expect(!path.contains("/../"))
    }

    @Test func unscheduledHandoverRuleTreatsNullAsMissing() {
        let order = record(["status": .string("approved"), "rental_term": .string("long_term"), "handover": .null])
        let alerts = DashboardAlerts.build(sources: ["orders": .array([order])], today: "2026-11-18")
        #expect(alerts.contains { $0.id == "handover-unscheduled" && $0.count == 1 })
        #expect(alerts.first { $0.id == "handover-unscheduled" }?.filter?.ruleID == "handover-unscheduled")
    }

    @Test func badgeCountsUniqueRecords() {
        // Matches both daily-due and daily-hold-lost; the sidebar must count it once.
        let order = record(["status": .string("approved"), "rental_term": .string("short_term"), "rental_start_date": .string("2026-11-18"), "rent_hold_lost": .bool(true)])
        let sources: [String: JSONValue] = ["orders": .array([order])]
        #expect(DashboardAlerts.actionableCount(resource: .orders, sources: sources, day: DayContext(today: "2026-11-18")) == 1)
        #expect(DashboardAlerts.build(sources: sources, today: "2026-11-18").filter { $0.destination == .orders }.count == 2)
    }

    @Test func dayContextComputesTomorrowAcrossMonth() {
        #expect(DayContext(today: "2026-11-30").tomorrow == "2026-12-01")
    }

    @Test func lifecycleStages() {
        let monthly = Lifecycle.of(record(["status": .string("ready_for_fulfillment")]), resource: .orders)
        #expect(monthly?.current == 2 && monthly?.exit == nil)
        let rejected = Lifecycle.of(record(["status": .string("rejected")]), resource: .orders)
        #expect(rejected?.exit == "rejected")
        let daily = Lifecycle.of(record(["status": .string("fulfilled"), "rental_term": .string("short_term"), "booking_handed_over_at": .string("2026-11-18T09:00:00Z")]), resource: .orders)
        #expect(daily?.stages[daily!.current] == "Abgeholt")
        let parcel = Lifecycle.of(record(["status": .string("scheduled"), "method": .string("parcel")]), resource: .returns)
        #expect(parcel?.stages[1] == "Label gesendet")
    }

    @Test func agendaEventsLinkToRecords() {
        let now = ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!
        let item: JSONValue = .object(["return_id": .string("r1"), "appointment": .object(["start_at": .string("2026-11-19T09:00:00Z")])])
        let events = CalendarEventMapper.events(sources: [.returns: [item]], now: now)
        #expect(events.first?.resource == .returns)
        #expect(events.first?.recordID == "r1")
    }
}
