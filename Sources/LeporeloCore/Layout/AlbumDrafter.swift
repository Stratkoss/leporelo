import Foundation

public struct DraftOptions: Sendable, Equatable {
    public var includeClosing: Bool
    /// Photos per gallery spread before padding (clamped to the gallery templates, 1...3).
    public var galleryPhotosPerSpread: Int

    public init(includeClosing: Bool = true, galleryPhotosPerSpread: Int = 2) {
        self.includeClosing = includeClosing
        self.galleryPhotosPerSpread = galleryPhotosPerSpread
    }
}

/// Builds a first draft of the album from the selected photos (spec 6.3).
///
/// Pure and deterministic: photo order ties are broken by `capturedAt`, then `id`, and spread ids
/// are derived from the spread's role (`intro`, `closing`, `2026-06-18-journal`,
/// `2026-06-18-gallery-2`, `blank-1`, `cover-front`, `cover-back`).
///
/// Invariant: no spread other than `blank` has an empty frame (preflight blocks empty frames).
public enum AlbumDrafter {
    public static let noPlaceTitle = "Bez místa"

    public static func pageCount(of album: Album) -> Int {
        album.spreads.count * 2
    }

    public static func draft(album: Album, days: [DayGroup], profile: SupplierProfile, format: BookFormat,
                             options: DraftOptions = .init()) -> Album {
        draft(album: album, days: days, profile: profile, format: format, options: options,
              includeIntro: true, reservedSpreads: 0)
    }

    /// `draft` with two knobs for `AlbumUpdater.redraft`: `includeIntro: false` plans no intro
    /// spread (the cover is still built), and `reservedSpreads` counts spreads the caller will add
    /// (kept manual spreads) when padding to the page-count rule.
    static func draft(album: Album, days: [DayGroup], profile: SupplierProfile, format: BookFormat,
                      options: DraftOptions, includeIntro: Bool, reservedSpreads: Int) -> Album {
        var result = album
        result.supplierProfileID = profile.id
        result.formatID = format.id

        // Selected photos per day, using the album's copy of each photo (its selection state wins).
        var seen: Set<PhotoID> = []
        var selectedDays: [(group: DayGroup, photos: [Photo])] = []
        for group in days.sorted(by: { $0.dayKey < $1.dayKey }) {
            let photos = group.photos
                .map { album.photos[$0.id] ?? $0 }
                .filter { $0.isSelected && seen.insert($0.id).inserted }
                .sorted(by: Photo.chronological)
            if !photos.isEmpty { selectedDays.append((group, photos)) }
        }
        let allSelected = selectedDays.flatMap(\.photos)
        // Nothing to lay out: an empty draft rather than empty frames. Note for callers (e.g. a
        // redraft): an empty selection CLEARS the cover and all spreads and yields 0 pages.
        guard let lastPhoto = allSelected.last else {
            result.spreads = []
            result.cover = nil
            return result
        }
        let ranked = allSelected.sorted(by: rank)
        let introPhoto = ranked.first(where: \.isLandscape) ?? ranked[0]

        // 1. Plan the spreads.
        var plan: [Planned] = []
        let introBody = self.introBody(selectedDays.map(\.group))
        if includeIntro {
            plan.append(Planned(templateID: "intro-1", dayKey: nil, photos: [introPhoto],
                                texts: [.title: album.title, .body: introBody]))
        }

        let perGallery = min(max(options.galleryPhotosPerSpread, 1), 3)
        for (group, photos) in selectedDays {
            plan += planDay(group, photos: photos, perGallery: perGallery)
        }
        if options.includeClosing {
            plan.append(Planned(templateID: "closing-1", dayKey: nil, photos: [lastPhoto], texts: [.caption: ""]))
        }

        // 2. Pad to the supplier's page-count rule.
        pad(&plan, rule: profile.pageCount, hasClosing: options.includeClosing, reserved: reservedSpreads)

        // 3. Instantiate templates.
        let geometry = PageGeometry(format: format, profile: profile)
        result.spreads = instantiate(plan, geometry: geometry)
        result.cover = cover(title: album.title, photoID: introPhoto.id, format: format, profile: profile)
        return result
    }

    // MARK: - Planning

    private struct Planned {
        var templateID: String
        var dayKey: DayKey?
        var photos: [Photo]
        var texts: [TextRole: String]

        var kind: SpreadKind { TemplateCatalog.template(id: templateID)!.kind }
    }

    /// Best score first; ties by `capturedAt`, then `id`.
    private static func rank(_ a: Photo, _ b: Photo) -> Bool {
        let sa = PhotoScore.score(a), sb = PhotoScore.score(b)
        if sa != sb { return sa > sb }
        return Photo.chronological(a, b)
    }

