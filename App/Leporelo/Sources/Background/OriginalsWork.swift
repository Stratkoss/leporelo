import Foundation
import LeporeloCore
import Observation
import os
import SwiftUI

/// Downloads the ORIGINALS the album needs into its package (spec section 5: once a photo leaves
/// Photos the package copy is the only one; section 8: export never depends on iCloud).
///
/// Ownership as `BackgroundWork` (Task 17 contract): `AlbumSession` creates one per binding and
/// cancels it on a BindKey change or when the window closes; the work only writes to its own
/// store, through the no-undo API, and never after `cancel()`.
///
/// - What is needed (`OriginalsWork.wanted`): every non-video photo that is selected OR placed in a
///   frame of a spread or the cover (a photo can be placed but deselected; the export needs the
///   original of every placed photo, controller ruling 2) and whose original is not stored.
/// - Trigger: the work observes `store.revision`; on every change it enqueues the wanted photos
///   whose state is `.missing` (or `.downloading` left over from a cancelled work) and that are not
///   in flight. `OriginalsDownloader` (concurrency 3) dedups.
/// - Bounded automatic retries: a photo is tried automatically at most `Options.autoAttempts`
///   times per work (first attempt + one retry for transient errors, which end as `.missing`).
///   `.unavailable` (gone from Photos, or iCloud failed three times in a row inside the downloader)
///   is never retried automatically. `retryFailed()` ("Stáhnout znovu") re-enqueues every wanted
///   photo that is `.unavailable` or `.missing` and resets the automatic budget.
/// - Batching: state changes are collected and written as ONE no-undo store mutation
///   (`AlbumStore.setOriginalStates`) every `batchSize` changes or `flushInterval`, and when a run
///   ends. States of photos no longer in the album are ignored by the store.
/// - Source: `sourceProvider` like `BackgroundWork`; without a source (no query, no Photos access)
///   nothing is downloaded and `sourceUnavailable` is set while something is wanted.
@MainActor
@Observable
final class OriginalsWork {
    struct Options: Sendable {
        var batchSize = 50
        var flushInterval: Duration = .milliseconds(500)
        var concurrency = 3
        var retryDelay: Duration = .seconds(2)
        /// Automatic attempts per photo and work (1 + one retry).
        var autoAttempts = 2
    }

    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    /// The current wave of downloads (nil when nothing runs).
    private(set) var progress: Progress?
    /// Something is wanted but there is no source to read it from.
    private(set) var sourceUnavailable = false
    /// Wanted photos whose original could not be downloaded (`.unavailable`, or `.missing` after
    /// the automatic attempts ran out): what "Stáhnout znovu" would retry.
    private(set) var failedCount = 0

    @ObservationIgnored private weak var store: AlbumStore?
    @ObservationIgnored private let sourceProvider: PhotoSourceProvider
    @ObservationIgnored private let options: Options
    @ObservationIgnored private var downloader: OriginalsDownloader?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var enqueueTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [PhotoID: OriginalState] = [:]
    @ObservationIgnored private var inFlight: Set<PhotoID> = []
    @ObservationIgnored private var attempts: [PhotoID: Int] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var isCancelled = false
    /// Store mutations written by this work (tests).
    @ObservationIgnored private(set) var flushCount = 0

    init(store: AlbumStore, sourceProvider: @escaping PhotoSourceProvider, options: Options = Options()) {
        self.store = store
        self.sourceProvider = sourceProvider
        self.options = options
    }

    /// Starts observing the store (once).
    func start() {
        guard !started, !isCancelled, let store else { return }
        started = true
        if store.album.source != nil, let source = sourceProvider(store.album) {
            downloader = OriginalsDownloader(source: source, package: store.package,
                                             concurrency: options.concurrency, retryDelay: options.retryDelay)
        }
        observe()
        storeChanged()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pending.removeAll()
        runTask?.cancel()
        flushTask?.cancel()
        enqueueTasks.values.forEach { $0.cancel() }
        progress = nil
    }

    /// "Stáhnout znovu": every wanted photo that failed gets another chance (and a fresh automatic
    /// budget).
    func retryFailed() {
        guard !isCancelled, let store else { return }
        let ids = Self.wanted(in: store.album).filter { id in
            guard !inFlight.contains(id), let state = store.album.photos[id]?.originalState else { return false }
            return state == .unavailable || state == .missing
        }
        for id in ids { attempts[id] = 0 }
        enqueue(ids.sorted())
    }

