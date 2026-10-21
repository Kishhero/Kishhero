#if os(iOS) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Security

/// Device secret computed inside the Secure Enclave, the iPhone's separate
/// security chip.
///
/// At setup the Enclave creates a P-256 key whose private half never leaves
/// the chip. We pair it with a throwaway software key and keep only that key's
/// public half. The device secret is ECDH(enclave key, partner public key)
/// passed through HKDF, and it can only be recomputed by asking this phone's
/// Enclave.
///
/// What is stored, both in the Keychain (this device only, unlocked only):
/// - the enclave key's `dataRepresentation`: an opaque blob that only this
///   phone's Secure Enclave can use. It is not the key itself.
/// - the partner public key.
///
/// Protects against: vault files plus a Keychain dump being attacked on
/// another machine. Neither stored item yields the secret without this
/// phone's Enclave.
/// Does not protect against: code running on this phone while it is unlocked,
/// which can ask the Enclave to compute the secret.
public struct SecureEnclaveDeviceSecret: DeviceSecretProvider {
    public var binding: DeviceBinding { .secureEnclave }
    private let enclaveKeyItem = KeychainItem(service: "PhotoVault.deviceBinding", account: "secure-enclave-key")
    private let partnerKeyItem = KeychainItem(service: "PhotoVault.deviceBinding", account: "partner-public-key")

    public init() {}

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public func createSecret() throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { throw VaultError.secureEnclaveUnavailable }
        try destroySecret()

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &error
        ) else {
            throw VaultError.secureEnclaveUnavailable
        }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)

        // The partner's private half goes out of scope here and is never
        // stored. Keeping it would defeat the point: partner private key plus
        // the enclave key's public half reproduce the same shared secret
        // without the Secure Enclave.
        let partnerPublicKey = P256.KeyAgreement.PrivateKey().publicKey

        try enclaveKeyItem.write(enclaveKey.dataRepresentation)
        try partnerKeyItem.write(partnerPublicKey.x963Representation)
        return try derive(enclaveKey: enclaveKey, partnerPublicKey: partnerPublicKey)
    }

    public func loadSecret() throws -> SymmetricKey {
        guard let keyData = try enclaveKeyItem.read(), let partnerData = try partnerKeyItem.read() else {
            throw VaultError.deviceSecretMissing
        }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyData)
        let partnerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: partnerData)
        return try derive(enclaveKey: enclaveKey, partnerPublicKey: partnerPublicKey)
    }

    /// Deleting the enclave key blob destroys the key for good: the Enclave
    /// keeps no copy of it.
    public func destroySecret() throws {
        try enclaveKeyItem.delete()
        try partnerKeyItem.delete()
    }

    private func derive(
        enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey,
        partnerPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: partnerPublicKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Format.Label.deviceBinding,
            outputByteCount: Format.Header.keySize
        )
    }
}

public enum DeviceSecrets {
    /// The Secure Enclave on a real iPhone, a Keychain secret on the Simulator.
    public static func platformDefault() -> any DeviceSecretProvider {
        #if targetEnvironment(simulator)
        return KeychainDeviceSecret()
        #else
        return SecureEnclaveDeviceSecret()
        #endif
    }
}
#endif
