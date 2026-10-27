import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private var prague: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
    return calendar
}

/// 2026-10-27 15:30 in Prague.
private let now = Date(timeIntervalSince1970: 1_793_111_400)

private let summer = SourceAlbum(identifier: "a1", name: "Léto", count: 2, isShared: false)
private let family = SourceAlbum(identifier: "s1", name: "Rodina", count: 1, isShared: true)
private let untitled = SourceAlbum(identifier: "a2", name: "  ", count: 3, isShared: false)

private let books = [URL(fileURLWithPath: "/tmp/Řím.leporelo"), URL(fileURLWithPath: "/tmp/Léto.leporelo")]

/// Polls `condition` on the main actor.
@MainActor
private func waitUntil(_ what: String, timeout: Duration = .seconds(10),
                       _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func makeModel(_ source: FakePhotoSource, books: [URL] = books) -> StartModel {
    StartModel(source: source, recentBooks: { books }, now: now, calendar: prague)
}

@MainActor
struct StartModelTests {
    @Test func loadListsAlbumsAndBooks() async throws {
        let source = FakePhotoSource(albums: [summer, family])
        let model = makeModel(source)
        #expect(model.books.isEmpty && model.albums.isEmpty)  // nothing read before `load`

        await model.load()

        #expect(model.books == books)
        #expect(model.albums == [summer, family])
        #expect(model.accessProblem == nil)
        // Like Photos: the first album is selected when nothing was.
        #expect(model.selection == .album("a1"))
        #expect(model.selectedAlbum == summer)
    }

    @Test func loadWithoutAlbumsSelectsTheDateRange() async throws {
        let model = makeModel(FakePhotoSource())
        await model.load()
        #expect(model.selection == .dateRange)
    }

    @Test func selectingAlbumLoadsItsPhotos() async throws {
        let source = FakePhotoSource(photos: [.fake("p1"), .fake("p2")], albums: [summer, family])
        let model = makeModel(source)
        await model.load()

        model.selection = .album("s1")
        #expect(model.selectedAlbum == family)
        #expect(model.query == .album(identifier: "s1", name: "Rodina"))
        await model.loadPhotos()

        #expect(model.photos.map(\.identifier) == ["p1", "p2"])
        #expect(source.queries == [.album(identifier: "s1", name: "Rodina")])
        #expect(model.photoCount == 2)
    }

    @Test func staleAlbumPhotosAreDropped() async throws {
        let source = FakePhotoSource(photos: [.fake("old")], albums: [summer, family])
        let model = makeModel(source)
        await model.load()
        model.selection = .album("a1")
        source.holdPhotos()
        let first = Task { await model.loadPhotos() }
        try await waitUntil("the first fetch to be held") { source.heldCalls == 1 }

        // The user picks another album while the first one is still loading.
        model.selection = .album("s1")
        source.releaseAll()
        await first.value
        #expect(model.photos.isEmpty)  // "old" belongs to Léto, not to Rodina

        source.setPhotos([.fake("new")])
        await model.loadPhotos()
        #expect(model.photos.map(\.identifier) == ["new"])
    }

    @Test func switchingSelectionHidesThePreviousPhotos() async throws {
        let source = FakePhotoSource(photos: [.fake("p1")], albums: [summer, family])
        let model = makeModel(source)
        await model.load()
        await model.loadPhotos()
        #expect(model.photos.count == 1)

        model.selection = .album("s1")
        #expect(model.photos.isEmpty)
        #expect(model.photoCount == 1)  // the album's own count until its photos are loaded
    }

    @Test func dateRangeQueryUsesWholeDays() async throws {
        let model = makeModel(FakePhotoSource())
        model.selection = .dateRange
        let start = try #require(prague.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let afterEnd = try #require(prague.date(from: DateComponents(year: 2026, month: 10, day: 28)))
        // Defaults like "Nové album": the last 7 days.
        #expect(model.start == start)
        #expect(model.end == now)
        #expect(model.query == .dateRange(start: start, end: afterEnd))

        model.start = try #require(prague.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 18)))
        model.end = try #require(prague.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 9)))
        let july1 = try #require(prague.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let july4 = try #require(prague.date(from: DateComponents(year: 2026, month: 7, day: 4)))
        #expect(model.query == .dateRange(start: july1, end: july4))

        model.end = try #require(prague.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        #expect(model.query == nil)  // start after end
    }

    @Test func newAlbumModelFromAlbumIsPreset() async throws {
        let source = FakePhotoSource(albums: [summer, family, untitled])
        let model = makeModel(source)
        await model.load()
        let profiles = try ProfileCatalog.all()

        model.selection = .album("s1")
        let shared = try #require(model.makeNewAlbumModel(profiles: profiles))
        #expect(shared.title == "Rodina")
        #expect(shared.queryMode == .album)
        #expect(shared.selectedAlbum == family)
        #expect(shared.albums == [summer, family, untitled])
        #expect(shared.query == .album(identifier: "s1", name: "Rodina"))
        #expect(shared.sharedAlbumWarning == NewAlbumModel.sharedAlbumMessage)
        #expect(shared.profileID == "canva-photobook")

        model.selection = .album("a2")
        #expect(model.makeNewAlbumModel(profiles: profiles)?.title == "Nové album")
    }

    @Test func newAlbumModelFromDateRange() async throws {
        let model = makeModel(FakePhotoSource())
        model.selection = .dateRange
        model.start = try #require(prague.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        model.end = try #require(prague.date(from: DateComponents(year: 2026, month: 7, day: 14)))

        let created = try #require(model.makeNewAlbumModel(profiles: try ProfileCatalog.all()))
        #expect(created.title == "Nové album")
        #expect(created.queryMode == .dateRange)
        #expect(created.start == model.start)
        #expect(created.end == model.end)
        #expect(created.query == model.query)
    }

    @Test func newAlbumModelForBookIsNil() async throws {
        let model = makeModel(FakePhotoSource(albums: [summer]))
        await model.load()
        let profiles = try ProfileCatalog.all()
        model.selection = .book(books[0])
        #expect(model.makeNewAlbumModel(profiles: profiles) == nil)
        model.selection = nil
        #expect(model.makeNewAlbumModel(profiles: profiles) == nil)
        // An album that is no longer listed makes no book either.
        model.selection = .album("gone")
        #expect(model.makeNewAlbumModel(profiles: profiles) == nil)
    }

    @Test func notAuthorizedSetsAccessProblem() async throws {
        let source = FakePhotoSource(albums: [summer])
        source.setAlbumsError(.notAuthorized)
        let model = makeModel(source)

        await model.load()
        #expect(model.accessProblem == NewAlbumModel.errorMessage(for: PhotoSourceError.notAuthorized))
        #expect(model.albums.isEmpty)
        #expect(model.books == books)  // the books do not need Photos
        #expect(model.selection == nil)

        // Access granted later: a new load clears the problem and selects the first album; a
        // failing photo fetch sets the problem again.
        source.setAlbumsError(nil)
        await model.load()
        #expect(model.accessProblem == nil)
        #expect(model.selection == .album("a1"))
        source.setPhotosError(.notAuthorized)
        await model.loadPhotos()
        #expect(model.accessProblem == NewAlbumModel.errorMessage(for: PhotoSourceError.notAuthorized))
        #expect(model.photos.isEmpty)
    }
}
