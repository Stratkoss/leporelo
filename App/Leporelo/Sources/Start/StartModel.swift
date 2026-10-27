import Foundation
import LeporeloCore
import Observation

/// A row of the start window's sidebar. An album is identified by `SourceAlbum.identifier`
/// (`SourceAlbum` is Equatable, not Hashable).
enum StartItem: Hashable {
    case book(URL)
    case album(String)
    case dateRange
}

/// The start window (spec section 2): recent books, the albums from Photos and "Podle data…",
/// the photos of the selected album or date range, and the preset `NewAlbumModel` for
/// "Udělat z toho knihu".
///
/// Photo fetches run off the main actor (`PhotoSource` methods are nonisolated async). A result
/// for a selection that changed meanwhile is dropped, and `photos` only ever shows the photos of
/// the current `query`.
@MainActor
@Observable
final class StartModel {
    private(set) var books: [URL] = []
    private(set) var albums: [SourceAlbum] = []
    var selection: StartItem?
    /// Day-precision bounds of "Podle data…" as picked (the query uses whole days).
    var start: Date
    var end: Date
    /// Why the albums or photos could not be read (e.g. no access to Photos).
    private(set) var accessProblem: String?

    /// The photos of the current query (empty until they are loaded).
    var photos: [SourcePhoto] {
        guard let loadedQuery, loadedQuery == query else { return [] }
        return loadedPhotos
    }

    /// The loaded photo count, else the album's own count (nil for a date range not yet counted).
    var photoCount: Int? {
        if let loadedQuery, loadedQuery == query { return loadedPhotos.count }
        return selectedAlbum?.count
    }

    /// True while the photos of the current query are being fetched.
    var isLoadingPhotos: Bool {
        guard let query else { return false }
        return loadedQuery != query
    }

    var selectedAlbum: SourceAlbum? {
        guard case .album(let identifier) = selection else { return nil }
        return albums.first { $0.identifier == identifier }
    }

    /// The selected album, or whole days from `start`'s midnight up to the midnight after `end`
    /// (as `NewAlbumModel.query`). Nil for a book, nothing selected or an empty range.
    var query: SourceQuery? {
        switch selection {
        case .album:
            guard let album = selectedAlbum else { return nil }
            return .album(identifier: album.identifier, name: album.name)
        case .dateRange:
            let from = calendar.startOfDay(for: start)
            guard let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)),
                  from < to else { return nil }
            return .dateRange(start: from, end: to)
        case .book, nil:
            return nil
        }
    }

    @ObservationIgnored private let source: any PhotoSource
    @ObservationIgnored private let recentBooks: @MainActor () -> [URL]
    @ObservationIgnored private let now: Date
    @ObservationIgnored private let calendar: Calendar
    private var loadedQuery: SourceQuery?
    private var loadedPhotos: [SourcePhoto] = []

    /// `recentBooks` is only called from `load()` (the app reads the document controller there,
    /// never while building scenes). The date range defaults to `NewAlbumModel`'s last 7 days.
    init(source: any PhotoSource, recentBooks: @escaping @MainActor () -> [URL], now: Date = Date(),
         calendar: Calendar = .current) {
        self.source = source
        self.recentBooks = recentBooks
        self.now = now
        self.calendar = calendar
        end = now
        start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7, to: now) ?? now)
    }

    /// Reads the recent books and the albums. Once the albums are read, selects the first album
    /// (else "Podle data…") when nothing, or an album no longer listed, is selected. A failed read
    /// leaves the selection alone, so granting access later still lands on the first album.
    func load() async {
        books = recentBooks()
        do {
            albums = try await source.albums()
            accessProblem = nil
        } catch {
            albums = []
            accessProblem = NewAlbumModel.errorMessage(for: error)
            return
        }
        let selectionIsGone: Bool = switch selection {
        case nil: true
        case .album: selectedAlbum == nil
        case .book, .dateRange: false
        }
        if selectionIsGone {
            selection = albums.first.map { .album($0.identifier) } ?? .dateRange
        }
    }

    /// Fetches the photos of the current query. A result for a query that changed meanwhile is
    /// dropped.
    func loadPhotos() async {
        guard let query else { return }
        do {
            let fetched = try await source.photos(matching: query)
            guard query == self.query else { return }
            loadedPhotos = fetched
            accessProblem = nil
        } catch {
            guard query == self.query, !(error is CancellationError) else { return }
            loadedPhotos = []
            accessProblem = NewAlbumModel.errorMessage(for: error)
        }
        loadedQuery = query
    }

    /// The "Udělat z toho knihu" form preset from the selection: the album (titled by its name,
    /// "Nové album" when it has none) or the date range. Nil for a book or nothing selected.
    func makeNewAlbumModel(profiles: [SupplierProfile]) -> NewAlbumModel? {
        let model = NewAlbumModel(source: source, profiles: profiles, now: now, calendar: calendar)
        switch selection {
        case .album:
            guard let album = selectedAlbum else { return nil }
            model.queryMode = .album
            model.albums = albums
            model.selectedAlbum = album
            let name = album.name.trimmingCharacters(in: .whitespacesAndNewlines)
            model.title = name.isEmpty ? NewAlbumModel.defaultTitle : name
        case .dateRange:
            model.queryMode = .dateRange
            model.start = start
            model.end = end
        case .book, nil:
            return nil
        }
        return model
    }
}
