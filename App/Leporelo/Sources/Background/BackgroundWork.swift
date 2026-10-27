import Foundation
import LeporeloCore
import Observation
import os

/// Gives the background work the photo source of an album, or nil when there is none to read
/// (no source query, no Photos access). Supplied at the app level (`\.photoSourceProvider`).
typealias PhotoSourceProvider = @MainActor (Album) -> (any PhotoSource)?

/// What the banner at the top of the album window shows (one line; `BannerText.line` picks it).
enum BackgroundActivity: Equatable, Sendable {
    case idle
    case analyzing(done: Int, total: Int)
    case downloading(done: Int, total: Int)
    case resolvingPlaces
    case sourceUnavailable
    /// Originals that could not be downloaded ("Stáhnout znovu" retries them).
    case failedOriginals(Int)
    /// Explicit autosaves failed several times in a row.
    case autosaveFailed
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
/// - Thumbnail self-heal: an analysed photo whose thumbnail file is missing is processed again.
///   Since Task 23 the pipeline writes through the store's coordinated package
///   (`DocumentPackageWrites`), so a save can no longer drop a thumbnail; the repair still covers
///   packages damaged before that (or by anything outside the app): such a photo already has
///   `analysis`, so nothing else would ever regenerate its thumbnail. The pipeline gets a COPY of the album in which those photos have no analysis
///   (the copy is only its input, never written back); their new results go through the normal
///   batched flush. A repair is not an analysis: it does not count toward the recommendations
///   trigger, but it does count in the banner's total. After the pass, ONE extra repair pass runs
///   if a thumbnail went missing during it (bounded: at most one per work, no loops).
/// - Recommendations: after an analysis pass that analyzed at least one photo in this session and
///   was not cancelled, `AlbumStore.applyRecommendations()` once (it only changes photos the user
///   has not decided), and only while the album has no spreads yet (late photos of a drafted album
///   must not change the selection behind the layout). Reopening an analyzed album therefore never
///   reruns them.
/// - Autosave: while a pass runs, `AlbumStore.backgroundAnalysisRunning` is set, so autosave uses
///   the longer busy delay.
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
        /// Run the automatic recommendations after a pass that analysed photos. Off for the work
        /// restarted after a source refresh: the new photos stay unselected (the user picks).
        var recommends = true
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
    /// Photos analyzed by this work that had no analysis before (failures and thumbnail repairs
    /// excluded): what triggers the recommendations.
    @ObservationIgnored private var analyzedCount = 0
    /// The photos of the current pass that count toward `analyzedCount`.
    @ObservationIgnored private var countable: Set<PhotoID> = []
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
        if !Self.analysisWork(album, package: store.package).isEmpty {
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
        store?.backgroundAnalysisRunning = false
    }

    /// Returns when every started task has ended (finished or cancelled).
    func waitUntilFinished() async {
        for task in tasks { await task.value }
    }

    /// What an analysis pass has to process.
    struct AnalysisWork: Equatable {
        /// Non-video photos without analysis.
        var unanalyzed: Set<PhotoID> = []
        /// Analysed photos whose thumbnail file is gone (see "Thumbnail self-heal").
        var missingThumbnails: Set<PhotoID> = []

        var isEmpty: Bool { unanalyzed.isEmpty && missingThumbnails.isEmpty }
    }

    /// A file-existence check per analysed photo (no decoding).
    static func analysisWork(_ album: Album, package: ProjectPackage) -> AnalysisWork {
        var work = AnalysisWork()
        let files = FileManager.default
        for (id, photo) in album.photos where photo.kind != .video {
            if photo.analysis == nil {
                work.unanalyzed.insert(id)
            } else if !files.fileExists(atPath: thumbnailURL(for: id, in: package).path) {
                work.missingThumbnails.insert(id)
            }
        }
        return work
    }

    /// Where `ProjectPackage.storeThumbnail` puts a photo's thumbnail (`thumbs/<id>.jpg`; Core keeps
    /// the URL private). Used only for a cheap existence check; a test pins it to Core's layout.
    nonisolated static func thumbnailURL(for id: PhotoID, in package: ProjectPackage) -> URL {
        package.url.appendingPathComponent("thumbs", isDirectory: true).appendingPathComponent("\(id).jpg")
    }

    static func needsPlaces(_ album: Album) -> Bool {
        album.photos.values.contains { $0.location != nil && $0.placeName == nil }
    }

    // MARK: Analysis

    private func analyze(with source: any PhotoSource, package: ProjectPackage) async {
        guard let album = store?.album else { return }
        // Autosave less often while analysing (each save of a large package takes a while).
        store?.backgroundAnalysisRunning = true
        defer { if !isCancelled { store?.backgroundAnalysisRunning = false } }
        let work = Self.analysisWork(album, package: package)
        await runPass(over: album, work: work, source: source, package: package)
        guard !isCancelled, !Task.isCancelled, let store else { return }
        // Only before the first draft: once spreads exist, the recommendations would flip
        // undecided PLACED photos to deselected while they stay in their frames.
        if analyzedCount > 0 && options.recommends && store.album.spreads.isEmpty {
            store.applyRecommendations()
            recommendationsApplied = true
        }
        // Every no-undo store change (these flushes, the recommendations, the places) also asks
        // for an explicit autosave (`AlbumStore.requestAutosave`, Task 17 ruling (b)).

        // One bounded repair pass for thumbnails lost while the first pass ran (e.g. dropped by
        // an autosave swap). Photos whose analysis failed are not retried here (next session).
        let current = store.album
        let lost = Self.analysisWork(current, package: package).missingThumbnails
        guard !lost.isEmpty else { return }
        await runPass(over: current, work: AnalysisWork(missingThumbnails: lost), source: source,
                      package: package, only: lost)
    }

    /// Runs the pipeline over a copy of `album` where the photos to repair have no analysis
    /// (with `only`, the copy holds just those photos), then flushes. Only photos in
    /// `work.unanalyzed` count as analysed in this session.
    private func runPass(over album: Album, work: AnalysisWork, source: any PhotoSource,
                         package: ProjectPackage, only: Set<PhotoID>? = nil) async {
        var input = album
        if let only { input.photos = input.photos.filter { only.contains($0.key) } }
        for id in work.missingThumbnails { input.photos[id]?.analysis = nil }
        countable = work.unanalyzed
        let pipeline = AnalysisPipeline(source: source, package: package, analyzer: ImageAnalyzer(),
                                        concurrency: options.concurrency)
        lastFlush = .now
        // The pipeline stores each thumbnail with `package.storeThumbnail`, coordinated with the
        // document's saves through the store's package (`AlbumDocument.bind`).
        await pipeline.run(
            album: input,
            onPhotoAnalyzed: { id, analysis in await self.received(analysis, for: id) },
            onProgress: { progress in await self.report(progress) })
        flush()
        analysisProgress = nil
    }

    private func received(_ analysis: PhotoAnalysis, for id: PhotoID) {
        guard !isCancelled else { return }
        pending[id] = analysis
        if countable.contains(id) { analyzedCount += 1 }
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
