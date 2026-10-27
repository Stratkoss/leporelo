import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private let testQuery = SourceQuery.dateRange(start: Date(timeIntervalSince1970: 1_782_000_000),
                                              end: Date(timeIntervalSince1970: 1_783_000_000))

/// `count` photos 10 minutes apart on 2026-07-01 (+02:00).
private func dayOfPhotos(_ count: Int, location: GeoPoint? = nil) -> [SourcePhoto] {
    (0..<count).map { SourcePhoto.fake(String(format: "p%02d", $0), minutes: 8 * 60 + $0 * 10, location: location) }
}

/// A saved package with an album built from `photos` (what `NewAlbumModel.createAlbum` leaves),
/// and a store on it.
@MainActor
private func makeStore(_ photos: [SourcePhoto], source query: SourceQuery? = testQuery) async throws -> AlbumStore {
    let url = makeTempDir().appendingPathComponent("Pozadí.leporelo")
    let package = try Workflow.createPackage(at: url, title: "Pozadí", profileID: "canva-photobook",
                                             formatID: "landscape-8x6in")
    var album = try await Workflow.buildAlbum(
        from: FakePhotoSource(photos: photos), query: query ?? testQuery, title: "Pozadí",
        profileID: "canva-photobook", formatID: "landscape-8x6in", package: package,
        resolver: InMemoryPlaceResolver([]))
    album.source = query
    return AlbumStore(album: album, package: package)
}

private let noPlaces: @Sendable () -> any PlaceResolver = { InMemoryPlaceResolver([]) }

@MainActor
private func makeWork(_ store: AlbumStore, source: (any PhotoSource)?,
                      places: @escaping @Sendable () -> any PlaceResolver = noPlaces,
                      batchSize: Int = 50, flushInterval: Duration = .seconds(3600)) -> BackgroundWork {
    BackgroundWork(store: store, sourceProvider: { _ in source }, placeResolver: places,
                   options: .init(batchSize: batchSize, flushInterval: flushInterval))
}

/// Polls `condition` on the main actor (the background work hops there for every result).
@MainActor
private func waitUntil(_ what: String, timeout: Duration = .seconds(10),
                       _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func makeUndoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
}

@MainActor
struct BackgroundWorkTests {
    @Test func bannerTextUsesCzechGrouping() {
        #expect(BannerText.analyzing(done: 120, total: 3000) == "Analyzuji fotky 120 / 3\u{00A0}000")
        #expect(BannerText.analyzing(done: 0, total: 12) == "Analyzuji fotky 0 / 12")
        #expect(BannerText.resolvingPlaces == "Zjišťuji místa…")
        #expect(BannerText.sourceUnavailable == "Fotky nelze načíst: chybí přístup k Fotkám")
        #expect(BannerText.text(for: .idle) == nil)
        #expect(BannerText.text(for: .analyzing(done: 1, total: 2)) == "Analyzuji fotky 1 / 2")
    }

