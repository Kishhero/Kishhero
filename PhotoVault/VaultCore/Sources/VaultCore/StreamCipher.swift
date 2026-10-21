import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Size of each encrypted chunk, as a power of two.
public struct ChunkSize: Equatable, Sendable {
    public let log2: UInt8

    public init(log2: UInt8) throws {
        guard Format.Stream.allowedLog2ChunkSizes.contains(log2) else { throw VaultError.invalidParameters }
        self.log2 = log2
    }

    private init(unchecked log2: UInt8) {
        self.log2 = log2
    }

    /// 256 KiB. Trade-off: smaller chunks make video seeking cheaper (less to
    /// decrypt before the first frame), bigger chunks waste less on tags. At
    /// 256 KiB the 16-byte tag costs 0.006% and a seek decrypts well under a
    /// millisecond of AES.
    public static let standard = ChunkSize(unchecked: 18)

    var bytes: UInt64 { UInt64(1) << UInt64(log2) }
}

public enum PaddingPolicy: Sendable {
    case none
    /// Round the encrypted size up with Padmé (see `Padme`). Default on.
    case padme
}

/// Chunked authenticated encryption for photos, videos and thumbnails.
///
/// This is the STREAM construction (Hoang, Reyhanitabar, Rogaway, Vizár 2015)
/// with the nonce layout of Google Tink's streaming AEAD, built on CryptoKit's
/// AES-256-GCM. CryptoKit has no streaming mode of its own, and encrypting a
/// 4 GB video in one AES-GCM call would need 4 GB of memory and could not seek.
///
///     blob  = header (16) || chunk 0 || chunk 1 || ... || chunk n-1
///     chunk = AES-GCM(key, nonce_i, plaintext_i, aad: header || context) → ciphertext || tag
///     nonce_i = noncePrefix (7 random bytes) || i (UInt32, big-endian) || last (0x00 / 0x01)
///
/// The plaintext stream is the content length (UInt64, big-endian), then the
/// content, then zero padding up to the Padmé size. Layout: docs/FORMAT.md.
///
/// Protects against:
/// - reading any byte without the key (AES-256)
/// - changing, reordering, dropping, duplicating or appending chunks (each
///   chunk's position is in its nonce and authenticated)
/// - cutting the file short at a chunk boundary (the "last" flag)
/// - swapping in a blob that belongs to another item or role (the `context`
///   is authenticated on every chunk)
/// - learning exact file sizes (Padmé padding)
///
/// Does not protect against:
/// - replacing a blob with an older version of the same blob, if one existed.
///   VaultCore never rewrites a blob in place (an edit gets a new key), so no
///   older version exists to replay.
/// - leaking rough size and file count.
///
/// Nonce safety: every blob gets a fresh random key (`VaultKeyring.newItemKey`,
/// one per item, with different contexts for original and thumbnail) and each
/// chunk index is used once, so no (key, nonce) pair can ever repeat. The
/// random prefix is defense in depth in case a key is ever reused by mistake.
public enum StreamCipher {
    /// Encrypts all of `source`, passing the blob to `write` in order, one chunk
    /// (256 KiB) at a time, so memory use stays flat for any file size.
    ///
    /// - Parameter context: binds the blob to where it belongs, for example
    ///   "<item UUID>/original". Decryption must pass the same value.
    public static func encrypt<Source: ByteSource>(
        _ source: Source,
        key: SymmetricKey,
        context: Data,
        chunkSize: ChunkSize = .standard,
        padding: PaddingPolicy = .padme,
        write: (Data) throws -> Void
    ) throws {
        try encrypt(source, key: key, context: context, chunkSize: chunkSize, padding: padding, random: SecureRandom(), write: write)
    }

