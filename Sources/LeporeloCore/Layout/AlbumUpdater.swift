import Foundation

/// Changes to an album after the first "Navrhnout album" (spec 5, "Přegenerování vs. ruční úpravy").
///
/// All functions are pure (album in, album out) and deterministic. Spread ids stay unique and follow
/// the drafter's scheme (`<day>-journal`, `<day>-gallery-N`, `blank-N`, `intro`, `closing`); a new
/// id takes the smallest free N.
///
/// Convention for "marked" frames (spec: a deselected photo "empties its frame and marks it"):
/// an emptied frame is a frame with `photoID == nil` in a non-blank spread. No extra model field;
/// the preflight already reports such frames and the editor can highlight them.
public enum AlbumUpdater {

    // MARK: - Selection

    /// Places a newly selected photo and marks it selected, as a user decision
    /// (`selectionDecidedByUser = true`, so recommendations leave it alone).
    ///
    /// - Unknown photo or photo without `dayKey`: the album is returned unchanged (a photo without a
    ///   day cannot be placed; the user first assigns a day, then selects it again).
    /// - Photo already in a frame of any spread: only `isSelected` is set (idempotent).
    /// - Otherwise it is placed in its day (`place`, spec 4.5) with `weights` (the liked layouts).
    /// - A video is never placed: the album is returned unchanged.
    public static func photoSelected(_ id: PhotoID, in album: Album, geometry: PageGeometry,
                                     weights: LayoutWeights = .init()) -> Album {
        guard let photo = album.photos[id], photo.kind != .video, let key = photo.dayKey else { return album }
        var result = album
        result.photos[id]?.isSelected = true
        result.photos[id]?.selectionDecidedByUser = true
        if result.spreads.contains(where: { $0.frames.contains { $0.photoID == id } }) { return result }
        place(photo, day: key, in: &result, geometry: geometry, weights: weights)
        return result
    }

    /// Moves a photo to another day (triage drag onto a day) once the album has spreads, so it
    /// follows into the new day's layout (Task 20/21 ruling). Pure.
    ///
    /// - Sets `dayKey`. Selection fields are untouched (a move is not a selection decision).
    /// - An unselected photo or a video (or the same day, or an unknown photo) changes nothing else.
    /// - A selected photo leaves every journal/gallery frame that holds it (`photoID = nil`, offset
    ///   0, zoom 1: the "marked" convention) and is placed in the new day exactly like
    ///   `photoSelected` places a new photo (`place`). Intro, closing and cover frames keep it: the
    ///   trip's title photo does not depend on its day, and clearing them would leave empty frames
    ///   for no reason.
    ///
    /// The caller decides about manual work: the app only calls this when no journal/gallery
    /// spread holding the photo is `manuallyEdited` (else it only sets the day).
    public static func photoMoved(_ id: PhotoID, to day: DayKey, in album: Album, geometry: PageGeometry,
                                  weights: LayoutWeights = .init()) -> Album {
        guard var photo = album.photos[id], photo.dayKey != day else { return album }
        var result = album
        result.photos[id]?.dayKey = day
        photo.dayKey = day
        guard photo.isSelected, photo.kind != .video else { return result }
        for s in result.spreads.indices where isDaySpread(result.spreads[s]) {
            for f in result.spreads[s].frames.indices where result.spreads[s].frames[f].photoID == id {
                result.spreads[s].frames[f].photoID = nil
                result.spreads[s].frames[f].offset = Point(x: 0, y: 0)
                result.spreads[s].frames[f].zoom = 1
            }
        }
        place(photo, day: day, in: &result, geometry: geometry, weights: weights)
        return result
    }

