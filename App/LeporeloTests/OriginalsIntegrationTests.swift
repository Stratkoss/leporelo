import AppKit
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private let originalsQuery = SourceQuery.dateRange(start: Date(timeIntervalSince1970: 1_782_000_000),
                                                   end: Date(timeIntervalSince1970: 1_783_000_000))

private func sourcePhotos(_ count: Int) -> [SourcePhoto] {
    (0..<count).map { SourcePhoto.fake(String(format: "o%02d", $0), minutes: 9 * 60 + $0 * 10) }
}

/// A saved package with an album of `count` photos (nothing selected, no originals) and a store.
@MainActor
private func makeOriginalsStore(_ count: Int, name: String = "Originály") async throws -> AlbumStore {
    let url = makeTempDir().appendingPathComponent("\(name).leporelo")
    let package = try Workflow.createPackage(at: url, title: name, profileID: "canva-photobook",
                                             formatID: "landscape-8x6in")
    var album = try await Workflow.buildAlbum(
        from: FakePhotoSource(photos: sourcePhotos(count)), query: originalsQuery, title: name,
        profileID: "canva-photobook", formatID: "landscape-8x6in", package: package,
        resolver: InMemoryPlaceResolver([]))
    album.source = originalsQuery
    try package.save(album)
    return AlbumStore(album: album, package: package)
}

@MainActor
private func makeOriginalsWork(_ store: AlbumStore, source: (any PhotoSource)?, batchSize: Int = 50,
                               flushInterval: Duration = .milliseconds(20)) -> OriginalsWork {
    OriginalsWork(store: store, sourceProvider: { _ in source },
                  options: .init(batchSize: batchSize, flushInterval: flushInterval, retryDelay: .zero))
}

@MainActor
private func waitFor(_ what: String, timeout: Duration = .seconds(10),
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
private func undoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
}

@MainActor
private func select(_ id: PhotoID, in store: AlbumStore) throws {
    let undo = undoManager()
    undo.beginUndoGrouping()
    try store.apply(.setSelected(id, true), undoManager: undo)
    undo.endUndoGrouping()
}

private extension AlbumStore {
    func sortedIDs() -> [PhotoID] { album.photos.values.sorted(by: Photo.chronological).map(\.id) }
}

@MainActor
struct OriginalsWorkTests {
    /// Selecting a photo in the store downloads its original: the source is asked once, the state
    /// ends `.stored` and the file is in the package.
    @Test func selectingPhotoEnqueuesDownload() async throws {
        let store = try await makeOriginalsStore(3)
        let source = FakePhotoSource()
        let work = makeOriginalsWork(store, source: source)
        work.start()
        await work.waitUntilIdle()
        #expect(source.totalOriginalCalls == 0)  // nothing selected yet

        let id = store.sortedIDs()[1]
        let identifier = try #require(store.album.photos[id]?.sourceIdentifier)
        try select(id, in: store)
        try await waitFor("stored original") {
            if case .stored = store.album.photos[id]?.originalState { return true }
            return false
        }
        await work.waitUntilIdle()
        #expect(source.originalCalls(identifier) == 1)
        #expect(source.totalOriginalCalls == 1)
        #expect(store.package.originalURL(for: id, album: store.album) != nil)
        #expect(work.progress == nil)
        work.cancel()
    }

