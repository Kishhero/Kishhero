import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VaultCore

struct Inspection: Sendable {
    let metadata: ImportMetadata
    let thumbnailJPEG: Data
}

enum ImportError: Error {
    case unreadable
}

/// Reads size, date and duration from a staged file and makes its thumbnail.
///
/// Only Apple's ImageIO and AVFoundation parse imported files (MASVS-CODE-4):
/// no third-party image decoder ever sees untrusted input.
enum MediaInspector {
    /// Longest side of stored thumbnails: enough for a 3-column grid on the
    /// largest iPhone at 3x, and small (about 40 KB) so the grid loads fast.
    static let thumbnailPixels = 512

    static func inspect(_ file: StagedFile) async throws -> Inspection {
        if file.contentType.conforms(to: .movie) {
            return try await inspectVideo(file)
        }
        return try inspectImage(file)
    }

    private static func inspectImage(_ file: StagedFile) throws -> Inspection {
        // Don't decode the full image: a 48 MP photo would take ~190 MB.
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImportError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if (5...8).contains(orientation) {
            swap(&width, &height) // rotated 90°: display size is transposed
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let capturedAt = exifDate(
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        )

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in the orientation
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadable
        }
        let metadata = ImportMetadata(
            kind: .photo,
            uniformType: file.contentType.identifier,
            originalFilename: file.originalFilename,
            pixelWidth: width,
            pixelHeight: height,
            capturedAt: capturedAt
        )
        return Inspection(metadata: metadata, thumbnailJPEG: try jpeg(thumbnail))
    }

    private static func inspectVideo(_ file: StagedFile) async throws -> Inspection {
        let asset = AVURLAsset(url: file.url)
        let duration = try await asset.load(.duration)
        var size = CGSize.zero
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
            size = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        }
        var capturedAt: Date?
        if let creation = try await asset.load(.creationDate) {
            capturedAt = try await creation.load(.dateValue)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailPixels, height: thumbnailPixels)
        // A little way in: the very first frame is often black.
        let seconds = duration.seconds.isFinite ? min(1, duration.seconds / 10) : 0
        let (frame, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))

        let metadata = ImportMetadata(
            kind: .video,
            uniformType: file.contentType.identifier,
            originalFilename: file.originalFilename,
            pixelWidth: Int(size.width.rounded()),
            pixelHeight: Int(size.height.rounded()),
            duration: duration.seconds.isFinite ? duration.seconds : nil,
            capturedAt: capturedAt
        )
        return Inspection(metadata: metadata, thumbnailJPEG: try jpeg(frame))
    }

    /// Encodes a thumbnail as JPEG with no metadata at all: no EXIF, no GPS.
    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        return data as Data
    }

    /// EXIF dates look like "2024:07:14 18:03:22", with the UTC offset (when
    /// the camera recorded one) in a separate field.
    static func exifDate(_ value: String?, offset: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: value + offset) {
                return date
            }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }
}

enum DiskSpace {
    enum Shortage: Error {
        case insufficient
    }

    /// Left free so iOS and other apps keep working.
    static let reserveBytes: Int64 = 300 << 20

    /// Checks there is room for the encrypted (and padded) original and
    /// thumbnail before writing a single byte.
    static func ensureRoom(forContentLength length: UInt64, thumbnailLength: Int) throws {
        let needed = StreamCipher.encryptedSize(contentLength: length)
            + StreamCipher.encryptedSize(contentLength: UInt64(thumbnailLength))
        let values = try URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        if Int64(clamping: needed) + reserveBytes > available {
            throw Shortage.insufficient
        }
    }
}
