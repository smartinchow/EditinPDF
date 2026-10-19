import EditinPDFCore
import Observation
import UIKit

/// One page in the Organize grid, for the diffable data source: its index and the revision of the
/// document it is shown at, so that every change to the document is a fresh snapshot (a page's index
/// may name another page afterwards, and every picture is redrawn).
struct PageItem: Hashable, Sendable {
    let index: Int
    let revision: UInt64
}

/// The pages of the document in a grid, for the Organize screen: three columns on a compact width,
/// as many 140 point columns as fit on a regular one. A tap selects a page or takes it out of the
/// selection (several can be selected at once, and each selected page has a checkmark); a long press
/// picks up the selected pages (or the page pressed, when it is not selected) to drag them somewhere
/// else in the grid.
///
/// The pictures come from the shared `ThumbnailStore`: each page asks for its picture as it comes into
/// view and gives the request up as it leaves. The grid follows the document: `update()`, which the
/// screen calls whenever the document's revision moves, moves the store on to the new revision and
/// makes a new snapshot.
final class PageGridViewController: UICollectionViewController {
    private let model: DocumentModel
    private let store: ThumbnailStore
    private var dataSource: UICollectionViewDiffableDataSource<Int, PageItem>?
    /// The revision the grid shows.
    private var shownRevision: UInt64?

    /// The selected pages, counting from 0. Setting it redraws the pages whose state changed.
    var selection: Set<Int> = [] {
        didSet {
            guard selection != oldValue else { return }
            reconfigure(pages: selection.symmetricDifference(oldValue))
        }
    }

    /// Told of every selection the reader makes with a tap.
    var onSelectionChange: (Set<Int>) -> Void = { _ in }
    /// Told of a drop: the pages picked up (counting from 0) and the item of the grid as it was that
    /// they were dropped before (the page count for the end).
    var onMove: ([Int], Int) -> Void = { _, _ in }
    /// Whether pages can be picked up and dropped now.
    var canMove = true
    /// Whether a tap selects; false when the document's pages cannot be changed.
    var canSelect = true

    init(model: DocumentModel, store: ThumbnailStore) {
        self.model = model
        self.store = store
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .secondarySystemBackground
        collectionView.accessibilityIdentifier = "organizeGrid"
        collectionView.dragInteractionEnabled = true
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.reorderingCadence = .immediate
        let registration = UICollectionView.CellRegistration<PageGridCell, PageItem> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        update()
        trackPictures()
    }

    // MARK: Following the document

    /// Shows the document's pages as they are now: when the revision has moved, the store moves on to
    /// it, and every page is a new item.
    func update() {
        guard let dataSource, shownRevision != model.revision else { return }
        shownRevision = model.revision
        store.reload(pages: model.pages, revision: model.revision)
        var snapshot = NSDiffableDataSourceSnapshot<Int, PageItem>()
        snapshot.appendSections([0])
        snapshot.appendItems((0..<model.pageCount).map { PageItem(index: $0, revision: model.revision) })
        dataSource.apply(snapshot, animatingDifferences: false)
        prefetchVisible()
    }

    /// Scrolls the first of `pages` into view, unless one of them is in view already: for pages a
    /// change selected (an inserted page, moved pages), which may be anywhere.
    func reveal(_ pages: Set<Int>) {
        let visible = Set(collectionView.indexPathsForVisibleItems.map(\.item))
        guard let first = pages.min(), first < model.pageCount, visible.isDisjoint(with: pages) else { return }
        collectionView.scrollToItem(at: IndexPath(item: first, section: 0), at: .centeredVertically, animated: true)
    }

    /// Redraws the cells of `pages` that are there.
    private func reconfigure(pages: Set<Int>) {
        guard let dataSource, let revision = shownRevision else { return }
        var snapshot = dataSource.snapshot()
        let items = pages.map { PageItem(index: $0, revision: revision) }.filter { snapshot.indexOfItem($0) != nil }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Watches the store for pictures arriving (or going, on a reload) and redraws the cells in view
    /// when they do. The store tells observers of any picture, so reading one is enough to hear of all.
    private func trackPictures() {
        withObservationTracking {
            _ = store.image(for: 0)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                reconfigure(pages: Set(collectionView.indexPathsForVisibleItems.map(\.item)))
                trackPictures()
            }
        }
    }

    private func prefetchVisible() {
        for path in collectionView.indexPathsForVisibleItems {
            store.prefetch(path.item..<path.item + 1)
        }
    }

    private func configure(_ cell: PageGridCell, for item: PageItem) {
        let page = item.index
        guard model.pages.indices.contains(page) else { return }
        let info = model.pages[page]
        cell.show(page: page, aspectRatio: info.organizeAspectRatio, image: store.image(for: page),
                  isSelected: selection.contains(page))
    }

    // MARK: Taps

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard canSelect else { return }
        var selection = selection
        if selection.contains(indexPath.item) { selection.remove(indexPath.item) } else { selection.insert(indexPath.item) }
        self.selection = selection
        onSelectionChange(selection)
    }

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                                 forItemAt indexPath: IndexPath) {
        store.prefetch(indexPath.item..<indexPath.item + 1)
    }

    override func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                                 forItemAt indexPath: IndexPath) {
        store.cancelPrefetch(indexPath.item..<indexPath.item + 1)
    }

    // MARK: Layout

    /// Three columns on a compact width; on a regular one, as many as fit at 140 points or more. A
    /// cell is as tall as its paper (4 to 3 of the column's width, tall enough for a Letter or A4 page)
    /// and the page number under it.
    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let spacing: CGFloat = 16
            let inset: CGFloat = 16
            let width = environment.container.effectiveContentSize.width - 2 * inset
            let columns = environment.traitCollection.horizontalSizeClass == .compact
                ? 3 : max(3, Int((width + spacing) / (140 + spacing)))
            let cellWidth = max(1, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            let height = (cellWidth * PageGridCell.paperHeightInWidths).rounded(.up) + PageGridCell.captionHeight
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(cellWidth), heightDimension: .absolute(height)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                                                           repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 20
            section.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
            return section
        }
    }
}

