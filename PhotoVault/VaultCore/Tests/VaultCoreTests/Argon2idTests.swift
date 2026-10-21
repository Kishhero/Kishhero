import Foundation
import Testing
@testable import VaultCore

@Suite("Argon2id")
struct Argon2idTests {
    let kdf = Argon2idKDF()
    let salt = [UInt8](Data(hex: ReferenceVectors.salt))
    let parameters = KDFParameters(opsLimit: ReferenceVectors.opsLimit, memLimitBytes: ReferenceVectors.memLimitBytes)

    @Test("matches libsodium and the reference Argon2 implementation")
    func knownAnswer() throws {
        let key = try kdf.deriveKey(passcode: passcode(ReferenceVectors.pin), salt: salt, parameters: parameters)
        #expect(key.rawData.hex == ReferenceVectors.argon2idOutput)
    }

    @Test("is deterministic and sensitive to passcode, salt and cost")
    func sensitivity() throws {
        let pin = passcode(ReferenceVectors.pin)
        let base = try kdf.deriveKey(passcode: pin, salt: salt, parameters: parameters).rawData
        let again = try kdf.deriveKey(passcode: pin, salt: salt, parameters: parameters).rawData
        var otherSalt = salt
        otherSalt[0] ^= 1
        let variants = [
            try kdf.deriveKey(passcode: passcode("20251022"), salt: salt, parameters: parameters).rawData,
            try kdf.deriveKey(passcode: pin, salt: otherSalt, parameters: parameters).rawData,
            try kdf.deriveKey(passcode: pin, salt: salt, parameters: .init(opsLimit: 3, memLimitBytes: parameters.memLimitBytes)).rawData,
            try kdf.deriveKey(passcode: pin, salt: salt, parameters: .init(opsLimit: 2, memLimitBytes: 16 << 20)).rawData,
        ]
        #expect(base == again)
        for variant in variants {
            #expect(variant != base)
        }
    }

    @Test(
        "refuses out-of-bounds costs before doing any work",
        arguments: [
            KDFParameters(opsLimit: 0, memLimitBytes: 8 << 20),
            KDFParameters(opsLimit: 17, memLimitBytes: 8 << 20),
            KDFParameters(opsLimit: 1 << 56, memLimitBytes: 8 << 20),
            KDFParameters(opsLimit: 2, memLimitBytes: 4 << 10),
            KDFParameters(opsLimit: 2, memLimitBytes: 512 << 20),
            KDFParameters(opsLimit: 2, memLimitBytes: (8 << 20) + 1),
        ]
    )
    func rejectsBadParameters(bad: KDFParameters) {
        #expect(throws: VaultError.invalidParameters) {
            try kdf.deriveKey(passcode: passcode("12345678"), salt: salt, parameters: bad)
        }
    }

    @Test("requires a 16-byte salt")
    func rejectsBadSalt() {
        #expect(throws: VaultError.invalidParameters) {
            try kdf.deriveKey(passcode: passcode("12345678"), salt: Array(salt.prefix(15)), parameters: parameters)
        }
    }

    @Test("calibration stays within the allowed range and never weakens the default")
    func calibration() throws {
        let calibrated = try kdf.calibratedParameters(target: .milliseconds(50), memLimitBytes: 8 << 20)
        #expect(calibrated.isWithinBounds)
        #expect(calibrated.opsLimit >= KDFParameters.recommended.opsLimit)
        #expect(calibrated.opsLimit <= Argon2idKDF.maxCalibratedPasses)
        #expect(calibrated.memLimitBytes == 8 << 20)
    }

    @Test("default settings are within bounds and above OWASP's minimum")
    func recommendedDefaults() {
        #expect(KDFParameters.recommended.isWithinBounds)
        #expect(KDFParameters.recommended.memLimitBytes >= 19 << 20)
        #expect(KDFParameters.recommended.opsLimit >= 2)
    }
}
