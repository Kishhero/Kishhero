import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The keys of an unlocked vault. It exists only in memory, only while the
/// vault is open; locking the vault means dropping every reference to it.
///
/// Key separation: the master key itself encrypts nothing. Each job gets its
/// own key derived with HKDF and a distinct label, so a flaw in how one key
/// is used cannot leak another.
///
/// `@unchecked Sendable`: every stored property is an immutable `let` of an
/// immutable value type, so sharing it across tasks is safe. (Spelled out
/// because not every SDK marks CryptoKit's `SymmetricKey` as `Sendable`.)
public struct VaultKeyring: @unchecked Sendable {
    let masterKey: SymmetricKey
    /// Encrypts the catalog file (`index.enc`).
    public let indexKey: SymmetricKey
    /// Wraps the per-item keys stored in the catalog.
    let itemWrapKey: SymmetricKey

    init(masterKey: SymmetricKey) {
        self.masterKey = masterKey
        indexKey = Self.subkey(of: masterKey, label: Format.Label.indexKey)
        itemWrapKey = Self.subkey(of: masterKey, label: Format.Label.itemWrapKey)
    }

    static func subkey(of key: SymmetricKey, label: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(), info: label, outputByteCount: Format.Header.keySize)
    }

    /// A fresh random key for one photo or video and its thumbnail.
    ///
    /// One key per item means deleting an item deletes its key, so its blobs
    /// become unreadable even if fragments survive on flash storage. It also
    /// keeps the stream nonces safe: a key only ever encrypts one item, once.
    public static func newItemKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Encrypts an item key for storage in the catalog: nonce (12) || ciphertext (32) || tag (16).
    /// The item's ID is authenticated too, so a wrapped key copied onto
    /// another catalog entry fails to unwrap.
    public func wrapItemKey(_ itemKey: SymmetricKey, itemID: UUID) throws -> Data {
        try wrapItemKey(itemKey, itemID: itemID, nonce: AES.GCM.Nonce())
    }

    func wrapItemKey(_ itemKey: SymmetricKey, itemID: UUID, nonce: AES.GCM.Nonce) throws -> Data {
        var raw = itemKey.withUnsafeBytes { Array($0) }
        defer { SecureMemory.zero(&raw) }
        // Random 96-bit nonces under one wrap key stay safe for about 2^32
        // wraps (NIST SP 800-38D); a photo library is many orders below that.
        let sealed = try AES.GCM.seal(raw, using: itemWrapKey, nonce: nonce, authenticating: Self.itemAAD(itemID))
        return nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
    }

    public func unwrapItemKey(_ wrapped: Data, itemID: UUID) throws -> SymmetricKey {
        let nonceSize = Format.Header.nonceSize, keySize = Format.Header.keySize
        let bytes = [UInt8](wrapped)
        guard bytes.count == nonceSize + keySize + Format.Header.tagSize else {
            throw VaultError.malformedData
        }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: bytes[0..<nonceSize]),
            ciphertext: bytes[nonceSize..<(nonceSize + keySize)],
            tag: bytes[(nonceSize + keySize)...]
        )
        do {
            return SymmetricKey(data: try AES.GCM.open(box, using: itemWrapKey, authenticating: Self.itemAAD(itemID)))
        } catch {
            throw VaultError.authenticationFailed
        }
    }

    static func itemAAD(_ itemID: UUID) -> Data {
        Format.Label.itemKeyAAD + itemID.rawBytes
    }
}
