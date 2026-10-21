import Foundation
import Observation
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

/// The open vault as the UI sees it: the item list, imports in progress, and
/// thumbnails. Created on unlock, closed and dropped on lock.
@MainActor
@Observable
final class LibraryModel {
    private(set) var items: [VaultItem] = []
    private(set) var importProgress: ImportProgress?
    /// Shown after an import: failures or running out of space.
    var importSummary: String?
    /// Drives the "delete originals from Photos?" prompt after an import.
    var isOfferingOriginalDeletion = false
    private(set) var originalsToDelete: [String] = []
    var cleanupMessage: String?
    /// The import summary, held back while the delete prompt is up: SwiftUI
    /// can't show an alert and a dialog at the same time.
    @ObservationIgnored private var pendingSummary: String?

    let vault: VaultLibrary
    @ObservationIgnored private let thumbnails = ThumbnailCache()
    @ObservationIgnored private var importTask: Task<Void, Never>?
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
    }

    var photoCount: Int { items.lazy.filter { $0.kind == .photo }.count }
    var videoCount: Int { items.lazy.filter { $0.kind == .video }.count }

    func reload() async {
        items = await vault.items()
    }

    func thumbnail(for item: VaultItem) async -> UIImage? {
        await thumbnails.image(for: item, from: vault)
    }

    /// Stops any import and drops every decrypted thumbnail. Called on lock.
    func close() {
        isClosed = true
        importTask?.cancel()
        importTask = nil
        thumbnails.removeAll()
    }

    // MARK: Import

    func startImport(_ picked: [PhotosPickerItem]) {
        guard importTask == nil, !picked.isEmpty else { return }
        importProgress = ImportProgress(total: picked.count)
        importSummary = nil
        let vault = vault
        importTask = Task {
            await runImport(picked, vault: vault)
            importTask = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private enum Outcome: Sendable {
        case imported(assetIdentifier: String?)
        case failed
        case outOfSpace
        case cancelled
    }

    private func runImport(_ picked: [PhotosPickerItem], vault: VaultLibrary) async {
        var pending = picked[...]
        var importedAssetIDs: [String] = []
        var sinceCommit = 0

        await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<Self.concurrentImports {
                guard let next = pending.popFirst() else { break }
                group.addTask { await Self.importOne(next, into: vault) }
            }
            while let outcome = await group.next() {
                switch outcome {
                case .imported(let assetIdentifier):
                    importProgress?.completed += 1
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
        try? await vault.commit()
        guard !isClosed else { return }
        await reload()
        finishImport(importedAssetIDs: importedAssetIDs, wasCancelled: Task.isCancelled)
    }

    private func finishImport(importedAssetIDs: [String], wasCancelled: Bool) {
        var summary: String?
        if let progress = importProgress {
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
            _ = try await vault.importFile(at: file.url, metadata: inspection.metadata, thumbnailJPEG: inspection.thumbnailJPEG)
            return .imported(assetIdentifier: picked.itemIdentifier)
        } catch is CancellationError {
            return .cancelled
        } catch DiskSpace.Shortage.insufficient {
            return .outOfSpace
        } catch {
            return .failed
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
