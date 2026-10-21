import Foundation
import Testing
@testable import VaultCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("Catalog file")
struct CatalogFileTests {
    let indexKey = SymmetricKey(hex: ReferenceVectors.indexKey)

    @Test("matches the reference envelope byte for byte")
    func knownAnswer() throws {
        let sealed = try CatalogFile.seal(
            pattern(ReferenceVectors.catalogLength),
            indexKey: indexKey,
            random: FixedRandom(Data(hex: ReferenceVectors.catalogSalt), Data(hex: ReferenceVectors.streamNoncePrefix))
        )
        #expect(sealed.count == ReferenceVectors.catalogSize)
        #expect(sha256Hex(sealed) == ReferenceVectors.catalogSHA256)
        #expect(try CatalogFile.open(sealed, indexKey: indexKey) == pattern(ReferenceVectors.catalogLength))
    }

    @Test("every save uses a new salt, so a new key")
    func freshKeyPerSave() throws {
        let first = try CatalogFile.seal(pattern(100), indexKey: indexKey)
        let second = try CatalogFile.seal(pattern(100), indexKey: indexKey)
        #expect(first[8..<40] != second[8..<40])
        #expect(first != second)
    }

    @Test("rejects the wrong key, edits and truncation")
    func integrity() throws {
        let sealed = try CatalogFile.seal(pattern(5_000), indexKey: indexKey)
        #expect(throws: VaultError.authenticationFailed) {
            try CatalogFile.open(sealed, indexKey: SymmetricKey(size: .bits256))
        }
        for offset in [0, 4, 5, 8, 39, 40, 60, sealed.count - 1] {
            var tampered = sealed
            tampered[offset] ^= 0x10
            #expect(throws: (any Error).self, "edit at \(offset) accepted") { try CatalogFile.open(tampered, indexKey: indexKey) }
        }
        #expect(throws: (any Error).self) { try CatalogFile.open(sealed.prefix(40), indexKey: indexKey) }
    }

    @Test("per-blob keys match the reference")
    func blobKeys() {
        let keys = ItemKeys(itemKey: SymmetricKey(hex: ReferenceVectors.itemKey))
        #expect(keys.original.rawData.hex == ReferenceVectors.originalBlobKey)
        #expect(keys.thumbnail.rawData.hex == ReferenceVectors.thumbnailBlobKey)
    }
}

@Suite("Vault library")
struct VaultLibraryTests {
    struct Fixture {
        let store = temporaryVaultStore()
        let keyring = VaultKeyring(masterKey: SymmetricKey(size: .bits256))

        func open() async throws -> VaultLibrary {
            try await VaultLibrary.open(store: store, keyring: keyring)
        }

        /// A stand-in "photo": random bytes in a file. No real image is used.
        func makeFile(_ length: Int, seed: UInt64) throws -> (URL, Data) {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let url = store.directory.appendingPathComponent("source-\(seed).bin")
            let content = randomData(length, seed: seed)
            try content.write(to: url)
            return (url, content)
        }