    /// Returns when nothing is queued, running or waiting to be written (pending states are
    /// flushed).
    func waitUntilIdle() async {
        while !isCancelled {
            if let task = enqueueTasks.values.first {
                await task.value
            } else if let runTask {
                await runTask.value
            } else {
                break
            }
        }
        flush()
    }

    // MARK: Pure logic

    /// Non-video photos that are selected or placed (spreads, cover) and whose original is not
    /// stored.
    nonisolated static func wanted(in album: Album) -> Set<PhotoID> {
        let placed = album.placedPhotoIDs
        var result = Set<PhotoID>()
        for (id, photo) in album.photos where photo.kind != .video && (photo.isSelected || placed.contains(id)) {
            if case .stored = photo.originalState { continue }
            result.insert(id)
        }
        return result
    }

    /// What to enqueue automatically now: wanted photos that are `.missing` (or `.downloading`
    /// without being in flight here), not in flight, and still within their automatic budget.
    nonisolated static func toEnqueue(in album: Album, inFlight: Set<PhotoID>, attempts: [PhotoID: Int],
                          autoAttempts: Int) -> [PhotoID] {
        wanted(in: album).filter { id in
            guard !inFlight.contains(id), attempts[id, default: 0] < autoAttempts,
                  let state = album.photos[id]?.originalState else { return false }
            return state == .missing || state == .downloading
        }.sorted()
    }

    // MARK: Observation

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                self.storeChanged()
                self.observe()
            }
        }
    }

    private func storeChanged() {
        guard !isCancelled, let store else { return }
        let album = store.album
        let wanted = Self.wanted(in: album)
        failedCount = wanted.filter { id in
            guard !inFlight.contains(id), let state = album.photos[id]?.originalState else { return false }
            return state == .unavailable || (state == .missing && attempts[id, default: 0] >= options.autoAttempts)
        }.count
        guard downloader != nil else {
            sourceUnavailable = !wanted.isEmpty
            return
        }
        let ids = Self.toEnqueue(in: album, inFlight: inFlight, attempts: attempts, autoAttempts: options.autoAttempts)
        if !ids.isEmpty { enqueue(ids) }
    }

    private func enqueue(_ ids: [PhotoID]) {
        guard let downloader, !ids.isEmpty else { return }
        for id in ids {
            inFlight.insert(id)
            attempts[id, default: 0] += 1
        }
        progress = Progress(done: progress?.done ?? 0, total: (progress?.total ?? 0) + ids.count)
        let token = UUID()
        enqueueTasks[token] = Task {
            await downloader.enqueue(ids)
            self.enqueueTasks[token] = nil
            self.ensureRunning()
        }
    }

    private func ensureRunning() {
        guard !isCancelled, runTask == nil, let downloader else { return }
        runTask = Task {
            await downloader.run(
                album: { await self.currentAlbum() },
                onStateChange: { id, state in await self.received(state, for: id) })
            self.runTask = nil
            guard !self.isCancelled else { return }
            self.flush()
            if await downloader.queuedCount > 0 {
                self.ensureRunning()
            } else if self.runTask == nil, self.enqueueTasks.isEmpty {
                // Idle. Ids the downloader skipped without a state (stored meanwhile, removed from
                // the album) are no longer in flight; the wave is over.
                self.inFlight.removeAll()
                self.progress = nil
                self.storeChanged()
            }
        }
    }

    private func currentAlbum() -> Album {
        store?.album ?? Album(formatVersion: Album.currentFormatVersion, id: "", title: "", supplierProfileID: "",
                              formatID: "", world: "", cover: nil, spreads: [], photos: [:], source: nil,
                              createdAt: .distantPast)
    }

    private func received(_ state: OriginalState, for id: PhotoID) {
        guard !isCancelled else { return }
        pending[id] = state
        if state != .downloading {
            inFlight.remove(id)
            if let p = progress { progress = Progress(done: min(p.done + 1, p.total), total: p.total) }
        }
        if pending.count >= options.batchSize {
            flush()
        } else if flushTask == nil {
            let interval = options.flushInterval
            flushTask = Task {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.flushTask = nil
                self.flush()
            }
        }
    }

    /// Writes the collected states as one no-undo mutation.
    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !isCancelled, !pending.isEmpty, let store else { return }
        let batch = pending
        pending.removeAll()
        if store.setOriginalStates(batch) { flushCount += 1 }
    }
}

/// "Stáhnout znovu" (File menu, banner): retries the originals that could not be downloaded.
struct RetryDownloadsAction {
    let run: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var albumRetryDownloads: RetryDownloadsAction? = nil
}
