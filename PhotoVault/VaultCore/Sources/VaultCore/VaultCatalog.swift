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
    private let url: URL
    private let keyring: VaultKeyring

    private init(document: CatalogDocument, url: URL, keyring: VaultKeyring) {
        self.document = document
        self.url = url
        self.keyring = keyring
    }

    /// Returns nil when `index.enc` does not exist yet.
    static func load(url: URL, keyring: VaultKeyring) throws -> VaultCatalog? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let plaintext = try CatalogFile.open(Data(contentsOf: url), indexKey: keyring.indexKey)
        let document = try JSONDecoder().decode(CatalogDocument.self, from: plaintext)
        guard document.version == 1 else { throw VaultError.unsupportedVersion(UInt8(clamping: document.version)) }
        return VaultCatalog(document: document, url: url, keyring: keyring)
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
    func add(_ item: VaultItem) {
        document.items.append(item)
        isDirty = true
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

    func referencedBlobs() -> Set<UUID> {
        Set(document.items.flatMap { [$0.originalBlob, $0.thumbnailBlob] })
    }

    public func saveIfNeeded() throws {
        guard isDirty else { return }
        try Self.write(document, to: url, keyring: keyring)
        isDirty = false
    }

    /// Atomic: a crash mid-save leaves the previous catalog intact.
    private static func write(_ document: CatalogDocument, to url: URL, keyring: VaultKeyring) throws {
        let plaintext = try JSONEncoder().encode(document)
        let sealed = try CatalogFile.seal(plaintext, indexKey: keyring.indexKey)
        try sealed.write(to: url, options: VaultStore.writeOptions)
        FileTimestamps.normalize(url)
    }
}
