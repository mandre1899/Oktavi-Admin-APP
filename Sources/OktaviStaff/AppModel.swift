import AppKit
import Foundation
import Observation

struct ServerAddress: Equatable, Sendable {
    let url: URL

    var domain: String {
        guard let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func parse(_ input: String) throws -> ServerAddress {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ValidationError("Bitte eine Domain eingeben.") }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard var components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ValidationError("Bitte nur eine gültige Domain eingeben, zum Beispiel dev.oktavi.de.")
        }
        components.path = "/"
        guard let url = components.url else { throw ValidationError("Die Domain ist ungültig.") }
        return ServerAddress(url: url)
    }
}

enum AuthenticationState: Equatable { case loading, setup, locked(VaultMetadata), unlocked(VaultMetadata) }

@MainActor @Observable
final class AppModel {
    private(set) var authState: AuthenticationState = .loading
    var errorMessage: String?
    var failedUnlocks = 0
    var retryAfter: Date?
    private(set) var server: ServerAddress

    let keyStore = MemoryKeyStore()
    let calendarSynchronizer = CalendarSynchronizer()
    private(set) var client: APIClient
    private let vault: CredentialVault
    private var inactivityTask: Task<Void, Never>?
    private var hiddenAt: Date?
    private var loadedDataClearers: [UUID: @MainActor () -> Void] = [:]

    init(vault: CredentialVault = .shared) {
        let fallback: String
        switch UserDefaults.standard.string(forKey: "environment") {
        case "staging": fallback = "https://dev.oktavi.de/"
        case "local": fallback = "https://localhost/"
        default: fallback = "https://oktavi.de/"
        }
        let saved = UserDefaults.standard.string(forKey: "serverOrigin") ?? fallback
        server = (try? ServerAddress.parse(saved)) ?? ServerAddress(url: URL(string: "https://oktavi.de/")!)
        self.vault = vault
        client = APIClient(baseURL: server.url, keyStore: keyStore)
        Task { await loadState() }
    }

    func selectServer(_ input: String) throws {
        let selected = try ServerAddress.parse(input)
        server = selected
        client = APIClient(baseURL: selected.url, keyStore: keyStore)
        UserDefaults.standard.set(selected.url.absoluteString, forKey: "serverOrigin")
    }

    func loadState() async {
        do {
            if let metadata = try await vault.metadata() { authState = .locked(metadata) }
            else { authState = .setup }
        } catch {
            errorMessage = error.localizedDescription
            authState = .setup
        }
    }

    func setup(apiKey: String, password: String, domain: String) async throws {
        guard password.count >= 10 else { throw ValidationError("Das App-Passwort muss mindestens 10 Zeichen lang sein.") }
        try selectServer(domain)
        let host = server.url.host?.lowercased()
        if host == "oktavi.de", !apiKey.hasPrefix("okt_live_") { throw ValidationError("Für oktavi.de ist ein Live-Schlüssel erforderlich.") }
        if host == "dev.oktavi.de" || host == "localhost", !apiKey.hasPrefix("okt_test_") { throw ValidationError("Für diese Domain ist ein Test-Schlüssel erforderlich.") }
        guard apiKey.hasPrefix("okt_live_") || apiKey.hasPrefix("okt_test_") else { throw ValidationError("Das Format des API-Schlüssels ist ungültig.") }
        let me = try await client.validate(key: apiKey)
        let roles = me["roles"]?.array?.compactMap(\.string) ?? []
        guard roles.contains("admin") else {
            await keyStore.clear()
            throw APIError(status: 403, code: "forbidden", message: "Keine Admin-Berechtigung.")
        }
        let email = me["email"]?.string ?? "Admin"
        let metadata = VaultMetadata(prefix: String(apiKey.prefix(12)), email: email, createdAt: .now, origin: server.url.absoluteString)
        try await vault.save(apiKey: apiKey, password: password, metadata: metadata, origin: server.url.absoluteString)
        authState = .unlocked(metadata)
        resetInactivityTimer()
        synchronizeCalendarIfEnabled()
    }

    func unlock(password: String, domain: String) async throws {
        if let retryAfter, retryAfter > .now { throw ValidationError("Bitte noch \(Int(retryAfter.timeIntervalSinceNow.rounded(.up))) Sekunden warten.") }
        try selectServer(domain)
        let key: String
        do {
            key = try await vault.unlock(password: password, origin: server.url.absoluteString)
        } catch {
            failedUnlocks += 1
            if failedUnlocks >= 5 { retryAfter = .now.addingTimeInterval(30) }
            throw error
        }
        do {
            await keyStore.set(key)
            guard let me = try await client.request("auth/me") else { throw URLError(.badServerResponse) }
            guard me["roles"]?.array?.compactMap(\.string).contains("admin") == true else {
                throw APIError(status: 403, code: "forbidden", message: "Keine Admin-Berechtigung.")
            }
            failedUnlocks = 0
            retryAfter = nil
            let metadata = try await vault.metadata() ?? VaultMetadata(prefix: String(key.prefix(12)), email: me["email"]?.string ?? "Admin", createdAt: .now, origin: server.url.absoluteString)
            authState = .unlocked(metadata)
            resetInactivityTimer()
            synchronizeCalendarIfEnabled()
        } catch {
            await keyStore.clear()
            if let apiError = error as? APIError, apiError.status == 401 {
                try? await vault.remove()
                authState = .setup
            }
            throw error
        }
    }

    func lock() {
        inactivityTask?.cancel()
        Task { await keyStore.clear() }
        loadedDataClearers.values.forEach { $0() }
        if case .unlocked(let metadata) = authState { authState = .locked(metadata) }
    }

    func removeCredential() async throws {
        lock()
        try await vault.remove()
        failedUnlocks = 0
        authState = .setup
    }

    func changePassword(current: String, new: String) async throws {
        guard new.count >= 10 else { throw ValidationError("Das neue Passwort muss mindestens 10 Zeichen lang sein.") }
        let key = try await vault.unlock(password: current, origin: server.url.absoluteString)
        guard let metadata = try await vault.metadata() else { throw VaultError.noCredential }
        try await vault.save(apiKey: key, password: new, metadata: metadata, origin: server.url.absoluteString)
    }

    func userActivity() { if case .unlocked = authState { resetInactivityTimer() } }

    func sceneBecameInactive() { hiddenAt = .now }

    func sceneBecameActive() {
        if let hiddenAt, Date().timeIntervalSince(hiddenAt) > 120 { lock() }
        self.hiddenAt = nil
    }

    func handle(_ error: Error) {
        if let apiError = error as? APIError, apiError.status == 401 {
            Task { try? await removeCredential() }
            errorMessage = "Schlüssel widerrufen oder abgelaufen; bitte einen neuen Schlüssel eingeben."
        } else { errorMessage = error.localizedDescription }
    }

    func registerDataClearer(_ clear: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); loadedDataClearers[id] = clear; return id
    }
    func unregisterDataClearer(_ id: UUID) { loadedDataClearers.removeValue(forKey: id) }

    private func resetInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    private func synchronizeCalendarIfEnabled() {
        guard calendarSynchronizer.automaticSync else { return }
        Task { _ = try? await calendarSynchronizer.synchronize(client: client) }
    }
}

struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
