#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Which kind of hardware binding a vault header was created with.
/// Stored in the header (and authenticated), so a vault never silently opens
/// with a weaker binding than it was created with.
public enum DeviceBinding: UInt8, Sendable {
    /// Secret produced inside the Secure Enclave. Real iPhones.
    case secureEnclave = 1
    /// Random secret in the Keychain. iOS Simulator only: it has no Secure Enclave.
    case keychain = 2
    /// In-memory secret. Unit tests only.
    case testing = 0xFE
}

/// A 256-bit secret that exists only on this phone, mixed into the
/// passcode-derived key.
///
/// Protects against: anyone who copies the vault files off the phone (from a
/// backup, a forensic file dump, or a stolen file) guessing the passcode on
/// their own computers. Without this secret, every guess is useless.
/// Does not protect against: an attacker who can run code on this phone while
/// it is unlocked. They can obtain the secret once and then guess offline,
/// which is why passcode length still matters.
public protocol DeviceSecretProvider: Sendable {
    var binding: DeviceBinding { get }
    /// Creates a fresh secret, destroying any previous one. Any vault sealed
    /// with the old secret can never be opened again.
    func createSecret() throws -> SymmetricKey
    func loadSecret() throws -> SymmetricKey
    /// Permanently destroys the secret, which makes the vault unrecoverable
    /// even with the right passcode. Used for "erase vault".
    func destroySecret() throws
}
