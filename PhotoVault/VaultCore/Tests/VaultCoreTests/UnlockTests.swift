import Foundation
import Testing
@testable import VaultCore

@Suite("Unlock throttle")
struct UnlockThrottleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func makeThrottle() -> UnlockThrottle {
        UnlockThrottle(store: InMemoryThrottleStore(), policy: .standard)
    }

    @Test("four free tries, then 30 s, 1 min, 5 min, 15 min, 1 h, 1 h ...")
    func delaySchedule() {
        let policy = UnlockPolicy.standard
        let expected: [TimeInterval] = [0, 0, 0, 0, 30, 60, 300, 900, 3600, 3600, 3600]
        #expect((1...11).map { policy.delay(afterFailures: $0) } == expected)
    }

    @Test("an attempt counts as failed before its result is known")
    func countsBeforeResult() throws {
        let throttle = makeThrottle()
        for attempt in 1...5 {
            _ = try throttle.beginAttempt(now: start)
            #expect(try throttle.status(now: start).failedAttempts == attempt)
        }
        // The fifth failure locks the keypad for 30 seconds.
        #expect(try throttle.status(now: start).retryAfter == start.addingTimeInterval(30))
        #expect(try throttle.status(now: start.addingTimeInterval(29)).retryAfter != nil)
        #expect(try throttle.status(now: start.addingTimeInterval(30)).retryAfter == nil)
    }

    @Test("success clears the count but keeps the erase setting")
    func successResets() throws {
        let throttle = makeThrottle()
        try throttle.setEraseEnabled(true)
        for _ in 1...6 { _ = try throttle.beginAttempt(now: start) }
        try throttle.recordSuccess()
        let status = try throttle.status(now: start)
        #expect(status.failedAttempts == 0)
        #expect(status.retryAfter == nil)
        #expect(status.eraseEnabled)
        #expect(status.attemptsBeforeErase == 10)
    }

    @Test("turning the clock back restarts the wait instead of skipping it")
    func clockRollback() throws {
        let throttle = makeThrottle()
        for _ in 1...6 { _ = try throttle.beginAttempt(now: start) } // 1 minute lockout
        let earlier = start.addingTimeInterval(-86_400)
        #expect(try throttle.status(now: earlier).retryAfter == earlier.addingTimeInterval(60))
    }

    @Test("restore undoes an attempt that never checked the passcode")
    func restoreUndoes() throws {
        let throttle = makeThrottle()
        let previous = try throttle.beginAttempt(now: start)
        try throttle.restore(previous)
        #expect(try throttle.status(now: start).failedAttempts == 0)
    }
}

@Suite("Vault unlocker")
struct VaultUnlockerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Fixture {
        let store = temporaryVaultStore()
        let device = InMemoryDeviceSecret()
        let throttleStore = InMemoryThrottleStore()

