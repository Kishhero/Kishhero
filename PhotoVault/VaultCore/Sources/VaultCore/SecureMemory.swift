import Sodium

public enum SecureMemory {
    /// Overwrites a buffer holding secret material with zeros, using libsodium's
    /// `sodium_memzero`, which the compiler cannot optimize away.
    ///
    /// Protects against: key bytes lingering in freed memory after the vault
    /// locks, where a later memory dump could find them.
    /// Does not protect against: copies Swift made that we no longer reference
    /// (arrays are copy-on-write), or an attacker reading memory while the vault
    /// is open. This is best-effort hygiene, not a guarantee.
    public static func zero(_ bytes: inout [UInt8]) {
        Sodium().utils.zero(&bytes)
    }
}
