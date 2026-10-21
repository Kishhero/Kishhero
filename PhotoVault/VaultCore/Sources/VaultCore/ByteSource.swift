import Foundation

/// Random-access read-only bytes: an in-memory buffer or a file on disk.
/// Lets the stream cipher work on multi-gigabyte videos one chunk at a time.
public protocol ByteSource {
    var size: UInt64 { get }
    /// Returns exactly `count` bytes starting at `offset`, or throws.
    func read(at offset: UInt64, count: Int) throws -> Data
}

extension ByteSource {
    func checkRange(offset: UInt64, count: Int) throws {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw VaultError.truncatedSource
        }
    }
}

public struct DataByteSource: ByteSource {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var size: UInt64 { UInt64(data.count) }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        try checkRange(offset: offset, count: count)
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<(start + count))
    }
}

/// Reads a file through a `FileHandle`. Not thread-safe: use one instance per
/// queue (each read seeks the shared handle).
public final class FileByteSource: ByteSource {
    private let handle: FileHandle
    public let size: UInt64

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.size = try handle.seekToEnd()
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        try checkRange(offset: offset, count: count)
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        // A short read means the file changed under us; never pad or guess.
        guard data.count == count else { throw VaultError.truncatedSource }
        return data
    }
}
