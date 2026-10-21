import Foundation
import Testing
@testable import VaultCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("Vault key hierarchy")
struct VaultKeyTests {
    func makeManager(device: InMemoryDeviceSecret = InMemoryDeviceSecret()) -> VaultKeyManager {
        VaultKeyManager(deviceSecret: device)
    }

    // MARK: Reference vectors

    @Test("creates exactly the reference header from fixed inputs")
    func headerKnownAnswer() throws {
        let device = InMemoryDeviceSecret(fixed: SymmetricKey(hex: ReferenceVectors.deviceSecret))
        var manager = VaultKeyManager(deviceSecret: device)
        // createVault draws the master key first, then the salt, then the wrap nonce.
        let random = FixedRandom(
            Data(hex: ReferenceVectors.masterKey),
            Data(hex: ReferenceVectors.salt),
            Data(hex: ReferenceVectors.wrapNonce)
        )
        manager.random = random
        let parameters = KDFParameters(opsLimit: ReferenceVectors.opsLimit, memLimitBytes: ReferenceVectors.memLimitBytes)

        let (header, keyring) = try manager.createVault(passcode: passcode(ReferenceVectors.pin), parameters: parameters)

        #expect(header.encoded.hex == ReferenceVectors.header)
        #expect(keyring.masterKey.rawData.hex == ReferenceVectors.masterKey)
        #expect(keyring.indexKey.rawData.hex == ReferenceVectors.indexKey)
        #expect(random.isExhausted)
    }

    @Test("unlocks the reference header with the reference passcode")
    func unlockKnownAnswer() throws {
        let device = InMemoryDeviceSecret(fixed: SymmetricKey(hex: ReferenceVectors.deviceSecret))
        _ = try device.createSecret()
        let header = try VaultHeader(decoding: Data(hex: ReferenceVectors.header))

        let keyring = try makeManager(device: device).unlock(passcode: passcode(ReferenceVectors.pin), header: header)

        #expect(keyring.masterKey.rawData.hex == ReferenceVectors.masterKey)
    }

    @Test("wraps an item key exactly like the reference")
    func itemKeyKnownAnswer() throws {
        let keyring = VaultKeyring(masterKey: SymmetricKey(hex: ReferenceVectors.masterKey))
        let itemID = UUID(rawBytes: Data(hex: ReferenceVectors.itemID))
        let nonce = try AES.GCM.Nonce(data: Data(hex: ReferenceVectors.itemWrapNonce))

        let wrapped = try keyring.wrapItemKey(SymmetricKey(hex: ReferenceVectors.itemKey), itemID: itemID, nonce: nonce)

        #expect(wrapped.hex == ReferenceVectors.wrappedItemKey)
        #expect(try keyring.unwrapItemKey(wrapped, itemID: itemID).rawData.hex == ReferenceVectors.itemKey)
    }

    // MARK: Passcode checks

