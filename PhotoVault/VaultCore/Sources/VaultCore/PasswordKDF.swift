import Foundation
import Sodium
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Cost settings for Argon2id. Stored in the vault header so a vault keeps
/// opening after the defaults change.
public struct KDFParameters: Equatable, Sendable {
    /// Argon2 passes over memory ("t"). Unlock time grows linearly with it.
    public var opsLimit: UInt64
    /// Memory each guess must fill ("m"), in bytes. This is what makes
    /// guessing on GPUs expensive: each parallel guess needs its own copy.
    public var memLimitBytes: UInt64

    public init(opsLimit: UInt64, memLimitBytes: UInt64) {
        self.opsLimit = opsLimit
        self.memLimitBytes = memLimitBytes
    }

    /// 3 passes over 64 MiB: above OWASP's Argon2id minimum (2 passes, 19 MiB)
    /// and comfortably inside a foreground iOS app's memory budget.
    /// `Argon2idKDF.calibratedParameters()` raises the pass count on fast phones.
    public static let recommended = KDFParameters(opsLimit: 3, memLimitBytes: 64 << 20)

    /// Hard limits, checked before the KDF runs. A corrupted or edited header
    /// could otherwise ask for 2^56 passes or terabytes of memory and hang or
    /// crash the app at the lock screen. (Found by the reference tests: flipping
    /// a bit in the header's cost field did exactly that.)
    static let opsBounds: ClosedRange<UInt64> = 1...16
    static let memBounds: ClosedRange<UInt64> = (8 << 10)...(256 << 20)

    var isWithinBounds: Bool {
        Self.opsBounds.contains(opsLimit)
            && Self.memBounds.contains(memLimitBytes)
            && memLimitBytes % 1024 == 0
    }
}

/// Turns a passcode into a key. Abstracted so tests can count calls or swap
/// in cheaper settings; the app always uses `Argon2idKDF`.
public protocol PasswordKDF: Sendable {
    func deriveKey(passcode: [UInt8], salt: [UInt8], parameters: KDFParameters) throws -> SymmetricKey
}

/// Argon2id v1.3 (RFC 9106), one lane, 32-byte output, via libsodium's
/// `crypto_pwhash`.
///
/// Protects against: fast guessing of the passcode by someone who has the
/// vault files and the device secret. Every guess costs `memLimitBytes` of
/// memory and about half a second on a phone.
/// Does not protect against: short passcodes. 6 digits is only a million
/// guesses, which GPUs work through in minutes even at these costs once the
/// device secret is in hand. Passcode length is what really matters, which is
/// why `PasscodePolicy` requires at least 8 characters.
public struct Argon2idKDF: PasswordKDF {
    public init() {}

    /// Slow by design (about 0.5 s with calibrated settings): never call it
    /// on the main thread.
    public func deriveKey(passcode: [UInt8], salt: [UInt8], parameters: KDFParameters) throws -> SymmetricKey {
        guard parameters.isWithinBounds, salt.count == Format.Header.saltSize else {
            throw VaultError.invalidParameters
        }
        guard var output = Sodium().pwHash.hash(
            outputLength: Format.Header.keySize,
            passwd: passcode,
            salt: salt,
            opsLimit: Int(parameters.opsLimit),
            memLimit: Int(parameters.memLimitBytes),
            alg: .Argon2ID13
        ) else {
            throw VaultError.keyDerivationFailed
        }
        defer { SecureMemory.zero(&output) }
        return SymmetricKey(data: output)
    }

    static let maxCalibratedPasses: UInt64 = 10

    /// Times one derivation on this phone and returns settings that take about
    /// `target` per unlock. Run once, when the vault is created.
    ///
    /// Memory stays fixed, because memory is what slows GPU attacks; only the
    /// pass count scales. It never goes below `recommended`, so a slow phone
    /// gets a slower unlock rather than weaker protection.
    public func calibratedParameters(
        target: Duration = .milliseconds(500),
        memLimitBytes: UInt64 = KDFParameters.recommended.memLimitBytes
    ) throws -> KDFParameters {
        let probe = KDFParameters(opsLimit: KDFParameters.recommended.opsLimit, memLimitBytes: memLimitBytes)
        let salt = try SecureRandom().bytes(Format.Header.saltSize)
        let elapsed = try ContinuousClock().measure {
            _ = try deriveKey(passcode: Array("calibration".utf8), salt: salt, parameters: probe)
        }
        let perPass = elapsed / Int(probe.opsLimit)
        let wanted = perPass > .zero ? target / perPass : 0
        let passes = min(max(wanted, Double(probe.opsLimit)), Double(Self.maxCalibratedPasses))
        return KDFParameters(opsLimit: UInt64(passes), memLimitBytes: memLimitBytes)
    }
}

/// Rules for choosing a passcode, enforced when one is set or changed.
public enum PasscodePolicy {
    /// 8 digits is 100 million combinations. A 6-digit PIN (1 million) falls
    /// to a GPU in minutes if an attacker ever extracts the device secret.
    public static let minimumLength = 8
    public static let maximumLength = 128

    public static func validate(_ passcode: [UInt8]) throws {
        guard (minimumLength...maximumLength).contains(passcode.count) else {
            throw VaultError.passcodeLength(minimum: minimumLength, maximum: maximumLength)
        }
    }
}
