import Observation
import VaultCore

enum PasscodeKind: String {
    case digits
    case passphrase
}

enum Preferences {
    /// Whether the passcode is digits or a passphrase, so the lock screen
    /// shows the right input. Kept in UserDefaults: it reveals only which kind
    /// of passcode is used, never anything about the passcode itself.
    static let passcodeKind = "passcodeKind"
    static let shuffleKeypad = "shuffleKeypad"
}

/// A passcode as it is typed: raw bytes, never a `String`.
///
/// Strings cannot be wiped and get copied freely. This buffer reserves its
/// full capacity up front (so appending never leaves old copies behind in
/// reallocated memory) and is zeroed as soon as the passcode has been used.
///
/// Limitation: passphrase mode has to go through SwiftUI's `SecureField`,
/// which holds a `String` that we cannot wipe; it is cleared right after use.
@MainActor
@Observable
final class PasscodeBuffer {
    private(set) var count = 0
    @ObservationIgnored private var storage: [UInt8]

    init() {
        storage = []
        storage.reserveCapacity(PasscodePolicy.maximumLength)
    }

    var bytes: [UInt8] { storage }

    func append(asciiDigit digit: UInt8) {
        guard digit <= 9, storage.count < PasscodePolicy.maximumLength else { return }
        storage.append(UInt8(ascii: "0") + digit)
        count = storage.count
    }

    func removeLast() {
        guard !storage.isEmpty else { return }
        storage[storage.count - 1] = 0
        storage.removeLast()
        count = storage.count
    }

    func replace(withUTF8 text: String) {
        wipe()
        storage.append(contentsOf: text.utf8.prefix(PasscodePolicy.maximumLength))
        count = storage.count
    }

    func copy(from other: PasscodeBuffer) {
        wipe()
        storage.append(contentsOf: other.storage)
        count = storage.count
    }

    func matches(_ other: PasscodeBuffer) -> Bool {
        storage == other.storage
    }

    func wipe() {
        SecureMemory.zero(&storage)
        storage.removeAll(keepingCapacity: true)
        count = 0
    }
}
