import Foundation

/// The vault folder on disk: `Application Support/Vault/`.
///
/// Application Support is not visible in the Files app and, unlike Caches, is
/// never purged by iOS to free space.
///
/// Protects against: the vault ending up in iCloud or computer backups
/// (excluded explicitly), and its files being readable while the phone is
/// locked (`FileProtectionType.complete`: iOS evicts the file keys about 10
/// seconds after the phone locks).
/// Does not protect against: anything once the phone is unlocked. That is the
/// job of the vault's own encryption.
public struct VaultStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The real vault location. Tests must use a temporary directory instead.
    public static func standard() -> VaultStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VaultStore(directory: base.appendingPathComponent("Vault", isDirectory: true))
    }

    var headerURL: URL {
        directory.appendingPathComponent("vault.hdr", isDirectory: false)
    }

    /// Cheap enough for app launch: a single metadata lookup, which works even
    /// while file contents are protected.
    public var hasVault: Bool {
        FileManager.default.fileExists(atPath: headerURL.path)
    }

    /// Creates the folder with complete file protection, excluded from backups.
    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // New files inherit the folder's protection class; set it explicitly in
        // case the folder already existed.
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        #if canImport(Darwin)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #endif
    }

    public func readHeader() throws -> VaultHeader {
        try VaultHeader(decoding: Data(contentsOf: headerURL))
    }

    /// Atomic: a crash mid-write leaves the old header, never half of each.
    public func writeHeader(_ header: VaultHeader) throws {
        try header.encoded.write(to: headerURL, options: Self.writeOptions)
    }

    /// Deletes every vault file. Call only after the device secret has been
    /// destroyed, so the vault is already unreadable if this is interrupted.
    public func eraseFiles() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}