    /// `photoSelected`'s placement (spec 4.5, 9). No empty frame is ever created.
    ///
    /// 1. The first empty frame of the day's journal and gallery spreads (album order, frame
    ///    order) whose orientation fits the photo (`slotOrientation`), else any empty one. Filling
    ///    a frame of a manually edited spread does not change its `manuallyEdited`.
    /// 2. Else the day's spreads with `manuallyEdited == false` are planned again with the photo
    ///    (`PagePlanner.planDay` on their photos and the new one; an opener page only when the first
    ///    of them has the day's header, see `hasDayHeader`; hero candidates from the whole
    ///    selection, the intro, closing and cover photos excluded and never on a `full` page).
    ///    The day keeps at least its former page count when the plan can grow
    ///    (`PagePlanner.expand`), so the book does not drop under the supplier's minimum. The new
    ///    spreads take the old ids in order (extra ones a free id of their kind) and all go where
    ///    the last automatic spread of the day was, so manual spreads between them come first
    ///    (spec 9). Old books' template spreads are planned again the same way.
    /// 3. Else (every spread of the day is manual) a new `gallery` after the day's last spread:
    ///    `framed-1` (▭ or square) / `portrait-text` (▯) with the photo on the left, `empty` on the
    ///    right.
    /// A day with no spread yet is planned like step 2 with an opener (`opener-text` and a page
    /// with the photo, texts as in a draft). It is inserted after the last spread of the latest
    /// earlier day, else before the first spread of a later day, else after the intro (i.e.
    /// before blank and closing spreads).
    private static func place(_ photo: Photo, day key: DayKey, in result: inout Album, geometry: PageGeometry,
                              weights: LayoutWeights) {
        let id = photo.id
        let day = result.spreads.indices.filter { isDaySpread(result.spreads[$0]) && result.spreads[$0].dayKey == key }

        // 1. An empty frame of the day.
        let empty = day.flatMap { s in
            result.spreads[s].frames.indices.filter { result.spreads[s].frames[$0].photoID == nil }.map { (s, $0) }
        }
        let fitting = empty.first { s, f in
            TemplateLayout.fits(photo, slotOrientation(result.spreads[s], frameID: result.spreads[s].frames[f].id))
        }
        if let (s, f) = fitting ?? empty.first {
            result.spreads[s].frames[f].photoID = id
            result.spreads[s].frames[f].offset = Point(x: 0, y: 0)
            result.spreads[s].frames[f].zoom = 1
            return
        }

        let auto = day.filter { !result.spreads[$0].manuallyEdited }
        if !day.isEmpty && auto.isEmpty {
            // 3. A new spread after the day's last one.
            let layout = PageLayoutCatalog.layout(id: TemplateLayout.fits(photo, .landscape) ? "framed-1" : "portrait-text")!
            let spreadID = freeID(prefix: "\(AlbumDrafter.dayString(key))-gallery", bareFirst: false,
                                  taken: Set(result.spreads.map(\.id)))
            var spread = PageSpread.compose(left: layout, right: PageLayoutCatalog.layout(id: "empty")!,
                                            kind: .gallery, dayKey: key, id: spreadID, geometry: geometry,
                                            marginMM: result.marginMM)
            spread.frames[0].photoID = id
            result.spreads.insert(spread, at: result.spreads.lastIndex { $0.dayKey == key }! + 1)
            return
        }

        // 2. The day's automatic spreads planned again (or a new day).
        var photos = [photo]
        var seen: Set<PhotoID> = [id]
        for s in auto {
            for photoID in result.spreads[s].frames.compactMap(\.photoID) where seen.insert(photoID).inserted {
                if let p = result.photos[photoID] { photos.append(p) }
            }
        }
        photos.sort(by: Photo.chronological)
        let opener = auto.first.map { hasDayHeader(result.spreads[$0]) } ?? true
        let notFull = titlePhotos(of: result)
        let selection = result.photos.values.filter { $0.isSelected && $0.kind != .video }
        let heroes = PagePlanner.heroCandidates(selection, excluding: notFull)
        var pages = PagePlanner.planDay(photos, heroCandidates: heroes, opener: opener,
                                        target: DraftOptions().photosPerPage, weights: weights, excluding: notFull)
        for extra in stride(from: auto.count * 2 - pages.count, to: 0, by: -2) {
            if let grown = PagePlanner.expand(pages, by: extra, weights: weights, excluding: notFull) {
                pages = grown
                break
            }
        }
        var spreads = AlbumDrafter.daySpreads(pages, dayKey: key, placeNames: placeNames(of: key, in: result),
                                              geometry: geometry, marginMM: result.marginMM)
        let oldIDs = auto.map { result.spreads[$0].id }
        var taken = Set(result.spreads.map(\.id))
        for i in spreads.indices {
            spreads[i].id = i < oldIDs.count ? oldIDs[i] : freeID(for: spreads[i], taken: taken)
            taken.insert(spreads[i].id)
        }

        let index: Int
        if let last = auto.last {
            index = last - (auto.count - 1)
            for s in auto.reversed() { result.spreads.remove(at: s) }
        } else if let prev = result.spreads.lastIndex(where: { $0.dayKey.map { $0 < key } ?? false }) {
            index = prev + 1
        } else if let next = result.spreads.firstIndex(where: { $0.dayKey.map { $0 > key } ?? false }) {
            index = next
        } else if let intro = result.spreads.lastIndex(where: { $0.kind == .intro }) {
            index = intro + 1
        } else {
            index = 0
        }
        result.spreads.insert(contentsOf: spreads, at: index)
    }

