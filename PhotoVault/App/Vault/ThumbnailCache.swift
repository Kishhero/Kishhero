import UIKit
import VaultCore

/// Decrypted thumbnails, kept in memory only and never written to disk.
/// Emptied the moment the vault locks.
///
/// `@unchecked Sendable` because NSCache is documented as thread-safe.
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSUUID, UIImage>()

    init() {
        cache.countLimit = 800
        cache.totalCostLimit = 80 << 20 // decoded bytes, about 600 thumbnails
    }

    func image(for item: VaultItem, from vault: VaultLibrary) async -> UIImage? {
        let key = item.id as NSUUID
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? vault.thumbnailData(for: item), let image = UIImage(data: data) else {
                return nil
            }
            // Decode here, off the main thread, so scrolling never waits on JPEG decoding.
            return image.preparingForDisplay() ?? image
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