        var blobFiles: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: store.blobsDirectory.path)) ?? []
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: store.directory)
        }
    }

    let metadata = ImportMetadata(kind: .photo, uniformType: "public.heic", originalFilename: "IMG_0001.HEIC", pixelWidth: 4032, pixelHeight: 3024)

    @Test("imports, commits, and reopens with the same items and thumbnails")
    func importAndReopen() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let (file, content) = try fixture.makeFile(600_000, seed: 1)
        let thumbnail = randomData(30_000, seed: 2)

        let item = try await library.importFile(at: file, metadata: metadata, thumbnailJPEG: thumbnail)
        #expect(item.byteCount == UInt64(content.count))
        #expect(try library.thumbnailData(for: item) == thumbnail)
        try await library.commit()

        let reopened = try await fixture.open()
        let items = await reopened.items()
        #expect(items == [item])
        #expect(try reopened.thumbnailData(for: items[0]) == thumbnail)

        // The original decrypts back to the exact input bytes.
        let keys = try ItemKeys(itemKey: fixture.keyring.unwrapItemKey(item.wrappedKey, itemID: item.id))
        let original = try reopened.blobs.open(item.originalBlob, key: keys.original, context: BlobContext.original(item.id))
        #expect(try original.readAll() == content)
    }

    @Test("an item that was never committed is cleaned up on the next unlock")
    func uncommittedImportIsCollected() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let (file, _) = try fixture.makeFile(10_000, seed: 3)
        _ = try await library.importFile(at: file, metadata: metadata, thumbnailJPEG: Data([1, 2, 3]))
        #expect(fixture.blobFiles.count == 2)

        let reopened = try await fixture.open() // simulates a crash before commit
        #expect(await reopened.items().isEmpty)
        #expect(fixture.blobFiles.isEmpty)
    }

    @Test("blob names reveal nothing about items, and leftovers are removed")
    func blobHygiene() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let (file, _) = try fixture.makeFile(10_000, seed: 4)
        let item = try await library.importFile(at: file, metadata: metadata, thumbnailJPEG: Data([9]))
        try await library.commit()

        #expect(fixture.blobFiles.allSatisfy { !$0.contains(item.id.uuidString) })
        for name in fixture.blobFiles {
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.store.blobsDirectory.appendingPathComponent(name).path)
            #expect(attributes[.modificationDate] as? Date == FileTimestamps.normalized)
        }

        // A half-written file and an orphan from a crash, plus a staged import.
        try Data([0]).write(to: fixture.store.blobsDirectory.appendingPathComponent("\(UUID().uuidString).tmp"))
        try Data([0]).write(to: fixture.store.blobsDirectory.appendingPathComponent("\(UUID().uuidString).bin"))
        try Data([0]).write(to: fixture.store.incomingDirectory.appendingPathComponent("IMG_0002.HEIC"))
        _ = try await fixture.open()
        #expect(fixture.blobFiles.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.incomingDirectory.path).isEmpty)
    }

    @Test("delete removes the catalog entry first, then the files")
    func delete() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        var imported: [VaultItem] = []
        for seed in UInt64(10)..<UInt64(13) {
            let (file, _) = try fixture.makeFile(5_000, seed: seed)
            imported.append(try await library.importFile(at: file, metadata: metadata, thumbnailJPEG: Data([UInt8(seed)])))
        }
        try await library.commit()
        #expect(fixture.blobFiles.count == 6)

        try await library.delete([imported[0].id, imported[2].id])

        #expect(await library.items().map(\.id) == [imported[1].id])
        #expect(fixture.blobFiles.count == 2)
        #expect(try await fixture.open().items().map(\.id) == [imported[1].id])
    }

    @Test("a missing catalog with files present refuses to open instead of deleting them")
    func missingCatalogIsNotTreatedAsEmpty() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let (file, _) = try fixture.makeFile(5_000, seed: 20)
        _ = try await library.importFile(at: file, metadata: metadata, thumbnailJPEG: Data([1]))
        try await library.commit()
        try FileManager.default.removeItem(at: fixture.store.catalogURL)

        await #expect(throws: VaultError.catalogMissing) { try await fixture.open() }
        #expect(fixture.blobFiles.count == 2)
    }

    @Test("a different vault's keys cannot read the catalog or the thumbnails")
    func otherKeysFail() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let (file, _) = try fixture.makeFile(5_000, seed: 30)
        let item = try await library.importFile(at: file, metadata: metadata, thumbnailJPEG: Data([1]))
        try await library.commit()

        let intruder = VaultKeyring(masterKey: SymmetricKey(size: .bits256))
        await #expect(throws: VaultError.authenticationFailed) {
            try await VaultLibrary.open(store: fixture.store, keyring: intruder)
        }
        // Even with the catalog entry in hand, the item key won't unwrap.
        #expect(throws: VaultError.authenticationFailed) {
            try intruder.unwrapItemKey(item.wrappedKey, itemID: item.id)
        }
    }

    @Test("items come back oldest first by capture date")
    func ordering() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [UUID] = []
        for (seed, offset) in [(40, 300.0), (41, 100.0), (42, 200.0)] {
            let (file, _) = try fixture.makeFile(1_000, seed: UInt64(seed))
            var meta = metadata
            meta.capturedAt = base.addingTimeInterval(offset)
            ids.append(try await library.importFile(at: file, metadata: meta, thumbnailJPEG: Data([1])).id)
        }
        #expect(await library.items().map(\.id) == [ids[1], ids[2], ids[0]])
    }
}
