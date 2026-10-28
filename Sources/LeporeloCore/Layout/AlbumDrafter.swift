import Foundation

public struct DraftOptions: Sendable, Equatable {
    public var includeClosing: Bool
    /// The page planner's target photos per page (at least 1). Above the supplier's page maximum the
    /// days are planned again with `AlbumDrafter.denserTargets`.
    public var photosPerPage: Int
    /// How strongly the design prefers each layout (the user's liked layouts, spec 6).
    public var layoutWeights: LayoutWeights

    public init(includeClosing: Bool = true, photosPerPage: Int = 3, layoutWeights: LayoutWeights = .init()) {
        self.includeClosing = includeClosing
        self.photosPerPage = photosPerPage
        self.layoutWeights = layoutWeights
    }
}

/// Builds a first draft of the album from the selected photos (spec 6.3; pages: page-layouts spec 4).
///
/// Pure and deterministic: photo order ties are broken by `capturedAt`, then `id`, and spread ids
/// are derived from the spread's role (`intro`, `closing`, `2026-06-18-journal`,
/// `2026-06-18-gallery-2`, `blank-1`, `cover-front`, `cover-back`).
///
/// Each day is planned page by page (`PagePlanner.planDay`, hero candidates computed once from the
/// whole selection without the intro, closing and cover photos) and its pages are paired into
/// spreads (`PageSpread.compose`): the first spread is the day's `journal` when it starts with an
/// opener page, the others are `gallery`.
///
/// Invariant: no spread other than `blank` has an empty frame (preflight blocks empty frames).
/// Videos are never laid out (only `.photo`/`.livePhoto` kinds), even when selected.
///
/// Page maximum: when the planned spreads (intro, days, closing and `reservedSpreads`) exceed the
/// profile's `pageCount.max`, all days are planned again with 4, then 5 photos per page; nothing is
/// dropped, so a very long trip can still be above the maximum (the preflight reports it).
public enum AlbumDrafter {
    public static let noPlaceTitle = "Bez místa"
    /// Targets tried in order, after `DraftOptions.photosPerPage`, while the plan exceeds the maximum.
    static let denserTargets = [4, 5]

    public static func pageCount(of album: Album) -> Int {
        album.spreads.count * 2
    }

    public static func draft(album: Album, days: [DayGroup], profile: SupplierProfile, format: BookFormat,
                             options: DraftOptions = .init()) -> Album {
        draft(album: album, days: days, profile: profile, format: format, options: options,
              includeIntro: true, reservedSpreads: 0)
    }

