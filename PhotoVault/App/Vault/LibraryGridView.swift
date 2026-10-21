import SwiftUI
import UIKit
import VaultCore

/// The library grid, built on UICollectionView rather than SwiftUI's
/// LazyVGrid: cells are recycled, upcoming thumbnails are prefetched, and
/// step 6's drag-to-select comes with it. It stays smooth with tens of
/// thousands of items.
struct LibraryGridView: UIViewControllerRepresentable {
    let items: [VaultItem]
    let library: LibraryModel
    let onSelect: (VaultItem) -> Void

    func makeUIViewController(context: Context) -> GridViewController {
        GridViewController(library: library)
    }

    func updateUIViewController(_ controller: GridViewController, context: Context) {
        controller.onSelect = onSelect
        controller.show(items)
    }
}

final class GridViewController: UICollectionViewController, UICollectionViewDataSourcePrefetching {
    var onSelect: (VaultItem) -> Void = { _ in }

    private let library: LibraryModel
    private var itemsByID: [UUID: VaultItem] = [:]
    private var orderedIDs: [UUID] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private var hasScrolledToBottom = false

    init(library: LibraryModel) {
        self.library = library
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Square cells, 2 pt apart: 3 across in portrait, more on wider screens.
    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(3, Int(width / 130))
            let fraction = 1 / CGFloat(columns)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(fraction),
                heightDimension: .fractionalWidth(fraction)
            ))
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(fraction)),
                repeatingSubitem: item,
                count: columns
            )
            return NSCollectionLayoutSection(group: group)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.prefetchDataSource = self
        let registration = UICollectionView.CellRegistration<ThumbnailGridCell, UUID> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            cell.configure(with: item, library: library)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func show(_ items: [VaultItem]) {
        loadViewIfNeeded() // SwiftUI may call this before the view has loaded
        let ids = items.map(\.id)
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard ids != orderedIDs else { return }
        let wasAtBottom = isNearBottom
        orderedIDs = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        dataSource.apply(snapshot, animatingDifferences: false)
        // Like Photos: newest at the bottom, and stay there as imports arrive.
        if wasAtBottom && hasScrolledToBottom {
            collectionView.layoutIfNeeded()
            scrollToBottom()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !hasScrolledToBottom, !orderedIDs.isEmpty, collectionView.bounds.height > 0 {
            hasScrolledToBottom = true
            scrollToBottom()
        }
    }

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return orderedIDs.isEmpty || visibleBottom >= collectionView.contentSize.height - 200
    }

    private func scrollToBottom() {
        guard !orderedIDs.isEmpty else { return }
        collectionView.scrollToItem(at: IndexPath(item: orderedIDs.count - 1, section: 0), at: .bottom, animated: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = itemsByID[id] else { return }
        onSelect(item)
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let items = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { itemsByID[$0] }
        library.prefetchThumbnails(for: items)
    }
}

final class ThumbnailGridCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private var representedID: UUID?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        durationLabel.font = .preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        durationLabel.textColor = .white
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.6
        durationLabel.layer.shadowRadius = 2
        durationLabel.layer.shadowOffset = .zero
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)
        NSLayoutConstraint.activate([
            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
        ])

        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedID = nil
        imageView.image = nil
    }

    func configure(with item: VaultItem, library: LibraryModel) {
        representedID = item.id
        if item.kind == .video, let duration = item.duration {
            durationLabel.text = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
            durationLabel.isHidden = false
        } else {
            durationLabel.isHidden = true
        }
        let date = item.sortDate.formatted(date: .abbreviated, time: .omitted)
        accessibilityLabel = item.kind == .video ? "Video, \(date)" : "Photo, \(date)"

        if let cached = library.cachedThumbnail(for: item) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            let image = await library.thumbnail(for: item)
            guard let self, !Task.isCancelled, representedID == item.id else { return }
            imageView.image = image
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
