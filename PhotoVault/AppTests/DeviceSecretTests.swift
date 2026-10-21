import CryptoKit
import Foundation
import Testing
import VaultCore

// These run inside the app on a real iPhone or the Simulator, because the
// Secure Enclave and the Keychain need an app. Every test uses its own
// Keychain service name and a temporary folder, so running them can never
// touch, or destroy, the real vault's secret or files.

private func uniqueService() -> String {
    "PhotoVault.tests.\(UUID().uuidString)"
}

private func rawBytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

@Suite("Device secret (on device)", .serialized)
struct DeviceSecretTests {
    @Test("Secure Enclave secret is stable, and gone once destroyed", .enabled(if: SecureEnclave.isAvailable))
    func secureEnclave() throws {
        let provider = SecureEnclaveDeviceSecret(service: uniqueService())
        defer { try? provider.destroySecret() }

        let created = try provider.createSecret()
        #expect(rawBytes(try provider.loadSecret()) == rawBytes(created))
        #expect(rawBytes(try provider.loadSecret()) == rawBytes(created))

        let replaced = try provider.createSecret()
        #expect(rawBytes(replaced) != rawBytes(created))

        try provider.destroySecret()
        #expect(throws: VaultError.deviceSecretMissing) { try provider.loadSecret() }
    }

    @Test("Keychain fallback secret is stable, and gone once destroyed")
    func keychainFallback() throws {
        let provider = KeychainDeviceSecret(service: uniqueService())
        defer { try? provider.destroySecret() }

        let created = try provider.createSecret()
        #expect(rawBytes(try provider.loadSecret()) == rawBytes(created))
        try provider.destroySecret()
        #expect(throws: VaultError.deviceSecretMissing) { try provider.loadSecret() }
    }

    @Test("full set up and unlock with this phone's real device binding")
    func endToEnd() async throws {
        let service = uniqueService()
        let deviceSecret = DeviceSecrets.platformDefault(service: service)
        let store = VaultStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoVaultTests-\(UUID().uuidString)", isDirectory: true))
        let unlocker = VaultUnlocker(
            store: store,
            deviceSecret: deviceSecret,
            throttleStore: KeychainThrottleStore(service: service + ".throttle"),
            parameters: .fixed(KDFParameters(opsLimit: 1, memLimitBytes: 8 << 20))
        )
        defer {
            try? deviceSecret.destroySecret()
            try? FileManager.default.removeItem(at: store.directory)
        }

        let created = try await unlocker.setUp(passcode: Array("13572468".utf8))
        guard case .success(let opened) = try await unlocker.unlock(passcode: Array("13572468".utf8)) else {
            Issue.record("right passcode did not unlock")
            return
        }
        #expect(rawBytes(opened.indexKey) == rawBytes(created.indexKey))

        guard case .wrongPasscode = try await unlocker.unlock(passcode: Array("00000000".utf8)) else {
            Issue.record("wrong passcode accepted")
            return
        }

        // The vault folder must be excluded from backups and fully protected.
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #if !targetEnvironment(simulator)
        // The Simulator does not implement Data Protection classes.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        #endif
    }

    @Test("throttle state survives a reload from the Keychain")
    func throttleStore() throws {
        let store = KeychainThrottleStore(service: uniqueService())
        var state = ThrottleState()
        state.failedAttempts = 6
        state.eraseEnabled = true
        try store.save(state)
        #expect(try store.load() == state)
        try store.save(ThrottleState())
    }

    @Test("Argon2id with the app's real settings takes a sensible time on this phone")
    func kdfTiming() throws {
        let kdf = Argon2idKDF()
        let parameters = try kdf.calibratedParameters()
        let salt = [UInt8](repeating: 7, count: 16)
        let elapsed = try ContinuousClock().measure {
            _ = try kdf.deriveKey(passcode: Array("13572468".utf8), salt: salt, parameters: parameters)
        }
        print("Argon2id \(parameters.opsLimit) passes x \(parameters.memLimitBytes >> 20) MiB: \(elapsed)")
        #expect(parameters.memLimitBytes == 64 << 20)
        #expect(elapsed < .seconds(3), "unlock would feel broken")
    }
}