    /// Results are collected and written in batches (one no-undo mutation each), not per photo.
    @Test func analysisIsFlushedInBatches() async throws {
        let store = try await makeStore(dayOfPhotos(12))
        var marks = 0
        store.markChanged = { marks += 1 }
        let work = makeWork(store, source: FakePhotoSource(), batchSize: 5)

        work.start()
        await work.waitUntilFinished()

        #expect(store.album.photos.values.allSatisfy { $0.analysis != nil })
        #expect(work.flushCount == 3)  // 5 + 5 + 2
        #expect(marks == work.flushCount + 1)  // + the one recommendation mutation
        #expect(work.activity == .idle)
        for id in store.album.photos.keys { #expect(store.package.thumbnail(for: id) != nil) }
    }

    /// With a short interval a slow trickle of results is still flushed regularly.
    @Test func analysisIsFlushedAfterTheInterval() async throws {
        let store = try await makeStore(dayOfPhotos(3))
        let work = makeWork(store, source: FakePhotoSource(), batchSize: 1000, flushInterval: .zero)
        work.start()
        await work.waitUntilFinished()
        #expect(work.flushCount == 3)
        #expect(store.album.photos.values.allSatisfy { $0.analysis != nil })
    }

    @Test func progressIsReportedForTheBanner() async throws {
        let store = try await makeStore(dayOfPhotos(12))
        let source = FakePhotoSource()
        source.holdThumbnails()
        let work = makeWork(store, source: source)
        work.start()
        try await waitUntil("held thumbnails") { source.heldCalls > 0 }
        #expect(work.activity == .analyzing(done: 0, total: 12))
        #expect(work.bannerText == "Analyzuji fotky 0 / 12")
        source.releaseAll()
        await work.waitUntilFinished()
        #expect(work.bannerText == nil)
    }

    /// Recommendations run once, after the first analysis that analyzed photos; they never
    /// reselect a photo the user deselected, neither on a later automatic pass nor a manual rerun.
    @Test func recommendationsApplyOnlyOnce() async throws {
        let store = try await makeStore(dayOfPhotos(12))
        let first = makeWork(store, source: FakePhotoSource())
        first.start()
        await first.waitUntilFinished()
        #expect(first.recommendationsApplied)
        let recommended = Set(store.album.photos.values.filter(\.isSelected).map(\.id))
        #expect(recommended.count == Recommender.targetCount(photoCount: 12))
        #expect(store.album.photos.values.allSatisfy { !$0.selectionDecidedByUser })

        let dropped = try #require(recommended.sorted().first)
        let undo = makeUndoManager()
        undo.beginUndoGrouping()
        try store.apply(.setSelected(dropped, false), undoManager: undo)
        undo.endUndoGrouping()

        // Reopening: everything is analyzed, so no analysis and no automatic recommendations.
        let source = FakePhotoSource()
        let again = makeWork(store, source: source)
        again.start()
        await again.waitUntilFinished()
        #expect(!again.recommendationsApplied)
        #expect(source.thumbnailCalls == 0)
        #expect(store.album.photos[dropped]?.isSelected == false)

        // A manual rerun keeps the user's decision; the other photos keep the recommendation.
        store.applyRecommendations()
        #expect(store.album.photos[dropped]?.isSelected == false)
        #expect(Set(store.album.photos.values.filter(\.isSelected).map(\.id)) == recommended.subtracting([dropped]))
    }

    /// A pass in which no photo could be analyzed (e.g. every thumbnail unavailable) does not
    /// count as "the first analysis": no recommendations, nothing written.
    @Test func noRecommendationsWhenNothingWasAnalyzed() async throws {
        let store = try await makeStore(dayOfPhotos(3))
        let before = store.album
        let source = FakePhotoSource()
        source.failThumbnails(with: .cloudUnavailable("x"))
        let work = makeWork(store, source: source)
        work.start()
        await work.waitUntilFinished()
        #expect(source.thumbnailCalls == 3)
        #expect(!work.recommendationsApplied)
        #expect(work.flushCount == 0)
        #expect(store.album == before)
    }

    /// Re-binding (revert, reload) cancels the old store's work; only the new store gets results.
    @Test func reboundSessionCancelsTheOldWork() async throws {
        let store = try await makeStore(dayOfPhotos(6))
        let url = store.package.url
        let source = FakePhotoSource()
        source.holdThumbnails()
        let session = AlbumSession(placeResolver: noPlaces, options: .init(batchSize: 1, flushInterval: .zero))

        let first = try AlbumDocument(file: FileWrapper(url: url, options: []))
        session.bind(document: first, fileURL: url, sourceProvider: { _ in source })
        let firstStore = try #require(session.store)
        let firstWork = try #require(session.work)
        try await waitUntil("held thumbnails") { source.heldCalls > 0 }

        let reloaded = try AlbumDocument(file: FileWrapper(url: url, options: []))
        session.bind(document: reloaded, fileURL: url, sourceProvider: { _ in source })
        #expect(firstWork.isCancelled)
        let secondStore = try #require(session.store)
        let secondWork = try #require(session.work)
        #expect(secondStore !== firstStore && secondWork !== firstWork)

        source.releaseAll()
        await firstWork.waitUntilFinished()
        await secondWork.waitUntilFinished()
        #expect(firstStore.album.photos.values.allSatisfy { $0.analysis == nil })
        #expect(secondStore.album.photos.values.allSatisfy { $0.analysis != nil })
        #expect(!firstWork.recommendationsApplied)

        session.close()
        #expect(secondWork.isCancelled)
        #expect(session.work == nil)
    }

    /// Places are resolved off the main actor on a snapshot and applied to the store's CURRENT
    /// album: an edit the user makes while geocoding runs survives.
    @Test func placeRefinementAppliesToTheLiveAlbum() async throws {
        let rome = GeoPoint(latitude: 40.63, longitude: 14.48)
        let store = try await makeStore(dayOfPhotos(4, location: rome))
        let resolver = HeldPlaceResolver(place: Place(name: "Positano", timeZoneIdentifier: "Europe/Rome"), held: true)
        let work = makeWork(store, source: nil, places: { resolver })
        work.start()
        try await waitUntil("geocoding") { await resolver.calls > 0 }
        #expect(work.activity == .resolvingPlaces)
        #expect(work.bannerText == "Zjišťuji místa…")

        let moved = try #require(store.album.photos.keys.sorted().first)
        let undo = makeUndoManager()
        undo.beginUndoGrouping()
        try store.apply(.setPhotoDay(moved, DayKey(year: 2026, month: 7, day: 5)), undoManager: undo)
        try store.apply(.setTitle("Amalfi"), undoManager: undo)
        undo.endUndoGrouping()

        await resolver.release()
        await work.waitUntilFinished()
        #expect(store.album.photos.values.allSatisfy { $0.placeName == "Positano" })
        #expect(store.album.photos[moved]?.dayKey == DayKey(year: 2026, month: 7, day: 5))
        #expect(store.album.title == "Amalfi")
    }

    @Test func missingSourceShowsAMessageAndChangesNothing() async throws {
        for (query, source) in [(testQuery, nil), (nil, FakePhotoSource() as (any PhotoSource)?)] {
            let store = try await makeStore(dayOfPhotos(2), source: query)
            let before = store.album
            var marks = 0
            store.markChanged = { marks += 1 }
            let work = makeWork(store, source: source)
            work.start()
            await work.waitUntilFinished()
            #expect(work.activity == .sourceUnavailable)
            #expect(work.bannerText == "Fotky nelze načíst: chybí přístup k Fotkám")
            #expect(store.album == before)
            #expect(marks == 0)
        }
    }

    @Test func analysisResumesWhereItStopped() async throws {
        let store = try await makeStore(dayOfPhotos(4))
        var album = store.album
        let done = try #require(album.photos.keys.sorted().first)
        album.photos[done]?.analysis = PhotoAnalysis(aesthetic: 0.5, sharpness: 900, isUtility: false,
                                                     faceRects: [], closedEyes: false, featurePrint: nil)
        store.replaceWithoutUndo(album: album)
        let source = FakePhotoSource()
        let work = makeWork(store, source: source)
        work.start()
        await work.waitUntilFinished()
        #expect(source.thumbnailCalls == 3)
        #expect(store.album.photos.values.allSatisfy { $0.analysis != nil })
    }
}

@MainActor
struct AlbumStoreBackgroundTests {
    @Test func analysesAreAppliedInOneMutation() async throws {
        let store = try await makeStore(dayOfPhotos(3))
        var marks = 0
        store.markChanged = { marks += 1 }
        let analysis = PhotoAnalysis(aesthetic: 0.7, sharpness: 800, isUtility: false, faceRects: [],
                                     closedEyes: false, featurePrint: nil)
        var batch = Dictionary(uniqueKeysWithValues: store.album.photos.keys.map { ($0, analysis) })
        batch["gone"] = analysis  // a photo removed meanwhile is ignored
        store.setAnalyses(batch)
        #expect(marks == 1)
        #expect(store.album.photos.count == 3)
        #expect(store.album.photos.values.allSatisfy { $0.analysis == analysis })
        store.setAnalyses([:])
        #expect(marks == 1)
    }
}