    /// Marks the photo unselected (a user decision: `selectionDecidedByUser = true`) and empties every frame holding it (spreads and cover):
    /// `photoID = nil`, offset 0, zoom 1. Spreads are never removed and `manuallyEdited` is left as
    /// is (a deselect is not a manual layout edit). See the type comment for the "marked" convention.
    public static func photoDeselected(_ id: PhotoID, in album: Album) -> Album {
        var result = album
        result.photos[id]?.isSelected = false
        result.photos[id]?.selectionDecidedByUser = true
        func clear(_ spread: inout Spread) {
            for i in spread.frames.indices where spread.frames[i].photoID == id {
                spread.frames[i].photoID = nil
                spread.frames[i].offset = Point(x: 0, y: 0)
                spread.frames[i].zoom = 1
            }
        }
        for i in result.spreads.indices { clear(&result.spreads[i]) }
        if result.cover != nil {
            clear(&result.cover!.front)
            clear(&result.cover!.back)
        }
        return result
    }

    // MARK: - Redraft

    /// "Navrhnout znovu": keeps every spread with `manuallyEdited == true` verbatim (never deleted,
    /// even if all its photos were deselected) and regenerates the rest. `keptManual` is the number
    /// of kept manual spreads, for the confirmation the UI shows first.
    ///
    /// If `format` differs from the album's, the album is first passed through `changeFormat`, so the
    /// kept spreads match the new geometry.
    ///
    /// Generation: the drafter runs on the full selection, but its per-day planning (journals and
    /// galleries) skips the photos already in kept spreads, so those are never placed in another day
    /// spread; the intro, closing and cover photos and the intro body use the full selection (they
    /// may repeat a day photo, as in a first draft). A day left with no photos gets no new spreads.
    /// No intro when a manual intro is kept, no closing when a manual closing is kept or the album
    /// had no closing; the kept spreads are reserved in the drafter's page-count padding (it gives
    /// days more pages / adds blanks before its closing as in a first draft).
    ///
    /// Day headers are not duplicated (spec 4.1): a day with a kept spread that has the day's header
    /// (`hasDayHeader`: a journal, a date or title text, an old gallery's date caption) gets
    /// galleries only (no opener page). New spreads leave every caption empty. `weights` (the liked
    /// layouts) go to the drafter.
    ///
    /// Merge order:
    /// 1. kept manual intro spreads (album order), or else the generated intro;
    /// 2. per day ascending, the day's spreads: journals first, then the others; within each group
    ///    kept spreads (album order) before generated ones (drafter order);
    /// 3. kept spreads without a day that are not intro/closing (e.g. manual blanks), album order;
    /// 4. generated blank spreads;
    /// 5. kept manual closing spreads (album order), or else the generated closing.
    /// A generated spread whose id is taken by a kept spread is renamed with the next free id of
    /// its kind. If the merged album still misses the page-count rule (e.g. every selected photo is
    /// in a kept spread, so nothing was generated), blank spreads are added before a trailing
    /// closing until the rule holds or the maximum would be exceeded.
    ///
    /// Cover: always rebuilt through `AlbumDrafter.cover`, with the existing cover photo if it is
    /// still selected, else the generated cover photo, else the first selected photo; no selected
    /// photo at all means no cover (like the drafter).
    public static func redraft(album: Album, days: [DayGroup], profile: SupplierProfile,
                               format: BookFormat, weights: LayoutWeights = .init()) -> (album: Album, keptManual: Int) {
        let base = album.formatID == format.id && album.supplierProfileID == profile.id
            ? album : changeFormat(album: album, to: format, profile: profile)
        let kept = base.spreads.filter(\.manuallyEdited)
        let keptPhotos = Set(kept.flatMap { $0.frames.compactMap(\.photoID) })
        let hasManualIntro = kept.contains { $0.kind == .intro }
        let hasManualClosing = kept.contains { $0.kind == .closing }
        let hadClosing = base.spreads.isEmpty || base.spreads.contains { $0.kind == .closing }

        let headerDays = Set(kept.filter { isDaySpread($0) && hasDayHeader($0) }.compactMap(\.dayKey))
        let generated = AlbumDrafter.draft(
            album: base, days: days, profile: profile, format: format,
            options: DraftOptions(includeClosing: hadClosing && !hasManualClosing, layoutWeights: weights),
            includeIntro: !hasManualIntro, reservedSpreads: kept.count,
            excludedFromDays: keptPhotos, galleryOnlyDays: headerDays)

        // Merge.
        let gen = generated.spreads
        let isDay: (Spread) -> Bool = { $0.dayKey != nil && $0.kind != .intro && $0.kind != .closing }
        var merged: [Spread] = hasManualIntro ? kept.filter { $0.kind == .intro } : gen.filter { $0.kind == .intro }
        let dayKeys = Set((kept + gen).filter(isDay).compactMap(\.dayKey)).sorted()
        for key in dayKeys {
            let mine = kept.filter { isDay($0) && $0.dayKey == key }
            let theirs = gen.filter { isDay($0) && $0.dayKey == key }
            merged += (mine + theirs).filter { $0.kind == .journal } + (mine + theirs).filter { $0.kind != .journal }
        }
        merged += kept.filter { !isDay($0) && $0.kind != .intro && $0.kind != .closing }
        merged += gen.filter { !isDay($0) && $0.kind != .intro && $0.kind != .closing }
        merged += hasManualClosing ? kept.filter { $0.kind == .closing } : gen.filter { $0.kind == .closing }

        // Unique ids: kept spreads keep theirs, generated ones yield.
        var taken = Set(kept.map(\.id))
        for i in merged.indices where !merged[i].manuallyEdited {
            if taken.contains(merged[i].id) {
                merged[i].id = freeID(for: merged[i], taken: taken)
            }
            taken.insert(merged[i].id)
        }

        // Safety net for the page-count rule.
        let rule = profile.pageCount
        while !rule.isSatisfied(by: merged.count * 2) {
            if let max = rule.max, (merged.count + 1) * 2 > max { break }
            let blankID = freeID(prefix: "blank", bareFirst: false, taken: Set(merged.map(\.id)))
            let blank = TemplateLayout.instantiate(TemplateCatalog.template(id: "blank")!,
                                                   geometry: PageGeometry(format: format, profile: profile),
                                                   dayKey: nil, id: blankID, marginMM: base.marginMM)
            merged.insert(blank, at: merged.last?.kind == .closing ? merged.count - 1 : merged.count)
        }

        var result = generated
        result.photos = base.photos
        result.spreads = merged
        let selected = base.selectedPhotos
        let oldCoverPhoto = base.cover?.front.frames.first?.photoID
        let coverPhoto = oldCoverPhoto.flatMap { base.photos[$0]?.isSelected == true ? $0 : nil }
            ?? generated.cover?.front.frames.first?.photoID
            ?? selected.first?.id
        result.cover = selected.isEmpty ? nil
            : AlbumDrafter.cover(title: base.title, photoID: coverPhoto, format: format, profile: profile,
                                 marginMM: base.marginMM)
        return (result, kept.count)
    }

