#if canImport(Security)
import CryptoKit
import Foundation
import Security

/// One generic-password Keychain item, readable only by this app, only while
/// the phone is unlocked, and only on this phone.
struct KeychainItem {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw VaultError.keychain(status: status) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw VaultError.keychain(status: status)
        }
    }

    func write(_ data: Data) throws {
        try delete()
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // WhenUnlocked: unreadable while the phone is locked.
        // ThisDeviceOnly: never synced to iCloud Keychain, and never restored
        // to a different phone from a backup.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status: status)
        }
    }
}

/// Device secret kept as 32 random bytes in the Keychain.
///
/// For the iOS Simulator, which has no Secure Enclave. Weaker than
/// `SecureEnclaveDeviceSecret`: a Keychain dump from a compromised phone
/// contains the secret itself. `DeviceSecrets.platformDefault()` never picks
/// this on a real device.
public struct KeychainDeviceSecret: DeviceSecretProvider {
    public var binding: DeviceBinding { .keychain }
    private let item: KeychainItem

    /// - Parameter service: Keychain service name. Tests must pass their own
    ///   so they never touch, or destroy, the real vault's secret.
    public init(service: String = DeviceSecrets.defaultService) {
        item = KeychainItem(service: service, account: "keychain-secret")
    }

    public func createSecret() throws -> SymmetricKey {
        var bytes = try SecureRandom().bytes(Format.Header.keySize)
        defer { SecureMemory.zero(&bytes) }
        try item.write(Data(bytes))
        return SymmetricKey(data: bytes)
    }

    public func loadSecret() throws -> SymmetricKey {
        guard let data = try item.read(), data.count == Format.Header.keySize else {
            throw VaultError.deviceSecretMissing
        }
        return SymmetricKey(data: data)
    }

    public func destroySecret() throws {
        try item.delete()
    }
}

/// Keeps the failed-attempt counter in the Keychain rather than in the app's
/// files, so deleting the vault folder or restoring an old backup of the app's
/// preferences does not reset it.
public struct KeychainThrottleStore: ThrottleStateStore {
    private let item: KeychainItem

    public init(service: String = "PhotoVault.unlockThrottle") {
        item = KeychainItem(service: service, account: "state")
    }

    public func load() throws -> ThrottleState {
        guard let data = try item.read() else { return ThrottleState() }
        // Unreadable state starts fresh. Only code that can already write this
        // app's Keychain could corrupt it, and that code can bypass the
        // throttle anyway; the real protection is Argon2id plus the device
        // secret. Refusing to unlock would only lock out the owner.
        return (try? JSONDecoder().decode(ThrottleState.self, from: data)) ?? ThrottleState()
    }

    public func save(_ state: ThrottleState) throws {
        try item.write(JSONEncoder().encode(state))
    }
}
#endif

public enum DeviceSecrets {
    public static let defaultService = "PhotoVault.deviceBinding"
}
