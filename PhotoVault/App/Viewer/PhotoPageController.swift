import UIKit
import VaultCore

/// A zoomable photo.
///
/// Shows the cached thumbnail instantly, then a screen-resolution decode.
/// The full-resolution decode happens only when you zoom in, and is dropped
/// again when you swipe away. Speed vs. memory: a 48 MP photo at full size
/// is about 190 MB in memory, so it is decoded at most at
/// `zoomedPixelLimit` and only for the page on screen.
final class PhotoPageController: MediaPageController, UIScrollViewDelegate {
    /// Enough for sharp zooming on any iPhone without exhausting memory.
    private static let zoomedPixelLimit = 6144

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var hasStartedLoading = false
    private var isFullResolution = false
    private var lastLaidOutSize = CGSize.zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)

        imageView.contentMode = .scaleToFill // the frame already has the photo's aspect ratio
        imageView.image = library.cachedThumbnail(for: item)
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "Photo, \(item.sortDate.formatted(date: .long, time: .shortened))"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastLaidOutSize, view.bounds.width > 0 else { return }
        lastLaidOutSize = view.bounds.size
        scrollView.zoomScale = 1
        imageView.frame = fittedFrame(in: view.bounds.size)
        scrollView.contentSize = imageView.frame.size
        centerImage()
        if !hasStartedLoading {
            hasStartedLoading = true
            load(maxPixelSize: screenPixelSize)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Give back the memory of a full-resolution decode as soon as the page is off screen.
        if isFullResolution {
            isFullResolution = false
            scrollView.zoomScale = 1
            load(maxPixelSize: screenPixelSize)
        }
    }

    /// The screen's longest side in pixels, plus headroom for a little zoom.
    private var screenPixelSize: Int {
        let points = max(view.bounds.width, view.bounds.height)
        return min(Int(points * traitCollection.displayScale * 1.25), 4096)
    }

    private func load(maxPixelSize: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self, library, item] in
            let image = await library.displayImage(for: item, maxPixelSize: maxPixelSize)
            guard let self, !Task.isCancelled, let image else { return }
            // Same aspect ratio as the frame, so swapping in a sharper image
            // keeps the current zoom and position.
            imageView.image = image
        }
    }

    private func fittedFrame(in bounds: CGSize) -> CGRect {
        var imageSize = item.pixelWidth > 0 && item.pixelHeight > 0
            ? CGSize(width: item.pixelWidth, height: item.pixelHeight)
            : (imageView.image?.size ?? bounds)
        if imageSize.width <= 0 || imageSize.height <= 0 {
            imageSize = bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGRect(origin: .zero, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
    }

    private func centerImage() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale > 1.5, !isFullResolution {
            isFullResolution = true
            let longest = max(item.pixelWidth, item.pixelHeight)
            load(maxPixelSize: min(longest > 0 ? longest : Self.zoomedPixelLimit, Self.zoomedPixelLimit))
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func handleSingleTap() {
        onToggleChrome()
    }
}
