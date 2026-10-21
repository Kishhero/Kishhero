import Foundation

/// The 100-byte file `vault.hdr`: everything needed to turn the passcode back
/// into the master key, and nothing that helps without the passcode.
///
/// It holds no password hash and no "verifier". A wrong passcode is detected
/// only because AES-GCM refuses to unwrap the master key, so there is nothing
/// here an attacker can test guesses against except the full Argon2id + device
/// secret + AES-GCM pipeline. Layout: docs/FORMAT.md.
public struct VaultHeader: Equatable, Sendable {
    public let binding: DeviceBinding
    public let kdfParameters: KDFParameters
    let salt: [UInt8]
    let wrapNonce: [UInt8]
    /// AES-256-GCM ciphertext of the master key (32 bytes) followed by its tag (16).
    let wrappedMasterKey: [UInt8]

    init(binding: DeviceBinding, kdfParameters: KDFParameters, salt: [UInt8], wrapNonce: [UInt8], wrappedMasterKey: [UInt8]) {
        self.binding = binding
        self.kdfParameters = kdfParameters
        self.salt = salt
        self.wrapNonce = wrapNonce
        self.wrappedMasterKey = wrappedMasterKey
    }

    /// Bytes 0..<40, authenticated as associated data when the master key is
    /// wrapped. Changing the binding, cost settings or salt therefore makes the
    /// unwrap fail instead of quietly deriving a different key.
    var authenticatedPrefix: Data {
        var out = Data(Format.Header.magic)
        out.append(Format.Header.version)
        out.append(Format.Header.kdfArgon2id)
        out.append(binding.rawValue)
        out.append(0) // reserved
        out.append(contentsOf: kdfParameters.opsLimit.bigEndianBytes)
        out.append(contentsOf: kdfParameters.memLimitBytes.bigEndianBytes)
        out.append(contentsOf: salt)
        return out
    }

    public var encoded: Data {
        authenticatedPrefix + wrapNonce + wrappedMasterKey
    }

    /// Parses and sanity-checks a header. The KDF cost bounds are checked here,
    /// before any key derivation runs, so a damaged file fails fast instead of
    /// hanging the lock screen.
    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count == Format.Header.size, Array(bytes[0..<4]) == Format.Header.magic else {
            throw VaultError.malformedData
        }
        guard bytes[4] == Format.Header.version else {
            throw VaultError.unsupportedVersion(bytes[4])
        }
        guard bytes[5] == Format.Header.kdfArgon2id,
              bytes[7] == 0,
              let binding = DeviceBinding(rawValue: bytes[6])
        else {
            throw VaultError.malformedData
        }
        let parameters = KDFParameters(
            opsLimit: bytes.readBigEndian(UInt64.self, at: 8),
            memLimitBytes: bytes.readBigEndian(UInt64.self, at: 16)
        )
        guard parameters.isWithinBounds else { throw VaultError.malformedData }
        self.init(
            binding: binding,
            kdfParameters: parameters,
            salt: Array(bytes[24..<40]),
            wrapNonce: Array(bytes[40..<52]),
            wrappedMasterKey: Array(bytes[52..<100])
        )
    }
}
