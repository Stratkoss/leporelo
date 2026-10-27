import Foundation
import LeporeloCore
import Observation

/// Where the photos of a new album come from.
enum QueryMode: String, CaseIterable, Sendable {
    case dateRange
    case album
}

/// Why a new album could not be created (shown in the sheet's alert).
enum NewAlbumError: LocalizedError, Equatable {
    case noPhotosInRange
    case noPhotosInAlbum
    case noAlbumSelected
    case invalidRange
    case unknownFormat

    var errorDescription: String? {
        switch self {
        case .noPhotosInRange: "V tomto rozmezí nejsou žádné fotky"
        case .noPhotosInAlbum: "V tomto albu nejsou žádné fotky"
        case .noAlbumSelected: "Vyberte album z Fotek."
        case .invalidRange: "Začátek rozmezí je po jeho konci."
        case .unknownFormat: "Vyberte formát knihy."
        }
    }
}

/// The "Nové album" form: title, supplier format and photo source, plus the checks shown before
/// creating (photo count, empty source, reduced photos, shared albums) and `createAlbum`.
///
/// `createAlbum` is fast on purpose (spec section 8: grid in 5 s, days in 30 s, geocoding never
/// blocks): it fetches, groups days with an EMPTY place resolver and saves the first state.
/// Place names, day corrections, analysis and recommendations come later from `BackgroundWork`.
@MainActor
@Observable
final class NewAlbumModel {
    static let defaultTitle = "Nové album"
    static let preferredProfileID = "canva-photobook"
    /// The longer side at or under which a photo counts as reduced (iCloud shared albums: ~2048 px).
    static let reducedLongSide = 2048
    static let lowResolutionMessage =
        "Fotky z tohoto zdroje jsou zmenšené (nejdelší strana nejvýš 2\u{00A0}048 px). Pro tisk přes celou stranu nemusí stačit."
    static let sharedAlbumMessage =
        "Sdílené album iCloudu zmenšuje fotky na zhruba 2\u{00A0}048 px. Pro tisk přes celou stranu nemusí stačit, album ale založit můžete."
    static let unverifiedFormatMessage = "Rozměry formátu nejsou ověřené u dodavatele."

    let profiles: [SupplierProfile]
    var title = NewAlbumModel.defaultTitle
    var profileID: String {
        didSet {
            if !formats.contains(where: { $0.id == formatID }) {
                formatID = profile.flatMap(Workflow.defaultFormat(of:))?.id ?? ""
            }
        }
    }
    var formatID: String
    var queryMode: QueryMode = .dateRange
    /// Day-precision bounds as picked (the query uses whole days: see `query`).
    var start: Date
    var end: Date
    var albums: [SourceAlbum] = []
    var selectedAlbum: SourceAlbum?
    /// The reduced-photos warning for the current source (from `refreshPreview`).
    var warning: String?
    /// How many photos the current source has (`refreshPreview`); nil until counted.
    private(set) var photoCount: Int?
    /// Why the source could not be read (e.g. no access), from the last preview or album load.
    private(set) var sourceError: String?

    @ObservationIgnored private let source: any PhotoSource
    @ObservationIgnored private let calendar: Calendar