    // MARK: - Format

    /// Recomputes the layout for `format`, keeping content and order.
    ///
    /// Spreads composed of pages (`pageLayouts` not empty) are rebuilt page by page
    /// (`rebuiltPages`): a page with a layout id from `PageLayoutCatalog`, a manual page scaled
    /// proportionally like a custom layout below; `customLayout`, `manuallyEdited` and
    /// `pageLayouts` are kept.
    ///
    /// Old template spreads with `customLayout == true` are NOT re-instantiated: their frame and
    /// text rects scale proportionally (`x * newWidth / oldWidth`, `y * newHeight / oldHeight`, sizes likewise; the old
    /// size is the album's current format, looked up in `profile` or, for another supplier, in the
    /// catalog; if it cannot be found the rects are only conformed), then photos, crops, zooms and
    /// texts stay as they are. Every other spread is re-instantiated from `TemplateCatalog.template(id: spread.templateID)` for the
    /// new geometry, keeping id, kind, dayKey and `manuallyEdited`; frames take over photoID, offset and
    /// zoom by frame id (FrameFit offsets are relative to the slack, so they carry over verbatim), texts
    /// take over their text by text id. A template slot without an old counterpart gets an empty
    /// frame/text; old frames/texts with no slot in the template are dropped. Template layouts and
    /// scaled custom layouts are conformed to `album.marginMM`. Spreads whose templateID is not in
    /// the catalog (and are not custom) are kept unchanged.
    ///
    /// The cover is not a catalog template: it is rebuilt through `AlbumDrafter.cover` with the
    /// existing cover photo (with its offset and zoom) and the cover's title text (album title if it
    /// has none). `formatID` changes, `supplierProfileID` is kept.
    public static func changeFormat(album: Album, to format: BookFormat, profile: SupplierProfile) -> Album {
        var result = album
        result.formatID = format.id
        let geometry = PageGeometry(format: format, profile: profile)
        let rule = MarginRule(geometry: geometry, marginMM: album.marginMM)
        let oldFormat = currentFormat(of: album, in: profile)
        result.spreads = album.spreads.map { old in
            if !old.pageLayouts.isEmpty {
                return rebuiltPages(old, from: oldFormat, geometry: geometry, marginMM: album.marginMM)
            }
            if old.customLayout {
                var scaled = old
                if let oldFormat {
                    let scale = scaling(from: oldFormat, to: format)
                    for i in scaled.frames.indices { scaled.frames[i].rect = scale(scaled.frames[i].rect) }
                    for i in scaled.texts.indices { scaled.texts[i].rect = scale(scaled.texts[i].rect) }
                }
                return rule.conform(scaled, area: .spread)
            }
            return reinstantiated(old, geometry: geometry, marginMM: album.marginMM) ?? old
        }
        if let old = album.cover {
            let oldFrame = old.front.frames.first
            let title = old.front.texts.first { $0.role == .title }?.text ?? album.title
            var cover = AlbumDrafter.cover(title: title, photoID: oldFrame?.photoID, format: format, profile: profile,
                                           marginMM: album.marginMM)
            if let oldFrame, !cover.front.frames.isEmpty {
                cover.front.frames[0].offset = oldFrame.offset
                cover.front.frames[0].zoom = oldFrame.zoom
            }
            result.cover = cover
        }
        return result
    }

