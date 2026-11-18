import Foundation

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

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
        "validation_failed": "Die Angaben sind ungültig.",
        "bad_request": "Die Angaben sind ungültig.",
        "payload_too_large": "Die Datei ist zu groß (höchstens 10 MiB).",
        "unsupported_media_type": "Nur JPEG-, PNG- oder WebP-Bilder sind erlaubt.",
        "http_409": "Der Eintrag wird noch verwendet oder wurde zwischenzeitlich geändert.",
        "http_413": "Die Datei ist zu groß (höchstens 10 MiB).",
        "http_500": "Interner Serverfehler. Bitte später erneut versuchen.",
        "http_503": "Der Dienst ist momentan nicht verfügbar. Bitte erneut versuchen."
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
        var request = try await makeRequest(path, method: method, query: query, accept: "application/json")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try await send(request)
        return data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Image bytes for `/api/v1/media/:id` and `/api/v1/admin/media-files/:id/content`. Kept in memory only.
    func data(_ path: String) async throws -> Data {
        try await send(try await makeRequest(path, method: .get, query: [], accept: "image/*"))
    }

    /// `multipart/form-data` upload with a single `file` field (condition and shop images).
    func upload(_ path: String, file: Data, filename: String, contentType: String) async throws -> JSONValue? {
        var request = try await makeRequest(path, method: .post, query: [], accept: "application/json")
        let boundary = "oktavi-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = filename.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let data = try await send(request)
        return data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Resolves a stored image reference (`/api/v1/media/<id>` or an absolute URL on the API origin) to a path.
    /// Other origins are refused: only the two Oktavi image routes are image sources.
    func mediaPath(for reference: String) -> String? {
        if reference.hasPrefix("/") { return String(reference.dropFirst()) }
        guard let url = URL(string: reference), url.host == baseURL.host, url.port == baseURL.port else { return nil }
        return String(url.path.dropFirst())
    }

    private func makeRequest(_ path: String, method: HTTPMethod, query: [URLQueryItem], accept: String) async throws -> URLRequest {
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
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw Self.decodeError(data: data, status: http.statusCode) }
        return data
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