    /// A photo placed in a frame but deselected is downloaded too (the export needs every placed
    /// photo's original); an unselected, unplaced photo is not.
    @Test func placedButDeselectedPhotosAreDownloaded() async throws {
        let store = try await makeOriginalsStore(4)
        let ids = store.sortedIDs()
        var album = store.album
        for id in ids { album.photos[id]?.isSelected = true }
        let (profile, format) = try ProfileCatalog.format(profileID: album.supplierProfileID, formatID: album.formatID)
        album = Workflow.draft(album: album, profile: profile, format: format)
        let placed = album.placedPhotoIDs
        let placedDeselected = try #require(placed.sorted().first)
        for id in ids { album.photos[id]?.isSelected = false }
        let unplaced = Set(ids).subtracting(placed)
        store.replaceWithoutUndo(album: album)
        #expect(!placed.isEmpty)

        let source = FakePhotoSource()
        let work = makeOriginalsWork(store, source: source)
        work.start()
        try await waitFor("placed originals") {
            placed.allSatisfy { id in
                if case .stored = store.album.photos[id]?.originalState { return true }
                return false
            }
        }
        await work.waitUntilIdle()
        #expect(store.album.photos[placedDeselected]?.isSelected == false)
        for id in unplaced { #expect(store.album.photos[id]?.originalState == .missing) }
        #expect(OriginalsWork.wanted(in: store.album).isEmpty)
        work.cancel()
    }

    /// `.unavailable` is a hard problem: not retried automatically (also not on later store
    /// changes), only by "Stáhnout znovu".
    @Test func unavailablePhotosAreRetriedOnlyByTheManualCommand() async throws {
        let store = try await makeOriginalsStore(2)
        let id = store.sortedIDs()[0]
        let identifier = try #require(store.album.photos[id]?.sourceIdentifier)
        let source = FakePhotoSource()
        source.failOriginal(identifier, with: .notFound(identifier))
        let work = makeOriginalsWork(store, source: source)
        work.start()
        try select(id, in: store)
        try await waitFor("unavailable") { store.album.photos[id]?.originalState == .unavailable }
        await work.waitUntilIdle()
        for title in ["A", "B", "C"] {
            try store.applyWithoutUndo(.setTitle(title))
            try await Task.sleep(for: .milliseconds(30))
            await work.waitUntilIdle()
        }
        #expect(source.originalCalls(identifier) == 1)
        #expect(work.failedCount == 1)

        source.failOriginal(identifier, with: nil)
        work.retryFailed()
        try await waitFor("stored after retry") {
            if case .stored = store.album.photos[id]?.originalState { return true }
            return false
        }
        await work.waitUntilIdle()
        #expect(source.originalCalls(identifier) == 2)
        #expect(work.failedCount == 0)
        work.cancel()
    }

    /// A transient failure (`.missing` after the attempt) is retried automatically once per work,
    /// then waits for the manual command, however often the store changes.
    @Test func transientFailuresAreRetriedAutomaticallyOnlyOnce() async throws {
        let store = try await makeOriginalsStore(2)
        let id = store.sortedIDs()[0]
        let identifier = try #require(store.album.photos[id]?.sourceIdentifier)
        let source = FakePhotoSource()
        source.failOriginal(identifier, with: .notAuthorized)
        let work = makeOriginalsWork(store, source: source)
        work.start()
        try select(id, in: store)
        try await waitFor("two attempts") { source.originalCalls(identifier) >= 2 }
        await work.waitUntilIdle()
        for title in ["A", "B", "C", "D"] {
            try store.applyWithoutUndo(.setTitle(title))
            try await Task.sleep(for: .milliseconds(30))
            await work.waitUntilIdle()
        }
        #expect(source.originalCalls(identifier) == 2)
        #expect(store.album.photos[id]?.originalState == .missing)
        #expect(work.failedCount == 1)

        source.failOriginal(identifier, with: nil)
        work.retryFailed()
        try await waitFor("stored after retry") {
            if case .stored = store.album.photos[id]?.originalState { return true }
            return false
        }
        #expect(source.originalCalls(identifier) == 3)
        work.cancel()
    }

    /// State changes are written in batches (one no-undo mutation each), not per photo.
    @Test func stateChangesAreBatched() async throws {
        let store = try await makeOriginalsStore(12)
        var album = store.album
        for id in album.photos.keys { album.photos[id]?.isSelected = true }
        store.replaceWithoutUndo(album: album)
        var writes = 0
        store.markChanged = { writes += 1 }
        let work = makeOriginalsWork(store, source: FakePhotoSource(), batchSize: 5, flushInterval: .seconds(3600))
        work.start()
        await work.waitUntilIdle()
        #expect(store.album.photos.values.allSatisfy {
            if case .stored = $0.originalState { return true }
            return false
        })
        // 24 state changes (downloading + stored per photo) in at most ceil(24 / 5) + 1 writes.
        #expect(writes == work.flushCount)
        #expect(work.flushCount >= 2 && work.flushCount <= 6)
    }

    /// Without a source nothing is downloaded and the banner says why; nothing is written.
    @Test func missingSourceIsReportedAndChangesNothing() async throws {
        let store = try await makeOriginalsStore(2)
        try select(store.sortedIDs()[0], in: store)
        var writes = 0
        store.markChanged = { writes += 1 }
        let work = makeOriginalsWork(store, source: nil)
        work.start()
        await work.waitUntilIdle()
        #expect(work.sourceUnavailable)
        #expect(writes == 0)
        work.cancel()
    }

    /// Re-binding (revert, reload) cancels the old work: nothing lands in the old store, the new
    /// store gets the originals.
    @Test func reboundSessionCancelsTheOldDownloads() async throws {
        let seed = try await makeOriginalsStore(3, name: "Znovu")
        var album = seed.album
        for id in album.photos.keys { album.photos[id]?.isSelected = true }
        try seed.package.save(album)
        let url = seed.package.url
        let source = FakePhotoSource()
        source.holdOriginals()
        source.holdThumbnails()
        let session = AlbumSession(placeResolver: { InMemoryPlaceResolver([]) },
                                   originalsOptions: .init(batchSize: 1, flushInterval: .zero, retryDelay: .zero))

        let first = try AlbumDocument(file: FileWrapper(url: url, options: []))
        session.bind(document: first, fileURL: url, sourceProvider: { _ in source })
        let firstStore = try #require(session.store)
        let firstWork = try #require(session.originals)
        try await waitFor("held originals") { source.heldCalls >= 3 }

        let reloaded = try AlbumDocument(file: FileWrapper(url: url, options: []))
        session.bind(document: reloaded, fileURL: url, sourceProvider: { _ in source })
        #expect(firstWork.isCancelled)
        let secondStore = try #require(session.store)
        let secondWork = try #require(session.originals)
        #expect(secondStore !== firstStore)

        source.releaseAll()
        await secondWork.waitUntilIdle()
        try await waitFor("second store stored") {
            secondStore.album.photos.values.allSatisfy {
                if case .stored = $0.originalState { return true }
                return false
            }
        }
        #expect(firstStore.album.photos.values.allSatisfy {
            if case .stored = $0.originalState { return false }
            return true
        })
        session.close()
        #expect(secondWork.isCancelled)
    }

    /// The store ignores states of photos that are no longer in the album, in one mutation.
    @Test func statesOfRemovedPhotosAreIgnored() async throws {
        let store = try await makeOriginalsStore(2)
        let id = store.sortedIDs()[0]
        var writes = 0
        store.markChanged = { writes += 1 }
        #expect(!store.setOriginalStates(["gone": .stored(relativePath: "originals/gone.jpg")]))
        #expect(writes == 0)
        #expect(store.setOriginalStates([id: .downloading, "gone": .unavailable]))
        #expect(writes == 1)
        #expect(store.album.photos.count == 2)
        #expect(store.album.photos[id]?.originalState == .downloading)
    }

    @Test func wantedAndEnqueueLogic() throws {
        var album = makeTestAlbum(photos: [makeTestPhoto("sel"), makeTestPhoto("video"), makeTestPhoto("stored"),
                                           makeTestPhoto("idle"), makeTestPhoto("gone"), makeTestPhoto("left")])
        album.photos["sel"]?.isSelected = true
        album.photos["video"]?.isSelected = true
        album.photos["video"]?.kind = .video
        album.photos["stored"]?.isSelected = true
        album.photos["stored"]?.originalState = .stored(relativePath: "originals/stored.jpg")
        album.photos["gone"]?.isSelected = true
        album.photos["gone"]?.originalState = .unavailable
        album.photos["left"]?.isSelected = true
        album.photos["left"]?.originalState = .downloading  // left over by a cancelled work
        #expect(OriginalsWork.wanted(in: album) == ["sel", "gone", "left"])
        #expect(OriginalsWork.toEnqueue(in: album, inFlight: [], attempts: [:], autoAttempts: 2) == ["left", "sel"])
        #expect(OriginalsWork.toEnqueue(in: album, inFlight: ["left"], attempts: ["sel": 2], autoAttempts: 2).isEmpty)
    }
}

