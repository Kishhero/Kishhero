import Foundation
import Observation
import os
import PhotosUI
import SwiftUI
import UIKit
import VaultCore

struct ImportProgress: Equatable {
    var total: Int
    var completed = 0
    var failed = 0
    var ranOutOfSpace = false
}

struct ExportProgress: Equatable {
    var total: Int
    var completed = 0
    var failed = 0
}

/// The open vault as the UI sees it: the item list, imports in progress, and
/// thumbnails. Created on unlock, closed and dropped on lock.
@MainActor
@Observable
final class LibraryModel {
    private(set) var items: [VaultItem] = []
    private(set) var albums: [Album] = []
    private(set) var importProgress: ImportProgress?
    private(set) var exportProgress: ExportProgress?
    /// Shown when a save to Photos finishes.
    var exportSummary: String?
    /// Shown when an album or item operation fails.
    var operationError: String?
    /// Shown after an import: failures or running out of space.
    var importSummary: String?
    /// Drives the "delete originals from Photos?" prompt after an import.
    var isOfferingOriginalDeletion = false
    private(set) var originalsToDelete: [String] = []
    var cleanupMessage: String?
    /// The import summary, held back while the delete prompt is up: SwiftUI
    /// can't show an alert and a dialog at the same time.
    @ObservationIgnored private var pendingSummary: String?
    @ObservationIgnored private var itemsByID: [UUID: VaultItem] = [:]
    @ObservationIgnored private var memoryWarningObserver: (any NSObjectProtocol)?

    let vault: VaultLibrary
    @ObservationIgnored private let thumbnails = ThumbnailCache()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// Set on lock. Distinguishes "the vault locked" from "the user tapped Cancel".
    @ObservationIgnored private var isClosed = false

    /// Two at a time: enough to keep the CPU busy, and it caps memory (each
    /// in-flight item holds one 256 KiB chunk and a thumbnail decode).
    static let concurrentImports = 2
    /// Rewriting the catalog after every item would make a 500-photo import
    /// rewrite it 500 times. Every 10 items, a crash loses at most 10.
    static let commitInterval = 10

