import Foundation

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

extension Collection where Element == UInt8 {
    /// Reads a big-endian integer from the bytes at `offset` (counted from
    /// `startIndex`, so it is safe on `Data` slices).
    func readBigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        let start = index(startIndex, offsetBy: offset)
        let end = index(start, offsetBy: MemoryLayout<T>.size)
        return self[start..<end].reduce(T.zero) { $0 << 8 | T($1) }
    }
}

extension UUID {
    /// The 16 raw bytes of the UUID, used to bind ciphertext to an item.
    var rawBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
