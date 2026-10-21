import Foundation
import Testing
@testable import VaultCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("Albums")
struct AlbumTests {
    struct Fixture {
        let store = temporaryVaultStore()
        let keyring = VaultKeyring(masterKey: SymmetricKey(size: .bits256))

        func open() async throws -> VaultLibrary {
            try await VaultLibrary.open(store: store, keyring: keyring)
        }

        /// Imports `count` stand-in items (random bytes, no real media).
        func populate(_ library: VaultLibrary, count: Int) async throws -> [VaultItem] {
            var items: [VaultItem] = []
            for seed in 0..<count {
                let url = store.directory.appendingPathComponent("source-\(seed).bin")
                try randomData(2_000, seed: UInt64(seed)).write(to: url)
                let metadata = ImportMetadata(kind: .photo, uniformType: "public.jpeg", pixelWidth: 10, pixelHeight: 10)
                items.append(try await library.importFile(at: url, metadata: metadata, thumbnailJPEG: Data([UInt8(seed)])))
            }
            try await library.commit()
            return items
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: store.directory)
        }
    }

    @Test("create, rename and delete, persisted across unlocks")
    func lifecycle() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()

        let trips = try await library.createAlbum(named: "  Trips  ")
        let family = try await library.createAlbum(named: "Family")
        #expect(trips.name == "Trips")
        try await library.renameAlbum(trips.id, to: "Holidays")
        #expect(try await fixture.open().albums().map(\.name) == ["Holidays", "Family"])

        try await library.deleteAlbum(family.id)
        #expect(try await fixture.open().albums().map(\.id) == [trips.id])
    }

    @Test("rejects empty and overlong names, and unknown albums")
    func validation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()

        await #expect(throws: VaultError.invalidAlbumName) { try await library.createAlbum(named: "   ") }
        await #expect(throws: VaultError.invalidAlbumName) {
            try await library.createAlbum(named: String(repeating: "a", count: Album.maximumNameLength + 1))
        }
        await #expect(throws: VaultError.albumNotFound) { try await library.renameAlbum(UUID(), to: "X") }
        await #expect(throws: VaultError.albumNotFound) { try await library.deleteAlbum(UUID()) }
    }

    @Test("adding is ordered, ignores duplicates and unknown items; removing keeps items in the library")
    func membership() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let items = try await fixture.populate(library, count: 4)
        let album = try await library.createAlbum(named: "Favorites")

        try await library.addItems([items[2].id, items[0].id], toAlbum: album.id)
        try await library.addItems([items[0].id, UUID(), items[3].id], toAlbum: album.id)
        #expect(try await fixture.open().albums()[0].itemIDs == [items[2].id, items[0].id, items[3].id])

        try await library.removeItems([items[0].id], fromAlbum: album.id)
        #expect(await library.albums()[0].itemIDs == [items[2].id, items[3].id])
        #expect(await library.items().count == 4)
    }

    @Test("deleting an item removes it from every album; deleting an album keeps its items")
    func deletionInteractions() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = try await fixture.open()
        let items = try await fixture.populate(library, count: 3)
        let first = try await library.createAlbum(named: "One")
        let second = try await library.createAlbum(named: "Two")
        try await library.addItems(items.map(\.id), toAlbum: first.id)
        try await library.addItems([items[1].id], toAlbum: second.id)

        try await library.delete([items[1].id])
        let albums = try await fixture.open().albums()
        #expect(albums[0].itemIDs == [items[0].id, items[2].id])
        #expect(albums[1].itemIDs.isEmpty)

        try await library.deleteAlbum(first.id)
        #expect(await library.items().count == 2)
    }
}