    /// Defaults: title "Nové album", the `canva-photobook` profile (else the first) with its default
    /// format, and the last 7 days (from the midnight 7 days before `now` to `now`).
    init(source: any PhotoSource, profiles: [SupplierProfile], now: Date = Date(),
         calendar: Calendar = .current) {
        self.source = source
        self.profiles = profiles
        self.calendar = calendar
        let profile = profiles.first { $0.id == Self.preferredProfileID } ?? profiles.first
        profileID = profile?.id ?? ""
        formatID = profile.flatMap(Workflow.defaultFormat(of:))?.id ?? ""
        end = now
        start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7, to: now) ?? now)
    }

    // MARK: Derived state

    var profile: SupplierProfile? { profiles.first { $0.id == profileID } }
    var formats: [BookFormat] { profile?.formats ?? [] }
    var format: BookFormat? { formats.first { $0.id == formatID } }

    var unverifiedFormatNote: String? {
        guard let profile, !profile.verified else { return nil }
        return Self.unverifiedFormatMessage
    }

    /// Shown before creating: a shared iCloud album only has reduced copies (creation stays allowed).
    var sharedAlbumWarning: String? {
        guard queryMode == .album, selectedAlbum?.isShared == true else { return nil }
        return Self.sharedAlbumMessage
    }

    /// The source query: whole days from `start`'s midnight up to the midnight after `end`
    /// (PhotoKit: `creationDate >= start AND < end`), or the selected album. Nil when incomplete.
    var query: SourceQuery? {
        switch queryMode {
        case .dateRange:
            let from = calendar.startOfDay(for: start)
            guard let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)),
                  from < to else { return nil }
            return .dateRange(start: from, end: to)
        case .album:
            guard let album = selectedAlbum else { return nil }
            return .album(identifier: album.identifier, name: album.name)
        }
    }

    /// Blocks creation when the counted source is empty.
    var emptySourceMessage: String? {
        guard photoCount == 0 else { return nil }
        return emptyError.errorDescription
    }

    var photoCountText: String? {
        photoCount.map { "Fotek ve zdroji: \(BannerText.czech($0))" }
    }

    var canCreate: Bool {
        !trimmedTitle.isEmpty && format != nil && query != nil && (photoCount ?? 0) > 0
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var emptyError: NewAlbumError { queryMode == .album ? .noPhotosInAlbum : .noPhotosInRange }

    // MARK: Source

    func loadAlbums() async {
        do {
            albums = try await source.albums()
            if let selected = selectedAlbum, !albums.contains(selected) { selectedAlbum = nil }
        } catch {
            sourceError = Self.errorMessage(for: error)
        }
    }

    /// Counts the photos of the current query and updates `warning`. A result for a query that
    /// changed meanwhile is dropped.
    func refreshPreview() async {
        guard let query else {
            photoCount = nil
            warning = nil
            return
        }
        do {
            let photos = try await source.photos(matching: query)
            guard query == self.query else { return }
            photoCount = photos.count
            warning = lowResolutionWarning(for: photos)
            sourceError = nil
        } catch {
            guard query == self.query else { return }
            photoCount = nil
            warning = nil
            sourceError = Self.errorMessage(for: error)
        }
    }

    /// Review Focus 5: when MORE than half of the photos (videos do not count) have the longer
    /// side at most 2048 px (upright `SourcePhoto` dims), the source only has reduced copies.
    func lowResolutionWarning(for photos: [SourcePhoto]) -> String? {
        let stills = photos.filter { $0.kind != .video }
        guard !stills.isEmpty else { return nil }
        let reduced = stills.filter { max($0.pixelWidth, $0.pixelHeight) <= Self.reducedLongSide }.count
        return reduced * 2 > stills.count ? Self.lowResolutionMessage : nil
    }

    // MARK: Creating

    /// Creates the package at `packageURL` (never over an existing one: `ProjectError.alreadyExists`),
    /// fetches the photos, groups days without geocoding and saves the first state. On any failure
    /// the package this call created is deleted again; an existing one is never touched.
    func createAlbum(packageURL: URL) async throws -> (ProjectPackage, Album) {
        guard let query else {
            throw queryMode == .album ? NewAlbumError.noAlbumSelected : NewAlbumError.invalidRange
        }
        guard let format else { throw NewAlbumError.unknownFormat }
        let title = trimmedTitle.isEmpty ? Self.defaultTitle : trimmedTitle
        let package = try Workflow.createPackage(at: packageURL, title: title, profileID: profileID,
                                                 formatID: format.id)
        do {
            let album = try await Workflow.buildAlbum(
                from: source, query: query, title: title, profileID: profileID, formatID: format.id,
                package: package, resolver: InMemoryPlaceResolver([]))
            guard !album.photos.isEmpty else { throw emptyError }
            return (package, album)
        } catch {
            try? FileManager.default.removeItem(at: package.url)
            throw error
        }
    }

    /// `<title>.leporelo`, with characters Finder or the file system dislike replaced.
    static func packageFileName(for title: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = defaultTitle }
        return name + ".leporelo"
    }

    /// A Czech message for any error of this flow.
    static func errorMessage(for error: any Error) -> String {
        switch error {
        case let error as PhotoSourceError:
            switch error {
            case .notAuthorized: "Leporelo nemá úplný přístup k Fotkám."
            case .notFound: "Fotka ve Fotkách nebyla nalezena."
            case .cloudUnavailable: "Fotku se nepodařilo stáhnout z iCloudu."
            }
        case let error as LocalizedError where error.errorDescription != nil:
            error.errorDescription!
        default:
            "Album se nepodařilo založit."
        }
    }
}