    /// `draft` with knobs for `AlbumUpdater.redraft`:
    /// - `includeIntro: false` plans no intro spread (the cover is still built);
    /// - `reservedSpreads` counts spreads the caller will add (kept manual spreads) when padding;
    /// - `excludedFromDays`: photos that per-day planning skips. The intro, closing and cover
    ///   photos, the hero candidates, the intro body and the empty-selection guard still use the
    ///   FULL selection. A day left with no photos gets no spreads;
    /// - `galleryOnlyDays`: days planned without an opener page (so only `gallery` spreads, all
    ///   texts empty).
    static func draft(album: Album, days: [DayGroup], profile: SupplierProfile, format: BookFormat,
                      options: DraftOptions, includeIntro: Bool, reservedSpreads: Int,
                      excludedFromDays: Set<PhotoID> = [], galleryOnlyDays: Set<DayKey> = []) -> Album {
        var result = album
        result.supplierProfileID = profile.id
        result.formatID = format.id

        // Selected photos per day, using the album's copy of each photo (its selection state wins).
        var seen: Set<PhotoID> = []
        var selectedDays: [(group: DayGroup, photos: [Photo])] = []
        for group in days.sorted(by: { $0.dayKey < $1.dayKey }) {
            let photos = group.photos
                .map { album.photos[$0.id] ?? $0 }
                .filter { $0.isSelected && $0.kind != .video && seen.insert($0.id).inserted }
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
        // The intro photo is also the cover photo, so it is never a hero, even without an intro.
        // These photos never get a whole page in a day, not even as a rescue page (spec 4.2).
        let notFull: Set<PhotoID> = options.includeClosing ? [introPhoto.id, lastPhoto.id] : [introPhoto.id]
        let heroes = PagePlanner.heroCandidates(allSelected, excluding: notFull)
        let weights = options.layoutWeights

        // 1. Plan the days. When the book has more pages than the supplier's maximum, plan every
        //    day again with a denser target. Still too many pages: leave it, the preflight reports it.
        let start = max(1, options.photosPerPage)
        var plans = selectedDays.compactMap { group, photos -> DayPlan? in
            let dayPhotos = photos.filter { !excludedFromDays.contains($0.id) }
            if dayPhotos.isEmpty { return nil }
            return DayPlan(group: group, photos: dayPhotos, opener: !galleryOnlyDays.contains(group.dayKey),
                           notFull: notFull)
                .planned(target: start, heroes: heroes, weights: weights)
        }
        let fixedSpreads = (includeIntro ? 1 : 0) + (options.includeClosing ? 1 : 0) + reservedSpreads
        func pages(_ plans: [DayPlan]) -> Int {
            (fixedSpreads + plans.map { ($0.pages.count + 1) / 2 }.reduce(0, +)) * 2
        }
        let rule = profile.pageCount
        if let max = rule.max {
            for target in denserTargets where target > start && pages(plans) > max {
                plans = plans.map { $0.planned(target: target, heroes: heroes, weights: weights) }
            }
        }

        // 2. Pad to the supplier's page-count rule: split pages of the densest days, then add
        //    blank spreads before the closing.
        var blanks = 0
        while !rule.isSatisfied(by: pages(plans) + blanks * 2) {
            let count = pages(plans) + blanks * 2
            if let max = rule.max, count > max { break }
            if rule.max.map({ count + 2 > $0 }) ?? false || !grow(&plans, weights: weights) {
                blanks += 1
            }
        }

        // 3. Build the spreads.
        let geometry = PageGeometry(format: format, profile: profile)
        let margin = album.marginMM
        var spreads: [Spread] = []
        if includeIntro {
            spreads.append(templateSpread("intro-1", id: "intro", photos: [introPhoto],
                                          texts: [.title: album.title, .body: introBody(selectedDays.map(\.group))],
                                          geometry: geometry, marginMM: margin))
        }
        for plan in plans {
            spreads += daySpreads(plan.pages, dayKey: plan.group.dayKey, placeNames: plan.group.placeNames,
                                  geometry: geometry, marginMM: margin)
        }
        for k in stride(from: 1, through: blanks, by: 1) {
            spreads.append(templateSpread("blank", id: "blank-\(k)", photos: [], texts: [:],
                                          geometry: geometry, marginMM: margin))
        }
        if options.includeClosing {
            spreads.append(templateSpread("closing-1", id: "closing", photos: [lastPhoto], texts: [.caption: ""],
                                          geometry: geometry, marginMM: margin))
        }
        result.spreads = spreads
        result.cover = cover(title: album.title, photoID: introPhoto.id, format: format, profile: profile,
                             marginMM: margin)
        return result
    }

    // MARK: - Planning

    /// One day's photos (chronological) and its planned pages.
    private struct DayPlan {
        var group: DayGroup
        var photos: [Photo]
        var opener: Bool
        /// The intro and closing photos: never on a `full` page.
        var notFull: Set<PhotoID>
        var pages: [PlannedPage] = []

        func planned(target: Int, heroes: Set<PhotoID>, weights: LayoutWeights) -> DayPlan {
            var plan = self
            plan.pages = PagePlanner.planDay(photos, heroCandidates: heroes, opener: opener, target: target,
                                             weights: weights, excluding: notFull)
            return plan
        }

        /// Photos per page, not counting the opener and `full` pages; 0 without such pages.
        var density: Double {
            let ordinary = pages.filter {
                $0.layoutID != "full" && PageLayoutCatalog.layout(id: $0.layoutID)?.role != .opener
            }
            return ordinary.isEmpty ? 0 : Double(ordinary.map(\.photos.count).reduce(0, +)) / Double(ordinary.count)
        }
    }

    /// Best score first; ties by `capturedAt`, then `id` (shared with the frame assignment).
    private static func rank(_ a: Photo, _ b: Photo) -> Bool { TemplateLayout.rank(a, b) }

    /// Padding (spec 4.3): the day with the most photos per page (ties: the earlier day) among the
    /// days that can still grow gets exactly 2 more pages (`PagePlanner.expand`, which splits its
    /// fullest pages). False when no day can grow.
    private static func grow(_ plans: inout [DayPlan], weights: LayoutWeights) -> Bool {
        let order = plans.indices.sorted { a, b in
            let da = plans[a].density, db = plans[b].density
            return da != db ? da > db : a < b
        }
        for i in order {
            if let pages = PagePlanner.expand(plans[i].pages, by: 2, weights: weights, excluding: plans[i].notFull) {
                plans[i].pages = pages
                return true
            }
        }
        return false
    }

    // MARK: - Instantiation

    /// A spread from a `TemplateCatalog` template (intro, closing, blank), photos assigned by score.
    private static func templateSpread(_ templateID: String, id: String, photos: [Photo], texts: [TextRole: String],
                                       geometry: PageGeometry, marginMM: Double) -> Spread {
        let template = TemplateCatalog.template(id: templateID)!
        var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: nil, id: id, marginMM: marginMM)
        let assignment = TemplateLayout.assign(template.frames, photos: photos)
        for i in spread.frames.indices {
            spread.frames[i].photoID = assignment[spread.frames[i].id]
        }
        for (role, text) in texts {
            if let i = spread.texts.firstIndex(where: { $0.role == role }) {
                spread.texts[i].text = text
            }
        }
        return spread
    }

