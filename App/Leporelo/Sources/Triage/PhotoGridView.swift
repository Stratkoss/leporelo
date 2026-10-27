import AppKit
import LeporeloCore
import SwiftUI

/// The triage grid: an `NSCollectionView` (cell reuse, prefetching) wrapped for SwiftUI.
///
/// Decision (Task 20 ruling): AppKit from the start instead of `LazyVGrid`, because a SwiftUI
/// grid may not scroll 3 000 cells smoothly and fps cannot be measured without a real library.
///
/// Updates are incremental: the item ids go through a diffable data source (only inserted or
/// removed cells change), and cells whose `TriageItem` changed (selection, badges, series chip)
/// are reconfigured in place; a selection toggle never reloads the grid. Thumbnails load
/// asynchronously in the cell (`ThumbnailLoader`), cancelled when the cell is reused.
///
/// Interaction: a click (mouse up without a drag) toggles the photo; space toggles the
/// keyboard-focused cell; the series chip expands or collapses; dragging a cell carries
/// `PhotoDrag.payload` as plain text, which the day list accepts.
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
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
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
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewPrefetching,
                             NSGestureRecognizerDelegate {
        let loader = ThumbnailLoader()
        var onToggle: (PhotoID) -> Void = { _ in }
        var onSeriesChip: (String) -> Void = { _ in }
        var package: ProjectPackage?

        private weak var collectionView: NSCollectionView?
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
            dataSource = NSCollectionViewDiffableDataSource<Int, PhotoID>(collectionView: collectionView) {
                [weak self] collectionView, indexPath, id in
                let cell = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath)
                if let self, let cell = cell as? PhotoCell { self.configure(cell, id: id) }
                return cell
            }
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            click.delaysPrimaryMouseButtonEvents = false // the collection view still sees mouse down (drag)
            click.delegate = self
            collectionView.addGestureRecognizer(click)
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
                return
            }
            // Reconfigure only the visible cells whose item changed (others are configured when
            // they scroll in).
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      previous[id] != itemsByID[id],
                      let cell = collectionView.item(at: indexPath) as? PhotoCell else { continue }
                configure(cell, id: id)
            }
        }

        private func configure(_ cell: PhotoCell, id: PhotoID) {
            guard let item = itemsByID[id], let package else { return }
            cell.onSeriesChip = { [weak self] seriesID in self?.onSeriesChip(seriesID) }
            cell.configure(item, loader: loader, package: package)
        }

        // MARK: Click and keyboard

        @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended, let collectionView,
                  let indexPath = collectionView.indexPathForItem(at: recognizer.location(in: collectionView)),
                  let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            onToggle(id)
        }

        /// Clicks on the series chip (a button) belong to the button, not to the toggle.
        func gestureRecognizer(_ recognizer: NSGestureRecognizer,
                               shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard let collectionView else { return false }
            let point = collectionView.convert(event.locationInWindow, from: nil)
            return !(collectionView.hitTest(point) is NSButton)
        }

        private func toggleFocused() {
            guard let indexPath = collectionView?.selectionIndexPaths.first,
                  let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            onToggle(id)
        }

        // MARK: Drag source

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                            with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            return PhotoDrag.payload(for: id) as NSString
        }

        // MARK: Prefetching

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let package else { return }
            loader.prefetch(indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }, from: package)
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            loader.cancelPrefetch(indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) })
        }
    }
}

/// Space toggles the keyboard-focused cell (arrow keys move the focus).
final class TriageCollectionView: NSCollectionView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", let onSpace {
            onSpace()
        } else {
            super.keyDown(with: event)
        }
    }
}
