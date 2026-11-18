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
}
