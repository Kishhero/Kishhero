import Foundation
import Testing
@testable import VaultCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("Stream cipher")
struct StreamCipherTests {
    let key = SymmetricKey(size: .bits256)
    let context = Data("3F2504E0-4F89-11D3-9A0C-0305E82C3301/original".utf8)
    let chunk = UInt64(ChunkSize.standard.bytes)

    func encrypt(
        _ content: Data,
        key: SymmetricKey? = nil,
        context: Data? = nil,
        chunkSize: ChunkSize = .standard,
        padding: PaddingPolicy = .padme
    ) throws -> Data {
        var blob = Data()
        try StreamCipher.encrypt(
            DataByteSource(content),
            key: key ?? self.key,
            context: context ?? self.context,
            chunkSize: chunkSize,
            padding: padding
        ) { blob.append($0) }
        return blob
    }

    func decrypt(_ blob: Data, key: SymmetricKey? = nil, context: Data? = nil) throws -> Data {
        try StreamDecryptor(source: DataByteSource(blob), key: key ?? self.key, context: context ?? self.context).readAll()
    }

    // MARK: Reference vectors

    @Test("produces exactly the reference blobs", arguments: ReferenceVectors.streams)
    func knownAnswer(vector: ReferenceVectors.Stream) throws {
        let chunkSize = try ChunkSize(log2: ReferenceVectors.streamLog2ChunkSize)
        let padding: PaddingPolicy = vector.padded ? .padme : .none
        var blob = Data()
        try StreamCipher.encrypt(
            DataByteSource(pattern(vector.contentLength)),
            key: SymmetricKey(hex: ReferenceVectors.streamKey),
            context: Data(ReferenceVectors.streamContext.utf8),
            chunkSize: chunkSize,
            padding: padding,
            random: FixedRandom(Data(hex: ReferenceVectors.streamNoncePrefix))
        ) { blob.append($0) }

        #expect(blob.count == vector.blobSize)
        #expect(sha256Hex(blob) == vector.blobSHA256)
        let predicted = StreamCipher.encryptedSize(contentLength: UInt64(vector.contentLength), chunkSize: chunkSize, padding: padding)
        #expect(predicted == UInt64(vector.blobSize))
    }

    @Test("decrypts a blob produced by the reference implementation")
    func decryptsReferenceBlob() throws {
        let plaintext = try StreamDecryptor(
            source: DataByteSource(Data(hex: ReferenceVectors.oneByteBlob)),
            key: SymmetricKey(hex: ReferenceVectors.streamKey),
            context: Data(ReferenceVectors.streamContext.utf8)
        ).readAll()
        #expect(plaintext == pattern(1))
    }

    // MARK: Round trips

    @Test(
        "encrypts and decrypts every size boundary",
        arguments: [0, 1, 2, 100, 262_135, 262_136, 262_137, 524_272, 786_432, 1_000_003]
    )
    func roundTrip(length: Int) throws {
        let content = randomData(length, seed: UInt64(length))
        for padding in [PaddingPolicy.padme, .none] {
            let blob = try encrypt(content, padding: padding)
            #expect(UInt64(blob.count) == StreamCipher.encryptedSize(contentLength: UInt64(length), padding: padding))
            #expect(try decrypt(blob) == content)
        }
    }

    @Test("any byte range reads back exactly")
    func randomAccess() throws {
        let content = randomData(3 * Int(chunk) + 12_345, seed: 7)
        let decryptor = try StreamDecryptor(source: DataByteSource(try encrypt(content)), key: key, context: context)
        #expect(decryptor.contentLength == UInt64(content.count))

        var generator = SplitMix64(state: 42)
        var ranges: [(Int, Int)] = [(0, 0), (0, 1), (content.count - 1, 1), (content.count, 0),
                                    (Int(chunk) - 3, 6), (Int(chunk) * 2, Int(chunk) + 1)]
        for _ in 0..<200 {
            let offset = Int.random(in: 0...content.count, using: &generator)
            ranges.append((offset, Int.random(in: 0...(600_000), using: &generator)))
        }
        for (offset, count) in ranges {
            let expected = content[offset..<min(offset + count, content.count)]
            #expect(try decryptor.read(at: UInt64(offset), count: count) == expected, "range \(offset)+\(count)")
        }
        #expect(throws: VaultError.invalidRange) { try decryptor.read(at: UInt64(content.count) + 1, count: 1) }
    }

    @Test("streams files from disk without loading them whole")
    func fileRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainURL = directory.appendingPathComponent("plain.bin")
        let blobURL = directory.appendingPathComponent("blob.bin")
        let content = randomData(2 * Int(chunk) + 99, seed: 99)
        try content.write(to: plainURL)

        _ = FileManager.default.createFile(atPath: blobURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: blobURL)
        try StreamCipher.encrypt(try FileByteSource(url: plainURL), key: key, context: context) { try output.write(contentsOf: $0) }
        try output.close()

