import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Encrypted files under `blobs/`, one per original and one per thumbnail.
///
/// File names are random UUIDs that have nothing to do with the item's ID,
/// and timestamps are reset after writing, so the folder shows neither which
/// thumbnail belongs to which original nor when each was added.
///
/// Thread-safe: every write goes to a new file, so imports can run in
/// parallel without going through an actor.
public struct BlobStore: Sendable {
    let directory: URL

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".bin", isDirectory: false)
    }

    /// Encrypts `source` into a new blob and returns its ID.
    ///
    /// Written to a `.tmp` file and renamed only once complete and flushed,
    /// so a crash never leaves a half-written `.bin`.
    func write<Source: ByteSource>(_ source: Source, key: SymmetricKey, context: Data) throws -> UUID {
        let id = UUID()
        let final = url(for: id)
        let temporary = final.deletingPathExtension().appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: Self.newFileAttributes) else {
            throw VaultError.truncatedSource
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try StreamCipher.encrypt(source, key: key, context: context) { try handle.write(contentsOf: $0) }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.moveItem(at: temporary, to: final)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        FileTimestamps.normalize(final)
        return id
    }

    func open(_ id: UUID, key: SymmetricKey, context: Data) throws -> StreamDecryptor {
        try StreamDecryptor(source: FileByteSource(url: url(for: id)), key: key, context: context)
    }

    func delete(_ id: UUID) throws {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Every `.bin` file name in the folder, as blob IDs.
    func allBlobIDs() throws -> Set<UUID> {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(names.compactMap { name in
            name.hasSuffix(".bin") ? UUID(uuidString: String(name.dropLast(4))) : nil
        })
    }

    /// Deletes `.tmp` leftovers and every `.bin` not in `keep`. Returns how many files went.
    func removeAll(except keep: Set<UUID>) throws -> Int {
        var removed = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let isOrphan: Bool
            if name.hasSuffix(".tmp") {
                isOrphan = true
            } else if name.hasSuffix(".bin"), let id = UUID(uuidString: String(name.dropLast(4))) {
                isOrphan = !keep.contains(id)
            } else {
                isOrphan = false
            }
            if isOrphan {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                removed += 1
            }
        }
        return removed
    }

    static var newFileAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.complete]
        #else
        return nil
        #endif
    }
}

/// Keys for one item's two blobs, derived from its item key so that no key
/// ever encrypts more than one file.
struct ItemKeys {
    let original: SymmetricKey
    let thumbnail: SymmetricKey

    init(itemKey: SymmetricKey) {
        original = VaultKeyring.subkey(of: itemKey, label: Format.Label.blobOriginal)
        thumbnail = VaultKeyring.subkey(of: itemKey, label: Format.Label.blobThumbnail)
    }
}

/// The authenticated context binding a blob to its item and role, so a
/// thumbnail blob can never be passed off as an original, or one item's
/// blob as another's.
enum BlobContext {
    static func original(_ itemID: UUID) -> Data { Data("\(itemID.uuidString)/original".utf8) }
    static func thumbnail(_ itemID: UUID) -> Data { Data("\(itemID.uuidString)/thumbnail".utf8) }
}

enum FileTimestamps {
    /// 2020-01-01 00:00:00 UTC, for every vault file.
    static let normalized = Date(timeIntervalSince1970: 1_577_836_800)

    /// Best effort. Hides when items were added from a casual look at the
    /// files. A forensic examiner can still read inode numbers and change
    /// times, which reveal the order files were written, but never contents.
    static func normalize(_ url: URL) {
        var attributes: [FileAttributeKey: Any] = [.modificationDate: normalized]
        #if canImport(Darwin)
        attributes[.creationDate] = normalized
        #endif
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
