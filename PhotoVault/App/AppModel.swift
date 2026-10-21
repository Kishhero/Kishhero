import Foundation
import Observation
import os
import VaultCore

/// App-wide state: which screen is showing, and the open vault while unlocked.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case setup
        case locked
        case unlocked
    }

    enum Feedback: Equatable {
        case succeeded
        case wrongPasscode
        case throttled
        case erased
        case failed
        /// Another attempt was already running; nothing was tried.
        case ignored
    }

    enum Notice: Equatable {
        case erasedAfterFailedAttempts
    }

    private(set) var phase: Phase
    private(set) var status: UnlockStatus?
    private(set) var isWorking = false
    private(set) var notice: Notice?
    /// Mirrors the stored setting so a Toggle can bind to it; saved by the
    /// view via `saveEraseAfterFailures`.
    var eraseAfterFailures = false
    /// The open vault. It holds the only references to the keys and to the
    /// decrypted thumbnails, so setting it to nil is locking.
    private(set) var library: LibraryModel?

    /// Bumped on every lock, so an unlock that finishes after the app went to
    /// the background is thrown away instead of reopening the vault.
    @ObservationIgnored private var lockGeneration = 0

    let unlocker: VaultUnlocker
    let store: VaultStore

    private static let signposter = Signposts.make()

    init(unlocker: VaultUnlocker, store: VaultStore) {
        self.unlocker = unlocker
        self.store = store
        phase = unlocker.hasVault ? .locked : .setup
        // Unencrypted leftovers from an import interrupted by a crash. Needs no
        // keys, and runs off the launch path.
        Task.detached(priority: .utility) {
            store.clearStagingFolders()
        }
    }

    static func live() -> AppModel {
        let store = VaultStore.standard()
        return AppModel(
            unlocker: VaultUnlocker(
                store: store,
                deviceSecret: DeviceSecrets.platformDefault(),
                throttleStore: KeychainThrottleStore()
            ),
            store: store
        )
    }

    /// Drops the keys. Called whenever the app leaves the foreground, and by the Lock button.
    func lock() {
        lockGeneration += 1
        library?.close()
        library = nil
        if phase == .unlocked {
            phase = .locked
        }
    }

    func refreshStatus() async {
        status = try? await unlocker.status()
        eraseAfterFailures = status?.eraseEnabled ?? false
    }

    func setUp(with passcode: PasscodeBuffer) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let generation = lockGeneration
        let interval = Self.signposter.beginInterval("Create vault")
        defer { Self.signposter.endInterval("Create vault", interval) }
        do {
            let keyring = try await unlocker.setUp(passcode: passcode.bytes)
            notice = nil
            status = nil
            let opened = try await open(keyring, generation: generation)
            if !opened {
                phase = .locked
            }
            return true
        } catch {
            // The vault may exist even if opening it failed; show the lock
            // screen rather than offering to create another one.
            if unlocker.hasVault { phase = .locked }
            return false
        }
    }

    func unlock(with passcode: PasscodeBuffer) async -> Feedback {
        guard !isWorking else { return .ignored }
        isWorking = true
        defer { isWorking = false }
        let generation = lockGeneration
        let interval = Self.signposter.beginInterval("Unlock")
        defer { Self.signposter.endInterval("Unlock", interval) }
        do {
            let outcome = try await unlocker.unlock(passcode: passcode.bytes)
            let result = feedback(for: outcome)
            if case .success(let keyring) = outcome {
                _ = try await open(keyring, generation: generation)
            }
            return result
        } catch {
            return .failed
        }
    }

    func changePasscode(current: PasscodeBuffer, new: PasscodeBuffer) async -> Feedback {
        guard !isWorking else { return .ignored }
        isWorking = true
        defer { isWorking = false }
        do {
            return feedback(for: try await unlocker.changePasscode(current: current.bytes, new: new.bytes))
        } catch {
            return .failed
        }
    }

    func saveEraseAfterFailures(_ enabled: Bool) async {
        try? await unlocker.setEraseAfterFailures(enabled)
        await refreshStatus()
    }

    func erase() async -> Bool {
        do {
            library?.close()
            try await unlocker.erase()
            didErase(notice: nil)
            return true
        } catch {
            return false
        }
    }

    /// Decrypts the catalog and shows the library. Returns false, and stays
    /// locked, if the app was locked while this ran.
    private func open(_ keyring: VaultKeyring, generation: Int) async throws -> Bool {
        let vault = try await VaultLibrary.open(store: store, keyring: keyring)
        guard generation == lockGeneration else { return false }
        let library = LibraryModel(vault: vault)
        await library.reload()
        guard generation == lockGeneration else { return false }
        self.library = library
        phase = .unlocked
        return true
    }

    private func feedback<Value: Sendable>(for outcome: AttemptOutcome<Value>) -> Feedback {
        switch outcome {
        case .success:
            status = nil
            return .succeeded
        case .wrongPasscode(let newStatus):
            status = newStatus
            return .wrongPasscode
        case .throttled(let newStatus):
            status = newStatus
            return .throttled
        case .erased:
            didErase(notice: .erasedAfterFailedAttempts)
            return .erased
        }
    }

    private func didErase(notice: Notice?) {
        lock()
        status = nil
        eraseAfterFailures = false
        self.notice = notice
        phase = .setup
    }
}
