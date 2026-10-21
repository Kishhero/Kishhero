import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The decrypted contents of `index.enc`.
struct CatalogDocument: Codable, Sendable {
    var version = 1
    var items: [VaultItem] = []
    var albums: [Album] = []
}

/// The encrypted envelope of `index.enc`.
///
///     index.enc = "PVCT" || 0x01 || 00 00 00 || salt (32) || stream blob
///     key       = HKDF-SHA256(indexKey, salt, "PhotoVault v1 catalog")
///
/// Every save draws a new random salt and so a new key. The catalog is
/// rewritten many times under one index key; a fresh key per save means its
/// stream nonces can never repeat, however often it is saved. This is the
/// same idea as Tink's AES-GCM-HKDF streaming AEAD.
///
/// Padded with Padmé like every blob, so its size gives away only a rough
/// item count.
enum CatalogFile {
    static func seal(_ plaintext: Data, indexKey: SymmetricKey, random: any RandomBytesGenerator = SecureRandom()) throws -> Data {
        let salt = try random.bytes(Format.Catalog.saltSize)
        let header = Data(Format.Catalog.magic) + [Format.Catalog.version, 0, 0, 0] + salt
        var sealed = header
        try StreamCipher.encrypt(
            DataByteSource(plaintext),
            key: fileKey(indexKey: indexKey, salt: salt),
            context: header,
            chunkSize: .standard,
            padding: .padme,
            random: random
        ) { sealed.append($0) }
        return sealed
    }

    static func open(_ data: Data, indexKey: SymmetricKey) throws -> Data {
        let headerSize = Format.Catalog.headerSize
        let bytes = [UInt8](data)
        guard bytes.count > headerSize, Array(bytes[0..<4]) == Format.Catalog.magic else {
            throw VaultError.malformedData
        }
        guard bytes[4] == Format.Catalog.version else { throw VaultError.unsupportedVersion(bytes[4]) }
        guard bytes[5] == 0, bytes[6] == 0, bytes[7] == 0 else { throw VaultError.malformedData }
        let header = Data(bytes[0..<headerSize])
        let salt = Array(bytes[8..<headerSize])
        let blob = DataByteSource(Data(bytes[headerSize...]))
        return try StreamDecryptor(source: blob, key: fileKey(indexKey: indexKey, salt: salt), context: header).readAll()
    }

    private static func fileKey(indexKey: SymmetricKey, salt: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: indexKey, salt: salt, info: Format.Label.catalog, outputByteCount: Format.Header.keySize)
    }
}

