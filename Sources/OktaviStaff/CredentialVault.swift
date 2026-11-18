import CryptoKit
import Foundation
import Security

struct VaultMetadata: Codable, Equatable, Sendable {
    let prefix: String
    let email: String
    let createdAt: Date
    var origin: String? = nil
}

/// The encrypted part of an envelope. Older envelopes hold the bare API key instead.
struct VaultPayload: Codable, Equatable, Sendable {
    let apiKey: String
    let basicAuth: BasicAuthCredentials?

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ plaintext: Data) throws -> VaultPayload {
        if plaintext.first == UInt8(ascii: "{") {
            guard let payload = try? JSONDecoder().decode(VaultPayload.self, from: plaintext) else { throw VaultError.invalidData }
            return payload
        }
        guard let key = String(data: plaintext, encoding: .utf8) else { throw VaultError.invalidData }
        return VaultPayload(apiKey: key, basicAuth: nil)
    }
}

struct UnlockedCredential: Sendable {
    let apiKey: String
    let basicAuth: BasicAuthCredentials?
    let metadata: VaultMetadata
}

private struct VaultEnvelope: Codable {
    let version: Int
    let salt: Data
    let nonce: Data
    let ciphertext: Data
    let tag: Data
    let metadata: VaultMetadata
}

enum VaultError: LocalizedError {
    case noCredential, wrongPassword, invalidData, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .noCredential: "Auf diesem Mac ist kein Schlüssel gespeichert."
        case .wrongPassword: "Das App-Passwort ist falsch."
        case .invalidData: "Die gespeicherten Anmeldedaten sind beschädigt."
        case .keychain(let status): "Schlüsselbundfehler (\(status))."
        }
    }
}

/// What the Keychain holds for one environment.
enum StoredCredential: Equatable, Sendable {
    /// No key for this environment yet: it has to be set up.
    case none
    /// A key saved for exactly this environment.
    case stored(VaultMetadata)
    /// A key saved before keys were kept per environment. Its environment is unknown until it
    /// is unlocked; a successful unlock moves it to the environment it belongs to.
    case legacy(VaultMetadata)
}

actor CredentialVault {
    static let shared = CredentialVault()
    private let service = "de.oktavi.staff.credentials"
    private static let legacyAccount = "api-key-v1"
    private let iterations = 600_000

    /// Keychain account of an environment's key. The origin is hashed so the Keychain item
    /// does not name the environment in clear.
    static func account(for origin: String) -> String {
        let digest = SHA256.hash(data: Data(origin.utf8))
        return "api-key-v2:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    func credential(origin: String) throws -> StoredCredential {
        if let data = try read(account: Self.account(for: origin)) { return .stored(try decode(data).metadata) }
        if let data = try read(account: Self.legacyAccount) { return .legacy(try decode(data).metadata) }
        return .none
    }

    func save(apiKey: String, basicAuth: BasicAuthCredentials?, password: String, metadata: VaultMetadata, origin: String) throws {
        let salt = randomData(count: 16)
        let nonceData = randomData(count: 12)
        let key = deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(
            VaultPayload(apiKey: apiKey, basicAuth: basicAuth).encoded(),
            using: key,
            nonce: nonce,
            authenticating: Data("oktavi-staff-app:v1:\(origin)".utf8)
        )
        let envelope = VaultEnvelope(
            version: 1,
            salt: salt,
            nonce: nonceData,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            metadata: metadata
        )
        try write(JSONEncoder().encode(envelope), account: Self.account(for: origin))
    }

    /// Decrypts the environment's key. A legacy key that opens with this origin belongs to it,
    /// so it is moved to the environment's own Keychain item.
    func unlock(password: String, origin: String) throws -> UnlockedCredential {
        let account = Self.account(for: origin)
        if let data = try read(account: account) {
            let envelope = try decode(data)
            let payload = try open(envelope, password: password, origin: origin)
            return UnlockedCredential(apiKey: payload.apiKey, basicAuth: payload.basicAuth, metadata: envelope.metadata)
        }
        guard let data = try read(account: Self.legacyAccount) else { throw VaultError.noCredential }
        let envelope = try decode(data)
        let payload = try open(envelope, password: password, origin: origin)
        try write(data, account: account)
        try delete(account: Self.legacyAccount)
        return UnlockedCredential(apiKey: payload.apiKey, basicAuth: payload.basicAuth, metadata: envelope.metadata)
    }

    /// Removes the environment's key, or the legacy key when the environment has none of its own.
    func remove(origin: String) throws {
        if try read(account: Self.account(for: origin)) != nil { try delete(account: Self.account(for: origin)) }
        else { try delete(account: Self.legacyAccount) }
    }

    private func decode(_ data: Data) throws -> VaultEnvelope {
        let envelope: VaultEnvelope
        do { envelope = try JSONDecoder().decode(VaultEnvelope.self, from: data) }
        catch { throw VaultError.invalidData }
        guard envelope.version == 1 else { throw VaultError.invalidData }
        return envelope
    }

    private func open(_ envelope: VaultEnvelope, password: String, origin: String) throws -> VaultPayload {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let plain = try AES.GCM.open(
                box,
                using: deriveKey(password: password, salt: envelope.salt),
                authenticating: Data("oktavi-staff-app:v1:\(origin)".utf8)
            )
            return try VaultPayload.decode(plain)
        } catch let vaultError as VaultError { throw vaultError }
        catch { throw VaultError.wrongPassword }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }

    private func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var block = Data(salt)
        block.append(contentsOf: [0, 0, 0, 1])
        var value = Data(HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: passwordData)))
        var result = value
        if iterations > 1 {
            for _ in 2...iterations {
                value = Data(HMAC<SHA256>.authenticationCode(for: value, using: SymmetricKey(data: passwordData)))
                for index in result.indices { result[index] ^= value[index] }
            }
        }
        return SymmetricKey(data: result)
    }

    private func randomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.keychain(status) }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        SecItemDelete(query(account: account) as CFDictionary)
        var request = query(account: account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
}
