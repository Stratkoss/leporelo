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
    /// The originals download of the same store (Task 23), bound and cancelled with `work`.
    private(set) var originals: OriginalsWork?
    private(set) var bindError: String?
    /// A "Načíst nové fotky ze zdroje" is running.
    private(set) var isRefreshing = false

    @ObservationIgnored private let placeResolver: @Sendable () -> any PlaceResolver
    @ObservationIgnored private let options: BackgroundWork.Options
    @ObservationIgnored private let originalsOptions: OriginalsWork.Options
    @ObservationIgnored private var sourceProvider: PhotoSourceProvider = { _ in nil }

    init(placeResolver: @escaping @Sendable () -> any PlaceResolver = { GeocoderPlaceResolver() },
         options: BackgroundWork.Options = .init(), originalsOptions: OriginalsWork.Options = .init()) {
        self.placeResolver = placeResolver
        self.options = options
        self.originalsOptions = originalsOptions
    }

    /// Binds to `document`'s store for `fileURL` and starts that store's background work. Also
    /// called again after a move (same store, new package URL: the work restarts on the new URL).
    ///
    /// The previous originals download keeps its results (writes what it downloaded, also late)
    /// only when the binding keeps the SAME store (a move); for a new store (revert, reload) the old
    /// store is a dead end and gets nothing, and the new work adopts the stored files instead.
    func bind(document: AlbumDocument, fileURL: URL?, sourceProvider: @escaping PhotoSourceProvider) {
        let previous = store
        previous?.flushPendingEdits()
        let oldWork = work, oldOriginals = originals
        work = nil
        originals = nil
        store = nil
        self.sourceProvider = sourceProvider
        var bound: AlbumStore?
        if let fileURL {
            do {
                bound = try document.bind(to: fileURL)
                bindError = nil
            } catch {
                bindError = error.localizedDescription
            }
        }
        oldWork?.cancel()
        oldOriginals?.cancel(keepingResults: bound != nil && bound === previous)
        guard let bound else { return }
        store = bound
        startWork(for: bound, options: options)
    }

    private func startWork(for store: AlbumStore, options: BackgroundWork.Options) {
        let work = BackgroundWork(store: store, sourceProvider: sourceProvider,
                                  placeResolver: placeResolver, options: options)
        self.work = work
        work.start()
        let originals = OriginalsWork(store: store, sourceProvider: sourceProvider, options: originalsOptions)
        self.originals = originals
        originals.start()
    }

    /// Restarts the background work of the bound store (same store, nothing rebound), e.g. after
    /// Photos access was granted while the window was open. Analysis and downloads resume where
    /// they stopped.
    func restartWork(recommends: Bool = true) {
        guard let store else { return }
        work?.cancel()
        originals?.cancel(keepingResults: true)
        var options = self.options
        options.recommends = options.recommends && recommends
        startWork(for: store, options: options)
    }

    /// Whether "Načíst nové fotky ze zdroje" can run: a bound album with a source query, a source,
    /// no refresh running.
    var canRefresh: Bool {
        guard !isRefreshing, let store, store.album.source != nil else { return false }
        return sourceProvider(store.album) != nil
    }

    enum RefreshOutcome: Equatable {
        case success(RefreshReport)
        case failure(RefreshText.Alert)
        /// The window was rebound (revert, reload) while the source was read: nothing was applied
        /// and there is nothing to report.
        case discarded
    }

    /// "Načíst nové fotky ze zdroje": `SourceRefresh.run` on the CURRENT store, then the
    /// background work restarts so the new photos get analysed and their places resolved (without
    /// automatic recommendations). A rebind meanwhile (the store it started on is a dead end) applies
    /// nothing and reports nothing: `.discarded`.
    func refreshFromSource() async -> RefreshOutcome {
        guard !isRefreshing, let store, store.album.source != nil, let source = sourceProvider(store.album) else {
            return .failure(RefreshText.failure(PhotoSourceError.notAuthorized))
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let report = try await SourceRefresh.run(store: store, source: source,
                                                           shouldApply: { [weak self] in self?.store === store })
            else { return .discarded }
            if report.added > 0, self.store === store { restartWork(recommends: false) }
            return .success(report)
        } catch {
            return self.store === store ? .failure(RefreshText.failure(error)) : .discarded
        }
    }

    /// Commits the editor's pending sessions into the store, then cancels the background work
    /// (window closed, or before a rebind after revert/reload/move).
    /// The store stays alive with its document, so the originals download writes what it has
    /// downloaded (`keepingResults`).
    func close() {
        store?.flushPendingEdits()
        work?.cancel()
        work = nil
        originals?.cancel(keepingResults: true)
        originals = nil
    }
}
