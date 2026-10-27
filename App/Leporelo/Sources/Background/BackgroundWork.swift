import Foundation
import LeporeloCore
import Observation
import os

/// Gives the background work the photo source of an album, or nil when there is none to read
/// (no source query, no Photos access). Supplied at the app level (`\.photoSourceProvider`).
typealias PhotoSourceProvider = @MainActor (Album) -> (any PhotoSource)?

/// What the banner at the top of the album window shows.
enum BackgroundActivity: Equatable, Sendable {
    case idle
    case analyzing(done: Int, total: Int)
    case resolvingPlaces
    case sourceUnavailable
}

/// The background work of ONE bound `AlbumStore` (Task 17 contract): image analysis, then the
/// first recommendations, and, in parallel, place names and day corrections.
///
/// Ownership: `AlbumSession` creates one per binding and cancels it when the binding changes
/// (revert, reload, move) or the window closes, so results never land in a dead store. The
/// work only ever writes to its own store, through the no-undo API, and only while not cancelled.
///
/// - Analysis: `AnalysisPipeline` over the photos without analysis (it skips analyzed ones, so a
///   crash mid-analysis resumes). Results are collected here and written in batches (every
///   `batchSize` results or `flushInterval`, and at the end) as ONE no-undo mutation each, because
///   every store change publishes a snapshot of the whole album and marks the document edited.
///   Progress goes to the cheap `activity` counter only the banner observes.
/// - Recommendations: after an analysis pass that analyzed at least one photo in this session and
///   was not cancelled, `AlbumStore.applyRecommendations()` once (it only changes photos the user
///   has not decided). Reopening an analyzed album therefore never reruns them.
/// - Places: `GroupingService.resolvePlaces` on a snapshot, off the main actor; then ONE
///   synchronous main-actor `AlbumStore.applyPlaceRefinement` on the store's CURRENT album (so
///   edits made during geocoding survive). The snapshot is never written back.
@MainActor
@Observable
final class BackgroundWork {
    struct Options: Sendable {
        var batchSize = 50
        var flushInterval: Duration = .milliseconds(500)
        var concurrency = 4
    }

    private(set) var analysisProgress: PipelineProgress?
    private(set) var isResolvingPlaces = false
    private(set) var sourceUnavailable = false

    @ObservationIgnored private weak var store: AlbumStore?
    @ObservationIgnored private let sourceProvider: PhotoSourceProvider
    @ObservationIgnored private let placeResolver: @Sendable () -> any PlaceResolver
    @ObservationIgnored private let options: Options
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pending: [PhotoID: PhotoAnalysis] = [:]
    @ObservationIgnored private var lastFlush = ContinuousClock.now
    @ObservationIgnored private var started = false
    /// Photos analyzed by this work (failures excluded).
    @ObservationIgnored private var analyzedCount = 0
    @ObservationIgnored private(set) var isCancelled = false
    /// Number of analysis batches written to the store (tests).
    @ObservationIgnored private(set) var flushCount = 0
    /// Whether this work ran the automatic recommendations.
    @ObservationIgnored private(set) var recommendationsApplied = false

    init(store: AlbumStore, sourceProvider: @escaping PhotoSourceProvider,
         placeResolver: @escaping @Sendable () -> any PlaceResolver = { GeocoderPlaceResolver() },
         options: Options = Options()) {
        self.store = store
        self.sourceProvider = sourceProvider
        self.placeResolver = placeResolver
        self.options = options
    }

    var activity: BackgroundActivity {
        if let progress = analysisProgress, progress.total > 0 {
            return .analyzing(done: progress.done, total: progress.total)
        }
        if isResolvingPlaces { return .resolvingPlaces }
        if sourceUnavailable { return .sourceUnavailable }
        return .idle
    }

    var bannerText: String? { BannerText.text(for: activity) }

    /// Starts what the album needs (once).
    func start() {
        guard !started, !isCancelled, let store else { return }
        started = true
        let album = store.album
        if Self.needsPlaces(album) {
            isResolvingPlaces = true
            tasks.append(Task { await self.refinePlaces() })
        }
        if Self.needsAnalysis(album) {
            if album.source != nil, let source = sourceProvider(album) {
                tasks.append(Task { await self.analyze(with: source, package: store.package) })
            } else {
                sourceUnavailable = true
            }
        }
    }

    /// Stops everything; nothing is written to the store afterwards (pending results are dropped:
    /// their thumbnails are stored, the next run analyzes those photos again).
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pending.removeAll()
        tasks.forEach { $0.cancel() }
        analysisProgress = nil
        isResolvingPlaces = false
    }

    /// Returns when every started task has ended (finished or cancelled).
    func waitUntilFinished() async {
        for task in tasks { await task.value }
    }

    static func needsAnalysis(_ album: Album) -> Bool {
        album.photos.values.contains { $0.analysis == nil && $0.kind != .video }
    }

    static func needsPlaces(_ album: Album) -> Bool {
        album.photos.values.contains { $0.location != nil && $0.placeName == nil }
    }

    // MARK: Analysis

    private func analyze(with source: any PhotoSource, package: ProjectPackage) async {
        guard let album = store?.album else { return }
        let pipeline = AnalysisPipeline(source: source, package: package, analyzer: ImageAnalyzer(),
                                        concurrency: options.concurrency)
        lastFlush = .now
        await pipeline.run(
            album: album,
            onPhotoAnalyzed: { id, analysis in await self.received(analysis, for: id) },
            onProgress: { progress in await self.report(progress) })
        flush()
        analysisProgress = nil
        guard !isCancelled, !Task.isCancelled, analyzedCount > 0, let store else { return }
        store.applyRecommendations()
        recommendationsApplied = true
        // HOOK(Task 23): request an explicit autosave here (Task 17 contract addition (b): after
        // background changes, do not rely on the change count alone). No such API exists yet.
    }

    private func received(_ analysis: PhotoAnalysis, for id: PhotoID) {
        guard !isCancelled else { return }
        pending[id] = analysis
        analyzedCount += 1
        if pending.count >= options.batchSize || ContinuousClock.now - lastFlush >= options.flushInterval {
            flush()
        }
    }

    private func report(_ progress: PipelineProgress) {
        guard !isCancelled else { return }
        analysisProgress = progress
    }

    /// Writes the collected results as one no-undo mutation.
    private func flush() {
        lastFlush = .now
        guard !isCancelled, !pending.isEmpty, let store else { return }
        store.setAnalyses(pending)
        pending.removeAll()
        flushCount += 1
    }

    // MARK: Places

    private func refinePlaces() async {
        defer { if !isCancelled { isResolvingPlaces = false } }
        guard let snapshot = store?.album else { return }
        let (places, completed) = await Self.resolvePlaces(of: snapshot, resolver: placeResolver())
        guard !isCancelled, !Task.isCancelled, let store else { return }
        let result = store.applyPlaceRefinement(places, completed: completed)
        Logger.background.info("Places: \(result.namedPhotos) named, \(result.changedDays) days corrected")
    }

    /// Off the main actor: geocoding can take minutes (1 s between lookups).
    @concurrent
    private nonisolated static func resolvePlaces(of album: Album, resolver: any PlaceResolver) async
        -> (places: [PhotoID: Place], completed: Bool) {
        await GroupingService.resolvePlaces(of: album, resolver: resolver)
    }
}

extension Logger {
    static let background = Logger(subsystem: "com.stratkoss.leporelo", category: "BackgroundWork")
}
