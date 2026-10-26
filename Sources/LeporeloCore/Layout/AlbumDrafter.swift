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

    /// Body slot used when the intro template has none (intro-1 only defines a title), in
    /// normalised spread units, below the title on the left page.
    static let introBodyRect = Rect(x: 0.06, y: 0.60, width: 0.38, height: 0.20)

    public static func pageCount(of album: Album) -> Int {
        album.spreads.count * 2
    }

    public static func draft(album: Album, days: [DayGroup], profile: SupplierProfile, format: BookFormat,
                             options: DraftOptions = .init()) -> Album {
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
        // Nothing to lay out: an empty draft (no intro photo, no cover) rather than empty frames.
        guard let lastPhoto = allSelected.last else {
            result.spreads = []
            result.cover = nil
            return result
        }
        let ranked = allSelected.sorted(by: rank)
        let introPhoto = ranked.first(where: \.isLandscape) ?? ranked[0]

        // 1. Plan the spreads.
        var plan: [Planned] = []
        var places: [String] = []
        for (group, _) in selectedDays {
            for name in group.placeNames where !places.contains(name) { places.append(name) }
        }
        var introBody = dateRange(selectedDays.first!.group.dayKey, selectedDays.last!.group.dayKey)
        if !places.isEmpty { introBody += "\n" + places.joined(separator: ", ") }
        plan.append(Planned(templateID: "intro-1", dayKey: nil, photos: [introPhoto],
                            texts: [.title: album.title, .body: introBody]))

        let perGallery = min(max(options.galleryPhotosPerSpread, 1), 3)
        for (group, photos) in selectedDays {
            plan += planDay(group, photos: photos, perGallery: perGallery)
        }
        if options.includeClosing {
            plan.append(Planned(templateID: "closing-1", dayKey: nil, photos: [lastPhoto], texts: [.caption: ""]))
        }

        // 2. Pad to the supplier's page-count rule.
        pad(&plan, rule: profile.pageCount, hasClosing: options.includeClosing)

        // 3. Instantiate templates.
        let geometry = PageGeometry(format: format, profile: profile)
        result.spreads = instantiate(plan, geometry: geometry)
        result.cover = cover(title: album.title, photo: introPhoto, format: format)
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

    /// Journal with the day's N best photos (N = 3...5), then the rest chronologically in galleries.
    /// A day with fewer than 3 photos cannot fill a journal template without empty frames, so it gets
    /// galleries only and the date and place go into the first gallery's caption.
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
            var caption = ""
            if spreads.isEmpty {
                caption = czechDate(key) + (group.placeNames.isEmpty ? "" : ", " + title)
            }
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
    private static func pad(_ plan: inout [Planned], rule: PageCountRule, hasClosing: Bool) {
        while !rule.isSatisfied(by: plan.count * 2) {
            if let max = rule.max, plan.count * 2 > max { return }
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
                } else if template.kind == .intro && role == .body {
                    let size = geometry.spreadSize
                    let r = introBodyRect
                    spread.texts.append(TextBox(
                        id: "body",
                        rect: Rect(x: r.minX * size.width, y: r.minY * size.height,
                                   width: r.size.width * size.width, height: r.size.height * size.height),
                        role: .body, text: text))
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
            let day = item.dayKey.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } ?? "day"
            let base = "\(day)-\(item.kind.rawValue)"
            counters[base, default: 0] += 1
            return item.kind == .journal && counters[base] == 1 ? base : "\(base)-\(counters[base]!)"
        }
    }

    /// Frame id -> photo id. Pass 1, in priority order: each oriented frame takes the best remaining
    /// photo of matching orientation (so the best fitting photo lands on the main frame). Pass 2:
    /// frames still empty (`.any` frames and frames with no matching photo) take the best remaining
    /// photo. No frame stays empty while photos remain.
    static func assign(_ slots: [FrameSlot], photos: [Photo]) -> [String: PhotoID] {
        var remaining = photos.sorted(by: rank)
        let ordered = slots.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        var result: [String: PhotoID] = [:]
        for slot in ordered where slot.orientation != .any {
            if let i = remaining.firstIndex(where: { fits($0, slot.orientation) }) {
                result[slot.id] = remaining.remove(at: i).id
            }
        }
        for slot in ordered where result[slot.id] == nil && !remaining.isEmpty {
            result[slot.id] = remaining.removeFirst().id
        }
        return result
    }

    private static func fits(_ photo: Photo, _ orientation: Orientation) -> Bool {
        switch orientation {
        case .any: return true
        case .landscape: return photo.pixelWidth > photo.pixelHeight
        case .portrait: return photo.pixelHeight > photo.pixelWidth
        }
    }

    /// Built directly from the page size (one page, origin 0,0) rather than from a catalog template,
    /// because every catalog template is a two-page spread. The photo fills the page (bleed is added
    /// by the exporter); the title sits inside the safe zone near the top.
    private static func cover(title: String, photo: Photo, format: BookFormat) -> Cover {
        let w = format.pageWidthMM, h = format.pageHeightMM
        let front = Spread(
            id: "cover-front", kind: .intro, templateID: "cover-front", dayKey: nil,
            frames: [Frame(id: "photo1", rect: Rect(x: 0, y: 0, width: w, height: h), photoID: photo.id,
                           offset: Point(x: 0, y: 0), zoom: 1)],
            texts: [TextBox(id: "title", rect: Rect(x: 0.1 * w, y: 0.08 * h, width: 0.8 * w, height: 0.14 * h),
                            role: .title, text: title)],
            manuallyEdited: false)
        let back = Spread(id: "cover-back", kind: .blank, templateID: "blank", dayKey: nil,
                          frames: [], texts: [], manuallyEdited: false)
        return Cover(front: front, back: back)
    }

    // MARK: - Texts

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