@MainActor
struct BannerTextTests {
    @Test func downloadingTextUsesCzechGrouping() {
        #expect(BannerText.downloading(done: 12, total: 148) == "Stahuji originály 12 / 148")
        #expect(BannerText.downloading(done: 0, total: 1200) == "Stahuji originály 0 / 1\u{00A0}200")
        #expect(BannerText.failedOriginals(1) == "1 originál se nepodařilo stáhnout")
        #expect(BannerText.failedOriginals(3) == "3 originály se nepodařilo stáhnout")
        #expect(BannerText.failedOriginals(5) == "5 originálů se nepodařilo stáhnout")
    }

    /// One line, by priority: analysis, originals, places, missing source, failed originals.
    @Test func bannerPriority() {
        var state = BannerState()
        #expect(BannerText.line(for: state) == nil)
        state.failedOriginals = 2
        #expect(BannerText.line(for: state) == .failedOriginals(2))
        state.sourceUnavailable = true
        #expect(BannerText.line(for: state) == .sourceUnavailable)
        state.resolvingPlaces = true
        #expect(BannerText.line(for: state) == .resolvingPlaces)
        state.originals = .init(done: 3, total: 9)
        #expect(BannerText.line(for: state) == .downloading(done: 3, total: 9))
        state.analysis = PipelineProgress(done: 1, total: 4)
        #expect(BannerText.line(for: state) == .analyzing(done: 1, total: 4))
        #expect(BannerText.text(for: .analyzing(done: 1, total: 4)) == "Analyzuji fotky 1 / 4")
        #expect(BannerText.text(for: .downloading(done: 3, total: 9)) == "Stahuji originály 3 / 9")
        // An empty analysis (0 of 0) does not hide the downloads.
        state.analysis = PipelineProgress(done: 0, total: 0)
        #expect(BannerText.line(for: state) == .downloading(done: 3, total: 9))
        // "Stáhnout znovu" is offered only when nothing is downloading.
        #expect(!BannerText.offersRetry(state))
        state.originals = nil
        #expect(!BannerText.offersRetry(state))  // no Photos access: retrying cannot help
        state.sourceUnavailable = false
        #expect(BannerText.offersRetry(state))
    }
}