    static func encrypt<Source: ByteSource>(
        _ source: Source,
        key: SymmetricKey,
        context: Data,
        chunkSize: ChunkSize,
        padding: PaddingPolicy,
        random: some RandomBytesGenerator,
        write: (Data) throws -> Void
    ) throws {
        let contentLength = source.size
        let lengthPrefixSize = UInt64(Format.Stream.lengthPrefixSize)
        guard contentLength <= maxContentLength else { throw VaultError.invalidParameters }
        let unpaddedLength = lengthPrefixSize + contentLength
        let streamLength = Self.streamLength(contentLength: contentLength, padding: padding)
        let chunkBytes = chunkSize.bytes
        let chunkCount = (streamLength + chunkBytes - 1) / chunkBytes
        guard chunkCount <= UInt64(UInt32.max) + 1 else { throw VaultError.invalidParameters }

        let noncePrefix = try random.bytes(Format.Stream.noncePrefixSize)
        let header = StreamHeader(chunkSize: chunkSize, noncePrefix: noncePrefix).encoded
        let aad = header + context
        let lengthPrefix = contentLength.bigEndianBytes
        try write(header)

        for index in 0..<chunkCount {
            let start = index * chunkBytes
            let end = min(start + chunkBytes, streamLength)
            var plaintext = Data(capacity: Int(end - start))
            // Stream bytes [0, 8): the content length.
            if start < lengthPrefixSize {
                plaintext.append(contentsOf: lengthPrefix[Int(start)..<Int(min(end, lengthPrefixSize))])
            }
            // Stream bytes [8, 8 + contentLength): the content.
            let contentStart = max(start, lengthPrefixSize)
            let contentEnd = min(end, unpaddedLength)
            if contentStart < contentEnd {
                plaintext.append(try source.read(at: contentStart - lengthPrefixSize, count: Int(contentEnd - contentStart)))
            }
            // The rest: zero padding, encrypted like everything else.
            let paddingStart = max(start, unpaddedLength)
            if paddingStart < end {
                plaintext.append(Data(count: Int(end - paddingStart)))
            }
            let nonce = try StreamHeader.nonce(prefix: noncePrefix, index: UInt32(index), isLast: index == chunkCount - 1)
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
            try write(sealed.ciphertext + sealed.tag)
        }
    }

    /// The exact blob size `encrypt` will produce, for checking free space
    /// before an import starts.
    public static func encryptedSize(
        contentLength: UInt64,
        chunkSize: ChunkSize = .standard,
        padding: PaddingPolicy = .padme
    ) -> UInt64 {
        let streamLength = Self.streamLength(contentLength: contentLength, padding: padding)
        let chunkCount = (streamLength + chunkSize.bytes - 1) / chunkSize.bytes
        return UInt64(Format.Stream.headerSize) + streamLength + chunkCount * UInt64(Format.Stream.tagSize)
    }

    /// 1 PiB: far beyond any phone's storage, and far from integer overflow.
    static let maxContentLength: UInt64 = 1 << 50

    static func streamLength(contentLength: UInt64, padding: PaddingPolicy) -> UInt64 {
        let unpadded = UInt64(Format.Stream.lengthPrefixSize) + contentLength
        switch padding {
        case .none: return unpadded
        case .padme: return Padme.paddedLength(unpadded)
        }
    }
}

/// The 16-byte blob header: magic, version, chunk size, nonce prefix.
struct StreamHeader {
    let chunkSize: ChunkSize
    let noncePrefix: [UInt8]

    init(chunkSize: ChunkSize, noncePrefix: [UInt8]) {
        self.chunkSize = chunkSize
        self.noncePrefix = noncePrefix
    }

    init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count == Format.Stream.headerSize, Array(bytes[0..<4]) == Format.Stream.magic else {
            throw VaultError.malformedData
        }
        guard bytes[4] == Format.Stream.version else { throw VaultError.unsupportedVersion(bytes[4]) }
        guard bytes[6] == 0, bytes[7] == 0, bytes[8] == 0,
              let chunkSize = try? ChunkSize(log2: bytes[5])
        else {
            throw VaultError.malformedData
        }
        self.chunkSize = chunkSize
        self.noncePrefix = Array(bytes[9..<16])
    }

    var encoded: Data {
        Data(Format.Stream.magic) + [Format.Stream.version, chunkSize.log2, 0, 0, 0] + noncePrefix
    }

    static func nonce(prefix: [UInt8], index: UInt32, isLast: Bool) throws -> AES.GCM.Nonce {
        let lastFlag: UInt8 = isLast ? 1 : 0
        return try AES.GCM.Nonce(data: prefix + index.bigEndianBytes + [lastFlag])
    }
}

/// Chunk geometry worked out from the blob's size alone.
struct StreamLayout {
    let chunkBytes: UInt64
    let chunkCount: UInt64
    let lastSealedChunkBytes: UInt64

    init(chunkSize: ChunkSize, blobSize: UInt64) throws {
        let headerSize = UInt64(Format.Stream.headerSize)
        let tagSize = UInt64(Format.Stream.tagSize)
        guard blobSize > headerSize else { throw VaultError.malformedData }
        let body = blobSize - headerSize
        let sealedChunk = chunkSize.bytes + tagSize
        let count = (body + sealedChunk - 1) / sealedChunk
        let last = body - (count - 1) * sealedChunk
        // The last chunk must hold at least one byte besides its tag; otherwise
        // the blob was cut inside a tag or never came from `encrypt`.
        guard count <= UInt64(UInt32.max) + 1, last > tagSize else { throw VaultError.malformedData }
        chunkBytes = chunkSize.bytes
        chunkCount = count
        lastSealedChunkBytes = last
        guard streamLength >= UInt64(Format.Stream.lengthPrefixSize) else { throw VaultError.malformedData }
    }