    @Test("right passcode opens, wrong passcode does not")
    func rightAndWrongPasscode() throws {
        let manager = makeManager()
        let (header, keyring) = try manager.createVault(passcode: passcode("31415926"), parameters: .fastForTests)

        let reopened = try manager.unlock(passcode: passcode("31415926"), header: header)
        #expect(reopened.masterKey.rawData == keyring.masterKey.rawData)

        for wrong in ["31415927", "3141592", "314159260", "", "31415926 "] {
            #expect(throws: VaultError.wrongPasscode) {
                try manager.unlock(passcode: passcode(wrong), header: header)
            }
        }
    }

    @Test("the same passcode on another device secret does not open the vault")
    func otherDeviceCannotOpen() throws {
        let (header, _) = try makeManager().createVault(passcode: passcode("27182818"), parameters: .fastForTests)
        // Simulates the vault files copied to another phone with a different Secure Enclave.
        let otherDevice = InMemoryDeviceSecret()
        _ = try otherDevice.createSecret()

        #expect(throws: VaultError.wrongPasscode) {
            try makeManager(device: otherDevice).unlock(passcode: passcode("27182818"), header: header)
        }
    }

    @Test("a missing device secret is reported, not mistaken for a wrong passcode")
    func missingDeviceSecret() throws {
        let device = InMemoryDeviceSecret()
        let (header, _) = try makeManager(device: device).createVault(passcode: passcode("27182818"), parameters: .fastForTests)
        try device.destroySecret()

        #expect(throws: VaultError.deviceSecretMissing) {
            try makeManager(device: device).unlock(passcode: passcode("27182818"), header: header)
        }
    }

    @Test("creating a new vault destroys access to the previous one")
    func recreateReplacesBinding() throws {
        let device = InMemoryDeviceSecret()
        let manager = makeManager(device: device)
        let (oldHeader, _) = try manager.createVault(passcode: passcode("11112222"), parameters: .fastForTests)
        _ = try manager.createVault(passcode: passcode("11112222"), parameters: .fastForTests)

        #expect(throws: VaultError.wrongPasscode) {
            try manager.unlock(passcode: passcode("11112222"), header: oldHeader)
        }
    }

    @Test("two vaults with the same passcode share nothing")
    func freshRandomnessPerVault() throws {
        let (first, firstKeys) = try makeManager().createVault(passcode: passcode("12121212"), parameters: .fastForTests)
        let (second, secondKeys) = try makeManager().createVault(passcode: passcode("12121212"), parameters: .fastForTests)
        #expect(first.salt != second.salt)
        #expect(first.wrapNonce != second.wrapNonce)
        #expect(first.wrappedMasterKey != second.wrappedMasterKey)
        #expect(firstKeys.masterKey.rawData != secondKeys.masterKey.rawData)
    }

    @Test("header binding must match the device secret provider")
    func bindingMismatch() throws {
        let (header, _) = try makeManager().createVault(passcode: passcode("12345678"), parameters: .fastForTests)
        let enclave = InMemoryDeviceSecret(binding: .secureEnclave)
        _ = try enclave.createSecret()

        #expect(throws: VaultError.deviceBindingMismatch) {
            try makeManager(device: enclave).unlock(passcode: passcode("12345678"), header: header)
        }
    }

    // MARK: Passcode policy and changes

    @Test("passcodes shorter than 8 or longer than 128 characters are refused")
    func passcodePolicy() throws {
        let manager = makeManager()
        let expected = VaultError.passcodeLength(minimum: 8, maximum: 128)
        #expect(throws: expected) { try manager.createVault(passcode: passcode("1234567"), parameters: .fastForTests) }
        #expect(throws: expected) {
            try manager.createVault(passcode: passcode(String(repeating: "9", count: 129)), parameters: .fastForTests)
        }
        _ = try manager.createVault(passcode: passcode("12345678"), parameters: .fastForTests)
        _ = try manager.createVault(passcode: passcode("correct horse battery staple"), parameters: .fastForTests)
    }

    @Test("changing the passcode keeps the master key and retires the old passcode")
    func changePasscode() throws {
        let manager = makeManager()
        let (header, keyring) = try manager.createVault(passcode: passcode("00001111"), parameters: .fastForTests)

        let newHeader = try manager.changePasscode(current: passcode("00001111"), new: passcode("99998888"), header: header)

        #expect(newHeader.salt != header.salt)
        #expect(try manager.unlock(passcode: passcode("99998888"), header: newHeader).masterKey.rawData == keyring.masterKey.rawData)
        #expect(throws: VaultError.wrongPasscode) {
            try manager.unlock(passcode: passcode("00001111"), header: newHeader)
        }
        #expect(throws: VaultError.wrongPasscode) {
            try manager.changePasscode(current: passcode("00001112"), new: passcode("55556666"), header: header)
        }
    }

    // MARK: Header integrity

    @Test("round-trips through its 100-byte encoding")
    func headerRoundTrip() throws {
        let (header, _) = try makeManager().createVault(passcode: passcode("12345678"), parameters: .fastForTests)
        #expect(header.encoded.count == 100)
        #expect(try VaultHeader(decoding: header.encoded) == header)
    }

    @Test("every single-bit change to the header is caught")
    func tamperedHeader() throws {
        let device = InMemoryDeviceSecret(fixed: SymmetricKey(hex: ReferenceVectors.deviceSecret))
        _ = try device.createSecret()
        let manager = makeManager(device: device)
        let original = Data(hex: ReferenceVectors.header)

        for offset in 0..<original.count {
            var tampered = original
            tampered[offset] ^= 0x01
            var outcome: VaultError?
            do {
                _ = try manager.unlock(passcode: passcode(ReferenceVectors.pin), header: VaultHeader(decoding: tampered))
            } catch let error as VaultError {
                outcome = error
            }
            // Either the parser refuses it, or the unwrap fails. Never a key.
            switch outcome {
            case .malformedData?, .unsupportedVersion(_)?, .deviceBindingMismatch?, .wrongPasscode?:
                break
            case nil:
                Issue.record("flipping byte \(offset) still unlocked the vault")
            default:
                Issue.record("flipping byte \(offset) gave unexpected \(String(describing: outcome))")
            }
        }
    }

    @Test("malformed headers are refused before any key derivation")
    func malformedHeaders() throws {
        let valid = Data(hex: ReferenceVectors.header)
        #expect(throws: VaultError.malformedData) { try VaultHeader(decoding: valid.prefix(99)) }
        #expect(throws: VaultError.malformedData) { try VaultHeader(decoding: valid + [0]) }
        #expect(throws: VaultError.malformedData) { try VaultHeader(decoding: Data()) }

        var badMagic = valid
        badMagic[0] = UInt8(ascii: "X")
        #expect(throws: VaultError.malformedData) { try VaultHeader(decoding: badMagic) }

        var futureVersion = valid
        futureVersion[4] = 2
        #expect(throws: VaultError.unsupportedVersion(2)) { try VaultHeader(decoding: futureVersion) }

        // Cost fields pushed out of bounds: the bug the reference tests found.
        var hugeOps = valid
        hugeOps[8] = 0x01
        #expect(throws: VaultError.malformedData) { try VaultHeader(decoding: hugeOps) }
        var hugeMemory = valid
        hugeMemory[19] = 0x01
        #expect(throws: VaultError.malformedData) { try VaultHeader(decoding: hugeMemory) }
    }

    // MARK: Item keys

    @Test("an item key only unwraps for its own item and its own vault")
    func itemKeyBinding() throws {
        let keyring = VaultKeyring(masterKey: SymmetricKey(size: .bits256))
        let otherVault = VaultKeyring(masterKey: SymmetricKey(size: .bits256))
        let itemKey = VaultKeyring.newItemKey()
        let itemID = UUID()
        let wrapped = try keyring.wrapItemKey(itemKey, itemID: itemID)

        #expect(wrapped.count == 60)
        #expect(try keyring.unwrapItemKey(wrapped, itemID: itemID).rawData == itemKey.rawData)
        #expect(throws: VaultError.authenticationFailed) { try keyring.unwrapItemKey(wrapped, itemID: UUID()) }
        #expect(throws: VaultError.authenticationFailed) { try otherVault.unwrapItemKey(wrapped, itemID: itemID) }
        #expect(throws: VaultError.malformedData) { try keyring.unwrapItemKey(wrapped.dropLast(), itemID: itemID) }
        for offset in [0, 11, 12, 43, 44, 59] {
            var tampered = wrapped
            tampered[offset] ^= 0x80
            #expect(throws: VaultError.authenticationFailed) { try keyring.unwrapItemKey(tampered, itemID: itemID) }
        }
    }

    @Test("subkeys are independent of each other and of the master key")
    func keySeparation() {
        let keyring = VaultKeyring(masterKey: SymmetricKey(size: .bits256))
        let keys = [keyring.masterKey.rawData, keyring.indexKey.rawData, keyring.itemWrapKey.rawData]
        #expect(Set(keys).count == 3)
    }
}