// MARK: Dragging pages

/// What a drag in the grid carries: the pages picked up, and the one the finger is on.
private final class PageDrag {
    let pages: [Int]
    let origin: Int

    init(pages: [Int], origin: Int) {
        self.pages = pages
        self.origin = origin
    }
}

extension PageGridViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard canMove else { return [] }
        let page = indexPath.item
        let pages = selection.contains(page) ? selection.sorted() : [page]
        session.localContext = PageDrag(pages: pages, origin: page)
        // One drag item, whatever the number of pages: the collection view reorders a single item (it
        // takes it out of the grid and opens a gap where it would go), and a drop of several items
        // was never performed (observed on the iOS 26.5 simulator). The pages travel in the context.
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = page
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession?.localContext is PageDrag
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard canMove, session.localDragSession?.localContext is PageDrag else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard canMove, let drag = coordinator.session.localDragSession?.localContext as? PageDrag else { return }
        let dropIndex = Self.dropIndex(destination: coordinator.destinationIndexPath?.item, origin: drag.origin,
                                       pageCount: model.pageCount)
        onMove(drag.pages, dropIndex)
    }

    /// The item of the grid as it was that a drop lands before. While pages are dragged, the collection
    /// view takes the page under the finger out of the grid and opens a gap where it would go:
    /// `destination` counts the items without it, so from the origin on it is one short. No
    /// destination (a drop past the last page) is the end.
    nonisolated static func dropIndex(destination: Int?, origin: Int, pageCount: Int) -> Int {
        guard let destination else { return pageCount }
        return min(destination >= origin ? destination + 1 : destination, pageCount)
    }
}

// MARK: The cell

/// A page in the grid: its picture on white paper of the page's shape, with a checkmark in the corner
/// when it is selected and its number under it.
final class PageGridCell: UICollectionViewCell {
    /// How tall the paper's frame is, in widths of the cell.
    static let paperHeightInWidths: CGFloat = 4.0 / 3.0
    /// How tall the caption is, in points.
    static let captionHeight: CGFloat = 26

    private let paper = UIView()
    private let picture = UIImageView()
    private let badge = UIImageView()
    private let caption = UILabel()
    private var aspectRatio: CGFloat = 612.0 / 792.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        paper.backgroundColor = .white
        paper.layer.shadowColor = UIColor.black.cgColor
        paper.layer.shadowOpacity = 0.2
        paper.layer.shadowRadius = 2
        paper.layer.shadowOffset = CGSize(width: 0, height: 1)
        paper.layer.borderColor = tintColor.cgColor
        picture.contentMode = .scaleAspectFit
        picture.clipsToBounds = true
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.adjustsFontForContentSizeCategory = true
        caption.textAlignment = .center
        caption.textColor = .secondaryLabel
        badge.contentMode = .scaleAspectFit
        paper.addSubview(picture)
        contentView.addSubview(paper)
        contentView.addSubview(badge)
        contentView.addSubview(caption)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(page: Int, aspectRatio: CGFloat, image: UIImage?, isSelected: Bool) {
        self.aspectRatio = aspectRatio
        picture.image = image
        caption.text = Strings.pageNumber(page + 1)
        caption.textColor = isSelected ? tintColor : .secondaryLabel
        paper.layer.borderWidth = isSelected ? 3 : 0
        badge.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        badge.tintColor = isSelected ? tintColor : .tertiaryLabel
        badge.backgroundColor = isSelected ? .white : .clear
        accessibilityIdentifier = "organizePage-\(page)"
        accessibilityLabel = Strings.thumbnailLabel(page: page + 1)
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        paper.layer.borderColor = tintColor.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let area = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.captionHeight)
        // The page's shape, as large as fits in the area, standing on its bottom edge.
        var size = CGSize(width: area.width, height: area.width / aspectRatio)
        if size.height > area.height { size = CGSize(width: area.height * aspectRatio, height: area.height) }
        paper.frame = CGRect(x: area.midX - size.width / 2, y: area.maxY - size.height, width: size.width, height: size.height)
        paper.layer.shadowPath = UIBezierPath(rect: paper.bounds).cgPath
        picture.frame = paper.bounds
        let badgeSide: CGFloat = 24
        badge.frame = CGRect(x: paper.frame.maxX - badgeSide - 4, y: paper.frame.maxY - badgeSide - 4, width: badgeSide, height: badgeSide)
        badge.layer.cornerRadius = badgeSide / 2
        caption.frame = CGRect(x: 0, y: area.maxY + 4, width: bounds.width, height: Self.captionHeight - 4)
    }
}

private extension PageInfo {
    /// The page's width over its height, for its paper: that of a Letter page when the size cannot be
    /// used, and no more extreme than 1 to 4 either way.
    var organizeAspectRatio: CGFloat {
        guard widthPt.isFinite, heightPt.isFinite, widthPt > 0, heightPt > 0 else { return 612.0 / 792.0 }
        let limit = CGFloat(ThumbnailStore.tallestInWidths)
        return min(max(widthPt / heightPt, 1 / limit), limit)
    }
}