        let decryptor = try StreamDecryptor(source: try FileByteSource(url: blobURL), key: key, context: context)
        #expect(try decryptor.readAll() == content)
    }

    // MARK: Confidentiality and nonces

    @Test("ciphertext does not contain the plaintext and never repeats")
    func ciphertextLooksRandom() throws {
        let content = Data(repeating: 0x41, count: 100_000)
        let first = try encrypt(content)
        let second = try encrypt(content)
        // Same key, same content: a fresh nonce prefix still makes every byte differ.
        #expect(first != second)
        #expect(first[9..<16] != second[9..<16])
        #expect(first.range(of: Data(repeating: 0x41, count: 32)) == nil)
    }

    @Test("padding makes similar sizes indistinguishable")
    func paddingHidesSize() throws {
        let a = try encrypt(randomData(1_000_000, seed: 1))
        let b = try encrypt(randomData(1_000_500, seed: 2))
        #expect(a.count == b.count)
        #expect(try decrypt(a).count == 1_000_000)
        #expect(try decrypt(b).count == 1_000_500)
    }

    // MARK: Integrity: every one of these must be rejected

    @Test("rejects the wrong key or the wrong context")
    func wrongKeyOrContext() throws {
        let blob = try encrypt(randomData(300_000, seed: 3))
        #expect(throws: VaultError.authenticationFailed) { try decrypt(blob, key: SymmetricKey(size: .bits256)) }
        // A thumbnail blob cannot be passed off as the original, or one item's
        // blob as another's.
        #expect(throws: VaultError.authenticationFailed) {
            try decrypt(blob, context: Data("3F2504E0-4F89-11D3-9A0C-0305E82C3301/thumbnail".utf8))
        }
    }

    @Test("rejects any flipped bit")
    func bitFlips() throws {
        let blob = try encrypt(randomData(3 * Int(chunk) + 777, seed: 4))
        var generator = SplitMix64(state: 5)
        var offsets = Array(0..<64) + Array((blob.count - 64)..<blob.count)
        for _ in 0..<200 {
            offsets.append(Int.random(in: 0..<blob.count, using: &generator))
        }
        for offset in offsets {
            var tampered = blob
            tampered[offset] ^= 0x01
            #expect(throws: (any Error).self, "flip at byte \(offset) was accepted") { try decrypt(tampered) }
        }
    }

    @Test("rejects truncation, extension, reordering and splicing")
    func structuralTampering() throws {
        // 3 full chunks + 500 bytes, padded: 4 chunks, the last one short.
        let blob = try encrypt(randomData(3 * Int(chunk) + 500, seed: 6))
        let otherBlob = try encrypt(randomData(3 * Int(chunk) + 500, seed: 7))
        let headerSize = 16
        let sealedSize = Int(chunk) + 16
        func part(_ index: Int, of data: Data) -> Data {
            Data(data[(headerSize + index * sealedSize)..<min(headerSize + (index + 1) * sealedSize, data.count)])
        }
        func join(_ parts: Data...) -> Data {
            parts.reduce(into: Data()) { $0.append($1) }
        }
        let header = Data(blob.prefix(headerSize))
        let chunks = (0..<4).map { part($0, of: blob) }
        #expect(join(header, chunks[0], chunks[1], chunks[2], chunks[3]) == blob)

        let attacks: [(String, Data)] = [
            ("cut at a chunk boundary", Data(blob.prefix(headerSize + 3 * sealedSize))),
            ("cut inside the last chunk", Data(blob.dropLast(1))),
            ("cut inside the last tag", Data(blob.prefix(headerSize + 3 * sealedSize + 10))),
            ("header only", header),
            ("extra byte appended", join(blob, Data([0]))),
            ("extra chunk appended", join(blob, chunks[1])),
            ("first chunk dropped", join(header, chunks[1], chunks[2], chunks[3])),
            ("middle chunk dropped", join(header, chunks[0], chunks[2], chunks[3])),
            ("chunks swapped", join(header, chunks[0], chunks[2], chunks[1], chunks[3])),
            ("chunk duplicated", join(header, chunks[0], chunks[1], chunks[1], chunks[3])),
            ("chunk from another blob, same key", join(header, chunks[0], part(1, of: otherBlob), chunks[2], chunks[3])),
            ("header from another blob", join(Data(otherBlob.prefix(headerSize)), chunks[0], chunks[1], chunks[2], chunks[3])),
        ]
        for (name, tampered) in attacks {
            #expect(throws: (any Error).self, "\(name) was accepted") {
                _ = try decrypt(tampered)
            }
        }
    }

    @Test("rejects a chunk-size change in the header")
    func headerChunkSizeChange() throws {
        var blob = try encrypt(randomData(10_000, seed: 8))
        blob[5] = 12
        #expect(throws: (any Error).self) { try decrypt(blob) }
        blob[5] = 30
        #expect(throws: VaultError.malformedData) { try decrypt(blob) }
    }

    @Test("rejects a blob from a future format version")
    func futureVersion() throws {
        var blob = try encrypt(Data([1, 2, 3]))
        blob[4] = 2
        #expect(throws: VaultError.unsupportedVersion(2)) { try decrypt(blob) }
    }
}
