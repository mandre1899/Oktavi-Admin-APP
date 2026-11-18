import Testing
@testable import OktaviStaff

@Suite("Credential vault: one key per environment")
struct CredentialVaultTests {
    @Test func everyEnvironmentHasItsOwnStableAccount() {
        let production = CredentialVault.account(for: "https://oktavi.de/")
        let staging = CredentialVault.account(for: "https://dev.oktavi.de/")
        #expect(production != staging)
        #expect(production == CredentialVault.account(for: "https://oktavi.de/"))
        #expect(production.hasPrefix("api-key-v2:"))
    }

    @Test func accountDoesNotNameTheEnvironment() {
        #expect(!CredentialVault.account(for: "https://dev.oktavi.de/").contains("oktavi"))
    }
}
