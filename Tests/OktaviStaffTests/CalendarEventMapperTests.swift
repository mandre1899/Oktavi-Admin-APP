import Foundation
import Testing
@testable import OktaviStaff

@Suite("Calendar event mapping")
struct CalendarEventMapperTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!

    @Test func mapsScheduledHandover() throws {
        let order: JSONValue = .object([
            "order_id": .string("order-1"), "order_number": .string("O-100"), "rental_term": .string("long_term"),
            "customer": .object(["name": .string("Thilo Test")]),
            "handover": .object(["start_at": .string("2026-12-01T09:00:00Z"), "end_at": .string("2026-12-01T10:00:00Z")])
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: now)
        #expect(events.count == 1)
        #expect(events[0].id == "order-order-1-handover")
        #expect(events[0].title == "Übergabe Thilo Test")
    }

    @Test func mapsAcceptedHandoverProposal() throws {
        let order: JSONValue = .object([
            "id": .string("order-2"), "rental_term": .string("long_term"),
            "handover": .object(["proposals": .array([.object([
                "status": .string("accepted"), "start_at": .string("2026-12-02T09:00:00Z"), "end_at": .string("2026-12-02T10:00:00Z")
            ])])])
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: now)
        #expect(events.map(\.id) == ["order-order-2-handover"])
    }

    @Test func mapsDailyPickupAndReturnInBerlinTime() throws {
        let order: JSONValue = .object([
            "order_id": .string("daily-1"), "rental_term": .string("short_term"), "status": .string("approved"),
            "customer": .object(["name": .string("Clara Schumann")]),
            "rental_start_date": .string("2026-12-03"), "pickup_time": .string("10:30"),
            "rental_end_date": .string("2026-12-04"), "return_time": .string("17:00")
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: now)
        #expect(Set(events.map(\.id)) == Set(["order-daily-1-pickup", "order-daily-1-return"]))
        #expect(events.contains { $0.title == "Tagesmiete Clara Schumann abholen" })
    }

    @Test func multipleDailyOrdersDoNotCollide() throws {
        let first: JSONValue = .object([
            "order_id": .string("daily-a"), "rental_term": .string("short_term"), "status": .string("approved"),
            "rental_start_date": .string("2026-11-25"), "pickup_time": .string("10:00"),
            "rental_end_date": .string("2026-11-28"), "return_time": .string("13:30")
        ])
        let second: JSONValue = .object([
            "order_id": .string("daily-b"), "rental_term": .string("short_term"), "status": .string("approved"),
            "rental_start_date": .string("2026-11-25"), "pickup_time": .string("11:00"),
            "rental_end_date": .string("2026-11-27"), "return_time": .string("14:00")
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [first, second]], now: now)
        #expect(events.count == 4)
        #expect(Set(events.map(\.id)) == Set([
            "order-daily-a-pickup", "order-daily-a-return",
            "order-daily-b-pickup", "order-daily-b-return"
        ]))
    }

    @Test func cancelledDailyOrdersAreSkipped() {
        let order: JSONValue = .object([
            "order_id": .string("daily-x"), "rental_term": .string("short_term"), "status": .string("cancelled"),
            "rental_start_date": .string("2026-12-13"), "pickup_time": .string("11:00"),
            "rental_end_date": .string("2026-12-14"), "return_time": .string("14:00")
        ])
        let events = CalendarEventMapper.events(sources: [.orders: [order]], now: now)
        #expect(events.isEmpty)
    }

    @Test func dailyRentalEndComesFromOrderNotMinimumTerm() {
        let rental: JSONValue = .object([
            "rental_id": .string("rental-1"), "rental_term": .string("short_term"), "state": .string("cancellation_scheduled"),
            "booked_end_date": .string("2026-11-20"), "effective_end_date": .string("2027-02-16")
        ])
        let events = CalendarEventMapper.events(sources: [.rentals: [rental]], now: now)
        #expect(events.isEmpty)
    }

    @Test func monthlyCancellationEndIsAllDay() throws {
        let rental: JSONValue = .object([
            "rental_id": .string("rental-2"), "rental_term": .string("long_term"), "state": .string("cancellation_scheduled"),
            "effective_end_date": .string("2027-02-16"),
            "customer": .object(["name": .string("Thilo Test")])
        ])
        let events = CalendarEventMapper.events(sources: [.rentals: [rental]], now: now)
        #expect(events.count == 1)
        #expect(events[0].id == "rental-rental-2-end")
        #expect(events[0].title == "Mietende Thilo Test")
        #expect(events[0].isAllDay)
    }

    @Test func excludesPastEvents() throws {
        let item: JSONValue = .object([
            "return_id": .string("return-1"), "appointment": .object(["start_at": .string("2025-01-01T10:00:00Z"), "end_at": .string("2025-01-01T11:00:00Z")])
        ])
        let events = CalendarEventMapper.events(sources: [.returns: [item]], now: now)
        #expect(events.isEmpty)
    }
}