        func makeUnlocker() -> VaultUnlocker {
            VaultUnlocker(store: store, deviceSecret: device, throttleStore: throttleStore, parameters: .fixed(.fastForTests))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: store.directory)
        }
    }

    @Test("set up, then unlock with the same passcode")
    func setUpAndUnlock() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        #expect(!unlocker.hasVault)

        let created = try await unlocker.setUp(passcode: passcode("24681357"))
        #expect(unlocker.hasVault)

        guard case .success(let opened) = try await unlocker.unlock(passcode: passcode("24681357"), now: start) else {
            Issue.record("right passcode did not unlock")
            return
        }
        #expect(opened.indexKey.rawData == created.indexKey.rawData)
    }

    @Test("refuses to create a vault over an existing one")
    func noOverwrite() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))
        await #expect(throws: VaultError.vaultAlreadyExists) {
            try await unlocker.setUp(passcode: passcode("11111111"))
        }
        // The original vault still opens.
        guard case .success = try await unlocker.unlock(passcode: passcode("24681357"), now: start) else {
            Issue.record("original vault was damaged")
            return
        }
    }

    @Test("wrong passcodes are counted and locked out, and the right one resets the count")
    func lockout() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))

        for attempt in 1...5 {
            guard case .wrongPasscode(let status) = try await unlocker.unlock(passcode: passcode("00000000"), now: start) else {
                Issue.record("attempt \(attempt) was not reported as wrong")
                return
            }
            #expect(status.failedAttempts == attempt)
        }
        // Locked for 30 s: even the right passcode is refused without being tried.
        guard case .throttled(let status) = try await unlocker.unlock(passcode: passcode("24681357"), now: start.addingTimeInterval(10)) else {
            Issue.record("lockout not enforced")
            return
        }
        #expect(status.retryAfter == start.addingTimeInterval(30))

        guard case .success = try await unlocker.unlock(passcode: passcode("24681357"), now: start.addingTimeInterval(31)) else {
            Issue.record("right passcode refused after the lockout ended")
            return
        }
        #expect(try await unlocker.status(now: start.addingTimeInterval(31)).failedAttempts == 0)
    }

    @Test("with erase enabled, the 10th wrong passcode destroys the vault")
    func eraseAfterTen() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))
        try await unlocker.setEraseAfterFailures(true)

        var now = start
        for attempt in 1...9 {
            guard case .wrongPasscode(let status) = try await unlocker.unlock(passcode: passcode("00000000"), now: now) else {
                Issue.record("attempt \(attempt) was not reported as wrong")
                return
            }
            #expect(status.attemptsBeforeErase == 10 - attempt)
            now = status.retryAfter ?? now
        }
        guard case .erased = try await unlocker.unlock(passcode: passcode("00000000"), now: now) else {
            Issue.record("10th wrong passcode did not erase")
            return
        }
        #expect(!unlocker.hasVault)
        #expect(!fixture.device.exists)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.path))
    }

    @Test("with erase off, the vault survives any number of wrong passcodes")
    func noEraseByDefault() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))

        var now = start
        for _ in 1...12 {
            guard case .wrongPasscode(let status) = try await unlocker.unlock(passcode: passcode("00000000"), now: now) else {
                Issue.record("wrong passcode not reported")
                return
            }
            #expect(status.attemptsBeforeErase == nil)
            now = status.retryAfter ?? now
        }
        #expect(unlocker.hasVault)
        guard case .success = try await unlocker.unlock(passcode: passcode("24681357"), now: now) else {
            Issue.record("vault did not survive")
            return
        }
    }

    @Test("an error unrelated to the passcode does not use up an attempt")
    func errorsDoNotCount() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))
        try fixture.device.destroySecret()

        await #expect(throws: VaultError.deviceSecretMissing) {
            try await unlocker.unlock(passcode: passcode("24681357"), now: start)
        }
        #expect(try await unlocker.status(now: start).failedAttempts == 0)
    }

    @Test("changing the passcode goes through the same attempt limits")
    func changePasscode() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))

        guard case .wrongPasscode(let status) = try await unlocker.changePasscode(current: passcode("99999999"), new: passcode("13579246"), now: start) else {
            Issue.record("wrong current passcode accepted")
            return
        }
        #expect(status.failedAttempts == 1)

        guard case .success = try await unlocker.changePasscode(current: passcode("24681357"), new: passcode("13579246"), now: start) else {
            Issue.record("passcode change failed")
            return
        }
        guard case .wrongPasscode = try await unlocker.unlock(passcode: passcode("24681357"), now: start) else {
            Issue.record("old passcode still works")
            return
        }
        guard case .success = try await unlocker.unlock(passcode: passcode("13579246"), now: start) else {
            Issue.record("new passcode does not work")
            return
        }
    }

    @Test("setup clears what an interrupted erase left behind")
    func setUpAfterInterruptedErase() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))
        // An erase that got as far as the header: old catalog and blobs remain.
        let leftovers = [
            fixture.store.catalogURL,
            fixture.store.blobsDirectory.appendingPathComponent("\(UUID().uuidString).bin"),
        ]
        for url in leftovers { try Data([1, 2, 3]).write(to: url) }
        try fixture.store.removeHeader()
        #expect(!unlocker.hasVault)

        let keyring = try await unlocker.setUp(passcode: passcode("11223344"))
        for url in leftovers {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        // The new vault opens: no stale catalog is in the way.
        let library = try await VaultLibrary.open(store: fixture.store, keyring: keyring)
        #expect(await library.items().isEmpty)
    }

    @Test("erase destroys the device secret, the files and the counter")
    func erase() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let unlocker = fixture.makeUnlocker()
        _ = try await unlocker.setUp(passcode: passcode("24681357"))
        _ = try await unlocker.unlock(passcode: passcode("00000000"), now: start)

        try await unlocker.erase()

        #expect(!unlocker.hasVault)
        #expect(!fixture.device.exists)
        #expect(try await unlocker.status(now: start).failedAttempts == 0)
        // A new vault can be created afterwards.
        _ = try await unlocker.setUp(passcode: passcode("11223344"))
        #expect(unlocker.hasVault)
    }
}

@Suite("Vault store")
struct VaultStoreTests {
    @Test("writes, reads and erases the header")
    func headerFile() throws {
        let store = temporaryVaultStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(!store.hasVault)

        try store.prepare()
        let header = try VaultHeader(decoding: Data(hex: ReferenceVectors.header))
        try store.writeHeader(header)
        #expect(store.hasVault)
        #expect(try store.readHeader() == header)

        try store.eraseFiles()
        #expect(!store.hasVault)
        try store.eraseFiles() // erasing twice is fine
    }
}
