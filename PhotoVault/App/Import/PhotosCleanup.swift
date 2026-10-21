import Photos

/// Deletes the originals of imported items from the Photos library, only
/// when the user asks to, right after an import.
///
/// Trade-off, stated in the prompt: deleting needs full Photos access, which
/// technically lets the app read the whole library. The app uses it for this
/// one call and nothing else, and asks for it only the first time.
/// Photos keeps deleted items in Recently Deleted for 30 days; they are only
/// gone from the phone once that is emptied.
enum PhotosCleanup {
    enum Result: Equatable {
        case deleted(Int)
        case denied
        case failed
    }

    static func deleteOriginals(_ localIdentifiers: [String]) async -> Result {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return .denied }
        let count = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil).count
        guard count > 0 else { return .deleted(0) }
        do {
            // iOS shows its own confirmation before anything is deleted.
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil))
            }
            return .deleted(count)
        } catch {
            return .failed // includes tapping "Don't Allow" in that confirmation
        }
    }
}
