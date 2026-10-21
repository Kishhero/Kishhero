import ImageIO
import UIKit

enum ImageDecoding {
    /// Decodes an image at no more than `maxPixelSize` on its longest side,
    /// with its orientation applied.
    ///
    /// Decoding at display size rather than full size is what keeps memory
    /// sane: a 48 MP photo is about 190 MB decoded, but under 40 MB at
    /// screen size.
    static func image(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
