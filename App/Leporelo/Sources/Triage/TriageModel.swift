import Foundation
import LeporeloCore
import Observation
import os

/// A flag shown on a grid cell (SF Symbols, top right).
enum Badge: String, Hashable, Sendable, CaseIterable {
    case blurred, closedEyes, duplicate, video, screenshot, cloud
}

/// One cell of the triage grid: a photo, or the head of a (collapsed or expanded) series.
struct TriageItem: Equatable, Identifiable {
    var photo: Photo
    /// The best member of a series of 2+ photos of this day; it carries the series chip.
    var isSeriesHead: Bool
    /// Members of the photo's series among the shown photos of the day; 1 outside a series.
    var seriesCount: Int
    /// Selected members of that series (shown on a collapsed head so no selection is hidden).
    var seriesSelectedCount: Int
    /// The photo's series is expanded (head and members).
    var isExpanded: Bool
    var badges: [Badge]

    var id: PhotoID { photo.id }
    var seriesID: String? { seriesCount > 1 ? photo.seriesID : nil }
    /// Videos are shown but never go into the album.
    var isSelectable: Bool { photo.kind != .video }

    /// "×4" on a head; "2 z 4" when members are selected and the series is collapsed.
    var seriesChip: String? {
        guard isSeriesHead else { return nil }
        if !isExpanded && seriesSelectedCount > 0 { return "\(seriesSelectedCount) z \(seriesCount)" }
        return "×\(seriesCount)"
    }

    /// VoiceOver: "Fotka, vybraná, rozmazaná".
    var accessibilityLabel: String {
        var parts: [String] = []
        if photo.kind == .video {
            parts.append("Video")
            parts.append("nelze vybrat")
        } else {
            parts.append("Fotka")
            parts.append(photo.isSelected ? "vybraná" : "nevybraná")
        }
        for badge in badges {
            switch badge {
            case .blurred: parts.append("rozmazaná")
            case .closedEyes: parts.append("zavřené oči")
            case .screenshot: parts.append("snímek obrazovky nebo účtenka")
            case .duplicate: parts.append("podobná fotka v sérii")
            case .cloud: parts.append(TriageText.originalDescription(photo.originalState))
            case .video: break
            }
        }
        if isSeriesHead {
            parts.append("série, \(CzechPlural.photos(seriesCount)), vybrané \(seriesSelectedCount)")
            parts.append(isExpanded ? "rozbalená" : "sbalená")
        }
        return parts.joined(separator: ", ")
    }
}

/// An entry of the day list: a day, or the photos without a day ("Bez data").
enum DayEntryID: Hashable, Sendable {
    case day(DayKey)
    case undated
}

struct DayEntry: Identifiable, Equatable {
    var id: DayEntryID
    var label: String
    var accessibilityLabel: String
    var selected: Int
    var total: Int
    /// Photos can be dropped on it (every day; not "Bez data").
    var acceptsDrop: Bool { id != .undated }
}

/// Texts of the triage view (Czech, sentence case).
enum TriageText {
    static let undated = "Bez data"
    static let noPlace = "bez místa"
    static let onlyRecommended = "Jen doporučené"
    static let propose = "Navrhnout album"
    static let proposeUnavailable = "Dostupné v dalším kroku"
    static let maxPlaces = 3

