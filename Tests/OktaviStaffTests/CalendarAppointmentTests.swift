import Foundation
import Testing
@testable import OktaviStaff

@Suite("Calendar: accepted appointments")
struct CalendarAppointmentTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!

    private func order(_ proposalStatus: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "order_id": .string("o1"), "order_number": .string("O-7"), "rental_term": .string("long_term"), "status": .string("approved"),
            "customer": .object(["name": .string("Clara Schumann"), "phone": .string("+49 30 1")]),
            "handover": .object(["proposals": .array([.object([
                "status": .string(proposalStatus), "start_at": .string("2026-11-25T14:00:00Z"), "end_at": .string("2026-11-25T15:00:00Z"), "note": .string("Klingel Hinterhaus")
            ])])])
        ].merging(extra) { _, new in new })
    }

    @Test func pendingOrDeclinedSlotsStayOutOfTheCalendar() {
        #expect(CalendarEventMapper.events(sources: [.orders: [order("pending")]], now: now).isEmpty)
        #expect(CalendarEventMapper.events(sources: [.orders: [order("declined")]], now: now).isEmpty)
        // A scheduled fulfillment does not count while a new proposal waits for the customer.
        let waiting = order("pending", extra: ["handover_proposal_status": .string("accepted")])
        #expect(CalendarEventMapper.events(sources: [.orders: [waiting]], now: now).isEmpty)
    }

    @Test func acceptedDeliveryCarriesInstrumentAndAddress() throws {
        let delivery = order("accepted", extra: [
            "in_person": .bool(false), "delivery_option_name": .string("Lieferung Berlin"),
            "delivery_address": .object(["street": .string("Hauptstr. 1"), "postal_code": .string("10115"), "city": .string("Berlin")]),
            "items": .array([.object(["instrument_type_name": .string("Violine"), "size": .string("3/4"), "quantity": .number(1),
                                      "allocations": .array([.object(["serial_number": .string("VL-0815")])])])])
        ])
        let event = try #require(CalendarEventMapper.events(sources: [.orders: [delivery]], now: now).first)
        #expect(event.title == "Lieferung: Clara Schumann · Violine 3/4")
        #expect(event.location == "Hauptstr. 1, 10115 Berlin")
        #expect(event.notes.contains("Zugewiesen: VL-0815"))
        #expect(event.notes.contains("Notiz zum Termin: Klingel Hinterhaus"))
        #expect(event.notes.contains("+49 30 1"))
        #expect(event.start == ISO8601DateFormatter().date(from: "2026-11-25T14:00:00Z"))
    }

    @Test func inPersonHandoverHasNoLocation() throws {
        let shop = order("accepted", extra: ["in_person": .bool(true), "delivery_address": .object(["street": .string("X"), "city": .string("Y")]),
                                             "first_instrument_name": .string("Cello"), "first_instrument_size": .string("1/2")])
        let event = try #require(CalendarEventMapper.events(sources: [.orders: [shop]], now: now).first)
        #expect(event.title == "Übergabe im Laden: Clara Schumann · Cello 1/2")
        #expect(event.location == nil)
    }

    @Test func handedOverOrderDropsItsEvent() {
        let done = order("accepted", extra: ["status": .string("fulfilled")])
        #expect(CalendarEventMapper.events(sources: [.orders: [done]], now: now).isEmpty)
    }

    @Test func returnPickupUsesPickupAddress() throws {
        let item: JSONValue = .object([
            "return_id": .string("x1"), "status": .string("scheduled"), "method": .string("pickup"),
            "customer": .object(["name": .string("Thilo Test")]),
            "instrument": .object(["instrument_type_name": .string("Gitarre"), "serial_number": .string("G-1")]),
            "pickup_address": .object(["street": .string("Ring 5"), "postal_code": .string("12043"), "city": .string("Berlin")]),
            "appointment": .object(["start_at": .string("2026-11-26T09:00:00Z"), "end_at": .string("2026-11-26T10:00:00Z")])
        ])
        let event = try #require(CalendarEventMapper.events(sources: [.returns: [item]], now: now).first)
        #expect(event.title == "Rückgabe abholen: Thilo Test · Gitarre · Nr. G-1")
        #expect(event.location == "Ring 5, 12043 Berlin")
        let received = item.merging(["status": .string("received")])
        #expect(CalendarEventMapper.events(sources: [.returns: [received]], now: now).isEmpty)
    }

    @Test func detailsAreLoadedForAgreedHandovers() async throws {
        let detail: JSONValue = .object(["order_id": .string("o1"), "items": .array([.object(["instrument_type_name": .string("Violine"), "size": .string("4/4")])]),
                                         "delivery_address": .object(["street": .string("Hauptstr. 1"), "postal_code": .string("10115"), "city": .string("Berlin")])])
        StubProtocol.responses = ["/api/v1/admin/orders/o1": try JSONEncoder().encode(detail)]
        let keys = MemoryKeyStore()
        await keys.set("okt_test_stub")
        let client = APIClient(baseURL: URL(string: "https://staff.test/")!, keyStore: keys, protocolClasses: [StubProtocol.self])
        let iso = ISO8601DateFormatter()
        let start = Date.now.addingTimeInterval(30 * 86_400)
        let upcoming = order("accepted").merging(["handover": .object(["proposals": .array([.object([
            "status": .string("accepted"), "start_at": .string(iso.string(from: start)), "end_at": .string(iso.string(from: start.addingTimeInterval(3600)))
        ])])])])
        let enriched = await CalendarSynchronizer.withDetails([.orders: [upcoming]], client: client)
        let event = try #require(CalendarEventMapper.events(sources: enriched).first)
        #expect(event.title == "Lieferung: Clara Schumann · Violine 4/4")
        #expect(event.location == "Hauptstr. 1, 10115 Berlin")
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let data = Self.responses[path]
        let response = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
