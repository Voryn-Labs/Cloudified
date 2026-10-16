import Foundation
import Security

/// Classified credential storage failures.
public enum CredentialError: Error, Sendable, Equatable {
    case notConfigured
    case invalidProfile
    case accessDenied(OSStatus)
    case storageFailure(OSStatus)
    case corrupt
}

/// Google authentication credentials persisted securely in Keychain.
public struct StoredGoogleCredential: Codable, Equatable, Sendable {
    public let androidId: String
    public let email: String
    public let masterToken: String
    public let authData: String
    public let connectedAt: Date

    public init(
        androidId: String,
        email: String,
        masterToken: String,
        authData: String,
        connectedAt: Date = Date()
    ) {
        self.androidId = androidId
        self.email = email
        self.masterToken = masterToken
        self.authData = authData
        self.connectedAt = connectedAt
    }
}

/// Telegram API credentials persisted securely in Keychain.
/// Database encryption keys are stored separately in dedicated atomic entries
/// via `KeychainCredentialStore.getOrCreateTDLibDatabaseKey(forProfile:)`.
/// Bot credentials are not used; Cloudified operates under user-authorized TDLib sessions only.
public struct StoredTelegramCredential: Codable, Equatable, Sendable {
    public let apiId: Int32
    public let apiHash: String
    public let phoneNumber: String?
    public let createdAt: Date

    public init(
        apiId: Int32,
        apiHash: String,
        phoneNumber: String? = nil,
        createdAt: Date = Date()
    ) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.phoneNumber = phoneNumber
        self.createdAt = createdAt
    }
}

/// Low-level Keychain operations protocol.
public protocol KeychainStoreBackend: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    /// Atomic creation; false means an existing item must be read, never overwritten.
    func insertIfAbsent(service: String, account: String, data: Data) throws -> Bool
    func delete(service: String, account: String) throws
}

/// Production implementation of KeychainStoreBackend targeting device Keychain.
public struct SystemKeychainBackend: KeychainStoreBackend {
    public init() {}

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw CredentialError.accessDenied(status)
        }
        guard status == errSecSuccess else {
            throw CredentialError.storageFailure(status)
        }
        guard let data = item as? Data else { throw CredentialError.corrupt }
        return data
    }

    public func write(service: String, account: String, data: Data) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateQuery = baseQuery(service: service, account: account)
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary)
            if updateStatus == errSecInteractionNotAllowed || updateStatus == errSecAuthFailed {
                throw CredentialError.accessDenied(updateStatus)
            }
            guard updateStatus == errSecSuccess else {
                throw CredentialError.storageFailure(updateStatus)
            }
            return
        }
        if addStatus == errSecInteractionNotAllowed || addStatus == errSecAuthFailed {
            throw CredentialError.accessDenied(addStatus)
        }
        guard addStatus == errSecSuccess else {
            throw CredentialError.storageFailure(addStatus)
        }
    }

    public func insertIfAbsent(service: String, account: String, data: Data) throws -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw CredentialError.accessDenied(status)
        }
        guard status == errSecSuccess else { throw CredentialError.storageFailure(status) }
        return true
    }

    public func delete(service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw CredentialError.accessDenied(status)
        }
        throw CredentialError.storageFailure(status)
    }
}

/// Secure native Keychain storage for provider credentials and TDLib encryption keys.
/// Items are protected with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and bound
/// by explicit validated private profile references rather than display names or token hashes.
public final class KeychainCredentialStore: Sendable {
    public static let defaultService = "com.vorynlabs.cloudified.credentials"

    private let service: String
    private let backend: any KeychainStoreBackend

    public init(
        service: String = defaultService,
        backend: any KeychainStoreBackend = SystemKeychainBackend()
    ) {
        self.service = service
        self.backend = backend
    }