    init(vault: VaultLibrary) {
        self.vault = vault
        if vault.recoveredCatalogFromBackup {
            operationError = "The vault's catalog was damaged and has been restored from its backup. Items added or changes made just before that may be missing."
        }
        // Thumbnails are only a cache; under memory pressure, give them back
        // rather than have iOS terminate the app.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [thumbnails] _ in
            thumbnails.removeAll()
        }
    }

    var photoCount: Int { items.lazy.filter { $0.kind == .photo }.count }
    var videoCount: Int { items.lazy.filter { $0.kind == .video }.count }

    func reload() async {
        let items = await vault.items()
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.items = items
        albums = await vault.albums()
    }

    // MARK: Albums

    func album(_ id: UUID) -> Album? {
        albums.first { $0.id == id }
    }

    /// The album's items in the order they were added.
    func items(inAlbum id: UUID) -> [VaultItem] {
        album(id)?.itemIDs.compactMap { itemsByID[$0] } ?? []
    }

    /// Like Photos: the most recently added item is the album's cover.
    func coverItem(for album: Album) -> VaultItem? {
        album.itemIDs.last.flatMap { itemsByID[$0] }
    }

    @discardableResult
    func createAlbum(named name: String) async -> Album? {
        do {
            let album = try await vault.createAlbum(named: name)
            await reload()
            return album
        } catch VaultError.invalidAlbumName {
            operationError = "Album names need 1 to \(Album.maximumNameLength) characters."
        } catch {
            operationError = "The album couldn't be created."
        }
        return nil
    }

    func renameAlbum(_ id: UUID, to name: String) async {
        do {
            try await vault.renameAlbum(id, to: name)
        } catch VaultError.invalidAlbumName {
            operationError = "Album names need 1 to \(Album.maximumNameLength) characters."
        } catch {
            operationError = "The album couldn't be renamed."
        }
        await reload()
    }

    func deleteAlbum(_ id: UUID) async {
        do {
            try await vault.deleteAlbum(id)
        } catch {
            operationError = "The album couldn't be deleted."
        }
        await reload()
    }

    /// Adds in library order, so an album reads like the library does.
    func add(_ ids: Set<UUID>, toAlbum id: UUID) async {
        let ordered = items.map(\.id).filter { ids.contains($0) }
        do {
            try await vault.addItems(ordered, toAlbum: id)
        } catch {
            operationError = "The items couldn't be added to the album."
        }
        await reload()
    }

    func remove(_ ids: Set<UUID>, fromAlbum id: UUID) async {
        do {
            try await vault.removeItems(ids, fromAlbum: id)
        } catch {
            operationError = "The items couldn't be removed from the album."
        }
        await reload()
    }

    func thumbnail(for item: VaultItem) async -> UIImage? {
        await thumbnails.image(for: item, from: vault)
    }

    /// Synchronous cache lookup, so a recycled grid cell can show its image
    /// immediately instead of flashing a placeholder.
    func cachedThumbnail(for item: VaultItem) -> UIImage? {
        thumbnails.cachedImage(for: item.id)
    }

    /// Starts decrypting thumbnails the grid is about to show.
    func prefetchThumbnails(for items: [VaultItem]) {
        for item in items where thumbnails.cachedImage(for: item.id) == nil {
            Task { _ = await thumbnail(for: item) }
        }
    }

    /// Decrypts a photo and decodes it at no more than `maxPixelSize`, off the
    /// main thread. The decrypted bytes exist only in memory, only for the
    /// duration of the decode.
    func displayImage(for item: VaultItem, maxPixelSize: Int) async -> UIImage? {
        let vault = vault
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let signposter = Signposts.make()
            let interval = signposter.beginInterval("Decode photo")
            defer { signposter.endInterval("Decode photo", interval) }
            guard let data = try? vault.originalData(for: item) else { return nil }
            return ImageDecoding.image(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Stops imports and exports and drops every decrypted thumbnail. Called
    /// on lock. Returns the tasks still finishing (each stops within one
    /// chunk), so the caller can wait for them before the vault is reopened.
    @discardableResult
    func close() -> [Task<Void, Never>] {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        memoryWarningObserver = nil
        isClosed = true
        let unfinished = [importTask, exportTask].compactMap { $0 }
        unfinished.forEach { $0.cancel() }
        importTask = nil
        exportTask = nil
        thumbnails.removeAll()
        return unfinished
    }

    // MARK: Import

    /// - Parameter album: also adds everything imported to this album.
    func startImport(_ picked: [PhotosPickerItem], intoAlbum album: UUID? = nil) {
        guard importTask == nil, !picked.isEmpty else { return }
        importProgress = ImportProgress(total: picked.count)
        importSummary = nil
        let vault = vault
        importTask = Task {
            await runImport(picked, vault: vault, album: album)
            importTask = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private enum Outcome: Sendable {
        case imported(itemID: UUID, assetIdentifier: String?)
        case failed
        case outOfSpace
        case cancelled
    }

    private func runImport(_ picked: [PhotosPickerItem], vault: VaultLibrary, album: UUID?) async {
        var pending = picked[...]
        var importedAssetIDs: [String] = []
        var importedItemIDs: [UUID] = []
        var sinceCommit = 0

        await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<Self.concurrentImports {
                guard let next = pending.popFirst() else { break }
                group.addTask { await Self.importOne(next, into: vault) }
            }
            while let outcome = await group.next() {
                switch outcome {
                case .imported(let itemID, let assetIdentifier):
                    importProgress?.completed += 1
                    importedItemIDs.append(itemID)
                    if let assetIdentifier { importedAssetIDs.append(assetIdentifier) }
                    sinceCommit += 1
                case .failed:
                    importProgress?.completed += 1
                    importProgress?.failed += 1
                case .outOfSpace:
                    importProgress?.completed += 1
                    importProgress?.failed += 1
                    importProgress?.ranOutOfSpace = true
                    pending.removeAll() // nothing else will fit either
                case .cancelled:
                    break
                }
                if sinceCommit >= Self.commitInterval {
                    sinceCommit = 0
                    try? await vault.commit()
                    await reload()
                }
                if !Task.isCancelled, let next = pending.popFirst() {
                    group.addTask { await Self.importOne(next, into: vault) }
                }
            }
        }

        // Also after a cancel or a lock: whatever finished encrypting is kept.
        var saved = true
        do {
            try await vault.commit()
        } catch {
            saved = false
        }
        if saved, let album, !importedItemIDs.isEmpty {
            try? await vault.addItems(importedItemIDs, toAlbum: album)
        }
        guard !isClosed else { return }
        await reload()
        // Never offer to delete originals unless their vault copies are saved.
        finishImport(importedAssetIDs: saved ? importedAssetIDs : [], wasCancelled: Task.isCancelled, saveFailed: !saved)
    }

    private func finishImport(importedAssetIDs: [String], wasCancelled: Bool, saveFailed: Bool) {
        var summary: String?
        if saveFailed {
            summary = "The vault couldn't save this import. Your originals are still in Photos."
        } else if let progress = importProgress {
            let added = progress.completed - progress.failed
            if wasCancelled {
                summary = "Stopped. \(added) of \(progress.total) items were added."
            } else if progress.ranOutOfSpace {
                summary = "Your iPhone ran out of space. \(added) of \(progress.total) items were added."
            } else if progress.failed > 0 {
                summary = progress.failed == 1
                    ? "1 item couldn't be added."
                    : "\(progress.failed) items couldn't be added."
            }
        }
        importProgress = nil
        if importedAssetIDs.isEmpty {
            importSummary = summary
        } else {
            pendingSummary = summary
            originalsToDelete = importedAssetIDs
            isOfferingOriginalDeletion = true
        }
    }

    /// Runs off the main actor, two at a time, inside the task group.
    private nonisolated static func importOne(_ picked: PhotosPickerItem, into vault: VaultLibrary) async -> Outcome {
        let signposter = Signposts.make()
        let interval = signposter.beginInterval("Import item")
        defer { signposter.endInterval("Import item", interval) }
        var staged: StagedFile?
        defer {
            // The unencrypted copy goes as soon as the item is done, whatever happened.
            if let staged { try? FileManager.default.removeItem(at: staged.url) }
        }
        do {
            try Task.checkCancellation()
            staged = try await StagedFile.load(from: picked)
            guard let file = staged else { return .failed }
            let inspection = try await MediaInspector.inspect(file)
            try DiskSpace.ensureRoom(forContentLength: file.byteCount, thumbnailLength: inspection.thumbnailJPEG.count)
            try Task.checkCancellation()
            let item = try await vault.importFile(at: file.url, metadata: inspection.metadata, thumbnailJPEG: inspection.thumbnailJPEG)
            return .imported(itemID: item.id, assetIdentifier: picked.itemIdentifier)
        } catch is CancellationError {
            return .cancelled
        } catch DiskSpace.Shortage.insufficient {
            return .outOfSpace
        } catch {
            return .failed
        }
    }

    // MARK: Deleting and saving

    /// Deletes for good, from the vault and every album.
    func delete(_ ids: Set<UUID>) async {
        do {
            try await vault.delete(ids)
        } catch {
            operationError = "The items couldn't be deleted."
        }
        await reload()
    }

    /// Saves copies to the Photos library, one at a time, so at most one
    /// decrypted file exists at any moment.
    func saveToPhotos(_ ids: Set<UUID>, removingLocation: Bool) {
        guard exportTask == nil, !ids.isEmpty else { return }
        let selected = items.filter { ids.contains($0.id) }
        exportProgress = ExportProgress(total: selected.count)
        exportSummary = nil
        let vault = vault
        let outgoing = VaultStore.standard().outgoingDirectory
        exportTask = Task {
            defer {
                exportProgress = nil
                exportTask = nil
            }
            guard await PhotosExporter.requestAccess() else {
                exportSummary = "PhotoVault isn't allowed to add to your library. You can allow it in Settings → Privacy & Security → Photos."
                return
            }
            for item in selected {
                if Task.isCancelled { return }
                do {
                    try await PhotosExporter.save(item, from: vault, via: outgoing, removingLocation: removingLocation)
                } catch {
                    exportProgress?.failed += 1
                }
                exportProgress?.completed += 1
            }
            guard let progress = exportProgress else { return }
            let saved = progress.completed - progress.failed
            var summary = saved == 1 ? "Saved 1 item to Photos." : "Saved \(saved) items to Photos."
            if progress.failed > 0 {
                summary += progress.failed == 1 ? " 1 couldn't be saved." : " \(progress.failed) couldn't be saved."
            }
            exportSummary = summary
        }
    }

    // MARK: Originals in Photos

    func deleteOriginalsFromPhotos() async {
        let identifiers = originalsToDelete
        originalsToDelete = []
        let message: String
        switch await PhotosCleanup.deleteOriginals(identifiers) {
        case .deleted(let count):
            message = count == identifiers.count
                ? "Deleted from Photos. They stay in Recently Deleted for 30 days; empty it in Photos to remove them from your iPhone."
                : "Deleted \(count) of \(identifiers.count) from Photos. The rest weren't accessible with the access you allowed."
        case .denied:
            message = "PhotoVault wasn't allowed to change your library, so the originals are still in Photos."
        case .failed:
            message = "The originals weren't deleted from Photos."
        }
        cleanupMessage = [pendingSummary, message].compactMap { $0 }.joined(separator: " ")
        pendingSummary = nil
    }

    func keepOriginals() {
        originalsToDelete = []
        importSummary = pendingSummary
        pendingSummary = nil
    }
}
