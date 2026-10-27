import Foundation
import LeporeloCore
import Observation

/// What an album window is bound to: the document's store and the background work that belongs
/// to exactly that store (Task 17 contract (a)). Every `bind` cancels the previous work before it
/// creates the store's new work, so after a revert or reload the old store, which is a dead end,
/// never receives results; `close` cancels it when the window goes away.
@MainActor
@Observable
final class AlbumSession {
    private(set) var store: AlbumStore?
    private(set) var work: BackgroundWork?
    private(set) var bindError: String?

    @ObservationIgnored private let placeResolver: @Sendable () -> any PlaceResolver
    @ObservationIgnored private let options: BackgroundWork.Options

    init(placeResolver: @escaping @Sendable () -> any PlaceResolver = { GeocoderPlaceResolver() },
         options: BackgroundWork.Options = .init()) {
        self.placeResolver = placeResolver
        self.options = options
    }

    /// Binds to `document`'s store for `fileURL` and starts that store's background work. Also
    /// called again after a move (same store, new package URL: the work restarts on the new URL).
    func bind(document: AlbumDocument, fileURL: URL?, sourceProvider: @escaping PhotoSourceProvider) {
        close()
        store = nil
        guard let fileURL else { return }
        do {
            let store = try document.bind(to: fileURL)
            self.store = store
            bindError = nil
            let work = BackgroundWork(store: store, sourceProvider: sourceProvider,
                                      placeResolver: placeResolver, options: options)
            self.work = work
            work.start()
        } catch {
            bindError = error.localizedDescription
        }
    }

    /// Commits the editor's pending sessions into the store, then cancels the background work
    /// (window closed, or before a rebind after revert/reload/move).
    func close() {
        store?.flushPendingEdits()
        work?.cancel()
        work = nil
    }
}