    // MARK: - Margin

    /// `album` with the margin set to `mm` (limited to the profile's safe zone and the maximum, see
    /// `MarginRule.clampedMargin`). A spread composed of pages is rebuilt page by page at the new
    /// margin (`rebuiltPages`: a page with a layout id from the catalog, a manual page conformed).
    /// An old template spread with the recommended layout (`customLayout == false`)
    /// is re-instantiated from its template at the new margin, carrying photos, crops and texts
    /// by id as in `changeFormat`, so going back to an earlier margin restores its layout exactly.
    /// A custom layout (and a spread whose template is not in the catalog) and both cover pages
    /// are conformed to the new margin (`MarginRule.conform`). Photos, crops, texts,
    /// `manuallyEdited` and `customLayout` are untouched; only rects change. Pure.
    public static func settingMargin(_ mm: Double, in album: Album, profile: SupplierProfile,
                                     format: BookFormat) -> Album {
        var result = album
        result.marginMM = MarginRule.clampedMargin(mm, profile: profile)
        let geometry = PageGeometry(format: format, profile: profile)
        let rule = MarginRule(geometry: geometry, marginMM: result.marginMM)
        result.spreads = album.spreads.map { old in
            if !old.pageLayouts.isEmpty {
                return rebuiltPages(old, from: format, geometry: geometry, marginMM: result.marginMM)
            }
            if !old.customLayout, let spread = reinstantiated(old, geometry: geometry, marginMM: result.marginMM) {
                return spread
            }
            return rule.conform(old, area: .spread)
        }
        if let cover = album.cover {
            result.cover = Cover(front: rule.conform(cover.front, area: .cover),
                                 back: rule.conform(cover.back, area: .cover))
        }
        return result
    }

    // MARK: - Helpers

    private static func isDaySpread(_ spread: Spread) -> Bool {
        spread.kind == .journal || spread.kind == .gallery
    }

