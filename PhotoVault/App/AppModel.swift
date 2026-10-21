import Foundation
import Observation
import os
import VaultCore

/// App-wide state: which screen is showing, and the keys while unlocked.
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

    /// The only reference to the vault's keys. Setting it to nil is locking.
    @ObservationIgnored private var keyring: VaultKeyring?
    /// Bumped on every lock, so an unlock that finishes after the app went to
    /// the background is thrown away instead of reopening the vault.
    @ObservationIgnored private var lockGeneration = 0

    let unlocker: VaultUnlocker

    /// Shows unlock and setup time in Instruments' "Points of Interest" track.
    /// Records timing only, never any data.
    private static let signposter = OSSignposter(subsystem: "PhotoVault", category: .pointsOfInterest)

    init(unlocker: VaultUnlocker) {
        self.unlocker = unlocker
        phase = unlocker.hasVault ? .locked : .setup
    }

    static func live() -> AppModel {
        AppModel(unlocker: VaultUnlocker(
            store: .standard(),
            deviceSecret: DeviceSecrets.platformDefault(),
            throttleStore: KeychainThrottleStore()
        ))
    }

    /// Drops the keys. Called whenever the app leaves the foreground, and by the Lock button.
    func lock() {
        lockGeneration += 1
        keyring = nil
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
            if generation == lockGeneration {
                self.keyring = keyring
                phase = .unlocked
            } else {
                phase = .locked
            }
            return true
        } catch {
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
            return apply(outcome) { keyring in
                guard generation == lockGeneration else { return }
                self.keyring = keyring
                phase = .unlocked
            }
        } catch {
            return .failed
        }
    }

    func changePasscode(current: PasscodeBuffer, new: PasscodeBuffer) async -> Feedback {
        guard !isWorking else { return .ignored }
        isWorking = true
        defer { isWorking = false }
        do {
            return apply(try await unlocker.changePasscode(current: current.bytes, new: new.bytes)) { _ in }
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
            try await unlocker.erase()
            didErase(notice: nil)
            return true
        } catch {
            return false
        }
    }

    private func apply<Value: Sendable>(_ outcome: AttemptOutcome<Value>, onSuccess: (Value) -> Void) -> Feedback {
        switch outcome {
        case .success(let value):
            status = nil
            onSuccess(value)
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
