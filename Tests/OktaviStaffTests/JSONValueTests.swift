import Foundation
import Testing
@testable import OktaviStaff

@Suite("Dynamic API values")
struct JSONValueTests {
    @Test func decodesNestedAPIResponse() throws {
        let data = Data(#"{"id":"1","deposit":{"settleable":true},"amount_cents":1200}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["id"]?.string == "1")
        #expect(value.value(at: "deposit.settleable")?.bool == true)
        #expect(value["amount_cents"]?.int == 1200)
    }

    @Test func extractsResourceSpecificIDs() {
        let order: JSONValue = .object(["order_id": .string("o-1")])
        let rental: JSONValue = .object(["rental_id": .string("r-1")])
        let deposit: JSONValue = .object(["deposit_id": .string("d-1")])
        let customer: JSONValue = .object(["user_id": .string("u-1")])
        #expect(order.id == "o-1")
        #expect(rental.id == "r-1")
        #expect(deposit.id == "d-1")
        #expect(customer.id == "u-1")
    }
}
