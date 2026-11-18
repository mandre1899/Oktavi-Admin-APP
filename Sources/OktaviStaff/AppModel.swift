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

/// Signed out means the login screen: pick an environment, then unlock its key or set one up.
enum AuthenticationState: Equatable { case signedOut, unlocked(VaultMetadata) }

@MainActor @Observable
final class AppModel {
    private(set) var authState: AuthenticationState = .signedOut
    var errorMessage: String?
    var failedUnlocks = 0
    var retryAfter: Date?
    private(set) var server: ServerAddress
    /// Whether the unlocked environment is reached through basic auth (shown in the settings).
    private(set) var usesBasicAuth = false

    let keyStore = MemoryKeyStore()
    /// Per-session state, recreated on every lock so nothing loaded survives it.
    private(set) var navigator = StaffNavigator()
    private(set) var queue = WorkQueue()
    let references = ReferenceCache()
    let images = ImageStore()
    let calendarSynchronizer = CalendarSynchronizer()
    private(set) var client: APIClient
    private let vault: CredentialVault
    private var inactivityTask: Task<Void, Never>?
    private var hiddenAt: Date?
    private var loadedDataClearers: [UUID: @MainActor () -> Void] = [:]

    init(vault: CredentialVault = .shared) {
        let initialServer = ServerAddress(url: URL(string: "https://oktavi.de/")!)
        server = initialServer
        self.vault = vault
        client = APIClient(baseURL: initialServer.url, keyStore: keyStore)
    }

    func selectServer(_ input: String) throws {
        let selected = try ServerAddress.parse(input)
        server = selected
        client = APIClient(baseURL: selected.url, keyStore: keyStore)
    }

    /// What this Mac holds for an environment, which decides between unlock and setup.
    func credential(for domain: String) async throws -> StoredCredential {
        try await vault.credential(origin: ServerAddress.parse(domain).url.absoluteString)
    }

    func setup(apiKey: String, basicAuth: BasicAuthCredentials?, password: String, domain: String) async throws {
        guard password.count >= 10 else { throw ValidationError("Das App-Passwort muss mindestens 10 Zeichen lang sein.") }
        try selectServer(domain)
        guard apiKey.hasPrefix("okt_") else { throw ValidationError("Der API-Schlüssel muss mit okt_ beginnen.") }
        let me = try await client.validate(key: apiKey, basicAuth: basicAuth)
        let email = me["email"]?.string ?? "Admin"
        let metadata = VaultMetadata(prefix: String(apiKey.prefix(12)), email: email, createdAt: .now)
        try await vault.save(apiKey: apiKey, basicAuth: basicAuth, password: password, metadata: metadata, origin: server.url.absoluteString)
        usesBasicAuth = basicAuth != nil
        authState = .unlocked(metadata)
        resetInactivityTimer()
        synchronizeCalendarIfEnabled()
    }

    /// `basicAuth` replaces the stored basic-auth login; it is saved once the server accepts it.
    func unlock(password: String, domain: String, basicAuth: BasicAuthCredentials? = nil) async throws {
        if let retryAfter, retryAfter > .now { throw ValidationError("Bitte noch \(Int(retryAfter.timeIntervalSinceNow.rounded(.up))) Sekunden warten.") }
        try selectServer(domain)
        let credential: UnlockedCredential
        do {
            credential = try await vault.unlock(password: password, origin: server.url.absoluteString)
        } catch {
            failedUnlocks += 1
            if failedUnlocks >= 5 { retryAfter = .now.addingTimeInterval(30) }
            throw error
        }
        do {
            let effectiveBasicAuth = basicAuth ?? credential.basicAuth
            await keyStore.set(credential.apiKey, basicAuth: effectiveBasicAuth)
            guard let me = try await client.request("auth/me") else { throw URLError(.badServerResponse) }
            failedUnlocks = 0
            retryAfter = nil
            let metadata = VaultMetadata(prefix: credential.metadata.prefix, email: credential.metadata.email, createdAt: credential.metadata.createdAt)
            if let basicAuth, basicAuth != credential.basicAuth {
                try? await vault.save(apiKey: credential.apiKey, basicAuth: basicAuth, password: password, metadata: metadata, origin: server.url.absoluteString)
            }
            usesBasicAuth = effectiveBasicAuth != nil
            authState = .unlocked(VaultMetadata(
                prefix: metadata.prefix,
                email: me["email"]?.string ?? metadata.email,
                createdAt: metadata.createdAt
            ))
            resetInactivityTimer()
            synchronizeCalendarIfEnabled()
        } catch {
            await keyStore.clear()
            if let apiError = error as? APIError, apiError.status == 401 {
                try? await vault.remove(origin: server.url.absoluteString)
                errorMessage = "Schlüssel widerrufen oder abgelaufen; bitte einen neuen Schlüssel eingeben."
            }
            throw error
        }
    }

    func lock() {
        inactivityTask?.cancel()
        Task { await keyStore.clear() }
        loadedDataClearers.values.forEach { $0() }
        navigator = StaffNavigator()
        queue = WorkQueue()
        references.clear()
        images.clear()
        usesBasicAuth = false
        authState = .signedOut
    }

    /// Removes the key of `domain`, or of the current environment when unlocked.
    func removeCredential(domain: String? = nil) async throws {
        lock()
        if let domain { try selectServer(domain) }
        try await vault.remove(origin: server.url.absoluteString)
        failedUnlocks = 0
        retryAfter = nil
    }

    func changePassword(current: String, new: String) async throws {
        guard new.count >= 10 else { throw ValidationError("Das neue Passwort muss mindestens 10 Zeichen lang sein.") }
        let credential = try await vault.unlock(password: current, origin: server.url.absoluteString)
        let metadata = credential.metadata
        let sanitizedMetadata = VaultMetadata(prefix: metadata.prefix, email: metadata.email, createdAt: metadata.createdAt)
        try await vault.save(apiKey: credential.apiKey, basicAuth: credential.basicAuth, password: new, metadata: sanitizedMetadata, origin: server.url.absoluteString)
    }

    func userActivity() { if case .unlocked = authState { resetInactivityTimer() } }

    func sceneBecameInactive() { hiddenAt = .now }

    func sceneBecameActive() {
        if let hiddenAt, Date().timeIntervalSince(hiddenAt) > 120 { lock() }
        self.hiddenAt = nil
    }

    /// Only a 401 is global: the key was revoked or expired, so lock and ask for a new one.
    /// Every other error is shown inline by the screen that made the request.
    func handleAuthFailure(_ error: Error) {
        guard let apiError = error as? APIError, apiError.status == 401, case .unlocked = authState else { return }
        Task { try? await removeCredential() }
        errorMessage = "Schlüssel widerrufen oder abgelaufen; bitte einen neuen Schlüssel eingeben."
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