/// Task 17 ruling (b): background changes are autosaved explicitly, also when a user undo brought
/// NSDocument's change count back to "clean".
@MainActor
struct BackgroundAutosaveTests {
    @Test func backgroundChangeIsAutosavedEvenAfterAnUndoClearedTheChangeCount() async throws {
        let fixture = try makeOpenablePackage("Autosave")
        let nsDocument = try await openDocument(fixture.url)
        defer { nsDocument.close() }
        let document = try #require(albumDocument(in: nsDocument))
        let store = try document.bind(to: fixture.url)
        store.autosaveDelay = .milliseconds(300)

        // A user edit, autosaved.
        nsDocument.updateChangeCount(.changeDone)
        try await autosave(nsDocument)
        #expect(!nsDocument.hasUnautosavedChanges)

        // A background change, then the user undoes their edit: the count is "clean" again.
        try store.applyWithoutUndo(.setTitle("Z pozadí"))
        nsDocument.updateChangeCount(.changeUndone)
        #expect(!nsDocument.isDocumentEdited)
        // The trap: AppKit's own autosave now writes nothing.
        try await autosave(nsDocument)
        #expect(try ProjectPackage.open(fixture.url).1.title != "Z pozadí")

        // The explicit request saves it.
        await store.waitForPendingAutosave()
        #expect(store.autosaveCount == 1)
        #expect(try ProjectPackage.open(fixture.url).1.title == "Z pozadí")
    }

    /// Requests are debounced: a burst of background flushes makes one save.
    @Test func autosaveRequestsAreDebounced() async throws {
        let store = AlbumStore(album: makeTestAlbum(), package: try ProjectPackage.create(
            at: makeTempDir().appendingPathComponent("Debounce.leporelo"), album: makeTestAlbum()))
        var saves = 0
        store.autosaveHandler = { saves += 1 }
        store.autosaveDelay = .milliseconds(50)
        for title in ["A", "B", "C"] { try store.applyWithoutUndo(.setTitle(title)) }
        await store.waitForPendingAutosave()
        #expect(saves == 1)
        #expect(store.autosaveCount == 1)
    }
}

// MARK: Refresh from the source, state screens

