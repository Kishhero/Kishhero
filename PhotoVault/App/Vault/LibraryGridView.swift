import SwiftUI
import UIKit
import VaultCore

/// The item grid, built on UICollectionView rather than SwiftUI's LazyVGrid:
/// cells are recycled, upcoming thumbnails are prefetched, and multi-select
/// (including two-finger swipe to select a range, as in Photos) comes with
/// it. It stays smooth with tens of thousands of items.
struct LibraryGridView: UIViewControllerRepresentable {
    let items: [VaultItem]
    let library: LibraryModel
    var footer: String?
    var isSelecting = false
    @Binding var selection: Set<UUID>
    let onOpen: (VaultItem) -> Void

    func makeUIViewController(context: Context) -> GridViewController {
        GridViewController(library: library)
    }

    func updateUIViewController(_ controller: GridViewController, context: Context) {
        controller.onOpen = onOpen
        let selection = $selection
        controller.onSelectionChange = { selection.wrappedValue = $0 }
        controller.show(items, footer: footer)
        controller.setSelecting(isSelecting, selection: selection.wrappedValue)
    }
}

final class GridViewController: UICollectionViewController, UICollectionViewDataSourcePrefetching {
    var onOpen: (VaultItem) -> Void = { _ in }
    var onSelectionChange: (Set<UUID>) -> Void = { _ in }

    private let library: LibraryModel
    private var itemsByID: [UUID: VaultItem] = [:]
    private var orderedIDs: [UUID] = []
    private var footerText: String?
    private var isSelecting = false
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
            let section = NSCollectionLayoutSection(group: group)
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52)),
                elementKind: UICollectionView.elementKindSectionFooter,
                alignment: .bottom
            )]
            return section
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.prefetchDataSource = self
        collectionView.allowsMultipleSelectionDuringEditing = true

        let cellRegistration = UICollectionView.CellRegistration<ThumbnailGridCell, UUID> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            cell.configure(with: item, library: library)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<FooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, _ in
            footer.label.text = self?.footerText
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    func show(_ items: [VaultItem], footer: String?) {
        loadViewIfNeeded() // SwiftUI may call this before the view has loaded
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        if footer != footerText {
            footerText = footer
            let footerPath = IndexPath(item: 0, section: 0)
            (collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: footerPath) as? FooterView)?
                .label.text = footer
        }
        let ids = items.map(\.id)
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

    /// Selection is owned by SwiftUI; this mirrors it into the collection view
    /// without reporting back, so no state changes during a view update.
    func setSelecting(_ selecting: Bool, selection: Set<UUID>) {
        if selecting != isSelecting {
            isSelecting = selecting
            collectionView.allowsMultipleSelection = selecting
            collectionView.isEditing = selecting
        }
        let selectedPaths = collectionView.indexPathsForSelectedItems ?? []
        let wanted = selecting ? selection : []
        for path in selectedPaths {
            if let id = dataSource.itemIdentifier(for: path), !wanted.contains(id) {
                collectionView.deselectItem(at: path, animated: false)
            }
        }
        let current = selectedIDs
        for id in wanted where !current.contains(id) {
            if let path = dataSource.indexPath(for: id) {
                collectionView.selectItem(at: path, animated: false, scrollPosition: [])
            }
        }
    }

    private var selectedIDs: Set<UUID> {
        Set((collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) })
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
        let insets = collectionView.adjustedContentInset
        let bottom = collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        collectionView.setContentOffset(CGPoint(x: 0, y: max(-insets.top, bottom)), animated: false)
    }

    // MARK: Selection

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard isSelecting else {
            if let id = dataSource.itemIdentifier(for: indexPath), let item = itemsByID[id] {
                onOpen(item)
            }
            return false
        }
        return true
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelectionChange(selectedIDs)
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        onSelectionChange(selectedIDs)
    }

    /// Two-finger swipe across the grid selects a range while selecting.
    override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        isSelecting
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let items = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { itemsByID[$0] }
        library.prefetchThumbnails(for: items)
    }
}

final class ThumbnailGridCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private let selectionDim = UIView()
    private let checkmark = UIImageView()
    private var representedID: UUID?
    private var loadTask: Task<Void, Never>?
    private var baseAccessibilityLabel = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        durationLabel.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.6
        durationLabel.layer.shadowRadius = 2
        durationLabel.layer.shadowOffset = .zero
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)

        selectionDim.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        selectionDim.frame = contentView.bounds
        selectionDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        selectionDim.isHidden = true
        contentView.addSubview(selectionDim)

        checkmark.image = UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])
        )
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.isHidden = true
        contentView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            checkmark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            checkmark.widthAnchor.constraint(equalToConstant: 24),
            checkmark.heightAnchor.constraint(equalToConstant: 24),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
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
        baseAccessibilityLabel = item.kind == .video ? "Video, \(date)" : "Photo, \(date)"
        updateSelectionAppearance()

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

    private func updateSelectionAppearance() {
        checkmark.isHidden = !isSelected
        selectionDim.isHidden = !isSelected
        // The checkmark sits where the duration label is; hide the label under it.
        if isSelected { durationLabel.alpha = 0 } else { durationLabel.alpha = 1 }
        accessibilityLabel = baseAccessibilityLabel
        accessibilityTraits = isSelected ? [.image, .button, .selected] : [.image, .button]
    }
}

final class FooterView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
