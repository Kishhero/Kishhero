import SwiftUI
import UIKit
import VaultCore

/// Full-screen viewer: swipe between items, pinch or double-tap to zoom
/// photos, videos play in place. Tap to show or hide the controls.
struct MediaViewer: View {
    let library: LibraryModel
    let items: [VaultItem]
    /// The album being viewed, for "Remove from Album".
    let albumID: UUID?
    @State private var index: Int
    @State private var showsChrome = true
    @State private var confirmingDelete = false
    @State private var confirmingSave = false
    @State private var choosingAlbum = false
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, items: [VaultItem], startID: UUID, albumID: UUID? = nil) {
        self.library = library
        self.items = items
        self.albumID = albumID
        _index = State(initialValue: items.firstIndex { $0.id == startID } ?? 0)
    }

    private var current: VaultItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        MediaPager(library: library, items: items, index: $index) {
            withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .overlay(alignment: .top) {
            if showsChrome, let current {
                header(for: current)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showsChrome, current != nil {
                actionBar
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .confirmationDialog("Delete this item?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Item", role: .destructive) {
                guard let current else { return }
                dismiss()
                Task { await library.delete([current.id]) }
            }
        } message: {
            Text("It's removed from the vault and from every album. This can't be undone.")
        }
        .confirmationDialog("Save to Photos?", isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("Save") { save(removingLocation: false) }
            Button("Save Without Location") { save(removingLocation: true) }
        } message: {
            Text(SaveToPhotos.explanation)
        }
        .sheet(isPresented: $choosingAlbum) {
            AlbumPickerSheet(library: library, excluding: albumID) { album in
                guard let current else { return }
                Task { await library.add([current.id], toAlbum: album) }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button {
                confirmingSave = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Save to Photos")
            .disabled(library.exportProgress != nil)
            Spacer()
            if library.exportProgress != nil {
                ProgressView()
                Spacer()
            }
            Button {
                choosingAlbum = true
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Add to Album")
            if let albumID, let current {
                Spacer()
                Button {
                    dismiss()
                    Task { await library.remove([current.id], fromAlbum: albumID) }
                } label: {
                    Image(systemName: "rectangle.stack.badge.minus")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Remove from Album")
            }
            Spacer()
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Delete")
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func save(removingLocation: Bool) {
        guard let current else { return }
        library.saveToPhotos([current.id], removingLocation: removingLocation)
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
