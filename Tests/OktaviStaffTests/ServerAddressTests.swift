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

@Suite("Environment presets")
struct ServerPresetTests {
    @Test func presetsResolveToTheirFixedDomain() {
        #expect(ServerPreset.production.resolvedDomain(custom: "ignored") == "oktavi.de")
        #expect(ServerPreset.staging.resolvedDomain(custom: "") == "dev.oktavi.de")
    }

    @Test func customPresetUsesTypedDomainOnlyWhenValid() {
        #expect(ServerPreset.custom.resolvedDomain(custom: "  localhost:8080 ") == "localhost:8080")
        #expect(ServerPreset.custom.resolvedDomain(custom: "") == nil)
        #expect(ServerPreset.custom.resolvedDomain(custom: "https://oktavi.de/admin") == nil)
    }
}