@MainActor
struct SourceRefreshTests {
    /// 2 new photos and 1 gone: counts reported; the new ones get days right away (unselected);
    /// the gone one is flagged but keeps its stored original and its frame; ONE store write.
    @Test func refreshUpdatesStoreAndReports() async throws {
        let store = try await makeOriginalsStore(3, name: "Obnova")
        let ids = store.sortedIDs()
        let gone = ids[0]
        var album = store.album
        for id in ids { album.photos[id]?.isSelected = true }
        let (profile, format) = try ProfileCatalog.format(profileID: album.supplierProfileID, formatID: album.formatID)
        album = Workflow.draft(album: album, profile: profile, format: format)
        let relative = try store.package.storeOriginal(data: Data([1, 2, 3]), ext: "jpg", for: gone)
        album.photos[gone]?.originalState = .stored(relativePath: relative)
        store.replaceWithoutUndo(album: album)
        #expect(album.placedPhotoIDs.contains(gone))
        let spreads = store.album.spreads
        var writes = 0
        store.markChanged = { writes += 1 }

        let remaining = sourcePhotos(3).dropFirst()
        let source = FakePhotoSource(photos: Array(remaining) + [.fake("n1", minutes: 9 * 60 + 5),
                                                                .fake("n2", minutes: 9 * 60 + 15)])
        let report = try await SourceRefresh.run(store: store, source: source)

        #expect(report == RefreshReport(added: 2, deleted: 1))
        #expect(RefreshText.summary(report) == "Přidány 2 nové fotky, 1 fotka už v Photos není.")
        #expect(writes == 1)
        #expect(store.album.photos.count == 5)
        let added = store.album.photos.values.filter { $0.sourceIdentifier.hasPrefix("n") }
        #expect(added.count == 2)
        #expect(added.allSatisfy { $0.dayKey == DayKey(year: 2026, month: 7, day: 1) && !$0.isSelected })
        let flagged = try #require(store.album.photos[gone])
        #expect(flagged.deletedInSource)
        #expect(flagged.originalState == .stored(relativePath: relative))
        #expect(store.package.originalURL(for: gone, album: store.album) != nil)
        #expect(store.album.spreads == spreads)
        #expect(source.queries == [originalsQuery])
    }

    /// An empty answer for a non-empty album: the refresh throws and the album stays as it was.
    @Test func refreshWithAnEmptyResultThrowsAndChangesNothing() async throws {
        let store = try await makeOriginalsStore(2)
        let before = store.album
        var writes = 0
        store.markChanged = { writes += 1 }
        await #expect(throws: SourceSyncError.emptyResult) {
            _ = try await SourceRefresh.run(store: store, source: FakePhotoSource(photos: []))
        }
        #expect(store.album == before)
        #expect(writes == 0)
        let alert = RefreshText.failure(SourceSyncError.emptyResult)
        #expect(alert.title == "Zdroj nevrátil žádné fotky. Fotky v albu zůstávají beze změny.")
        #expect(RefreshText.failure(PhotoSourceError.notAuthorized).title == "Fotky nelze načíst: chybí přístup k Fotkám")
    }

    /// Edits made while the source is read survive: the result is merged into the CURRENT album.
    @Test func refreshMergesIntoTheCurrentAlbum() async throws {
        let store = try await makeOriginalsStore(2)
        let source = FakePhotoSource(photos: sourcePhotos(2) + [.fake("n1", minutes: 9 * 60 + 1)])
        source.holdPhotos()
        let refresh = Task { try await SourceRefresh.run(store: store, source: source) }
        try await waitFor("held photos") { source.heldCalls > 0 }
        try store.applyWithoutUndo(.setTitle("Mezitím"))
        source.releaseAll()
        let report = try await refresh.value
        #expect(report == RefreshReport(added: 1, deleted: 0))
        #expect(store.album.title == "Mezitím")
        #expect(store.album.photos.count == 3)
    }

    /// The session's refresh applies the result and analyses the new photos (no automatic
    /// recommendations: the user's selection is not touched).
    @Test func sessionRefreshAnalysesTheNewPhotos() async throws {
        let seed = try await makeOriginalsStore(2, name: "Relace")
        let url = seed.package.url
        let source = FakePhotoSource(photos: sourcePhotos(2) + [.fake("n1", minutes: 9 * 60 + 3)])
        let session = AlbumSession(placeResolver: { InMemoryPlaceResolver([]) })
        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        session.bind(document: document, fileURL: url, sourceProvider: { _ in source })
        let store = try #require(session.store)
        await session.work?.waitUntilFinished()
        let selection = store.album.photos.mapValues(\.isSelected)

        let outcome = await session.refreshFromSource()
        #expect(outcome == .success(RefreshReport(added: 1, deleted: 0)))
        let work = try #require(session.work)
        await work.waitUntilFinished()
        #expect(store.album.photos.count == 3)
        #expect(store.album.photos.values.allSatisfy { $0.analysis != nil })
        #expect(!work.recommendationsApplied)
        for (id, selected) in selection { #expect(store.album.photos[id]?.isSelected == selected) }
        session.close()
    }

    @Test func summaryPlurals() {
        #expect(RefreshText.summary(.init(added: 0, deleted: 0)) == "Žádné změny.")
        #expect(RefreshText.summary(.init(added: 1, deleted: 0)) == "Přidána 1 nová fotka, 0 fotek už v Photos není.")
        #expect(RefreshText.summary(.init(added: 5, deleted: 3)) == "Přidáno 5 nových fotek, 3 fotky už v Photos nejsou.")
        #expect(RefreshText.summary(.init(added: 0, deleted: 1)) == "Přidáno 0 nových fotek, 1 fotka už v Photos není.")
        #expect(RefreshText.summary(.init(added: 3000, deleted: 5)) == "Přidáno 3\u{00A0}000 nových fotek, 5 fotek už v Photos není.")
    }
}