    // Formatting only, never mutated after creation.
    private static let shortFormatter: DateFormatter = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d. M."
        return formatter
    }()

    /// "čt 18. 6." for the day itself (no year inside one trip), independent of the Mac's zone.
    static func shortDate(_ key: DayKey) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: key.year, month: key.month, day: key.day, hour: 12))!
        return shortFormatter.string(from: date)
    }

    /// "Positano, Ravello", at most three then "…"; "bez místa" when none.
    static func places(_ names: [String]) -> String {
        if names.isEmpty { return noPlace }
        let shown = names.prefix(maxPlaces).joined(separator: ", ")
        return names.count > maxPlaces ? shown + "…" : shown
    }

    /// "čt 18. 6. · Positano, Ravello · 14/212".
    static func dayLabel(_ key: DayKey, placeNames: [String], selected: Int, total: Int) -> String {
        "\(shortDate(key)) · \(places(placeNames)) · \(counts(selected, total))"
    }

    /// "Bez data · 0/12".
    static func undatedLabel(selected: Int, total: Int) -> String {
        "\(undated) · \(counts(selected, total))"
    }

    static func dayAccessibilityLabel(_ key: DayKey, placeNames: [String], selected: Int, total: Int) -> String {
        "\(AlbumDrafter.czechDate(key)), \(places(placeNames)), vybráno \(selected) z \(total)"
    }

    /// "Vybráno 148 fotek · odhad 36 stran" (verb agrees: vybrána 1 fotka, vybrány 3 fotky);
    /// "Vybráno 148 fotek · 36 stran" when `estimated` is false (the album has spreads).
    static func footer(selected: Int, pages: Int, estimated: Bool = true) -> String {
        let verb = CzechPlural.choose(selected, one: "Vybrána", few: "Vybrány", many: "Vybráno")
        return "\(verb) \(CzechPlural.photos(selected)) · \(estimated ? "odhad " : "")\(CzechPlural.pages(pages))"
    }

    static func originalDescription(_ state: OriginalState) -> String {
        switch state {
        case .missing: "originál zatím není stažený"
        case .downloading: "originál se stahuje"
        case .unavailable: "originál není dostupný"
        case .stored: "originál je uložený"
        }
    }

    private static func counts(_ selected: Int, _ total: Int) -> String {
        "\(CzechPlural.grouped(selected))/\(CzechPlural.grouped(total))"
    }
}

/// The drag payload of a grid cell: plain text with a prefix, so a day row accepts only photos
/// dragged from this app's grid (any other dropped text is ignored).
enum PhotoDrag {
    static let prefix = "leporelo-photo:"

    static func payload(for id: PhotoID) -> String { prefix + id }

