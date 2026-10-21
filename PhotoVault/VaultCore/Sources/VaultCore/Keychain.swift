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
    private let item = KeychainItem(service: "PhotoVault.deviceBinding", account: "keychain-secret")

    public init() {}

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
#endif