/// The catalog in memory, and the only code that writes `index.enc`.
///
/// An actor so that imports running in parallel, deletions and album edits
/// cannot lose each other's changes.
public actor VaultCatalog {
    private var document: CatalogDocument
    private var isDirty = false
    /// Set when the vault locks. A task that outlives the lock (iOS can
    /// suspend it and resume it after the next unlock) must never write its
    /// stale catalog over a newer session's.
    private var isClosed = false
    private let url: URL
    private let keyring: VaultKeyring

    private init(document: CatalogDocument, url: URL, keyring: VaultKeyring) {
        self.document = document
        self.url = url
        self.keyring = keyring
    }

    struct Loaded {
        let catalog: VaultCatalog
        /// `index.enc` was damaged and the previous save was used instead.
        let recoveredFromBackup: Bool
    }

    /// The catalog as it was one save ago (`index.prev.enc`).
    ///
    /// `index.enc` holds every item key, so losing it would lose the whole
    /// vault. The backup turns a damaged catalog into, at worst, losing the
    /// changes of the last save. Items in that save can't be recovered either
    /// way, because their keys were only in the damaged file.
    static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("index.prev.enc", isDirectory: false)
    }

    /// Returns nil when neither `index.enc` nor its backup exists yet.
    static func load(url: URL, keyring: VaultKeyring) throws -> Loaded? {
        let fileManager = FileManager.default
        let backup = backupURL(for: url)
        let hasMain = fileManager.fileExists(atPath: url.path)
        guard hasMain || fileManager.fileExists(atPath: backup.path) else { return nil }

        var mainError: (any Error)?
        if hasMain {
            // A read error is not damage (for example, the files are still
            // protected): fail instead of falling back to an older catalog.
            let data = try Data(contentsOf: url)
            do {
                return Loaded(catalog: VaultCatalog(document: try decode(data, keyring: keyring), url: url, keyring: keyring), recoveredFromBackup: false)
            } catch {
                mainError = error
            }
        }
        do {
            let document = try decode(Data(contentsOf: backup), keyring: keyring)
            if hasMain {
                // Replace the damaged file now, without touching the good backup.
                try fileManager.removeItem(at: url)
                try write(document, to: url, keyring: keyring)
            }
            // Without a main file this is just a save interrupted between
            // its two steps (see `write`); nothing is lost, so nothing to report.
            return Loaded(catalog: VaultCatalog(document: document, url: url, keyring: keyring), recoveredFromBackup: hasMain)
        } catch {
            // A different vault's keys fail on both files: report the main error.
            throw mainError ?? error
        }
    }

    private static func decode(_ data: Data, keyring: VaultKeyring) throws -> CatalogDocument {
        let plaintext = try CatalogFile.open(data, indexKey: keyring.indexKey)
        let document = try JSONDecoder().decode(CatalogDocument.self, from: plaintext)
        guard document.version == 1 else { throw VaultError.unsupportedVersion(UInt8(clamping: document.version)) }
        return document
    }

    static func create(url: URL, keyring: VaultKeyring) throws -> VaultCatalog {
        let document = CatalogDocument()
        try Self.write(document, to: url, keyring: keyring)
        return VaultCatalog(document: document, url: url, keyring: keyring)
    }

    public var items: [VaultItem] { document.items }
    public var albums: [Album] { document.albums }

    func item(_ id: UUID) -> VaultItem? {
        document.items.first { $0.id == id }
    }

    /// Kept in memory until `saveIfNeeded`, so a large import rewrites the
    /// catalog every few items rather than once per item.
    func add(_ item: VaultItem) throws {
        guard !isClosed else { throw VaultError.vaultClosed }
        document.items.append(item)
        isDirty = true
    }

    func close() {
        isClosed = true
    }

    /// Removes items (and their album memberships) and returns what was removed.
    func remove(_ ids: Set<UUID>) -> [VaultItem] {
        let removed = document.items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        document.items.removeAll { ids.contains($0.id) }
        for index in document.albums.indices {
            document.albums[index].itemIDs.removeAll { ids.contains($0) }
        }
        isDirty = true
        return removed
    }

    // MARK: Albums

    func createAlbum(named name: String, now: Date) throws -> Album {
        let album = Album(id: UUID(), name: try Album.validatedName(name), itemIDs: [], createdAt: now)
        document.albums.append(album)
        isDirty = true
        return album
    }

    func renameAlbum(_ id: UUID, to name: String) throws {
        let index = try albumIndex(id)
        document.albums[index].name = try Album.validatedName(name)
        isDirty = true
    }

    /// Deletes the album only; its items stay in the library, as in Photos.
    func deleteAlbum(_ id: UUID) throws {
        document.albums.remove(at: try albumIndex(id))
        isDirty = true
    }

    /// Appends items not already in the album, in the order given. IDs that
    /// aren't in the library are ignored.
    func addItems(_ ids: [UUID], toAlbum id: UUID) throws {
        let index = try albumIndex(id)
        let known = Set(document.items.map(\.id))
        var present = Set(document.albums[index].itemIDs)
        for itemID in ids where known.contains(itemID) && present.insert(itemID).inserted {
            document.albums[index].itemIDs.append(itemID)
        }
        isDirty = true
    }

    func removeItems(_ ids: Set<UUID>, fromAlbum id: UUID) throws {
        let index = try albumIndex(id)
        document.albums[index].itemIDs.removeAll { ids.contains($0) }
        isDirty = true
    }

    private func albumIndex(_ id: UUID) throws -> Int {
        guard let index = document.albums.firstIndex(where: { $0.id == id }) else { throw VaultError.albumNotFound }
        return index
    }

    func referencedBlobs() -> Set<UUID> {
        Set(document.items.flatMap { [$0.originalBlob, $0.thumbnailBlob] })
    }

    public func saveIfNeeded() throws {
        guard !isClosed else { throw VaultError.vaultClosed }
        guard isDirty else { return }
        try Self.write(document, to: url, keyring: keyring)
        isDirty = false
    }

    /// Keeps the current file as the backup, then writes the new one
    /// atomically. A crash at any point leaves at least one complete catalog:
    /// between the two steps only the backup exists, and `load` uses it.
    private static func write(_ document: CatalogDocument, to url: URL, keyring: VaultKeyring) throws {
        let plaintext = try JSONEncoder().encode(document)
        let sealed = try CatalogFile.seal(plaintext, indexKey: keyring.indexKey)
        let fileManager = FileManager.default
        let backup = backupURL(for: url)
        if fileManager.fileExists(atPath: url.path) {
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try fileManager.moveItem(at: url, to: backup)
        }
        try sealed.write(to: url, options: VaultStore.writeOptions)
        FileTimestamps.normalize(url)
    }
}
