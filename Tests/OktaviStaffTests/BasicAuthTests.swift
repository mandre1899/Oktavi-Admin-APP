import Foundation
import Testing
@testable import OktaviStaff

@Suite("Basic auth in front of the API")
struct BasicAuthTests {
    private let login = BasicAuthCredentials(username: "staff", password: "s3cret")

    private func client(host: String, basicAuth: BasicAuthCredentials?) async -> APIClient {
        let keys = MemoryKeyStore()
        await keys.set("okt_test", basicAuth: basicAuth)
        return APIClient(baseURL: URL(string: "https://\(host)/")!, keyStore: keys, protocolClasses: [CaddyStubProtocol.self])
    }

    @Test func headerIsStandardBasicAuth() {
        #expect(login.headerValue == "Basic c3RhZmY6czNjcmV0")
    }

    @Test func sendsTheLoginAndTheKey() async throws {
        let response = try await client(host: "caddy.test", basicAuth: login).request("auth/me")
        #expect(response?["email"]?.string == "staff@oktavi.test")
    }

    @Test func missingLoginIsReportedAsBasicAuthNotAsRevokedKey() async {
        await #expect(throws: BasicAuthError.required) {
            _ = try await client(host: "caddy.test", basicAuth: nil).request("auth/me")
        }
    }

    @Test func wrongLoginIsRejected() async {
        await #expect(throws: BasicAuthError.rejected) {
            _ = try await client(host: "caddy.test", basicAuth: BasicAuthCredentials(username: "staff", password: "wrong")).request("auth/me")
        }
    }

    @Test func apiUnauthorizedStaysAnAPIError() async {
        do {
            _ = try await client(host: "api.test", basicAuth: nil).request("auth/me")
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.status == 401)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func inputNeedsBothFieldsAndNoColon() {
        #expect(BasicAuthInput.credentials(username: " staff ", password: "pw") == BasicAuthCredentials(username: "staff", password: "pw"))
        #expect(BasicAuthInput.credentials(username: "staff", password: "") == nil)
        #expect(BasicAuthInput.credentials(username: "st:aff", password: "pw") == nil)
    }

    @Test func vaultPayloadKeepsTheLoginAndReadsOldEnvelopes() throws {
        let payload = VaultPayload(apiKey: "okt_abc", basicAuth: login)
        #expect(try VaultPayload.decode(payload.encoded()) == payload)
        #expect(try VaultPayload.decode(Data("okt_legacy".utf8)) == VaultPayload(apiKey: "okt_legacy", basicAuth: nil))
    }
}

/// `caddy.test` acts like Caddy's `basic_auth` (staff / s3cret) in front of the API;
/// `api.test` is the API alone answering 401 without a basic-auth challenge.
final class CaddyStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status: Int
        var headers = ["Content-Type": "application/json"]
        var body = Data("{}".utf8)
        if url.host == "caddy.test" {
            if request.value(forHTTPHeaderField: "Authorization") == "Basic c3RhZmY6czNjcmV0",
               request.value(forHTTPHeaderField: "X-API-Key") == "okt_test" {
                status = 200
                body = Data(#"{"email":"staff@oktavi.test"}"#.utf8)
            } else {
                status = 401
                headers["WWW-Authenticate"] = #"Basic realm="restricted""#
            }
        } else {
            status = 401
            body = Data(#"{"error":{"code":"unauthorized","message":"invalid key"}}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