@MainActor
struct AlbumScreenTests {
    private func album(analysed: Bool, stored: Bool, selected: Bool = true, source: SourceQuery? = originalsQuery) -> Album {
        var photo = makeTestPhoto("p", state: stored ? .stored(relativePath: "originals/p.jpg") : .missing)
        photo.isSelected = selected
        if analysed {
            photo.analysis = PhotoAnalysis(aesthetic: 0.5, sharpness: 900, isUtility: false, faceRects: [],
                                           closedEyes: false, featurePrint: nil)
        }
        var album = makeTestAlbum(photos: [photo])
        album.source = source
        return album
    }

    /// The permission screen only when work needs the source, access blocks it, and there is
    /// nothing to browse; a downloaded (or browsable) album opens without Photos access.
    @Test func screenGating() {
        let denied = PhotoAccess.denied
        #expect(AlbumScreenLogic.screen(album: makeTestAlbum(), access: .authorized) == .empty)
        #expect(AlbumScreenLogic.screen(album: makeTestAlbum(), access: denied) == .empty)
        // Nothing analysed, needs the source, no access: the permission screen.
        #expect(AlbumScreenLogic.screen(album: album(analysed: false, stored: false), access: denied) == .noPermission(.denied))
        #expect(AlbumScreenLogic.screen(album: album(analysed: false, stored: false), access: .limited) == .noPermission(.limited))
        #expect(AlbumScreenLogic.screen(album: album(analysed: false, stored: false), access: .restricted) == .noPermission(.restricted))
        // Full access: always the content.
        #expect(AlbumScreenLogic.screen(album: album(analysed: false, stored: false), access: .authorized) == .content)
        // Browsable (thumbnails exist) but originals missing: the content (the banner explains).
        #expect(AlbumScreenLogic.screen(album: album(analysed: true, stored: false), access: denied) == .content)
        // Fully downloaded: the content, also without access.
        #expect(AlbumScreenLogic.screen(album: album(analysed: true, stored: true), access: denied) == .content)
        // No source query (CLI album): nothing could be read anyway.
        #expect(AlbumScreenLogic.screen(album: album(analysed: false, stored: false, source: nil), access: denied) == .content)
        #expect(AlbumScreenLogic.needsSource(album(analysed: true, stored: true)) == false)
        #expect(AlbumScreenLogic.needsSource(album(analysed: true, stored: false)) == true)
        #expect(AlbumScreenLogic.needsSource(album(analysed: true, stored: false, selected: false)) == false)
    }

    @Test func emptyStateTitles() {
        #expect(EmptyStateText.title(for: originalsQuery) == "V tomto rozmezí nejsou žádné fotky")
        #expect(EmptyStateText.title(for: .album(identifier: "x", name: "Léto")) == "V albu Léto nejsou žádné fotky")
        #expect(EmptyStateText.title(for: nil) == "V albu nejsou žádné fotky")
    }

    /// A photo gone from Photos is marked in triage (with a tooltip that says the original stays).
    @Test func deletedInSourceBadge() {
        var photo = makeTestPhoto("p", state: .stored(relativePath: "originals/p.jpg"))
        photo.deletedInSource = true
        #expect(TriageModel.badges(photo, duplicate: false).contains(.deletedInSource))
        #expect(PhotoCell.tooltip(.deletedInSource, state: photo.originalState) == "Už v Photos není, originál zůstává v albu")
        #expect(PhotoCell.tooltip(.deletedInSource, state: .missing) == "Už v Photos není")
        photo.deletedInSource = false
        #expect(!TriageModel.badges(photo, duplicate: false).contains(.deletedInSource))
    }
}
