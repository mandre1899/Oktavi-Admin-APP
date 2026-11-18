import Foundation

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }

struct APIError: LocalizedError, Sendable {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? { ErrorTranslations.translate(code: code, fallback: message) }
}

enum ErrorTranslations {
    private static let values: [String: String] = [
        "ambiguous_credentials": "Mehrere Anmeldedaten wurden gesendet.",
        "forbidden": "Keine Berechtigung.",
        "unauthorized": "Der API-Schlüssel ist ungültig oder abgelaufen.",
        "not_found": "Der Eintrag wurde nicht gefunden.",
        "conflict": "Der Eintrag wurde zwischenzeitlich geändert.",
        "service_unavailable": "Der Dienst ist momentan nicht verfügbar.",
        "validation_failed": "Die Angaben sind ungültig."
    ]

    static func translate(code: String, fallback: String) -> String {
        values[code] ?? (fallback.isEmpty ? "Unbekannter API-Fehler." : fallback)
    }
}

actor MemoryKeyStore {
    private var key: String?
    func set(_ value: String) { key = value }
    func get() -> String? { key }
    func clear() { key = nil }
}

struct APIClient: Sendable {
    let baseURL: URL
    let keyStore: MemoryKeyStore
    private let session: URLSession

    init(baseURL: URL, keyStore: MemoryKeyStore, protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        self.keyStore = keyStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    func request(
        _ path: String,
        method: HTTPMethod = .get,
        query: [URLQueryItem] = [],
        body: JSONValue? = nil,
        idempotencyKey: String? = nil
    ) async throws -> JSONValue? {
        guard let key = await keyStore.get() else {
            throw APIError(status: 401, code: "unauthorized", message: "App ist gesperrt.")
        }
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if (200..<300).contains(http.statusCode) {
            return data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data)
        }
        throw Self.decodeError(data: data, status: http.statusCode)
    }

    func validate(key: String) async throws -> JSONValue {
        await keyStore.set(key)
        do {
            guard let response = try await request("auth/me") else { throw URLError(.badServerResponse) }
            return response
        } catch {
            await keyStore.clear()
            throw error
        }
    }

    private static func decodeError(data: Data, status: Int) -> APIError {
        let payload = try? JSONDecoder().decode(JSONValue.self, from: data)
        let envelope = payload?["error"] ?? payload
        let code = envelope?["code"]?.string ?? (status == 401 ? "unauthorized" : status == 403 ? "forbidden" : "http_\(status)")
        let message = envelope?["message"]?.string ?? "HTTP \(status)"
        return APIError(status: status, code: code, message: message)
    }
}
