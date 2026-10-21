import Foundation

public enum MediaKind: String, Codable, Sendable {
    case photo
    case video
}

/// One photo or video in the vault, as recorded in the encrypted catalog.
/// Everything here, including the original filename, capture date and the
/// item's wrapped key, exists only inside `index.enc`.
public struct VaultItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: MediaKind
    public let addedAt: Date
    /// From the photo's EXIF data or the video's metadata, when present.
    public let capturedAt: Date?
    public let originalFilename: String?
    /// Uniform Type Identifier of the original file, such as "public.heic".
    public let uniformType: String
    /// Display size, already rotated by the image's orientation.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Seconds; videos only.
    public let duration: Double?
    /// Size of the original file before encryption and padding.
    public let byteCount: UInt64
    /// The item key, wrapped by the vault (`VaultKeyring.wrapItemKey`).
    let wrappedKey: Data
    /// Random file names under `blobs/`, unrelated to `id`.
    let originalBlob: UUID
    let thumbnailBlob: UUID

    /// The order the library is shown in, like Photos: by capture date, oldest first.
    public var sortDate: Date { capturedAt ?? addedAt }
}

/// A user folder. Items can be in any number of albums, as in Photos; an
/// album only lists item IDs, so adding or removing never copies media.
public struct Album: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var itemIDs: [UUID]
    public let createdAt: Date
}

/// What the importer learned about a file before encrypting it.
public struct ImportMetadata: Sendable {
    public var kind: MediaKind
    public var uniformType: String
    public var originalFilename: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double?
    public var capturedAt: Date?

    public init(
        kind: MediaKind,
        uniformType: String,
        originalFilename: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double? = nil,
        capturedAt: Date? = nil
    ) {
        self.kind = kind
        self.uniformType = uniformType
        self.originalFilename = originalFilename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.capturedAt = capturedAt
    }
}
