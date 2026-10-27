import Foundation

/// Page-level operations on a spread (spec 5): the alternatives of "Zkusit jinak", applying a
/// catalog layout to one page, and marking a page as changed by hand. A frame or text belongs to
/// the page its centre lies on (`PageSpread.side(of:geometry:)`). Pure.
public enum PageEditing {
    private static func index(_ side: PageSide) -> Int { side == .left ? 0 : 1 }

    private static func onPage(_ rect: Rect, _ side: PageSide, _ geometry: PageGeometry) -> Bool {
        PageSpread.side(of: rect, geometry: geometry) == side
    }

    /// The catalog layout id of a page, nil for a manual or old-template page.
    private static func layoutID(_ spread: Spread, side: PageSide) -> String? {
        let i = index(side)
        guard spread.pageLayouts.indices.contains(i), let id = spread.pageLayouts[i],
              PageLayoutCatalog.layout(id: id) != nil else { return nil }
        return id
    }

    /// The photos of the frames on the page, in frame order.
    public static func photoIDs(on side: PageSide, of spread: Spread, geometry: PageGeometry) -> [PhotoID] {
        spread.frames.filter { onPage($0.rect, side, geometry) }.compactMap(\.photoID)
    }

    /// Whether the page is the first page of a day: its layout has the role `.opener`. A manual page
    /// or a page of an old spread counts when it has a date or title text.
    public static func isOpenerPage(_ spread: Spread, side: PageSide, geometry: PageGeometry) -> Bool {
        if let id = layoutID(spread, side: side) {
            return PageLayoutCatalog.layout(id: id)?.role == .opener
        }
        return spread.texts.contains { onPage($0.rect, side, geometry) && ($0.role == .date || $0.role == .title) }
    }

    /// The page's photos (each once, frame order) that exist in `photos`.
    private static func pagePhotos(_ spread: Spread, side: PageSide, geometry: PageGeometry,
                                   photos: [PhotoID: Photo]) -> [Photo] {
        var seen = Set<PhotoID>()
        return photoIDs(on: side, of: spread, geometry: geometry).filter { seen.insert($0).inserted }
            .compactMap { photos[$0] }
    }

    /// Layouts with as many frames as the page has photos that these photos fill with matching
    /// orientation: an opener page only gets `.opener` layouts, any other page `.hero`, `.dense`
    /// and `.sparse` ones. Heaviest first (`weights`), then catalog order. Empty for the intro, the
    /// closing, a page without photos and the `empty` page.
    public static func alternatives(for spread: Spread, side: PageSide, geometry: PageGeometry,
                                    photos: [PhotoID: Photo], weights: LayoutWeights) -> [String] {
        guard spread.kind != .intro, spread.kind != .closing, layoutID(spread, side: side) != "empty" else { return [] }
        let own = pagePhotos(spread, side: side, geometry: geometry, photos: photos)
        guard !own.isEmpty else { return [] }
        let opener = isOpenerPage(spread, side: side, geometry: geometry)
        let candidates = PageLayoutCatalog.all.enumerated().filter { _, layout in
            (layout.role == .opener) == opener && layout.role != .empty && layout.photoCount == own.count
                && PagePlanner.canHold(own, in: layout)
        }
        return candidates.sorted { a, b in
            let wa = weights.weight(a.element.id), wb = weights.weight(b.element.id)
            return wa != wb ? wa > wb : a.offset < b.offset
        }.map(\.element.id)
    }

    /// The alternative after the page's current layout, round and round; the first one when the
    /// current layout is not in the list (manual or old page); nil when nothing else is left.
    public static func nextLayout(for spread: Spread, side: PageSide, geometry: PageGeometry,
                                  photos: [PhotoID: Photo], weights: LayoutWeights) -> String? {
        let list = alternatives(for: spread, side: side, geometry: geometry, photos: photos, weights: weights)
        guard let first = list.first else { return nil }
        guard let current = layoutID(spread, side: side), let i = list.firstIndex(of: current) else { return first }
        return list.count > 1 ? list[(i + 1) % list.count] : nil
    }