    /// The day's pages paired into spreads (left, right; an odd last page gets an `empty` right
    /// page); frame `L.photoK` / `R.photoK` gets the page's K-th photo. The first spread is the
    /// `journal` when it starts with an opener page, whose texts get the day's date and places
    /// (`noPlaceTitle` without places; body empty); every other spread is a `gallery` and all other
    /// texts (captions) stay empty. Ids: `2026-06-18-journal`, then `2026-06-18-gallery-1`,
    /// `-gallery-2`, ... Shared with `AlbumUpdater`, which re-plans a day after a new photo.
    static func daySpreads(_ pages: [PlannedPage], dayKey key: DayKey, placeNames: [String],
                           geometry: PageGeometry, marginMM: Double) -> [Spread] {
        let base = dayString(key)
        let title = placeNames.isEmpty ? noPlaceTitle : placeNames.joined(separator: ", ")
        let empty = PlannedPage(layoutID: "empty", photos: [])
        var galleries = 0
        return stride(from: 0, to: pages.count, by: 2).map { i in
            let left = pages[i]
            let right = i + 1 < pages.count ? pages[i + 1] : empty
            let journal = i == 0 && PageLayoutCatalog.layout(id: left.layoutID)?.role == .opener
            let id: String
            if journal {
                id = "\(base)-journal"
            } else {
                galleries += 1
                id = "\(base)-gallery-\(galleries)"
            }
            var spread = PageSpread.compose(left: PageLayoutCatalog.layout(id: left.layoutID)!,
                                            right: PageLayoutCatalog.layout(id: right.layoutID)!,
                                            kind: journal ? .journal : .gallery, dayKey: key, id: id,
                                            geometry: geometry, marginMM: marginMM)
            for (side, page) in [(PageSide.left, left), (.right, right)] {
                for (k, photo) in page.photos.enumerated() {
                    let frameID = PageSpread.prefix(side) + "photo\(k + 1)"
                    if let f = spread.frames.firstIndex(where: { $0.id == frameID }) {
                        spread.frames[f].photoID = photo.id
                    }
                }
            }
            if journal {
                for t in spread.texts.indices {
                    switch spread.texts[t].role {
                    case .date: spread.texts[t].text = czechDate(key)
                    case .title: spread.texts[t].text = title
                    default: break
                    }
                }
            }
            return spread
        }
    }

    /// Template id of the front cover. NOT a `TemplateCatalog` id: catalog templates are two-page
    /// spreads and the cover is a single page. Code that rebuilds the album (Task 9, AlbumUpdater)
    /// must rebuild `album.cover` through `cover(title:photoID:format:profile:)`, not the catalog.
    public static let coverFrontTemplateID = "cover-front"

    /// The cover for `format`, built directly from the page size (one page, origin 0,0).
    /// Front: the photo fills the page inside the margin and the title sits near the
    /// top inside the safe zone. Back: blank. Used by `draft` and by anything that rebuilds the cover.
    /// The result is conformed to `marginMM` (`MarginRule.conform`, area `.cover`).
    public static func cover(title: String, photoID: PhotoID?, format: BookFormat,
                             profile: SupplierProfile, marginMM: Double = Album.defaultMarginMM) -> Cover {
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
        let rule = MarginRule(geometry: PageGeometry(format: format, profile: profile), marginMM: marginMM)
        return Cover(front: rule.conform(front, area: .cover), back: rule.conform(back, area: .cover))
    }

    // MARK: - Texts

    /// "2026-06-18" (or "day" without a day): the day part of journal and gallery spread ids.
    static func dayString(_ key: DayKey?) -> String {
        key.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } ?? "day"
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
