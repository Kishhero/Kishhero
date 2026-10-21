import Foundation

/// Persistent record of wrong passcode attempts.
public struct ThrottleState: Codable, Equatable, Sendable {
    public var failedAttempts = 0
    /// No attempt is allowed before this moment.
    public var lockedUntil: Date?
    /// When the most recent attempt started; used to notice the clock being turned back.
    public var lastAttempt: Date?
    /// Opt-in: destroy the vault after `UnlockPolicy.eraseAfterFailures` wrong attempts in a row.
    public var eraseEnabled = false

    public init() {}
}

public protocol ThrottleStateStore: Sendable {
    func load() throws -> ThrottleState
    func save(_ state: ThrottleState) throws
}

/// How many wrong attempts are free, and how long each one after that locks the keypad.
public struct UnlockPolicy: Sendable {
    public var freeAttempts: Int
    /// Wait after each failure past the free ones; the last value repeats.
    public var delays: [TimeInterval]
    public var eraseAfterFailures: Int

    public init(freeAttempts: Int, delays: [TimeInterval], eraseAfterFailures: Int) {
        precondition(!delays.isEmpty && freeAttempts >= 0 && eraseAfterFailures > 0)
        self.freeAttempts = freeAttempts
        self.delays = delays
        self.eraseAfterFailures = eraseAfterFailures
    }

    /// 4 free tries, then 30 s, 1 min, 5 min, 15 min, and 1 hour per try after that.
    /// Erase (if enabled) happens on the 10th wrong attempt in a row.
    public static let standard = UnlockPolicy(freeAttempts: 4, delays: [30, 60, 300, 900, 3600], eraseAfterFailures: 10)

    func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > freeAttempts else { return 0 }
        return delays[min(failures - freeAttempts, delays.count) - 1]
    }
}

/// What the lock screen needs to show.
public struct UnlockStatus: Equatable, Sendable {
    public let failedAttempts: Int
    /// Set while the keypad is locked out; nil when an attempt is allowed now.
    public let retryAfter: Date?
    public let eraseEnabled: Bool
    /// Wrong attempts left before the vault is erased; nil when erase is off.
    public let attemptsBeforeErase: Int?

    init(state: ThrottleState, policy: UnlockPolicy, now: Date) {
        failedAttempts = state.failedAttempts
        retryAfter = state.lockedUntil.flatMap { $0 > now ? $0 : nil }
        eraseEnabled = state.eraseEnabled
        attemptsBeforeErase = state.eraseEnabled ? max(0, policy.eraseAfterFailures - state.failedAttempts) : nil
    }
}

/// Slows down guessing through the app's own lock screen.
///
/// Protects against: someone with the unlocked phone trying passcodes by hand.
/// With the standard policy, 10 guesses take over an hour, and the opt-in
/// erase ends the vault at the 10th.
/// Does not protect against: an attacker who copies the files and the device
/// secret off a compromised phone. They never go through this screen, and
/// Argon2id plus passcode length is what stops them. It also trusts the
/// phone's clock: turning the clock back restarts the wait, but turning it
/// forward skips it. A deterrent, not a cryptographic control.
struct UnlockThrottle: Sendable {
    let store: any ThrottleStateStore
    let policy: UnlockPolicy

    func status(now: Date) throws -> UnlockStatus {
        var state = try store.load()
        if let last = state.lastAttempt, now < last {
            // The clock went backwards since the last attempt. Restart the
            // current delay from now, so turning the clock back never shortens it.
            let delay = policy.delay(afterFailures: state.failedAttempts)
            state.lockedUntil = delay > 0 ? now.addingTimeInterval(delay) : nil
            state.lastAttempt = now
            try store.save(state)
        }
        return UnlockStatus(state: state, policy: policy, now: now)
    }

    /// Counts an attempt as failed before its result is known. Killing the
    /// app while the KDF runs therefore cannot be used to get a free guess.
    /// Returns the previous state, for `restore` if the attempt never ran.
    func beginAttempt(now: Date) throws -> ThrottleState {
        let previous = try store.load()
        var state = previous
        state.failedAttempts += 1
        state.lastAttempt = now
        let delay = policy.delay(afterFailures: state.failedAttempts)
        state.lockedUntil = delay > 0 ? now.addingTimeInterval(delay) : nil
        try store.save(state)
        return previous
    }

    /// Undo `beginAttempt` when the attempt failed for a reason that says
    /// nothing about the passcode (for example, the Keychain was unavailable).
    func restore(_ state: ThrottleState) throws {
        try store.save(state)
    }

    func recordSuccess() throws {
        var state = try store.load()
        state.failedAttempts = 0
        state.lockedUntil = nil
        try store.save(state)
    }

    func shouldErase(now: Date) throws -> Bool {
        let state = try store.load()
        return state.eraseEnabled && state.failedAttempts >= policy.eraseAfterFailures
    }

    func setEraseEnabled(_ enabled: Bool) throws {
        var state = try store.load()
        state.eraseEnabled = enabled
        try store.save(state)
    }

    func reset() throws {
        try store.save(ThrottleState())
    }
}
