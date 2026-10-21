import SwiftUI
import UIKit
import VaultCore

/// Full-screen viewer: swipe between items, pinch or double-tap to zoom
/// photos, videos play in place. Tap to show or hide the controls.
struct MediaViewer: View {
    let library: LibraryModel
    let items: [VaultItem]
    @State private var index: Int
    @State private var showsChrome = true
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, items: [VaultItem], startID: UUID) {
        self.library = library
        self.items = items
        _index = State(initialValue: items.firstIndex { $0.id == startID } ?? 0)
    }

    var body: some View {
        MediaPager(library: library, items: items, index: $index) {
            withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .overlay(alignment: .top) {
            if showsChrome, items.indices.contains(index) {
                header(for: items[index])
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
    }

    private func header(for item: VaultItem) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                Text(item.sortDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)
                Text(item.sortDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }
}

/// UIPageViewController, which gets the hard parts right: paging next to a
/// zoomed photo, and keeping only the neighbouring pages in memory.
private struct MediaPager: UIViewControllerRepresentable {
    let library: LibraryModel
    let items: [VaultItem]
    @Binding var index: Int
    let onToggleChrome: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 16]
        )
        pager.view.backgroundColor = .black
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        if let first = context.coordinator.page(at: index) {
            pager.setViewControllers([first], direction: .forward, animated: false)
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MediaPager

        init(_ parent: MediaPager) {
            self.parent = parent
        }

        func page(at index: Int) -> MediaPageController? {
            guard parent.items.indices.contains(index) else { return nil }
            let item = parent.items[index]
            let page: MediaPageController = item.kind == .video
                ? VideoPageController(index: index, item: item, library: parent.library)
                : PhotoPageController(index: index, item: item, library: parent.library)
            page.onToggleChrome = { [weak self] in self?.parent.onToggleChrome() }
            return page
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            (viewController as? MediaPageController).flatMap { page(at: $0.index - 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            (viewController as? MediaPageController).flatMap { page(at: $0.index + 1) }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed, let current = pageViewController.viewControllers?.first as? MediaPageController else { return }
            parent.index = current.index
        }
    }
}

/// One page of the viewer.
class MediaPageController: UIViewController {
    let index: Int
    let item: VaultItem
    let library: LibraryModel
    var onToggleChrome: () -> Void = {}

    init(index: Int, item: VaultItem, library: LibraryModel) {
        self.index = index
        self.item = item
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
