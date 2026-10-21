import UIKit
import VaultCore

/// Decrypted thumbnails, kept in memory only and never written to disk.
/// Dropped with the library when the vault locks.
///
/// When the grid prefetches a thumbnail and then shows it, both requests
/// share one decryption instead of doing the work twice.
///
/// `@unchecked Sendable`: NSCache is thread-safe, and `inFlight` is only
/// touched under `lock`.
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSUUID, UIImage>()
    private let lock = NSLock()
    private var inFlight: [UUID: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 800
        cache.totalCostLimit = 80 << 20 // decoded bytes, about 600 thumbnails
    }

    func cachedImage(for id: UUID) -> UIImage? {
        cache.object(forKey: id as NSUUID)
    }

    func image(for item: VaultItem, from vault: VaultLibrary) async -> UIImage? {
        if let cached = cachedImage(for: item.id) {
            return cached
        }
        let task = lock.withLock { () -> Task<UIImage?, Never> in
            if let existing = inFlight[item.id] {
                return existing
            }
            let task = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
                guard let data = try? vault.thumbnailData(for: item), let image = UIImage(data: data) else {
                    return nil
                }
                // Decode here, off the main thread, so scrolling never waits on JPEG decoding.
                let decoded = image.preparingForDisplay() ?? image
                cache.setObject(decoded, forKey: item.id as NSUUID, cost: decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
                return decoded
            }
            inFlight[item.id] = task
            return task
        }
        let image = await task.value
        lock.withLock { inFlight[item.id] = nil }
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
