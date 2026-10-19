import Foundation

private final class KeyFixture: KeychainStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private func key(_ service: String, _ account: String) -> String { service + "/" + account }
    func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return values[key(service, account)]
    }
    func write(service: String, account: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }; values[key(service, account)] = data
    }
    func insertIfAbsent(service: String, account: String, data: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let name = key(service, account)
        guard values[name] == nil else { return false }; values[name] = data; return true
    }
    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key(service, account))
    }
}
func boundaryCredentialStore() -> KeychainCredentialStore { KeychainCredentialStore(backend: KeyFixture()) }
func credentialKeyChecks() throws {
    let store = KeychainCredentialStore(backend: KeyFixture())
    do { _ = try store.getOrCreateTDLibDatabaseKey(forProfile: "primary", allowCreate: false); preconditionFailure("replacement database key generated") }
    catch { check((error as? CredentialError) == .notConfigured, "missing database key misclassified") }
    let key = try store.getOrCreateTDLibDatabaseKey(forProfile: "primary")
    check(try store.getOrCreateTDLibDatabaseKey(forProfile: "primary", allowCreate: false) == key, "existing database key changed")
    try store.deleteTDLibDatabaseKey(forProfile: "primary")
    do { _ = try store.getOrCreateTDLibDatabaseKey(forProfile: "primary", allowCreate: false); preconditionFailure("lost key silently replaced") }
    catch { check((error as? CredentialError) == .notConfigured, "lost database key misclassified") }
    print("PASS actual Keychain key policy: existing keys reused; creation forbidden for missing/lost keys when an existing database is present")
}
