import AppKit
import Foundation
import Observation

enum AppEnvironment: String, CaseIterable, Identifiable, Codable {
    case production, staging, local
    var id: String { rawValue }
    var title: String { switch self { case .production: "Produktion"; case .staging: "Staging"; case .local: "Lokal" } }
    var baseURL: URL {
        switch self {
        case .production: URL(string: "https://oktavi.de/")!
        case .staging: URL(string: "https://dev.oktavi.de/")!
        case .local: URL(string: "https://localhost/")!
        }
    }
    var requiredPrefix: String { self == .production ? "okt_live_" : "okt_test_" }
}

enum AuthenticationState: Equatable { case loading, setup, locked(VaultMetadata), unlocked(VaultMetadata) }

@MainActor @Observable
final class AppModel {
    private(set) var authState: AuthenticationState = .loading
    var errorMessage: String?
    var failedUnlocks = 0
    var retryAfter: Date?
    var environment: AppEnvironment {
        didSet { UserDefaults.standard.set(environment.rawValue, forKey: "environment") }
    }

    let keyStore = MemoryKeyStore()
    let calendarSynchronizer = CalendarSynchronizer()
    private(set) var client: APIClient
    private let vault: CredentialVault
    private var inactivityTask: Task<Void, Never>?
    private var hiddenAt: Date?
    private var loadedDataClearers: [UUID: @MainActor () -> Void] = [:]

    init(vault: CredentialVault = .shared) {
        let saved = UserDefaults.standard.string(forKey: "environment").flatMap(AppEnvironment.init(rawValue:)) ?? .production
        environment = saved
        self.vault = vault
        client = APIClient(baseURL: saved.baseURL, keyStore: keyStore)
        Task { await loadState() }
    }

    func selectEnvironment(_ value: AppEnvironment) {
        environment = value
        client = APIClient(baseURL: value.baseURL, keyStore: keyStore)
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

    func setup(apiKey: String, password: String) async throws {
        guard password.count >= 10 else { throw ValidationError("Das App-Passwort muss mindestens 10 Zeichen lang sein.") }
        guard apiKey.hasPrefix(environment.requiredPrefix) else { throw ValidationError("Der Schlüssel gehört nicht zu dieser Umgebung.") }
        let me = try await client.validate(key: apiKey)
        let roles = me["roles"]?.array?.compactMap(\.string) ?? []
        guard roles.contains("admin") else {
            await keyStore.clear()
            throw APIError(status: 403, code: "forbidden", message: "Keine Admin-Berechtigung.")
        }
        let email = me["email"]?.string ?? "Admin"
        let metadata = VaultMetadata(prefix: String(apiKey.prefix(12)), email: email, createdAt: .now)
        try await vault.save(apiKey: apiKey, password: password, metadata: metadata, origin: environment.baseURL.absoluteString)
        authState = .unlocked(metadata)
        resetInactivityTimer()
        synchronizeCalendarIfEnabled()
    }

    func unlock(password: String) async throws {
        if let retryAfter, retryAfter > .now { throw ValidationError("Bitte noch \(Int(retryAfter.timeIntervalSinceNow.rounded(.up))) Sekunden warten.") }
        let key: String
        do {
            key = try await vault.unlock(password: password, origin: environment.baseURL.absoluteString)
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
            let metadata = try await vault.metadata() ?? VaultMetadata(prefix: String(key.prefix(12)), email: me["email"]?.string ?? "Admin", createdAt: .now)
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
        let key = try await vault.unlock(password: current, origin: environment.baseURL.absoluteString)
        guard let metadata = try await vault.metadata() else { throw VaultError.noCredential }
        try await vault.save(apiKey: key, password: new, metadata: metadata, origin: environment.baseURL.absoluteString)
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
