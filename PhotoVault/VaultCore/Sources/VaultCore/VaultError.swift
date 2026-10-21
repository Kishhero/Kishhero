/// Every failure VaultCore reports. Messages shown to the user should be built
/// from these cases, never from underlying system errors, so nothing about the
/// vault's internals ends up on screen or in logs.
public enum VaultError: Error, Equatable, Sendable {
    /// The passcode did not unlock the vault. Also returned when the device
    /// secret differs (for example, the vault files were copied to another
    /// phone): the two cases are indistinguishable by design.
    case wrongPasscode
    /// A new passcode is shorter or longer than `PasscodePolicy` allows.
    case passcodeLength(minimum: Int, maximum: Int)
    /// The vault header was created with a different kind of device binding.
    case deviceBindingMismatch
    /// Refused to create a vault over an existing one, which would destroy it.
    case vaultAlreadyExists
    /// `index.enc` is gone but encrypted files remain. Refusing to open,
    /// rather than treating every file as unreferenced and deleting it.
    case catalogMissing
    /// No item with that ID is in the catalog.
    case itemNotFound
    /// The hardware-bound secret is gone (Keychain item deleted or wiped).
    case deviceSecretMissing
    case secureEnclaveUnavailable
    case keychain(status: Int32)
    /// Encrypted data failed its integrity check: corrupted or tampered with.
    case authenticationFailed
    /// Data is not in a format VaultCore wrote.
    case malformedData
    case unsupportedVersion(UInt8)
    case invalidParameters
    case invalidRange
    /// A file or buffer ended before the expected number of bytes.
    case truncatedSource
    case randomGenerationFailed
    case keyDerivationFailed
}
