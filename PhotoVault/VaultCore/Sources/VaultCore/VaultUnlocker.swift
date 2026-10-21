import Foundation

/// The result of anything that checks a passcode.
public enum AttemptOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case wrongPasscode(UnlockStatus)
    /// Refused without trying: the keypad is locked out until `retryAfter`.
    case throttled(UnlockStatus)
    /// That was the last allowed attempt and erase is enabled: the vault is gone.
    case erased
}

/// Everything the lock screen does: create the vault, unlock it, change the
/// passcode, erase it.
///
/// An actor for two reasons:
/// - attempts are serialized, so tapping "Unlock" twice cannot run two guesses
///   at once or race the attempt counter;
/// - Argon2id (about 0.5 s) runs off the main thread, so the UI stays at full
///   frame rate while the passcode is checked.
public actor VaultUnlocker {
    public enum ParameterChoice: Sendable {
        /// Measure this phone at setup (the app).
        case calibrated
        /// Fixed settings (tests).
        case fixed(KDFParameters)
    }

    private let store: VaultStore
    private let keys: VaultKeyManager
    private let throttle: UnlockThrottle
    private let parameterChoice: ParameterChoice

    public init(
        store: VaultStore,
        deviceSecret: any DeviceSecretProvider,
        throttleStore: any ThrottleStateStore,
        kdf: any PasswordKDF = Argon2idKDF(),
        parameters: ParameterChoice = .calibrated,
        policy: UnlockPolicy = .standard
    ) {
        self.store = store
        self.keys = VaultKeyManager(kdf: kdf, deviceSecret: deviceSecret)
        self.throttle = UnlockThrottle(store: throttleStore, policy: policy)
        self.parameterChoice = parameters
    }

    /// Synchronous, so the app can pick setup vs. lock screen at launch without waiting.
    public nonisolated var hasVault: Bool {
        store.hasVault
    }

    public func status(now: Date = Date()) throws -> UnlockStatus {
        try throttle.status(now: now)
    }

    /// First run. Refuses to run if a vault exists, because creating a new
    /// device secret would destroy the old vault.
    public func setUp(passcode: [UInt8]) throws -> VaultKeyring {
        guard !store.hasVault else { throw VaultError.vaultAlreadyExists }
        try PasscodePolicy.validate(passcode)
        // Leftovers of an erase that was interrupted: without a header none
        // of it can be decrypted, and it would break the new vault's catalog.
        try store.eraseFiles()
        let parameters: KDFParameters
        switch parameterChoice {
        case .calibrated: parameters = try Argon2idKDF().calibratedParameters()
        case .fixed(let fixed): parameters = fixed
        }
        try store.prepare()
        let (header, keyring) = try keys.createVault(passcode: passcode, parameters: parameters)
        try store.writeHeader(header)
        try throttle.reset()
        return keyring
    }

    public func unlock(passcode: [UInt8], now: Date = Date()) throws -> AttemptOutcome<VaultKeyring> {
        try attempt(now: now) {
            try keys.unlock(passcode: passcode, header: store.readHeader())
        }
    }

    /// Goes through the same attempt limits as unlocking, so it cannot be used
    /// to guess the current passcode faster.
    public func changePasscode(current: [UInt8], new: [UInt8], now: Date = Date()) throws -> AttemptOutcome<Bool> {
        try PasscodePolicy.validate(new)
        return try attempt(now: now) {
            let header = try keys.changePasscode(current: current, new: new, header: store.readHeader())
            try store.writeHeader(header)
            return true
        }
    }

    public func setEraseAfterFailures(_ enabled: Bool) throws {
        try throttle.setEraseEnabled(enabled)
    }

    /// Destroys the vault for good.
    ///
    /// The device secret goes first: from that instant the header can never be
    /// unwrapped again, even if deleting the files is interrupted halfway.
    public func erase() throws {
        try keys.deviceSecret.destroySecret()
        try store.removeHeader()
        try store.eraseFiles()
        try throttle.reset()
    }

    private func attempt<Value: Sendable>(now: Date, _ operation: () throws -> Value) throws -> AttemptOutcome<Value> {
        let before = try throttle.status(now: now)
        if before.retryAfter != nil {
            return .throttled(before)
        }
        let previous = try throttle.beginAttempt(now: now)
        do {
            let value = try operation()
            // The vault is already open (or the header already rewritten);
            // failing to reset the counter must not report that as an error.
            try? throttle.recordSuccess()
            return .success(value)
        } catch VaultError.wrongPasscode {
            if try throttle.shouldErase(now: now) {
                try erase()
                return .erased
            }
            return .wrongPasscode(try throttle.status(now: now))
        } catch {
            // Not a verdict on the passcode (missing file, Keychain error):
            // don't charge the user an attempt for it.
            try? throttle.restore(previous)
            throw error
        }
    }
}