    /// The spread carries the day's header (spec 4.1): it is a journal, has a non-empty date or
    /// title text, or a caption starting with the day's date (an old book's first gallery of a
    /// day without a journal, `AlbumDrafter.dayCaption`).
    static func hasDayHeader(_ spread: Spread) -> Bool {
        if spread.kind == .journal { return true }
        return spread.texts.contains { text in
            switch text.role {
            case .date, .title:
                return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .caption:
                return spread.dayKey.map { text.text.hasPrefix(AlbumDrafter.czechDate($0)) } ?? false
            case .body, .pageNumber:
                return false
            }
        }
    }

    /// The intro, closing and cover photos: never a hero or on a `full` page of a day (spec 4.2).
    private static func titlePhotos(of album: Album) -> Set<PhotoID> {
        var ids = Set(album.spreads.filter { $0.kind == .intro || $0.kind == .closing }
            .flatMap { $0.frames.compactMap(\.photoID) })
        if let cover = album.cover?.front.frames.first?.photoID { ids.insert(cover) }
        return ids
    }

    /// Proportional scaling of a rect from one format to another (`x * newWidth / oldWidth`, ...).
    private static func scaling(from old: BookFormat, to new: BookFormat) -> (Rect) -> Rect {
        let sx = new.pageWidthMM / old.pageWidthMM
        let sy = new.pageHeightMM / old.pageHeightMM
        return { r in Rect(x: r.minX * sx, y: r.minY * sy, width: r.size.width * sx, height: r.size.height * sy) }
    }

    /// A spread composed of pages, rebuilt for `geometry` and `marginMM` page by page (spec 4.4):
    /// - a page whose `pageLayouts` entry is a catalog id gets that layout's frames and texts afresh
    ///   (`PageSpread.pageItems`), taking over photoID, offset and zoom by frame id and the text by
    ///   text id (old items without a slot are dropped);
    /// - a manual page (nil, or an id not in the catalog) keeps the frames and texts whose centre lies
    ///   on it in `from`'s geometry, scaled proportionally from `from` to the new format (nil `from`:
    ///   not scaled); an item whose id a catalog page of the spread produces is left to that page.
    /// The left page's items come first; a spread without any catalog page keeps its item order.
    /// Then the whole spread is conformed (`MarginRule.conform`). Id, kind, dayKey, `templateID`,
    /// `manuallyEdited`, `customLayout` and `pageLayouts` are kept, so with nothing manual the
    /// result equals `PageSpread.compose` at the new margin.
    private static func rebuiltPages(_ old: Spread, from oldFormat: BookFormat?, geometry: PageGeometry,
                                     marginMM: Double) -> Spread {
        let scale = oldFormat.map { scaling(from: $0, to: geometry.format) } ?? { $0 }
        let oldGeometry = oldFormat.map { PageGeometry(format: $0, profile: geometry.profile) } ?? geometry
        let sides: [PageSide] = [.left, .right]
        let layouts = sides.indices.map { i in
            old.pageLayouts.indices.contains(i) ? old.pageLayouts[i].flatMap(PageLayoutCatalog.layout(id:)) : nil
        }
        var spread = old
        if layouts.allSatisfy({ $0 == nil }) {
            for i in spread.frames.indices { spread.frames[i].rect = scale(spread.frames[i].rect) }
            for i in spread.texts.indices { spread.texts[i].rect = scale(spread.texts[i].rect) }
        } else {
            var catalog = sides.indices.map { i -> (frames: [Frame], texts: [TextBox]) in
                layouts[i].map { PageSpread.pageItems($0, side: sides[i], geometry: geometry, marginMM: marginMM) }
                    ?? ([], [])
            }
            let catalogIDs = Set(catalog.flatMap { $0.frames.map(\.id) + $0.texts.map(\.id) })
            spread.frames = []
            spread.texts = []
            for (i, side) in sides.enumerated() {
                if layouts[i] != nil {
                    for f in catalog[i].frames.indices {
                        guard let o = old.frames.first(where: { $0.id == catalog[i].frames[f].id }) else { continue }
                        catalog[i].frames[f].photoID = o.photoID
                        catalog[i].frames[f].offset = o.offset
                        catalog[i].frames[f].zoom = o.zoom
                    }
                    for t in catalog[i].texts.indices {
                        if let o = old.texts.first(where: { $0.id == catalog[i].texts[t].id }) {
                            catalog[i].texts[t].text = o.text
                        }
                    }
                    spread.frames += catalog[i].frames
                    spread.texts += catalog[i].texts
                } else {
                    func onPage(_ id: String, _ rect: Rect) -> Bool {
                        !catalogIDs.contains(id) && PageSpread.side(of: rect, geometry: oldGeometry) == side
                    }
                    spread.frames += old.frames.filter { onPage($0.id, $0.rect) }.map { f in
                        var f = f
                        f.rect = scale(f.rect)
                        return f
                    }
                    spread.texts += old.texts.filter { onPage($0.id, $0.rect) }.map { t in
                        var t = t
                        t.rect = scale(t.rect)
                        return t
                    }
                }
            }
        }
        return MarginRule(geometry: geometry, marginMM: marginMM).conform(spread, area: .spread)
    }

