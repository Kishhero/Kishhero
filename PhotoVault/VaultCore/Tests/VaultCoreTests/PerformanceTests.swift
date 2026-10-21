import Foundation
import XCTest
@testable import VaultCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Throughput baselines for the hot paths. In Xcode, run these with the
/// Release configuration and set a baseline from the first run's result;
/// later runs then fail if a change makes them noticeably slower.
///
/// XCTest rather than Swift Testing, because it has `measure`.
final class PerformanceTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    /// Encrypting a 32 MiB "video". AES-GCM is hardware-accelerated on
    /// iPhone, so this should be far faster than reading the file from flash.
    func testStreamEncryptionThroughput() {
        let content = DataByteSource(Data(count: 32 << 20))
        measure {
            var written = 0
            try? StreamCipher.encrypt(content, key: key, context: Data()) { written += $0.count }
            XCTAssertGreaterThan(written, 32 << 20)
        }
    }

    /// What video seeking costs: 200 reads of 64 KiB at random offsets.
    func testRandomAccessReads() throws {
        let length = 32 << 20
        var blob = Data()
        try StreamCipher.encrypt(DataByteSource(Data(count: length)), key: key, context: Data()) { blob.append($0) }
        var generator = SplitMix64(state: 1)
        let offsets = (0..<200).map { _ in UInt64.random(in: 0..<UInt64(length - 65_536), using: &generator) }
        measure {
            guard let decryptor = try? StreamDecryptor(source: DataByteSource(blob), key: key, context: Data()) else {
                return XCTFail("could not open blob")
            }
            for offset in offsets {
                XCTAssertEqual(try? decryptor.read(at: offset, count: 65_536).count, 65_536)
            }
        }
    }

    /// Saving the catalog of a 10,000-item vault: JSON encoding plus
    /// encryption. The app saves every 10 imported items and on every album
    /// change, so this bounds that cost.
    func testCatalogSaveWithTenThousandItems() throws {
        let keyring = VaultKeyring(masterKey: SymmetricKey(size: .bits256))
        let wrapped = try keyring.wrapItemKey(VaultKeyring.newItemKey(), itemID: UUID())
        let now = Date()
        var document = CatalogDocument()
        document.items = (0..<10_000).map { index in
            VaultItem(
                id: UUID(), kind: index % 10 == 0 ? .video : .photo, addedAt: now,
                capturedAt: now.addingTimeInterval(Double(-index) * 60), originalFilename: "IMG_\(index).HEIC",
                uniformType: "public.heic", pixelWidth: 4032, pixelHeight: 3024,
                duration: index % 10 == 0 ? 12.5 : nil, byteCount: 2_500_000,
                wrappedKey: wrapped, originalBlob: UUID(), thumbnailBlob: UUID()
            )
        }
        measure {
            guard let plaintext = try? JSONEncoder().encode(document) else { return XCTFail("encoding failed") }
            XCTAssertNotNil(try? CatalogFile.seal(plaintext, indexKey: keyring.indexKey))
        }
    }
}