    /// Journal with the day's N best-scoring photos (N = 3...5), then the rest chronologically in
    /// galleries. The journal takes the best photos (not the first N) because the spec wants the
    /// day's best photo in the big frame; as a consequence gallery photos may be earlier in time
    /// than some journal photos.
    ///
    /// A day with only 1-2 selected photos gets gallery-only spreads (no journal): every journal
    /// template has at least 3 frames and a journal must not have empty frames. The date and place
    /// go into the first gallery's caption instead.
    private static func planDay(_ group: DayGroup, photos: [Photo], perGallery: Int) -> [Planned] {
        let key = group.dayKey
        let title = group.placeNames.isEmpty ? noPlaceTitle : group.placeNames.joined(separator: ", ")
        var spreads: [Planned] = []
        var rest = photos
        if photos.count >= 3 {
            let n = min(5, max(3, photos.count))
            let journal = Array(photos.sorted(by: rank).prefix(n))
            let ids = Set(journal.map(\.id))
            rest = photos.filter { !ids.contains($0.id) }
            spreads.append(Planned(templateID: "journal-\(n)", dayKey: key, photos: journal,
                                   texts: [.date: czechDate(key), .title: title, .body: ""]))
        }
        var start = 0
        while start < rest.count {
            let chunk = Array(rest[start..<min(start + perGallery, rest.count)])
            let caption = spreads.isEmpty ? dayCaption(key, placeNames: group.placeNames) : ""
            spreads.append(Planned(templateID: "gallery-\(chunk.count)", dayKey: key, photos: chunk,
                                   texts: [.caption: caption]))
            start += perGallery
        }
        return spreads
    }

    /// Pages = spreads x 2. While the rule is not met: first peel the last photo off a multi-photo
    /// gallery into a new gallery-1 right after it (more spreads, no empty frames); when no gallery
    /// can be split, insert a `blank` spread before the closing spread.
    ///
    /// If the draft already has more pages than the rule's maximum, content is not deleted: the
    /// loop stops and the preflight reports the page count to the user.
    private static func pad(_ plan: inout [Planned], rule: PageCountRule, hasClosing: Bool, reserved: Int) {
        while !rule.isSatisfied(by: (plan.count + reserved) * 2) {
            if let max = rule.max, (plan.count + reserved) * 2 > max { return }
            if let i = plan.firstIndex(where: { $0.kind == .gallery && $0.photos.count > 1 }) {
                let photo = plan[i].photos.removeLast()
                plan[i].templateID = "gallery-\(plan[i].photos.count)"
                plan.insert(Planned(templateID: "gallery-1", dayKey: plan[i].dayKey, photos: [photo],
                                    texts: [.caption: ""]), at: i + 1)
            } else {
                let blank = Planned(templateID: "blank", dayKey: nil, photos: [], texts: [:])
                plan.insert(blank, at: hasClosing ? plan.count - 1 : plan.count)
            }
        }
    }

    // MARK: - Instantiation

