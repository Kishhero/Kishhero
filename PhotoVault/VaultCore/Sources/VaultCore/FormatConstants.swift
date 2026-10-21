import Foundation

/// Byte-level constants for the on-disk formats.
///
/// Specified in docs/FORMAT.md and mirrored in tools/reference/vault_reference.py.
/// Changing any value here makes existing vaults unreadable, so change all three
/// together and bump the matching version byte.
enum Format {
    enum Header {
        static let magic: [UInt8] = Array("PVLT".utf8)
        static let version: UInt8 = 1
        static let kdfArgon2id: UInt8 = 1
        static let size = 100
        /// Bytes 0..<40 (everything before the nonce) are AES-GCM associated
        /// data, so editing the KDF settings or salt breaks the unwrap.
        static let authenticatedSize = 40
        static let saltSize = 16
        static let nonceSize = 12
        static let keySize = 32
        static let tagSize = 16
    }

    enum Stream {
        static let magic: [UInt8] = Array("PVSB".utf8)
        static let version: UInt8 = 1
        static let headerSize = 16
        static let noncePrefixSize = 7
        static let tagSize = 16
        /// Encrypted big-endian UInt64 holding the real content length, so
        /// padding can be stripped without trusting anything outside the blob.
        static let lengthPrefixSize = 8
        /// 4 KiB to 16 MiB. The app uses 256 KiB (`ChunkSize.standard`).
        static let allowedLog2ChunkSizes: ClosedRange<UInt8> = 12...24
    }

    enum Catalog {
        static let magic: [UInt8] = Array("PVCT".utf8)
        static let version: UInt8 = 1
        /// magic (4) || version (1) || reserved (3) || salt (32); also the
        /// stream's authenticated context.
        static let headerSize = 40
        static let saltSize = 32
    }

    /// HKDF info strings and AAD labels. Each key has exactly one purpose, and
    /// these labels keep keys derived from the same secret independent.
    enum Label {
        static let kek = Data("PhotoVault v1 kek".utf8)
        static let indexKey = Data("PhotoVault v1 index".utf8)
        static let itemWrapKey = Data("PhotoVault v1 item-wrap".utf8)
        static let itemKeyAAD = Data("PhotoVault v1 item-key".utf8)
        static let deviceBinding = Data("PhotoVault v1 device-binding".utf8)
        static let catalog = Data("PhotoVault v1 catalog".utf8)
        static let blobOriginal = Data("PhotoVault v1 blob original".utf8)
        static let blobThumbnail = Data("PhotoVault v1 blob thumbnail".utf8)
    }
}
