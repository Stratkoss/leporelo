import AppKit
import LeporeloCore
import SwiftUI

/// The triage grid: an `NSCollectionView` (cell reuse, prefetching) wrapped for SwiftUI.
///
/// Decision (Task 20 ruling): AppKit from the start instead of `LazyVGrid`, because a SwiftUI
/// grid may not scroll 3 000 cells smoothly and fps cannot be measured without a real library.
///
/// Updates are incremental: the item ids go through a diffable data source (only inserted or
/// removed cells change), and every instantiated cell whose `TriageItem` changed (selection,
/// badges, series chip) is reconfigured in place; a selection toggle never reloads the grid.
/// Thumbnails load asynchronously in the cell (`ThumbnailLoader`), cancelled when it is reused.
///
/// Interaction: a click (mouse down and up on the same cell, no drag) toggles the photo
/// (`GridClick`, decided in `TriageCollectionView`); space toggles the keyboard-focused cell; the
/// series chip (a button) expands or collapses; VoiceOver "press" toggles; dragging a cell
/// carries `PhotoDrag.payload` as plain text, which the day list accepts.
struct PhotoGridView: NSViewRepresentable {
    let items: [TriageItem]
    /// The shown entry: switching entries scrolls to the top without animation.
    let entry: DayEntryID?
    let package: ProjectPackage
    let onToggle: (PhotoID) -> Void
    let onSeriesChip: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: PhotoCell.side, height: PhotoCell.side)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collectionView = TriageCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true // needed for dragging and keyboard focus
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        // SwiftUI's dropDestination proposes a copy, so local drags offer move, copy and generic;
        // nothing is offered outside the app.
        collectionView.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([], forLocal: false)
        collectionView.setAccessibilityLabel("Fotky dne")

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.attach(collectionView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggle = onToggle
        coordinator.onSeriesChip = onSeriesChip
        coordinator.package = package
        coordinator.apply(items, entry: entry)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.loader.cancelAll()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        let loader = ThumbnailLoader()
        var onToggle: (PhotoID) -> Void = { _ in }
        var onSeriesChip: (String) -> Void = { _ in }
        var package: ProjectPackage?

        private weak var collectionView: TriageCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<Int, PhotoID>?
        private var itemsByID: [PhotoID: TriageItem] = [:]
        private var ids: [PhotoID] = []
        private var entry: DayEntryID?
        private var hasApplied = false

        func attach(_ collectionView: TriageCollectionView) {
            self.collectionView = collectionView
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.onSpace = { [weak self] in self?.toggleFocused() }
            collectionView.onClick = { [weak self] indexPath in self?.toggle(at: indexPath) }
            collectionView.isVideoAt = { [weak self] indexPath in
                guard let self, let id = self.dataSource?.itemIdentifier(for: indexPath) else { return false }
                return self.itemsByID[id]?.isSelectable == false
            }
            dataSource = NSCollectionViewDiffableDataSource<Int, PhotoID>(collectionView: collectionView) {
                [weak self] collectionView, indexPath, id in
                let cell = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath)
                if let self, let cell = cell as? PhotoCell { self.configure(cell, id: id) }
                return cell
            }
        }

        func apply(_ items: [TriageItem], entry: DayEntryID?) {
            guard let dataSource, let collectionView else { return }
            let previous = itemsByID
            let newIDs = items.map(\.id)
            itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let entryChanged = entry != self.entry || !hasApplied
            self.entry = entry

            if newIDs != ids || !hasApplied {
                var snapshot = NSDiffableDataSourceSnapshot<Int, PhotoID>()
                snapshot.appendSections([0])
                snapshot.appendItems(newIDs)
                ids = newIDs
                dataSource.apply(snapshot, animatingDifferences: !entryChanged)
            }
            hasApplied = true
            if entryChanged {
                collectionView.deselectAll(nil)
                collectionView.scroll(.zero)
            }
            // Reconfigure every instantiated cell (visible or prepared off screen) whose item
            // changed; ids new to the snapshot were configured by the cell provider.
            for item in items {
                guard let old = previous[item.id], old != item,
                      let indexPath = dataSource.indexPath(for: item.id),
                      let cell = collectionView.item(at: indexPath) as? PhotoCell else { continue }
                configure(cell, id: item.id)
            }
        }

        private func configure(_ cell: PhotoCell, id: PhotoID) {
            guard let item = itemsByID[id], let package else { return }
            cell.onSeriesChip = { [weak self] seriesID in self?.onSeriesChip(seriesID) }
            cell.onPress = { [weak self] in self?.onToggle(id) }
            cell.configure(item, loader: loader, package: package)
        }

        // MARK: Click and keyboard

        private func toggle(at indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            onToggle(id)
        }

        private func toggleFocused() {
            guard let indexPath = collectionView?.selectionIndexPaths.first else { return }
            toggle(at: indexPath)
        }

        // MARK: Drag source

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                            with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            return PhotoDrag.payload(for: id) as NSString
        }

        /// A drag began during this mouse down: the mouse up must not toggle.
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            (collectionView as? TriageCollectionView)?.didStartDrag = true
        }

        // MARK: Prefetching

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let package else { return }
            let requests = indexPaths.compactMap { indexPath -> (id: PhotoID, maxPixel: Int)? in
                guard let id = dataSource?.itemIdentifier(for: indexPath), let item = itemsByID[id] else { return nil }
                return (id, ThumbnailLoader.maxPixel(for: item.photo))
            }
            loader.prefetch(requests, from: package)
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            loader.cancelPrefetch(indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) })
        }
    }
}

