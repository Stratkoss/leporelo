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
    /// - Otherwise it goes into the first empty frame of the day's gallery spreads (album order, frame
    ///   order), preferring a frame whose template orientation fits the photo and falling back to any
    ///   empty frame. This also covers days with 1-2 photos, which have gallery-only spreads.
    /// - With no empty gallery frame a new `gallery-1` spread holding the photo is inserted right after
    ///   the day's last spread. For a day that has no spread yet it is inserted after the last spread of
    ///   the latest earlier day, else before the first spread of a later day, else after the intro
    ///   (i.e. before blank and closing spreads), and its caption gets the date and places like a
    ///   drafted day with 1-2 photos. No empty frame is ever created.
    /// - Filling an empty frame of a manually edited gallery does not change its `manuallyEdited`.
    public static func photoSelected(_ id: PhotoID, in album: Album, geometry: PageGeometry) -> Album {
        guard let photo = album.photos[id], let key = photo.dayKey else { return album }
        var result = album
        result.photos[id]?.isSelected = true
        result.photos[id]?.selectionDecidedByUser = true
        if result.spreads.contains(where: { $0.frames.contains { $0.photoID == id } }) { return result }

        // 1. An empty frame of the day's galleries.
        let galleries = result.spreads.indices.filter {
            result.spreads[$0].kind == .gallery && result.spreads[$0].dayKey == key
        }
        let empty = galleries.flatMap { s in
            result.spreads[s].frames.indices.filter { result.spreads[s].frames[$0].photoID == nil }.map { (s, $0) }
        }
        let fitting = empty.first { s, f in
            AlbumDrafter.fits(photo, slotOrientation(result.spreads[s], frameID: result.spreads[s].frames[f].id))
        }
        if let (s, f) = fitting ?? empty.first {
            result.spreads[s].frames[f].photoID = id
            result.spreads[s].frames[f].offset = Point(x: 0, y: 0)
            result.spreads[s].frames[f].zoom = 1
            return result
        }

        // 2. A new gallery-1.
        let template = TemplateCatalog.template(id: "gallery-1")!
        let spreadID = freeID(prefix: "\(AlbumDrafter.dayString(key))-gallery", bareFirst: false,
                              taken: Set(result.spreads.map(\.id)))
        var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: key, id: spreadID)
        spread.frames[0].photoID = id
        let index: Int
        if let last = result.spreads.lastIndex(where: { $0.dayKey == key }) {
            index = last + 1
        } else {
            let names = placeNames(of: key, in: result)
            if let i = spread.texts.firstIndex(where: { $0.role == .caption }) {
                spread.texts[i].text = AlbumDrafter.dayCaption(key, placeNames: names)
            }
            if let prev = result.spreads.lastIndex(where: { $0.dayKey.map { $0 < key } ?? false }) {
                index = prev + 1
            } else if let next = result.spreads.firstIndex(where: { $0.dayKey.map { $0 > key } ?? false }) {
                index = next
            } else if let intro = result.spreads.lastIndex(where: { $0.kind == .intro }) {
                index = intro + 1
            } else {
                index = 0
            }
        }
        result.spreads.insert(spread, at: index)
        return result
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
    /// had no closing; the kept spreads are reserved in the drafter's page-count padding (it splits
    /// its galleries / adds blanks before its closing as in a first draft).
    ///
    /// Day headers are not duplicated: a day with a kept `.journal` spread gets galleries only, with
    /// empty captions; a day with a kept `.gallery` whose caption text is non-empty gets new spreads
    /// (a journal too, if 3+ photos are left) but their gallery captions are empty.
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
                               format: BookFormat) -> (album: Album, keptManual: Int) {
        let base = album.formatID == format.id && album.supplierProfileID == profile.id
            ? album : changeFormat(album: album, to: format, profile: profile)
        let kept = base.spreads.filter(\.manuallyEdited)
        let keptPhotos = Set(kept.flatMap { $0.frames.compactMap(\.photoID) })
        let hasManualIntro = kept.contains { $0.kind == .intro }
        let hasManualClosing = kept.contains { $0.kind == .closing }
        let hadClosing = base.spreads.isEmpty || base.spreads.contains { $0.kind == .closing }

        let journalDays = Set(kept.filter { $0.kind == .journal }.compactMap(\.dayKey))
        let captionedDays = Set(kept.filter { spread in
            spread.kind == .gallery && spread.texts.contains { $0.role == .caption && !$0.text.isEmpty }
        }.compactMap(\.dayKey))
        let generated = AlbumDrafter.draft(
            album: base, days: days, profile: profile, format: format,
            options: DraftOptions(includeClosing: hadClosing && !hasManualClosing),
            includeIntro: !hasManualIntro, reservedSpreads: kept.count,
            excludedFromDays: keptPhotos, galleryOnlyDays: journalDays, captionlessDays: captionedDays)

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
                                                   dayKey: nil, id: blankID)
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
            : AlbumDrafter.cover(title: base.title, photoID: coverPhoto, format: format, profile: profile)
        return (result, kept.count)
    }

    // MARK: - Format

    /// Recomputes the layout for `format`, keeping content and order.
    ///
    /// Each spread is re-instantiated from `TemplateCatalog.template(id: spread.templateID)` for the
    /// new geometry, keeping id, kind, dayKey and `manuallyEdited`; frames take over photoID, offset and
    /// zoom by frame id (FrameFit offsets are relative to the slack, so they carry over verbatim), texts
    /// take over their text by text id. A template slot without an old counterpart gets an empty
    /// frame/text; old frames/texts with no slot in the template are dropped. Spreads whose
    /// templateID is not in the catalog are kept unchanged.
    ///
    /// The cover is not a catalog template: it is rebuilt through `AlbumDrafter.cover` with the
    /// existing cover photo (with its offset and zoom) and the cover's title text (album title if it
    /// has none). `formatID` changes, `supplierProfileID` is kept.
    public static func changeFormat(album: Album, to format: BookFormat, profile: SupplierProfile) -> Album {
        var result = album
        result.formatID = format.id
        let geometry = PageGeometry(format: format, profile: profile)
        result.spreads = album.spreads.map { old in
            guard let template = TemplateCatalog.template(id: old.templateID) else { return old }
            var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: old.dayKey, id: old.id)
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
        if let old = album.cover {
            let oldFrame = old.front.frames.first
            let title = old.front.texts.first { $0.role == .title }?.text ?? album.title
            var cover = AlbumDrafter.cover(title: title, photoID: oldFrame?.photoID, format: format, profile: profile)
            if let oldFrame, !cover.front.frames.isEmpty {
                cover.front.frames[0].offset = oldFrame.offset
                cover.front.frames[0].zoom = oldFrame.zoom
            }
            result.cover = cover
        }
        return result
    }

    // MARK: - Helpers

    private static func slotOrientation(_ spread: Spread, frameID: String) -> Orientation {
        TemplateCatalog.template(id: spread.templateID)?.frames.first { $0.id == frameID }?.orientation ?? .any
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
