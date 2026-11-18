import CryptoKit
import Foundation
import Security

struct VaultMetadata: Codable, Equatable, Sendable {
    let prefix: String
    let email: String
    let createdAt: Date
    var origin: String? = nil
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

actor CredentialVault {
    static let shared = CredentialVault()
    private let service = "de.oktavi.staff.credentials"
    private let account = "api-key-v1"
    private let iterations = 600_000

    func metadata() throws -> VaultMetadata? {
        guard let data = try read() else { return nil }
        return try JSONDecoder().decode(VaultEnvelope.self, from: data).metadata
    }

    func save(apiKey: String, password: String, metadata: VaultMetadata, origin: String) throws {
        let salt = randomData(count: 16)
        let nonceData = randomData(count: 12)
        let key = deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(
            Data(apiKey.utf8),
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
        try write(JSONEncoder().encode(envelope))
    }

    func unlock(password: String, origin: String) throws -> String {
        guard let data = try read() else { throw VaultError.noCredential }
        let envelope: VaultEnvelope
        do { envelope = try JSONDecoder().decode(VaultEnvelope.self, from: data) }
        catch { throw VaultError.invalidData }
        guard envelope.version == 1 else { throw VaultError.invalidData }
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
            guard let value = String(data: plain, encoding: .utf8) else { throw VaultError.invalidData }
            return value
        } catch let vaultError as VaultError { throw vaultError }
        catch { throw VaultError.wrongPassword }
    }

    func remove() throws {
        let status = SecItemDelete(query() as CFDictionary)
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

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read() throws -> Data? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.keychain(status) }
        return data
    }

    private func write(_ data: Data) throws {
        SecItemDelete(query() as CFDictionary)
        var request = query()
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
}