/// When a mouse down / mouse up pair on the grid toggles a photo: both on the same cell, no drag
/// session began in between, and the photo can be selected (videos cannot; the model rejects
/// them too).
enum GridClick {
    static func shouldToggle(down: IndexPath?, up: IndexPath?, didStartDrag: Bool, isVideo: Bool) -> Bool {
        guard let down, down == up else { return false }
        return !didStartDrag && !isVideo
    }
}

/// The grid's collection view: decides clicks itself (see `GridClick`) so that a drag never also
/// toggles; space toggles the keyboard-focused cell (arrow keys move the focus).
///
/// `super.mouseDown` keeps selection and drag tracking. AppKit may either return from it before
/// the mouse goes up (then `mouseUp` finishes the click) or track until mouse up itself (then the
/// current event is the mouse up and the click is finished right after `super`); either way it is
/// finished at most once per mouse down.
final class TriageCollectionView: NSCollectionView {
    var onSpace: (() -> Void)?
    var onClick: ((IndexPath) -> Void)?
    var isVideoAt: ((IndexPath) -> Bool)?
    /// Set by the delegate when a dragging session begins; reset on every mouse down.
    var didStartDrag = false

    private var downIndexPath: IndexPath?
    private var isTrackingClick = false

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        downIndexPath = indexPath(at: event)
        isTrackingClick = true
        super.mouseDown(with: event)
        if isTrackingClick, let current = NSApp.currentEvent, current.type == .leftMouseUp {
            finishClick(current)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if isTrackingClick { finishClick(event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", let onSpace {
            onSpace()
        } else {
            super.keyDown(with: event)
        }
    }

    private func finishClick(_ upEvent: NSEvent) {
        isTrackingClick = false
        let down = downIndexPath
        downIndexPath = nil
        let up = indexPath(at: upEvent)
        let isVideo = down.map { isVideoAt?($0) ?? false } ?? false
        guard GridClick.shouldToggle(down: down, up: up, didStartDrag: didStartDrag, isVideo: isVideo),
              let down else { return }
        onClick?(down)
    }

    private func indexPath(at event: NSEvent) -> IndexPath? {
        indexPathForItem(at: convert(event.locationInWindow, from: nil))
    }
}
