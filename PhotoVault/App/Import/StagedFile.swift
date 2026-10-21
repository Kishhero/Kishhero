import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// A picked photo or video, moved into the vault's `incoming/` folder and
/// waiting to be encrypted.
///
/// This is the one moment an original sits unencrypted in the app's own
/// storage: for the few seconds between the picker handing it over and
/// `VaultLibrary.importFile` finishing. It is protected by iOS Data
/// Protection (`.complete`), deleted right after encryption, and swept again
/// at every launch in case the app was killed mid-import
/// (`VaultStore.clearStagingFolders`).
struct StagedFile: Sendable {
    let url: URL
    let contentType: UTType
    let byteCount: UInt64
    let originalFilename: String?

    /// Asks the picker for the original file: HEIC stays HEIC and HEVC stays
    /// HEVC, because the picker is configured with `.current` encoding.
    /// Live Photos come in as their still image.
    static func load(from item: PhotosPickerItem) async throws -> StagedFile? {
        let isVideo = !item.supportedContentTypes.contains { $0.conforms(to: .image) }
        if isVideo {
            return try await item.loadTransferable(type: IncomingMovie.self)?.file
        }
        return try await item.loadTransferable(type: IncomingImage.self)?.file
    }

    /// Moves (not copies) the system's temporary file, so no second plaintext
    /// copy is ever written. Falls back to copying if a move isn't possible;
    /// the system deletes its temporary file right afterwards either way.
    fileprivate static func stage(_ received: ReceivedTransferredFile, fallback: UTType) throws -> StagedFile {
        let fileManager = FileManager.default
        let incoming = VaultStore.standard().incomingDirectory
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        let source = received.file
        let destination = incoming
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try fileManager.copyItem(at: source, to: destination)
        }
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return StagedFile(
            url: destination,
            contentType: UTType(filenameExtension: source.pathExtension) ?? fallback,
            byteCount: UInt64(size),
            originalFilename: source.lastPathComponent
        )
    }
}

struct IncomingImage: Transferable, Sendable {
    let file: StagedFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            IncomingImage(file: try StagedFile.stage(received, fallback: .image))
        }
    }
}

struct IncomingMovie: Transferable, Sendable {
    let file: StagedFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            IncomingMovie(file: try StagedFile.stage(received, fallback: .movie))
        }
    }
}
