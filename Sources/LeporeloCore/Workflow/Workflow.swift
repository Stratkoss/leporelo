import Foundation

/// The non-UI steps from a photo source to a drafted album, shared by `leporelo-cli` and the app.
///
/// Each step is separate so a caller can show progress and save between them:
/// `createPackage` -> `buildAlbum` (fetch, group, first save) -> `analyze` -> `recommendAndDraft`
/// -> `downloadSelectedOriginals` -> `Preflight` / `PDFExporter`. Only `buildAlbum` saves; the
/// other steps return the updated album and leave saving to the caller.
public enum Workflow {
    /// The only album world in v1.
    public static let world = "journal-gallery"

    /// Creates `url` as a new `.leporelo` package holding an empty album (no photos yet), ready for
    /// `buildAlbum`. Throws `ProjectError.alreadyExists` when `url` exists.
    public static func createPackage(at url: URL, title: String, profileID: String,
                                     formatID: String) throws -> ProjectPackage {
        let empty = Album(formatVersion: Album.currentFormatVersion, id: UUID().uuidString, title: title,
                          supplierProfileID: profileID, formatID: formatID, world: world, cover: nil,
                          spreads: [], photos: [:], source: nil, createdAt: now())
        return try ProjectPackage.create(at: url, album: empty)
    }

    /// Fetches the photos matching `query`, builds a new album from them (no selection, no spreads),
    /// assigns days and places (`GroupingService.assignDays`) and saves it to `package`.
    /// Analysis, recommendation and drafting are separate steps.
    public static func buildAlbum(from source: PhotoSource, query: SourceQuery, title: String,
                                  profileID: String, formatID: String, package: ProjectPackage,
                                  resolver: PlaceResolver) async throws -> Album {
        let sourcePhotos = try await source.photos(matching: query)
        var photos: [PhotoID: Photo] = [:]
        for sourcePhoto in sourcePhotos {
            let photo = Photo(source: sourcePhoto)
            photos[photo.id] = photo
        }
        var album = Album(formatVersion: Album.currentFormatVersion, id: UUID().uuidString, title: title,
                          supplierProfileID: profileID, formatID: formatID, world: world, cover: nil,
                          spreads: [], photos: photos, source: query, createdAt: now())
        await GroupingService.assignDays(to: &album, resolver: resolver)
        try package.save(album)
        return album
    }

    /// Runs `AnalysisPipeline` over every photo without analysis and returns the album with the
    /// results applied. Photos whose analysis failed keep `analysis == nil`.
    public static func analyze(album: Album, source: PhotoSource, package: ProjectPackage,
                               analyzer: ImageAnalyzer = ImageAnalyzer(),
                               onProgress: @Sendable (PipelineProgress) async -> Void = { _ in }) async -> Album {
        let results = ResultBox<PhotoAnalysis>()
        let pipeline = AnalysisPipeline(source: source, package: package, analyzer: analyzer)
        await pipeline.run(album: album,
                           onPhotoAnalyzed: { id, analysis in await results.set(analysis, for: id) },
                           onProgress: onProgress)
        var updated = album
        for (id, analysis) in await results.values {
            updated.photos[id]?.analysis = analysis
        }
        return updated
    }

    /// Recommends photos per day and drafts the album (pure, deterministic):
    /// days from `DayGrouper.group` over the photos that have a `dayKey` (photos without one were
    /// never grouped and are left out, unselected), series from `SeriesDetector` (feature-print
    /// distance) applied to the photos' `seriesID`, `Recommender.recommend` per day sets
    /// `isSelected` (every other photo is unselected), then `AlbumDrafter.draft`.
    ///
    /// No `places` / `timeZones` maps are passed: `DayGrouper.group` falls back to each photo's
    /// stored `placeName` (set by `GroupingService.assignDays`), and a stored `dayKey` wins over the
    /// zone computation.
    public static func recommendAndDraft(album: Album, profile: SupplierProfile, format: BookFormat,
                                         options: DraftOptions = .init()) -> Album {
        var result = album
        // TODO(task19): keep the selection of photos the user decided (`selectionDecidedByUser`);
        // until then the recommendation decides for all photos.
        for id in album.photos.keys { result.photos[id]?.isSelected = false }
        let dated = album.photos.values.filter { $0.dayKey != nil }
        var days = DayGrouper.group(Array(dated), timeZones: [:], places: [:])
        var recommended = Set<PhotoID>()
        for i in days.indices {
            let series = SeriesDetector.detect(days[i].photos, distance: FeaturePrintDistance.distance)
            days[i].photos = SeriesDetector.apply(series, to: days[i].photos)
            recommended.formUnion(Recommender.recommend(day: days[i], series: series))
        }
        for day in days {
            for photo in day.photos {
                result.photos[photo.id]?.seriesID = photo.seriesID
                result.photos[photo.id]?.isSelected = recommended.contains(photo.id)
            }
        }
        let draftDays = days.map { day in
            DayGroup(dayKey: day.dayKey, photos: day.photos.map { result.photos[$0.id] ?? $0 },
                     placeNames: day.placeNames, timeZoneSeconds: day.timeZoneSeconds)
        }
        return AlbumDrafter.draft(album: result, days: draftDays, profile: profile, format: format,
                                  options: options)
    }

    /// Copies the originals of the SELECTED photos into `package` (`OriginalsDownloader`) and
    /// returns the album with their final `originalState`. Unselected photos are not touched.
    public static func downloadSelectedOriginals(
        album: Album, source: PhotoSource, package: ProjectPackage,
        onProgress: @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }) async -> Album {
        let ids = album.selectedPhotos.filter { photo in
            if case .stored = photo.originalState { return false }
            return true
        }.map(\.id)
        let total = ids.count
        await onProgress(0, total)
        guard total > 0 else { return album }

        let states = ResultBox<OriginalState>()
        let downloader = OriginalsDownloader(source: source, package: package)
        await downloader.enqueue(ids)
        let snapshot = album
        await downloader.run(album: { snapshot }, onStateChange: { id, state in
            let finished = await states.set(state, for: id, final: state != .downloading)
            if state != .downloading { await onProgress(finished, total) }
        })
        var updated = album
        for (id, state) in await states.values {
            updated.photos[id]?.originalState = state
        }
        return updated
    }

    /// The current time on the millisecond grid `AlbumCoding` stores. Anything that creates an
    /// `Album` (or stamps a date on one) should use it, so the album in memory equals the one read
    /// back from the package.
    public static func now() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// The format a new album uses by default: the first whose id contains "landscape", else the
    /// first one.
    public static func defaultFormat(of profile: SupplierProfile) -> BookFormat? {
        profile.formats.first { $0.id.contains("landscape") } ?? profile.formats.first
    }
}

/// Collects per-photo results from `@Sendable` callbacks.
private actor ResultBox<Value: Sendable> {
    private(set) var values: [PhotoID: Value] = [:]

    private var finished = 0

    /// Returns how many values were reported as `final` so far.
    @discardableResult
    func set(_ value: Value, for id: PhotoID, final: Bool = true) -> Int {
        values[id] = value
        if final { finished += 1 }
        return finished
    }
}