    /// The page `side` of `spread` laid out on the catalog layout `layoutID`, the other page left
    /// as it is (the rules of `TemplateLayout.retemplate`, for one page):
    /// - frames and texts on the page are replaced by the layout's (`PageSpread.pageItems`,
    ///   conformed to `marginMM`); the left page's items come first;
    /// - the page's photos (frame order, each once) go to the frames: when each can have a frame
    ///   of its orientation, the best to the main frame and a square never in a frame a ▯ or ▭
    ///   needs (`PagePlanner.assignment`), else `TemplateLayout.assign`; crops reset; extra photos
    ///   are `unplacedPhotoIDs` (chronological), extra frames stay empty;
    /// - texts: a slot takes the old text with its id, else the first unused one with its role;
    ///   non-empty ones without a slot are `droppedTexts`;
    /// - `manuallyEdited = true`, `customLayout = pageLayouts.contains(nil)`;
    /// - an old spread (no `pageLayouts`) becomes `"pages"` and its other page manual (`nil`),
    ///   keeping its frames and texts; a `blank` spread becomes a gallery whose other page is `empty`.
    /// The intro, the closing and an unknown layout id come back unchanged.
    public static func applying(_ layoutID: String, to spread: Spread, side: PageSide, geometry: PageGeometry,
                                photos: [PhotoID: Photo], marginMM: Double) -> RetemplateResult {
        guard spread.kind != .intro, spread.kind != .closing,
              let layout = PageLayoutCatalog.layout(id: layoutID) else {
            return RetemplateResult(spread: spread, unplacedPhotoIDs: [], droppedTexts: [])
        }
        var result = spread
        let blank = spread.templateID == "blank"
        if blank {
            result.kind = .gallery
            result.pageLayouts = side == .left ? [layoutID, "empty"] : ["empty", layoutID]
        } else if spread.pageLayouts.isEmpty {
            result.pageLayouts = side == .left ? [layoutID, nil] : [nil, layoutID]
        } else {
            result.pageLayouts = spread.pageLayouts
            while result.pageLayouts.count < 2 { result.pageLayouts.append(nil) }
            result.pageLayouts[index(side)] = layoutID
        }
        result.templateID = PageSpread.templateID
        result.manuallyEdited = true
        result.customLayout = result.pageLayouts.contains { $0 == nil }

        let old = pagePhotos(spread, side: side, geometry: geometry, photos: photos)
        let oldTexts = spread.texts.filter { onPage($0.rect, side, geometry) }

        // The new page, conformed to the margin on its own: the other page stays as it is.
        let items = PageSpread.pageItems(layout, side: side, geometry: geometry, marginMM: marginMM)
        let conformed = MarginRule(geometry: geometry, marginMM: marginMM).conform(
            Spread(id: spread.id, kind: result.kind, templateID: result.templateID, dayKey: spread.dayKey,
                   frames: items.frames, texts: items.texts, manuallyEdited: true), area: .spread)
        var frames = conformed.frames
        var texts = conformed.texts

        let assignment = PagePlanner.assignment(layout, old)
        let prefix = PageSpread.prefix(side)
        for i in frames.indices {
            frames[i].photoID = assignment[String(frames[i].id.dropFirst(prefix.count))]?.id
        }
        let placed = Set(frames.compactMap(\.photoID))
        let unplaced = old.filter { !placed.contains($0.id) }.sorted(by: Photo.chronological).map(\.id)

        // Two passes, so a slot matched by id is never taken by another slot's role fallback.
        var used = Set<Int>()
        var filled = Set<Int>()
        for byID in [true, false] {
            for i in texts.indices where !filled.contains(i) {
                let box = texts[i]
                let match = oldTexts.indices.first {
                    !used.contains($0) && (byID ? oldTexts[$0].id == box.id : oldTexts[$0].role == box.role)
                }
                if let match {
                    used.insert(match)
                    filled.insert(i)
                    texts[i].text = oldTexts[match].text
                }
            }
        }
        let dropped = oldTexts.indices.filter { i in
            !used.contains(i) && !oldTexts[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { oldTexts[$0] }

        let otherFrames = spread.frames.filter { !onPage($0.rect, side, geometry) }
        let otherTexts = spread.texts.filter { !onPage($0.rect, side, geometry) }
        result.frames = side == .left ? frames + otherFrames : otherFrames + frames
        result.texts = side == .left ? texts + otherTexts : otherTexts + texts
        return RetemplateResult(spread: result, unplacedPhotoIDs: unplaced, droppedTexts: dropped)
    }

    /// `spread` after a manual change on page `side`: a spread of pages gets `nil` for that page;
    /// either way `customLayout` and `manuallyEdited` are set.
    public static func markingCustom(_ spread: Spread, side: PageSide) -> Spread {
        var result = spread
        let i = index(side)
        if result.pageLayouts.indices.contains(i) { result.pageLayouts[i] = nil }
        result.customLayout = true
        result.manuallyEdited = true
        return result
    }
}
