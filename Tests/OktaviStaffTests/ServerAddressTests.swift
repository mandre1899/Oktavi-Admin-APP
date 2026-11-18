import Testing
@testable import OktaviStaff

@Suite("Server domain input")
struct ServerAddressTests {
    @Test func acceptsBareDomain() throws {
        let server = try ServerAddress.parse("dev.oktavi.de")
        #expect(server.url.absoluteString == "https://dev.oktavi.de/")
        #expect(server.domain == "dev.oktavi.de")
    }

    @Test func preservesExplicitSchemeAndPort() throws {
        let server = try ServerAddress.parse("http://localhost:8080")
        #expect(server.url.absoluteString == "http://localhost:8080/")
        #expect(server.domain == "localhost:8080")
    }

    @Test func rejectsPathsAndCredentials() {
        #expect(throws: ValidationError.self) { try ServerAddress.parse("https://oktavi.de/admin") }
        #expect(throws: ValidationError.self) { try ServerAddress.parse("https://user:password@oktavi.de") }
    }
}
