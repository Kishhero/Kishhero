import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import VaultCore

/// Saves vault items back to the Photos library.
///
/// The original is decrypted, 1 MiB at a time, into `outgoing/` (complete
/// file protection), and Photos then *moves* the file into its library, so
/// no plaintext copy is left behind in the app. If saving fails, the file is
/// deleted at once; `outgoing/` is also swept at every launch.
///
/// Uses add-only access: PhotoVault can add to the library but not read it.
///
/// Once saved, a copy is outside the vault's protection: it is an ordinary
/// photo, and goes to iCloud if iCloud Photos is on. The prompt says so.
enum PhotosExporter {
    enum Failure: Error {
        case notAllowed
        case couldNotRemoveLocation
    }

    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
    }

    static func save(_ item: VaultItem, from vault: VaultLibrary, via outgoing: URL, removingLocation: Bool) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outgoing, withIntermediateDirectories: true)
        let fileExtension = UTType(item.uniformType)?.preferredFilenameExtension ?? (item.kind == .video ? "mov" : "jpg")
        let decrypted = outgoing.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        var temporaryFiles = [decrypted]
        defer {
            // Photos moved the file it was given; anything still here goes now.
            for url in temporaryFiles { try? fileManager.removeItem(at: url) }
        }

        try vault.writeOriginal(of: item, to: decrypted)
        var fileToSave = decrypted
        if removingLocation {
            let stripped = outgoing.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            temporaryFiles.append(stripped)
            if item.kind == .video {
                try await LocationStripper.stripVideo(from: decrypted, to: stripped, uniformType: item.uniformType)
            } else {
                try LocationStripper.stripPhoto(from: decrypted, to: stripped)
            }
            try? fileManager.removeItem(at: decrypted) // the version with location goes right away
            fileToSave = stripped
        }

        let resourceType: PHAssetResourceType = item.kind == .video ? .video : .photo
        let originalFilename = item.originalFilename
        let creationDate = item.capturedAt
        let url = fileToSave
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = originalFilename
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: resourceType, fileURL: url, options: options)
            if let creationDate {
                request.creationDate = creationDate
            }
        }
    }
}

/// Removes GPS location from a copy before it leaves the vault.
///
/// Inside the vault, location is encrypted along with everything else; this
/// matters only once a copy goes back to Photos, where it would be readable
/// by any app with library access and by anyone you share the photo with.
enum LocationStripper {
    /// Lossless for formats ImageIO can rewrite in place (JPEG, HEIC and
    /// others): the image data is copied untouched and only the metadata
    /// changes. Anything else is re-encoded with the GPS data removed.
    static func stripPhoto(from source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource)
        else {
            throw PhotosExporter.Failure.couldNotRemoveLocation
        }
        if let lossless = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) {
            let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            if CGImageDestinationCopyImageSource(lossless, imageSource, options as CFDictionary, nil) {
                return
            }
        }
        guard let reencoded = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw PhotosExporter.Failure.couldNotRemoveLocation
        }
        // Setting a property to kCFNull removes it.
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any]
        CGImageDestinationAddImageFromSource(reencoded, imageSource, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(reencoded) else {
            throw PhotosExporter.Failure.couldNotRemoveLocation
        }
    }

    /// Re-wraps the video without re-encoding it (passthrough), dropping
    /// location and other identifying metadata with Apple's `forSharing` filter.
    static func stripVideo(from source: URL, to destination: URL, uniformType: String) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PhotosExporter.Failure.couldNotRemoveLocation
        }
        let fileType: AVFileType = UTType(uniformType)?.conforms(to: .mpeg4Movie) == true ? .mp4 : .mov
        session.metadataItemFilter = .forSharing()
        if #available(iOS 18, *) {
            try await session.export(to: destination, as: fileType)
        } else {
            session.outputURL = destination
            session.outputFileType = fileType
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? PhotosExporter.Failure.couldNotRemoveLocation
            }
        }
    }
}