    static func photoID(from string: String) -> PhotoID? {
        guard string.hasPrefix(prefix) else { return nil }
        let id = String(string.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

/// The triage view's model (spec 6.2): days, the photos of a day with series collapsed to their
/// best photo, selection, day moves and the page estimate.
///
/// Everything is derived from the store's album and cached per `AlbumStore.revision`, so a
/// background flush costs one regrouping, not one per query. Reading any property registers an
/// observation of the store, so SwiftUI views (and the grid representable) update on every change.
///
/// Edits:
/// - selection: `AlbumEdit.setSelected` while the album has no spreads; once it has (back from
///   the editor) `AlbumUpdater.photoSelected/photoDeselected` through `AlbumStore.replace`, so the
///   photo is also placed in / removed from the layout (Task 20 ruling);
/// - day moves: `AlbumEdit.setPhotoDay`, undoable; a placed photo of non-manual spreads follows
///   into the new day's layout (`AlbumUpdater.photoMoved` via `replace`, see `move`).
@MainActor
@Observable
final class TriageModel {
    let store: AlbumStore
    /// The window's undo manager (set by the view); nil means edits without undo.
    @ObservationIgnored var undoManager: UndoManager?
    /// The entry the user chose; nil until they choose one. May point at an entry that no longer
    /// exists (its last photo was moved away); `visibleEntry` falls back to the first entry then.
    var currentEntry: DayEntryID? = nil
    /// Shows only photos that are selected or recommended for their day.
    var showOnlyRecommended = false
    /// Series (by `seriesID`) shown with all their members.
    var expandedSeries: Set<String> = []

    /// The shown day (`visibleEntry`); nil when "Bez data" or nothing is shown.
    var currentDay: DayKey? {
        get { if case .day(let key) = visibleEntry { key } else { nil } }
        set { currentEntry = newValue.map { .day($0) } }
    }

    /// Cheap: nothing is grouped until the first query (`visibleEntry` falls back to the first
    /// entry while `currentEntry` is nil).
    init(store: AlbumStore) {
        self.store = store
    }

    /// Whether the album has been grouped yet (tests: `init` must not do it).
    var hasDerivedData: Bool { derivedRevision >= 0 }

    // MARK: Derived data

    private struct Derived {
        var days: [DayGroup] = []
        var dayIndex: [DayKey: Int] = [:]
        var undated: [Photo] = []
        var selectedPerDay: [DayKey: Int] = [:]
        var undatedSelected = 0
        var totalSelected = 0
        /// What the page estimate depends on: the selected photos and their days.
        var selectionDays: [PhotoID: DayKey?] = [:]
        /// Filled lazily per day (only when "Jen doporučené" is on).
        var recommended: [DayKey: Set<PhotoID>] = [:]
    }

    private struct PagesKey: Equatable {
        var profileID: String
        var formatID: String
        var selection: [PhotoID: DayKey?]
    }

    @ObservationIgnored private var derivedRevision = -1
    @ObservationIgnored private var derivedCache = Derived()
    @ObservationIgnored private var pagesKey: PagesKey?
    @ObservationIgnored private var pagesCache = 0
    @ObservationIgnored private var formatCache: (key: String, profile: SupplierProfile, format: BookFormat)?

    private var derived: Derived {
        let revision = store.revision // observed: every store change invalidates
        if revision != derivedRevision {
            derivedCache = Self.derive(store.album)
            derivedRevision = revision
        }
        return derivedCache
    }

    private static func derive(_ album: Album) -> Derived {
        var d = Derived()
        var dated: [Photo] = []
        dated.reserveCapacity(album.photos.count)
        for photo in album.photos.values {
            if photo.dayKey != nil { dated.append(photo) } else { d.undated.append(photo) }
            if photo.isSelected {
                d.totalSelected += 1
                d.selectionDays[photo.id] = photo.dayKey
                if let key = photo.dayKey { d.selectedPerDay[key, default: 0] += 1 } else { d.undatedSelected += 1 }
            }
        }
        d.undated.sort(by: Photo.chronological)
        // Stored dayKeys win in DayGrouper, so no zones or places are needed; place names come
        // from the photos' stored `placeName`.
        d.days = DayGrouper.group(dated, timeZones: [:], places: [:])
        for (i, day) in d.days.enumerated() { d.dayIndex[day.dayKey] = i }
        return d
    }

    // MARK: Days

    /// Days ascending (stored `dayKey`s; photos without one are in the "Bez data" entry).
    var days: [DayGroup] { derived.days }

    /// The day list: every day, then "Bez data" when some photos have no day.
    var dayEntries: [DayEntry] {
        let d = derived
        var entries = d.days.map { day in
            let selected = d.selectedPerDay[day.dayKey] ?? 0
            return DayEntry(id: .day(day.dayKey),
                            label: TriageText.dayLabel(day.dayKey, placeNames: day.placeNames,
                                                       selected: selected, total: day.photos.count),
                            accessibilityLabel: TriageText.dayAccessibilityLabel(
                                day.dayKey, placeNames: day.placeNames, selected: selected,
                                total: day.photos.count),
                            selected: selected, total: day.photos.count)
        }
        if !d.undated.isEmpty {
            let label = TriageText.undatedLabel(selected: d.undatedSelected, total: d.undated.count)
            entries.append(DayEntry(id: .undated, label: label,
                                    accessibilityLabel: "\(TriageText.undated), vybráno \(d.undatedSelected) z \(d.undated.count)",
                                    selected: d.undatedSelected, total: d.undated.count))
        }
        return entries
    }

    /// `currentEntry` if it still exists, else the first entry.
    var visibleEntry: DayEntryID? {
        let ids = dayEntries.map(\.id)
        if let currentEntry, ids.contains(currentEntry) { return currentEntry }
        return ids.first
    }

    func selectedCount(day: DayKey) -> Int { derived.selectedPerDay[day] ?? 0 }

    /// All selected photos of the album (the footer count).
    var selectedTotal: Int { derived.totalSelected }

    // MARK: Grid items

    func photos(for day: DayKey) -> [TriageItem] { items(for: .day(day)) }

    /// The grid of an entry: chronological; a series of 2+ shown photos takes the place of its
    /// earliest member and shows only its head (best `PhotoScore.score`, ties by `capturedAt`, then
    /// id) unless expanded, then the head followed by the other members chronologically.
    /// With `showOnlyRecommended`, only selected or recommended photos are shown (series counts
    /// then refer to the shown members).
    func items(for entry: DayEntryID) -> [TriageItem] {
        let d = derived
        let onlyRecommended = showOnlyRecommended
        let expanded = expandedSeries
        var photos: [Photo]
        switch entry {
        case .day(let key):
            guard let index = d.dayIndex[key] else { return [] }
            photos = d.days[index].photos
            if onlyRecommended {
                let recommended = recommended(for: key)
                photos = photos.filter { $0.isSelected || recommended.contains($0.id) }
            }
        case .undated:
            photos = d.undated
            if onlyRecommended { photos = photos.filter(\.isSelected) }
        }
        return Self.items(photos, expanded: expanded)
    }

    /// `Recommender.recommend` for the day with series from the photos' `seriesID`, cached until
    /// the album changes.
    private func recommended(for key: DayKey) -> Set<PhotoID> {
        _ = derived
        if let cached = derivedCache.recommended[key] { return cached }
        guard let index = derivedCache.dayIndex[key] else { return [] }
        let day = derivedCache.days[index]
        var members: [String: [PhotoID]] = [:]
        var order: [String] = []
        for photo in day.photos {
            guard let s = photo.seriesID else { continue }
            if members[s] == nil { order.append(s) }
            members[s, default: []].append(photo.id)
        }
        let series = order.compactMap { s in
            members[s].flatMap { $0.count >= 2 ? Series(id: s, photoIDs: $0) : nil }
        }
        let result = Recommender.recommend(day: day, series: series)
        derivedCache.recommended[key] = result
        return result
    }

    private static func items(_ photos: [Photo], expanded: Set<String>) -> [TriageItem] {
        var groups: [String: [Photo]] = [:]
        for photo in photos { if let s = photo.seriesID { groups[s, default: []].append(photo) } }
        var result: [TriageItem] = []
        result.reserveCapacity(photos.count)
        var emitted = Set<String>()
        for photo in photos {
            guard let s = photo.seriesID, let group = groups[s], group.count >= 2 else {
                result.append(TriageItem(photo: photo, isSeriesHead: false, seriesCount: 1,
                                         seriesSelectedCount: 0, isExpanded: false,
                                         badges: badges(photo, duplicate: false)))
                continue
            }
            guard emitted.insert(s).inserted else { continue }
            let head = group.min(by: better)!
            let selected = group.reduce(0) { $0 + ($1.isSelected ? 1 : 0) }
            let isExpanded = expanded.contains(s)
            result.append(TriageItem(photo: head, isSeriesHead: true, seriesCount: group.count,
                                     seriesSelectedCount: selected, isExpanded: isExpanded,
                                     badges: badges(head, duplicate: false)))
            if isExpanded {
                for member in group where member.id != head.id {
                    result.append(TriageItem(photo: member, isSeriesHead: false, seriesCount: group.count,
                                             seriesSelectedCount: selected, isExpanded: true,
                                             badges: badges(member, duplicate: true)))
                }
            }
        }
        return result
    }

    /// Series head order: higher score first, then earlier, then smaller id.
    private static func better(_ a: Photo, _ b: Photo) -> Bool {
        let sa = PhotoScore.score(a), sb = PhotoScore.score(b)
        if sa != sb { return sa > sb }
        return (a.capturedAt, a.id) < (b.capturedAt, b.id)
    }

    /// From the stored analysis (no extra Core API needed): sharpness under the Core defect
    /// threshold => blurred; `closedEyes`; `isUtility` => screenshot; videos; a non-head series
    /// member => duplicate; a SELECTED photo whose original is not stored yet => cloud (downloads
    /// are Task 23; this only shows the state).
    static func badges(_ photo: Photo, duplicate: Bool) -> [Badge] {
        var result: [Badge] = []
        if photo.kind == .video { result.append(.video) }
        if let a = photo.analysis {
            if a.sharpness < PhotoScore.defectiveSharpness { result.append(.blurred) }
            if a.closedEyes { result.append(.closedEyes) }
            if a.isUtility { result.append(.screenshot) }
        }
        if duplicate { result.append(.duplicate) }
        if photo.isSelected {
            if case .stored = photo.originalState {} else { result.append(.cloud) }
        }
        return result
    }

    func toggleSeries(_ seriesID: String) {
        if expandedSeries.contains(seriesID) { expandedSeries.remove(seriesID) } else { expandedSeries.insert(seriesID) }
    }

    // MARK: Pages

    /// Pages of a first draft (`AlbumDrafter.draft`) of the current selection: an estimate, also
    /// once the album has spreads. Recomputed only when the selection, a selected photo's day or
    /// the format changes (not on analysis flushes).
    var estimatedPages: Int {
        let d = derived
        let album = store.album
        let key = PagesKey(profileID: album.supplierProfileID, formatID: album.formatID, selection: d.selectionDays)
        if key == pagesKey { return pagesCache }
        var pages = 0
        if d.totalSelected > 0, let (profile, format) = format(of: album) {
            let draft = AlbumDrafter.draft(album: album, days: d.days, profile: profile, format: format)
            pages = AlbumDrafter.pageCount(of: draft)
        }
        pagesKey = key
        pagesCache = pages
        return pages
    }

    /// The page count the footer shows: the album's actual pages (`spreads.count * 2`) once it has
    /// spreads, else the draft estimate.
    var pageCount: Int {
        let spreads = store.album.spreads.count
        return spreads > 0 ? spreads * 2 : estimatedPages
    }

    /// Whether `pageCount` is the estimate (no spreads yet).
    var pagesAreEstimated: Bool { store.album.spreads.isEmpty }

    /// "Vybráno 148 fotek · odhad 36 stran", or "… · 36 stran" once the album has spreads.
    var footerText: String {
        TriageText.footer(selected: selectedTotal, pages: pageCount, estimated: pagesAreEstimated)
    }

    /// The album's profile and format, read from the catalog once per format.
    private func format(of album: Album) -> (SupplierProfile, BookFormat)? {
        let key = album.supplierProfileID + "/" + album.formatID
        if let formatCache, formatCache.key == key { return (formatCache.profile, formatCache.format) }
        do {
            let (profile, format) = try ProfileCatalog.format(profileID: album.supplierProfileID,
                                                              formatID: album.formatID)
            formatCache = (key, profile, format)
            return (profile, format)
        } catch {
            Logger.triage.error("Unknown format \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Edits

    /// Selects or deselects one photo (videos: nothing). See the type comment for the two paths.
    func toggleSelection(_ id: PhotoID) {
        let album = store.album
        guard let photo = album.photos[id], photo.kind != .video else { return }
        let select = !photo.isSelected
        if !album.spreads.isEmpty, let (profile, format) = format(of: album) {
            let updated = select
                ? AlbumUpdater.photoSelected(id, in: album, geometry: PageGeometry(format: format, profile: profile))
                : AlbumUpdater.photoDeselected(id, in: album)
            // `photoSelected` leaves a photo without a day unchanged: select it plainly then.
            if updated != album {
                store.replace(album: updated, actionName: AlbumStore.actionName(for: .setSelected(id, select)),
                              undoManager: undoManager)
                return
            }
        }
        do {
            try store.apply(.setSelected(id, select), undoManager: undoManager)
        } catch {
            Logger.triage.error("Selection of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Moves a photo to another day (undoable); the grids regroup. Its own day: nothing.
    ///
    /// Once the album has spreads, a selected photo placed in journal/gallery spreads that are all
    /// NOT manually edited follows into the new day's layout: one `store.replace` of
    /// `AlbumUpdater.photoMoved` (it leaves its day spread and goes into the new day like a newly
    /// selected photo; intro, closing and cover keep it). If any such spread is manually edited,
    /// the layout is the user's: only the day changes (`setPhotoDay`) and the editor shows the
    /// photo where it is.
    func move(_ id: PhotoID, to day: DayKey) {
        let album = store.album
        guard let photo = album.photos[id], photo.dayKey != day else { return }
        let holders = album.spreads.filter { spread in
            (spread.kind == .journal || spread.kind == .gallery) && spread.frames.contains { $0.photoID == id }
        }
        if photo.isSelected, !holders.isEmpty, !holders.contains(where: \.manuallyEdited),
           let (profile, format) = format(of: album) {
            let updated = AlbumUpdater.photoMoved(id, to: day, in: album,
                                                  geometry: PageGeometry(format: format, profile: profile))
            store.replace(album: updated, actionName: AlbumStore.actionName(for: .setPhotoDay(id, day)),
                          undoManager: undoManager)
            return
        }
        do {
            try store.apply(.setPhotoDay(id, day), undoManager: undoManager)
        } catch {
            Logger.triage.error("Move of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension Logger {
    static let triage = Logger(subsystem: "com.stratkoss.leporelo", category: "Triage")
}