    var sealedChunkBytes: UInt64 { chunkBytes + UInt64(Format.Stream.tagSize) }

    /// Plaintext bytes in the whole stream: length prefix + content + padding.
    var streamLength: UInt64 {
        (chunkCount - 1) * chunkBytes + lastSealedChunkBytes - UInt64(Format.Stream.tagSize)
    }

    func sealedRange(of index: UInt64) -> (offset: UInt64, count: Int) {
        let offset = UInt64(Format.Stream.headerSize) + index * sealedChunkBytes
        let count = index == chunkCount - 1 ? lastSealedChunkBytes : sealedChunkBytes
        return (offset, Int(count))
    }
}

/// Random-access decryption of a blob written by `StreamCipher.encrypt`.
///
/// Opening a blob authenticates the header, the first chunk (which holds the
/// real length) and the last chunk (whose "last" flag proves the blob was not
/// truncated or extended). Every other chunk is authenticated when it is read;
/// no unauthenticated byte is ever returned.
///
/// Holds one decrypted chunk in memory to make sequential reads cheap. Not
/// thread-safe: use one instance per queue (for video, the resource loader's
/// delegate queue).
public final class StreamDecryptor {
    /// Length of the original content, padding excluded.
    public private(set) var contentLength: UInt64 = 0
    private let source: any ByteSource
    private let key: SymmetricKey
    private let aad: Data
    private let noncePrefix: [UInt8]
    private let layout: StreamLayout
    private var cachedChunk: (index: UInt64, plaintext: Data)?

    public init(source: any ByteSource, key: SymmetricKey, context: Data) throws {
        guard source.size >= UInt64(Format.Stream.headerSize) else { throw VaultError.malformedData }
        let headerBytes = try source.read(at: 0, count: Format.Stream.headerSize)
        let header = try StreamHeader(decoding: headerBytes)
        self.source = source
        self.key = key
        self.aad = headerBytes + context
        self.noncePrefix = header.noncePrefix
        self.layout = try StreamLayout(chunkSize: header.chunkSize, blobSize: source.size)

        if layout.chunkCount > 1 {
            _ = try chunk(layout.chunkCount - 1)
        }
        // Read chunk 0 last so it stays cached for the first real read.
        let first = try chunk(0)
        let length = first.readBigEndian(UInt64.self, at: 0)
        guard length <= layout.streamLength - UInt64(Format.Stream.lengthPrefixSize) else {
            throw VaultError.malformedData
        }
        contentLength = length
    }

    /// Up to `count` bytes of content from `offset`; fewer only at the end of
    /// the content. Padding is never returned.
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= contentLength else { throw VaultError.invalidRange }
        let end = offset + min(UInt64(count), contentLength - offset)
        let lengthPrefixSize = UInt64(Format.Stream.lengthPrefixSize)
        var output = Data(capacity: Int(end - offset))
        var position = offset + lengthPrefixSize
        let streamEnd = end + lengthPrefixSize
        while position < streamEnd {
            let index = position / layout.chunkBytes
            let within = Int(position % layout.chunkBytes)
            let plaintext = try chunk(index)
            let take = min(plaintext.count - within, Int(streamEnd - position))
            guard take > 0 else { throw VaultError.malformedData }
            let start = plaintext.startIndex + within
            output.append(plaintext[start..<(start + take)])
            position += UInt64(take)
        }
        return output
    }

    /// The whole content in memory. For thumbnails and photos; stream videos
    /// with `read(at:count:)` instead.
    public func readAll() throws -> Data {
        guard contentLength <= UInt64(Int.max) else { throw VaultError.invalidRange }
        return try read(at: 0, count: Int(contentLength))
    }

    private func chunk(_ index: UInt64) throws -> Data {
        if let cachedChunk, cachedChunk.index == index {
            return cachedChunk.plaintext
        }
        let (offset, count) = layout.sealedRange(of: index)
        let sealed = try source.read(at: offset, count: count)
        let tagStart = sealed.startIndex + count - Format.Stream.tagSize
        let nonce = try StreamHeader.nonce(prefix: noncePrefix, index: UInt32(index), isLast: index == layout.chunkCount - 1)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed[sealed.startIndex..<tagStart], tag: sealed[tagStart...])
            plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultError.authenticationFailed
        }
        cachedChunk = (index, plaintext)
        return plaintext
    }
}
