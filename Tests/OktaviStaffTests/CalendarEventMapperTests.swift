import Foundation
import Testing
@testable import OktaviStaff

@Suite("Calendar event mapping")
struct CalendarEventMapperTests {
    @Test func mapsScheduledHandover() throws {
        let order: JSONValue = .object([
            "id": .string("order-1"), "order_number": .string("O-100"), "term": .string("long_term"),
            "handover": .object(["start_at": .string("2026-12-01T09:00:00Z"), "end_at": .string("2026-12-01T10:00:00Z")])
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: try #require(ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")))
        #expect(events.count == 1)
        #expect(events[0].id == "order-order-1-handover")
        #expect(events[0].title == "Übergabe O-100")
    }

    @Test func mapsAcceptedHandoverProposal() throws {
        let order: JSONValue = .object([
            "id": .string("order-2"), "term": .string("long_term"),
            "handover": .object(["proposals": .array([.object([
                "status": .string("accepted"), "start_at": .string("2026-12-02T09:00:00Z"), "end_at": .string("2026-12-02T10:00:00Z")
            ])])])
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: try #require(ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")))
        #expect(events.map(\.id) == ["order-order-2-handover"])
    }

    @Test func mapsDailyPickupAndReturnInBerlinTime() throws {
        let order: JSONValue = .object([
            "id": .string("daily-1"), "order_number": .string("T-20"), "term": .string("short_term"),
            "rental_start_date": .string("2026-12-03"), "pickup_time": .string("10:30"),
            "rental_end_date": .string("2026-12-04"), "return_time": .string("17:00")
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: try #require(ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")))
        #expect(Set(events.map(\.id)) == Set(["order-daily-1-pickup", "order-daily-1-return"]))
    }

    @Test func excludesPastEvents() throws {
        let item: JSONValue = .object([
            "id": .string("return-1"), "appointment": .object(["start_at": .string("2025-01-01T10:00:00Z"), "end_at": .string("2025-01-01T11:00:00Z")])
        ])
        let events = CalendarEventMapper.events(sources: [.returns: [item]], now: try #require(ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")))
        #expect(events.isEmpty)
    }
}