    /// Validates private profile identifier against strict alphanumeric and length constraints.
    public static func validateProfileID(_ profileID: String) throws {
        guard !profileID.isEmpty,
              profileID.utf8.count <= 64,
              profileID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw CredentialError.invalidProfile
        }
    }

    private func googleAccountKey(profileID: String) throws -> String {
        try Self.validateProfileID(profileID)
        return "google.profile.\(profileID)"
    }

    private func telegramAccountKey(profileID: String) throws -> String {
        try Self.validateProfileID(profileID)
        return "telegram.profile.\(profileID)"
    }

    private func tdlibKeyAccountKey(profileID: String) throws -> String {
        try Self.validateProfileID(profileID)
        return "telegram.tdlib_db_key.\(profileID)"
    }

    // MARK: - Google Credentials

    public func saveGoogleCredential(_ cred: StoredGoogleCredential, forProfile profileID: String) throws {
        let key = try googleAccountKey(profileID: profileID)
        let data: Data
        do {
            data = try JSONEncoder().encode(cred)
        } catch {
            throw CredentialError.corrupt
        }
        try backend.write(service: service, account: key, data: data)
    }

    public func loadGoogleCredential(forProfile profileID: String) throws -> StoredGoogleCredential {
        let key = try googleAccountKey(profileID: profileID)
        guard let data = try backend.read(service: service, account: key) else {
            throw CredentialError.notConfigured
        }
        do {
            return try JSONDecoder().decode(StoredGoogleCredential.self, from: data)
        } catch {
            throw CredentialError.corrupt
        }
    }

    public func deleteGoogleCredential(forProfile profileID: String) throws {
        let key = try googleAccountKey(profileID: profileID)
        try backend.delete(service: service, account: key)
    }

    // Backward compatibility aliases
    public func saveGoogleCredential(_ cred: StoredGoogleCredential, forSession sessionID: String) throws {
        try saveGoogleCredential(cred, forProfile: sessionID)
    }
    public func loadGoogleCredential(forSession sessionID: String) throws -> StoredGoogleCredential {
        try loadGoogleCredential(forProfile: sessionID)
    }
    public func deleteGoogleCredential(forSession sessionID: String) throws {
        try deleteGoogleCredential(forProfile: sessionID)
    }

    // MARK: - Telegram Credentials

    public func saveTelegramCredential(_ cred: StoredTelegramCredential, forProfile profileID: String) throws {
        let key = try telegramAccountKey(profileID: profileID)
        let data: Data
        do {
            data = try JSONEncoder().encode(cred)
        } catch {
            throw CredentialError.corrupt
        }
        try backend.write(service: service, account: key, data: data)
    }

    public func loadTelegramCredential(forProfile profileID: String) throws -> StoredTelegramCredential {
        let key = try telegramAccountKey(profileID: profileID)
        guard let data = try backend.read(service: service, account: key) else {
            throw CredentialError.notConfigured
        }
        do {
            return try JSONDecoder().decode(StoredTelegramCredential.self, from: data)
        } catch {
            throw CredentialError.corrupt
        }
    }

    public func deleteTelegramCredential(forProfile profileID: String) throws {
        let key = try telegramAccountKey(profileID: profileID)
        try backend.delete(service: service, account: key)
    }

    // Backward compatibility aliases
    public func saveTelegramCredential(_ cred: StoredTelegramCredential, forSession sessionID: String) throws {
        try saveTelegramCredential(cred, forProfile: sessionID)
    }
    public func loadTelegramCredential(forSession sessionID: String) throws -> StoredTelegramCredential {
        try loadTelegramCredential(forProfile: sessionID)
    }
    public func deleteTelegramCredential(forSession sessionID: String) throws {
        try deleteTelegramCredential(forProfile: sessionID)
    }

    // MARK: - TDLib Database Encryption Key

    /// Generates a cryptographically secure 256-bit random key encoded in base64.
    public static func generateDatabaseEncryptionKey() throws -> String {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes { ptr -> Int32 in
            guard let baseAddress = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard result == errSecSuccess else {
            throw CredentialError.storageFailure(result)
        }
        return keyData.base64EncodedString()
    }

    /// Loads the TDLib database key for this profile or generates and persists a fresh 256-bit key.
    /// Preserves Architect's atomic insert-if-absent and corrupt byte validation.
    public func getOrCreateTDLibDatabaseKey(forProfile profileID: String, allowCreate: Bool = true) throws -> String {
        let account = try tdlibKeyAccountKey(profileID: profileID)
        if let existingData = try backend.read(service: service, account: account) {
            return try Self.validatedDatabaseKey(existingData)
        }

        guard allowCreate else { throw CredentialError.notConfigured }
        let freshKey = try Self.generateDatabaseEncryptionKey()
        guard let freshData = freshKey.data(using: .utf8) else {
            throw CredentialError.corrupt
        }
        if try backend.insertIfAbsent(service: service, account: account, data: freshData) {
            return freshKey
        }
        // Another vault/client won creation. Its key belongs to the existing database.
        guard let winner = try backend.read(service: service, account: account) else {
            throw CredentialError.corrupt
        }
        return try Self.validatedDatabaseKey(winner)
    }

    public func getOrCreateTDLibDatabaseKey(forSession sessionID: String) throws -> String {
        try getOrCreateTDLibDatabaseKey(forProfile: sessionID)
    }

    private static func validatedDatabaseKey(_ data: Data) throws -> String {
        guard let key = String(data: data, encoding: .utf8),
              let decoded = Data(base64Encoded: key), decoded.count == 32,
              decoded.base64EncodedString() == key else { throw CredentialError.corrupt }
        return key
    }

    public func deleteTDLibDatabaseKey(forProfile profileID: String) throws {
        let account = try tdlibKeyAccountKey(profileID: profileID)
        try backend.delete(service: service, account: account)
    }

    public func deleteTDLibDatabaseKey(forSession sessionID: String) throws {
        try deleteTDLibDatabaseKey(forProfile: sessionID)
    }
}
