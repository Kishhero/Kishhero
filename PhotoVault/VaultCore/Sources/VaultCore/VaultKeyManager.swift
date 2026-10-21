import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Creates the vault's key hierarchy, unlocks it, and changes the passcode.
///
///     passcode ──Argon2id(salt)──┐
///                                ├─ HKDF-SHA256 ─► KEK ─AES-GCM unwrap─► master key
///     device secret (Enclave) ───┘
///
/// The master key is random and never changes, so changing the passcode only
/// re-wraps 32 bytes. Nothing derived from the passcode is ever stored.
///
/// Every method here runs Argon2id (about 0.5 s): call from a background task,
/// never the main thread.
public struct VaultKeyManager: Sendable {
    public let kdf: any PasswordKDF
    public let deviceSecret: any DeviceSecretProvider
    /// Always `SecureRandom` outside tests.
    var random: any RandomBytesGenerator = SecureRandom()

    public init(kdf: any PasswordKDF = Argon2idKDF(), deviceSecret: any DeviceSecretProvider) {
        self.kdf = kdf
        self.deviceSecret = deviceSecret
    }

    /// First-time setup: a new device secret (replacing any old one) and a new
    /// random master key, wrapped under the passcode.
    ///
    /// The caller writes `header.encoded` to `vault.hdr` and keeps `keyring`
    /// in memory for the session.
    public func createVault(passcode: [UInt8], parameters: KDFParameters) throws -> (header: VaultHeader, keyring: VaultKeyring) {
        try PasscodePolicy.validate(passcode)
        guard parameters.isWithinBounds else { throw VaultError.invalidParameters }
        let device = try deviceSecret.createSecret()
        var masterKey = try random.bytes(Format.Header.keySize)
        defer { SecureMemory.zero(&masterKey) }
        let header = try seal(masterKey: masterKey, passcode: passcode, parameters: parameters, device: device)
        return (header, VaultKeyring(masterKey: SymmetricKey(data: masterKey)))
    }

    /// Returns the keyring if the passcode is right, else throws `.wrongPasscode`.
    ///
    /// Protects against: opening the vault without the passcode and this phone.
    /// Does not protect against: someone who knows or watches you enter the
    /// passcode. Attempt limits and delays live in the app layer; this method
    /// is deliberately just "right or wrong".
    public func unlock(passcode: [UInt8], header: VaultHeader) throws -> VaultKeyring {
        guard header.binding == deviceSecret.binding else { throw VaultError.deviceBindingMismatch }
        let device = try deviceSecret.loadSecret()
        let kek = try deriveKEK(passcode: passcode, salt: header.salt, parameters: header.kdfParameters, device: device)
        let keySize = Format.Header.keySize
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: header.wrapNonce),
            ciphertext: header.wrappedMasterKey[0..<keySize],
            tag: header.wrappedMasterKey[keySize...]
        )
        do {
            let masterKey = try AES.GCM.open(box, using: kek, authenticating: header.authenticatedPrefix)
            return VaultKeyring(masterKey: SymmetricKey(data: masterKey))
        } catch {
            // Wrong passcode, wrong device secret and a tampered header all land
            // here on purpose: the caller learns only "no".
            throw VaultError.wrongPasscode
        }
    }

    /// Re-wraps the same master key under a new passcode, with a new salt and
    /// nonce. Photos are not re-encrypted, so this takes as long as two unlocks.
    public func changePasscode(
        current: [UInt8],
        new: [UInt8],
        header: VaultHeader,
        parameters: KDFParameters? = nil
    ) throws -> VaultHeader {
        try PasscodePolicy.validate(new)
        let keyring = try unlock(passcode: current, header: header)
        let device = try deviceSecret.loadSecret()
        var masterKey = keyring.masterKey.withUnsafeBytes { Array($0) }
        defer { SecureMemory.zero(&masterKey) }
        return try seal(masterKey: masterKey, passcode: new, parameters: parameters ?? header.kdfParameters, device: device)
    }

    private func seal(masterKey: [UInt8], passcode: [UInt8], parameters: KDFParameters, device: SymmetricKey) throws -> VaultHeader {
        let salt = try random.bytes(Format.Header.saltSize)
        let nonce = try random.bytes(Format.Header.nonceSize)
        let unsealed = VaultHeader(binding: deviceSecret.binding, kdfParameters: parameters, salt: salt, wrapNonce: nonce, wrappedMasterKey: [])
        let kek = try deriveKEK(passcode: passcode, salt: salt, parameters: parameters, device: device)
        let sealed = try AES.GCM.seal(masterKey, using: kek, nonce: AES.GCM.Nonce(data: nonce), authenticating: unsealed.authenticatedPrefix)
        return VaultHeader(
            binding: deviceSecret.binding,
            kdfParameters: parameters,
            salt: salt,
            wrapNonce: nonce,
            wrappedMasterKey: Array(sealed.ciphertext) + Array(sealed.tag)
        )
    }

    /// KEK = HKDF-SHA256(Argon2id(passcode) || deviceSecret, salt, "PhotoVault v1 kek").
    /// Both inputs are required: the passcode alone is useless off this phone,
    /// and the phone alone is useless without the passcode.
    func deriveKEK(passcode: [UInt8], salt: [UInt8], parameters: KDFParameters, device: SymmetricKey) throws -> SymmetricKey {
        let passcodeKey = try kdf.deriveKey(passcode: passcode, salt: salt, parameters: parameters)
        var inputKeyMaterial = passcodeKey.withUnsafeBytes { Array($0) } + device.withUnsafeBytes { Array($0) }
        defer { SecureMemory.zero(&inputKeyMaterial) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: Format.Label.kek,
            outputByteCount: Format.Header.keySize
        )
    }
}
