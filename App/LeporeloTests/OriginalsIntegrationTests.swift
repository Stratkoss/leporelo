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
