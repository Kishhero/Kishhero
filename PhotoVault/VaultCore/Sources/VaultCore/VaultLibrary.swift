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
    /// The catalog was damaged and its previous save was used. Worth telling
    /// the user: the changes of that last save are gone.
    public let recoveredCatalogFromBackup: Bool

    private init(keyring: VaultKeyring, blobs: BlobStore, catalog: VaultCatalog, recoveredCatalogFromBackup: Bool) {
        self.keyring = keyring
        self.blobs = blobs
        self.catalog = catalog
        self.recoveredCatalogFromBackup = recoveredCatalogFromBackup
    }

    /// Decrypts the catalog and removes files a crash left behind.
    public static func open(store: VaultStore, keyring: VaultKeyring) async throws -> VaultLibrary {
        try store.prepare()
        let blobs = BlobStore(directory: store.blobsDirectory)
        let catalog: VaultCatalog
        var recovered = false
        if let loaded = try VaultCatalog.load(url: store.catalogURL, keyring: keyring) {
            catalog = loaded.catalog
            recovered = loaded.recoveredFromBackup
        } else {
            // Never start an empty catalog over existing files: garbage
            // collection would then delete every one of them.
            guard try blobs.allBlobIDs().isEmpty else { throw VaultError.catalogMissing }
            catalog = try VaultCatalog.create(url: store.catalogURL, keyring: keyring)
        }
        let library = VaultLibrary(keyring: keyring, blobs: blobs, catalog: catalog, recoveredCatalogFromBackup: recovered)
        // Safe only here, before any import can be in flight: an import writes
        // its blobs before adding them to the catalog.
        let referenced = await catalog.referencedBlobs()
        _ = try blobs.removeAll(except: referenced)
        store.clearStagingFolders()
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

    /// The whole original in memory. For photos; stream videos with
    /// `originalDecryptor(for:)` instead.
    public func originalData(for item: VaultItem) throws -> Data {
        try originalDecryptor(for: item).readAll()
    }

    /// Random-access reader for the original, decrypting one chunk at a time.
    /// Not thread-safe: use each one from a single queue.
    public func originalDecryptor(for item: VaultItem) throws -> StreamDecryptor {
        let keys = try ItemKeys(itemKey: keyring.unwrapItemKey(item.wrappedKey, itemID: item.id))
        return try blobs.open(item.originalBlob, key: keys.original, context: BlobContext.original(item.id))
    }

    /// Decrypts an original into a new file, 1 MiB at a time, with complete
    /// file protection. For handing to Photos, which then takes the file; the
    /// caller deletes it if that fails.
    public func writeOriginal(of item: VaultItem, to url: URL) throws {
        let reader = try originalDecryptor(for: item)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: BlobStore.newFileAttributes) else {
            throw VaultError.truncatedSource
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            while offset < reader.contentLength {
                let chunk = try reader.read(at: offset, count: 1 << 20)
                try handle.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
            }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: Albums

    /// All albums, in the order they were created.
    public func albums() async -> [Album] {
        await catalog.albums
    }

    /// Album changes are small and user-initiated, so each one is saved right away.
    public func createAlbum(named name: String, now: Date = Date()) async throws -> Album {
        let album = try await catalog.createAlbum(named: name, now: now)
        try await catalog.saveIfNeeded()
        return album
    }

    public func renameAlbum(_ id: UUID, to name: String) async throws {
        try await catalog.renameAlbum(id, to: name)
        try await catalog.saveIfNeeded()
    }

    public func deleteAlbum(_ id: UUID) async throws {
        try await catalog.deleteAlbum(id)
        try await catalog.saveIfNeeded()
    }

    public func addItems(_ ids: [UUID], toAlbum id: UUID) async throws {
        try await catalog.addItems(ids, toAlbum: id)
        try await catalog.saveIfNeeded()
    }

    public func removeItems(_ ids: Set<UUID>, fromAlbum id: UUID) async throws {
        try await catalog.removeItems(ids, fromAlbum: id)
        try await catalog.saveIfNeeded()
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