    /// `old` instantiated afresh from its catalog template for `geometry` and `marginMM`, keeping
    /// id, kind, dayKey, `manuallyEdited` (and `customLayout == false`); frames take over photoID,
    /// offset and zoom by frame id, texts their text by text id. Nil when the template is unknown.
    private static func reinstantiated(_ old: Spread, geometry: PageGeometry, marginMM: Double) -> Spread? {
        guard let template = TemplateCatalog.template(id: old.templateID) else { return nil }
        var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: old.dayKey, id: old.id,
                                                marginMM: marginMM)
        spread.kind = old.kind
        spread.manuallyEdited = old.manuallyEdited
        for i in spread.frames.indices {
            guard let o = old.frames.first(where: { $0.id == spread.frames[i].id }) else { continue }
            spread.frames[i].photoID = o.photoID
            spread.frames[i].offset = o.offset
            spread.frames[i].zoom = o.zoom
        }
        for i in spread.texts.indices {
            if let o = old.texts.first(where: { $0.id == spread.texts[i].id }) { spread.texts[i].text = o.text }
        }
        return spread
    }

    /// The format `album` currently has: from `profile` when it is the album's supplier, else
    /// from the profile catalog; nil when it cannot be found.
    private static func currentFormat(of album: Album, in profile: SupplierProfile) -> BookFormat? {
        if album.supplierProfileID == profile.id {
            return profile.formats.first { $0.id == album.formatID }
        }
        return (try? ProfileCatalog.format(profileID: album.supplierProfileID, formatID: album.formatID))?.1
    }

    /// The orientation a frame wants: from its page layout for a spread composed of pages (the
    /// frame id without its page prefix; `.any` on a manual page), else from its catalog template.
    private static func slotOrientation(_ spread: Spread, frameID: String) -> Orientation {
        guard !spread.pageLayouts.isEmpty else {
            return TemplateCatalog.template(id: spread.templateID)?.frames.first { $0.id == frameID }?.orientation ?? .any
        }
        for (i, side) in [PageSide.left, .right].enumerated() where frameID.hasPrefix(PageSpread.prefix(side)) {
            guard spread.pageLayouts.indices.contains(i), let id = spread.pageLayouts[i],
                  let layout = PageLayoutCatalog.layout(id: id) else { return .any }
            let slot = String(frameID.dropFirst(PageSpread.prefix(side).count))
            return layout.frames.first { $0.id == slot }?.orientation ?? .any
        }
        return .any
    }

    /// Place names of the day's photos in chronological order of first occurrence (as `DayGrouper`).
    private static func placeNames(of key: DayKey, in album: Album) -> [String] {
        var names: [String] = []
        for photo in album.photosByDay()[key] ?? [] {
            if let name = photo.placeName, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// `prefix` (only if `bareFirst`), else `prefix-N` with the smallest free N >= 1 (>= 2 if bare).
    static func freeID(prefix: String, bareFirst: Bool, taken: Set<String>) -> String {
        if bareFirst && !taken.contains(prefix) { return prefix }
        var n = bareFirst ? 2 : 1
        while taken.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    private static func freeID(for spread: Spread, taken: Set<String>) -> String {
        switch spread.kind {
        case .intro: return freeID(prefix: "intro", bareFirst: true, taken: taken)
        case .closing: return freeID(prefix: "closing", bareFirst: true, taken: taken)
        case .blank: return freeID(prefix: "blank", bareFirst: false, taken: taken)
        case .journal, .gallery:
            return freeID(prefix: "\(AlbumDrafter.dayString(spread.dayKey))-\(spread.kind.rawValue)",
                          bareFirst: spread.kind == .journal, taken: taken)
        }
    }
}
