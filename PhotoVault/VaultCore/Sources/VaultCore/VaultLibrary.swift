import Foundation

/// An unlocked vault: its keys, its catalog and its encrypted files.
///
/// Dropping the last reference to it is what locking means for the library.
///
/// Encryption and decryption run on the caller's task, not inside an actor,
/// so a long video import never stalls thumbnail loading. Only catalog
/// changes are serialized, through `VaultCatalog`. Call the heavy methods
/// from background tasks, never from the main actor.
public final class VaultLibrary: Sendable {
    let keyring: VaultKeyring
    let blobs: BlobStore
    let catalog: VaultCatalog

    private init(keyring: VaultKeyring, blobs: BlobStore, catalog: VaultCatalog) {
        self.keyring = keyring
        self.blobs = blobs
        self.catalog = catalog
    }

    /// Decrypts the catalog and removes files a crash left behind.
    public static func open(store: VaultStore, keyring: VaultKeyring) async throws -> VaultLibrary {
        try store.prepare()
        let blobs = BlobStore(directory: store.blobsDirectory)
        let catalog: VaultCatalog
        if let existing = try VaultCatalog.load(url: store.catalogURL, keyring: keyring) {
            catalog = existing
        } else {
            // Never start an empty catalog over existing files: garbage
            // collection would then delete every one of them.
            guard try blobs.allBlobIDs().isEmpty else { throw VaultError.catalogMissing }
            catalog = try VaultCatalog.create(url: store.catalogURL, keyring: keyring)
        }
        let library = VaultLibrary(keyring: keyring, blobs: blobs, catalog: catalog)
        // Safe only here, before any import can be in flight: an import writes
        // its blobs before adding them to the catalog.
        let referenced = await catalog.referencedBlobs()
        _ = try blobs.removeAll(except: referenced)
        store.clearIncoming()
        return library
    }

    /// All items, oldest first, like the Photos library.
    public func items() async -> [VaultItem] {
        await catalog.items.sorted { $0.sortDate < $1.sortDate }
    }

    /// Encrypts a file and its thumbnail and adds the item to the catalog in
    /// memory. Call `commit()` to persist; until then, a crash loses the item
    /// (its blobs are cleaned up on the next unlock) but never corrupts anything.
    ///
    /// Memory use is flat: the file is read and encrypted 256 KiB at a time.
    public func importFile(at url: URL, metadata: ImportMetadata, thumbnailJPEG: Data, now: Date = Date()) async throws -> VaultItem {
        let id = UUID()
        let itemKey = VaultKeyring.newItemKey()
        let keys = ItemKeys(itemKey: itemKey)
        let source = try FileByteSource(url: url)
        let originalBlob = try blobs.write(source, key: keys.original, context: BlobContext.original(id))
        let item: VaultItem
        do {
            let thumbnailBlob = try blobs.write(DataByteSource(thumbnailJPEG), key: keys.thumbnail, context: BlobContext.thumbnail(id))
            item = VaultItem(
                id: id,
                kind: metadata.kind,
                addedAt: now,
                capturedAt: metadata.capturedAt,
                originalFilename: metadata.originalFilename,
                uniformType: metadata.uniformType,
                pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight,
                duration: metadata.duration,
                byteCount: source.size,
                wrappedKey: try keyring.wrapItemKey(itemKey, itemID: id),
                originalBlob: originalBlob,
                thumbnailBlob: thumbnailBlob
            )
        } catch {
            try? blobs.delete(originalBlob)
            throw error
        }
        await catalog.add(item)
        return item
    }

    /// Writes the catalog if anything changed since the last commit.
    public func commit() async throws {
        try await catalog.saveIfNeeded()
    }

    /// The decrypted JPEG thumbnail (about 512 px). Safe to call from many
    /// tasks at once.
    public func thumbnailData(for item: VaultItem) throws -> Data {
        let keys = try ItemKeys(itemKey: keyring.unwrapItemKey(item.wrappedKey, itemID: item.id))
        return try blobs.open(item.thumbnailBlob, key: keys.thumbnail, context: BlobContext.thumbnail(item.id)).readAll()
    }

    /// Removes items for good.
    ///
    /// The catalog is saved first and the files deleted after, so a crash in
    /// between leaves only unreferenced files, which the next unlock removes.
    /// Deleting the files destroys their per-file iOS Data Protection keys,
    /// and the item keys are gone with the catalog entry, so leftover flash
    /// blocks are unreadable.
    public func delete(_ ids: Set<UUID>) async throws {
        let removed = await catalog.remove(ids)
        guard !removed.isEmpty else { return }
        try await catalog.saveIfNeeded()
        for item in removed {
            try? blobs.delete(item.originalBlob)
            try? blobs.delete(item.thumbnailBlob)
        }
    }
}