    private static func instantiate(_ plan: [Planned], geometry: PageGeometry) -> [Spread] {
        var counters: [String: Int] = [:]
        return plan.map { item in
            let template = TemplateCatalog.template(id: item.templateID)!
            let id = spreadID(item, counters: &counters)
            var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: item.dayKey, id: id)
            let assignment = assign(template.frames, photos: item.photos)
            for i in spread.frames.indices {
                spread.frames[i].photoID = assignment[spread.frames[i].id]
            }
            for (role, text) in item.texts {
                if let i = spread.texts.firstIndex(where: { $0.role == role }) {
                    spread.texts[i].text = text
                }
            }
            return spread
        }
    }

    private static func spreadID(_ item: Planned, counters: inout [String: Int]) -> String {
        switch item.kind {
        case .intro: return "intro"
        case .closing: return "closing"
        case .blank:
            counters["blank", default: 0] += 1
            return "blank-\(counters["blank"]!)"
        case .journal, .gallery:
            let base = "\(dayString(item.dayKey))-\(item.kind.rawValue)"
            counters[base, default: 0] += 1
            return item.kind == .journal && counters[base] == 1 ? base : "\(base)-\(counters[base]!)"
        }
    }

    /// Frame id -> photo id. Frames are visited in priority order:
    /// - the main frame (priority 0) takes the best remaining photo of matching orientation, or, if
    ///   none matches, the best remaining photo outright, before any other frame is filled;
    /// - pass 1: every other oriented frame takes the best remaining photo of matching orientation;
    /// - pass 2: frames still empty (`.any` frames and frames with no match) take the best remaining
    ///   photo. No frame stays empty while photos remain.
    static func assign(_ slots: [FrameSlot], photos: [Photo]) -> [String: PhotoID] {
        var remaining = photos.sorted(by: rank)
        let ordered = slots.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        var result: [String: PhotoID] = [:]
        if let main = ordered.first, main.priority == 0, !remaining.isEmpty {
            let i = remaining.firstIndex(where: { fits($0, main.orientation) }) ?? 0
            result[main.id] = remaining.remove(at: i).id
        }
        for slot in ordered where slot.orientation != .any && result[slot.id] == nil {
            if let i = remaining.firstIndex(where: { fits($0, slot.orientation) }) {
                result[slot.id] = remaining.remove(at: i).id
            }
        }
        for slot in ordered where result[slot.id] == nil && !remaining.isEmpty {
            result[slot.id] = remaining.removeFirst().id
        }
        return result
    }

    static func fits(_ photo: Photo, _ orientation: Orientation) -> Bool {
        switch orientation {
        case .any: return true
        case .landscape: return photo.pixelWidth > photo.pixelHeight
        case .portrait: return photo.pixelHeight > photo.pixelWidth
        }
    }

    /// Template id of the front cover. NOT a `TemplateCatalog` id: catalog templates are two-page
    /// spreads and the cover is a single page. Code that rebuilds the album (Task 9, AlbumUpdater)
    /// must rebuild `album.cover` through `cover(title:photoID:format:profile:)`, not the catalog.
    public static let coverFrontTemplateID = "cover-front"

    /// The cover for `format`, built directly from the page size (one page, origin 0,0).
    /// Front: the photo fills the page (bleed is added by the exporter) and the title sits near the
    /// top inside the safe zone. Back: blank. Used by `draft` and by anything that rebuilds the cover.
    public static func cover(title: String, photoID: PhotoID?, format: BookFormat,
                             profile: SupplierProfile) -> Cover {
        let w = format.pageWidthMM, h = format.pageHeightMM
        let safe = Rect(x: 0, y: 0, width: w, height: h).insetBy(profile.safeMM)
        let x = max(0.1 * w, safe.minX), y = max(0.08 * h, safe.minY)
        let titleRect = Rect(x: x, y: y, width: min(0.8 * w, safe.maxX - x),
                             height: min(0.14 * h, safe.maxY - y))
        let front = Spread(
            id: "cover-front", kind: .intro, templateID: coverFrontTemplateID, dayKey: nil,
            frames: [Frame(id: "photo1", rect: Rect(x: 0, y: 0, width: w, height: h), photoID: photoID,
                           offset: Point(x: 0, y: 0), zoom: 1)],
            texts: [TextBox(id: "title", rect: titleRect, role: .title, text: title)],
            manuallyEdited: false)
        let back = Spread(id: "cover-back", kind: .blank, templateID: "blank", dayKey: nil,
                          frames: [], texts: [], manuallyEdited: false)
        return Cover(front: front, back: back)
    }

    // MARK: - Texts

    /// "2026-06-18" (or "day" without a day): the day part of journal and gallery spread ids.
    static func dayString(_ key: DayKey?) -> String {
        key.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } ?? "day"
    }

    /// Caption of the first spread of a day that has no journal: "čtvrtek 18. června 2026, Ravello".
    static func dayCaption(_ key: DayKey, placeNames: [String]) -> String {
        czechDate(key) + (placeNames.isEmpty ? "" : ", " + placeNames.joined(separator: ", "))
    }

    /// Intro body: the date range of `days` (ascending), then their places in order of first
    /// occurrence. Empty for no days.
    static func introBody(_ days: [DayGroup]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        var places: [String] = []
        for group in days {
            for name in group.placeNames where !places.contains(name) { places.append(name) }
        }
        var body = dateRange(first.dayKey, last.dayKey)
        if !places.isEmpty { body += "\n" + places.joined(separator: ", ") }
        return body
    }

    /// "čtvrtek 18. června 2026" for the DayKey itself, independent of the Mac's time zone.
    public static func czechDate(_ key: DayKey) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: key.year, month: key.month, day: key.day, hour: 12))!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d. MMMM yyyy"
        return formatter.string(from: date)
    }

    /// "18. 6. – 19. 6. 2026"; one day: "18. 6. 2026"; across years: "30. 12. 2025 – 2. 1. 2026".
    static func dateRange(_ first: DayKey, _ last: DayKey) -> String {
        func dm(_ k: DayKey) -> String { "\(k.day). \(k.month)." }
        if first == last { return "\(dm(first)) \(first.year)" }
        if first.year == last.year { return "\(dm(first)) – \(dm(last)) \(last.year)" }
        return "\(dm(first)) \(first.year) – \(dm(last)) \(last.year)"
    }
}
