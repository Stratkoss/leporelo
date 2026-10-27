import Testing
import Foundation
@testable import LeporeloCore

@Suite struct PageEditingTests {
    typealias T = AlbumDrafterTests
    static let day = T.june18
    static let margin = 10.0

    static func geometry() throws -> PageGeometry {
        let (p, f) = try T.canva(formatID: "landscape-8x6in")
        return PageGeometry(format: f, profile: p)
    }

    /// `landscape` flag per photo; ids `<prefix>0`, `<prefix>1`, ...; aesthetic falls with the index.
    static func photos(_ prefix: String, _ landscape: [Bool]) -> [Photo] {
        landscape.enumerated().map {
            T.photo("\(prefix)\($0)", day: day, minute: $0, landscape: $1, aesthetic: 0.9 - Double($0) * 0.1)
        }
    }

    static func lookup(_ photos: [Photo]) -> [PhotoID: Photo] {
        Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    /// Two composed pages; `left`/`right` photos go into the page's frames in frame order.
    static func spread(_ left: String, _ leftPhotos: [Photo], _ right: String = "empty",
                       _ rightPhotos: [Photo] = []) throws -> Spread {
        var s = try PageSpread.compose(left: #require(PageLayoutCatalog.layout(id: left)),
                                       right: #require(PageLayoutCatalog.layout(id: right)),
                                       kind: .gallery, dayKey: day, id: "s", geometry: geometry(), marginMM: margin)
        for (side, ps) in [(PageSide.left, leftPhotos), (.right, rightPhotos)] {
            let ids = s.frames.indices.filter { s.frames[$0].id.hasPrefix(PageSpread.prefix(side)) }
            for (i, p) in zip(ids, ps) { s.frames[i].photoID = p.id }
        }
        return s
    }

    static func alternatives(_ s: Spread, side: PageSide = .left, _ photos: [Photo],
                             liked: Set<String> = []) throws -> [String] {
        try PageEditing.alternatives(for: s, side: side, geometry: geometry(), photos: lookup(photos),
                                     weights: LayoutWeights(liked: liked))
    }

    static func next(_ s: Spread, side: PageSide = .left, _ photos: [Photo],
                     liked: Set<String> = []) throws -> String? {
        try PageEditing.nextLayout(for: s, side: side, geometry: geometry(), photos: lookup(photos),
                                   weights: LayoutWeights(liked: liked))
    }

    static func apply(_ id: String, to s: Spread, side: PageSide = .left, _ photos: [Photo]) throws -> RetemplateResult {
        try PageEditing.applying(id, to: s, side: side, geometry: geometry(), photos: lookup(photos),
                                 marginMM: margin)
    }

    static func page(_ s: Spread, _ side: PageSide) throws -> (frames: [Frame], texts: [TextBox]) {
        let g = try geometry()
        return (s.frames.filter { PageSpread.side(of: $0.rect, geometry: g) == side },
                s.texts.filter { PageSpread.side(of: $0.rect, geometry: g) == side })
    }

    // 3 photos: ▯ ▭ ▭.
    static let mixed3 = photos("m", [false, true, true])

    @Test func alternativesForTwoPortraits() throws {
        let ps = Self.photos("p", [false, false])
        let s = try Self.spread("portraits-2", ps)
        #expect(try Self.alternatives(s, ps) == ["portraits-2"])
        #expect(try Self.next(s, ps) == nil)
        #expect(try PageEditing.photoIDs(on: .left, of: s, geometry: Self.geometry()) == ["p0", "p1"])
        #expect(try PageEditing.photoIDs(on: .right, of: s, geometry: Self.geometry()) == [])
    }

    @Test func cyclesThroughAlternatives() throws {
        let ps = Self.mixed3
        let left = try Self.spread("portrait-left-2l", ps)
        #expect(try Self.alternatives(left, ps) == ["portrait-left-2l", "portrait-right-2l"])
        #expect(try Self.next(left, ps) == "portrait-right-2l")
        let right = try Self.spread("portrait-right-2l", ps)
        #expect(try Self.next(right, ps) == "portrait-left-2l")
        // A layout that is not in the list (manual page): the first alternative.
        var manual = left
        manual.pageLayouts = [nil, "empty"]
        #expect(try Self.next(manual, ps) == "portrait-left-2l")
    }

    @Test func openerWithThreeLandscapesHasNoOtherLayout() throws {
        let ps = Self.photos("l", [true, true, true])
        let s = try Self.spread("opener-3", ps)
        #expect(try PageEditing.isOpenerPage(s, side: .left, geometry: Self.geometry()))
        #expect(try Self.alternatives(s, ps) == ["opener-3"])
        #expect(try Self.next(s, ps) == nil)
    }

    @Test func noAlternativesForIntroClosingOrEmptyPages() throws {
        let ps = Self.photos("p", [true])
        var s = try Self.spread("full", ps)
        s.kind = .intro
        #expect(try Self.alternatives(s, ps).isEmpty)
        s.kind = .closing
        #expect(try Self.alternatives(s, ps).isEmpty)
        let gallery = try Self.spread("full", ps)
        #expect(try Self.alternatives(gallery, side: .right, ps).isEmpty)   // the empty page
        #expect(try Self.next(gallery, side: .right, ps) == nil)
        let text = try Self.spread("opener-text", [])
        #expect(try Self.alternatives(text, []).isEmpty)
    }

    @Test func likedFirst() throws {
        let ps = Self.mixed3
        let s = try Self.spread("portrait-left-2l", ps)
        #expect(try Self.alternatives(s, ps, liked: ["portrait-right-2l"]) == ["portrait-right-2l", "portrait-left-2l"])
        #expect(try Self.next(s, ps, liked: ["portrait-right-2l"]) == "portrait-right-2l")   // wraps round
    }

    @Test func legacyOpenerIsRecognisedByItsTexts() throws {
        let t = try #require(TemplateCatalog.template(id: "journal-3"))
        var s = try TemplateLayout.instantiate(t, geometry: Self.geometry(), dayKey: Self.day, id: "j")
        s.templateID = t.id
        let g = try Self.geometry()
        let withTitle = [PageSide.left, .right].filter { PageEditing.isOpenerPage(s, side: $0, geometry: g) }
        #expect(withTitle.count == 1)
        let gallery = try #require(TemplateCatalog.template(id: "gallery-3"))
        let plain = TemplateLayout.instantiate(gallery, geometry: g, dayKey: Self.day, id: "g")
        #expect(!PageEditing.isOpenerPage(plain, side: .left, geometry: g))
        // A manual page counts by its texts too.
        var manual = try Self.spread("opener-text", [])
        manual.pageLayouts = [nil, "empty"]
        #expect(PageEditing.isOpenerPage(manual, side: .left, geometry: g))
        #expect(!PageEditing.isOpenerPage(manual, side: .right, geometry: g))
    }

    @Test func applyingKeepsOtherPage() throws {
        let left = Self.photos("a", [true, true, true, true])
        let right = Self.photos("b", [false, false])
        var s = try Self.spread("grid-4", left, "portraits-2", right)
        s.texts.append(TextBox(id: "R.note", rect: Rect(x: 250, y: 10, width: 40, height: 10), role: .caption, text: "hi"))
        let before = try Self.page(s, .right)
        let r = try Self.apply("landscape-2", to: s, left + right)
        #expect(try Self.page(r.spread, .right) == before)
        #expect(r.spread.pageLayouts == ["landscape-2", "portraits-2"])
        #expect(r.spread.templateID == "pages")
        #expect(r.spread.manuallyEdited && !r.spread.customLayout)
        #expect(r.spread.id == "s" && r.spread.dayKey == Self.day)
        let new = try Self.page(r.spread, .left)
        #expect(new.frames.map(\.id) == ["L.photo1", "L.photo2"])
        #expect(new.frames.compactMap(\.photoID) == ["a0", "a1"])
        #expect(new.frames.allSatisfy { $0.offset == Point(x: 0, y: 0) && $0.zoom == 1 })
        #expect(r.unplacedPhotoIDs == ["a2", "a3"])
    }

    @Test func applyingResetsCropsAndCarriesTextsByRole() throws {
        let ps = Self.photos("a", [true, true])
        var s = try Self.spread("opener-2l", ps)
        s.frames[0].zoom = 2
        s.frames[0].offset = Point(x: 0.5, y: 0)
        for i in s.texts.indices { s.texts[i].text = "text \(s.texts[i].role)" }
        let r = try Self.apply("opener-3", to: s, ps)
        #expect(r.spread.texts.map(\.text) == s.texts.map(\.text))
        #expect(r.droppedTexts.isEmpty)
        #expect(r.spread.frames.allSatisfy { $0.zoom == 1 })
        // To a layout without texts: the non-empty ones are reported.
        let plain = try Self.apply("landscape-2", to: s, ps)
        #expect(plain.droppedTexts.map(\.role) == [.date, .title, .body])
        #expect(plain.spread.texts.map(\.role) == [.caption] && plain.spread.texts[0].text == "")
        // An empty text is not reported.
        var blankTexts = s
        for i in blankTexts.texts.indices { blankTexts.texts[i].text = "  " }
        #expect(try Self.apply("landscape-2", to: blankTexts, ps).droppedTexts.isEmpty)
    }

    @Test func applyingKeepsSquareOutOfTheWrongOrientation() throws {
        // A square is the best photo; the ▯ must still get the only ▯ frame.
        let portrait = T.photo("p", day: Self.day, minute: 0, landscape: false, aesthetic: 0.1)
        let square = T.photo("s", day: Self.day, minute: 1, aesthetic: 0.9, pixels: (3000, 3000))
        let wide = T.photo("w", day: Self.day, minute: 2, aesthetic: 0.5)
        let ps = [portrait, square, wide]
        let s = try Self.spread("grid-4", [wide, square, portrait])
        let r = try Self.apply("portrait-left-2l", to: s, ps)
        let frames = Dictionary(uniqueKeysWithValues: r.spread.frames.map { ($0.id, $0.photoID) })
        #expect(frames["L.photo1"] == "p")
        #expect(frames["L.photo2"] == "s")
        #expect(frames["L.photo3"] == "w")
        #expect(r.unplacedPhotoIDs.isEmpty)
    }

    @Test func applyingGivesTheBestPhotoTheMainFrame() throws {
        let ps = Self.photos("a", [true, true, true])   // a0 is the best
        let s = try Self.spread("opener-3", [ps[2], ps[1], ps[0]])
        let r = try Self.apply("portrait-left-2l", to: s, ps)   // no ▯ photo: assign decides
        #expect(r.spread.frames.first { $0.id == "L.photo1" }?.photoID == "a0")
        #expect(r.unplacedPhotoIDs.isEmpty)
    }

    @Test func applyingFewerPhotosLeavesFramesEmpty() throws {
        let ps = Self.photos("a", [true])
        let s = try Self.spread("full", ps)
        let r = try Self.apply("grid-4", to: s, ps)
        #expect(r.spread.frames.compactMap(\.photoID) == ["a0"])
        #expect(r.spread.frames.first { $0.id == "L.photo1" }?.photoID == "a0")
        #expect(r.spread.frames.filter { $0.id.hasPrefix("L.") }.count == 4)
    }

    @Test func applyingOnLegacyConverts() throws {
        let g = try Self.geometry()
        let t = try #require(TemplateCatalog.template(id: "gallery-3"))
        var s = TemplateLayout.instantiate(t, geometry: g, dayKey: Self.day, id: "g")
        let ps = Self.photos("a", [false, true, true])   // photo1 (▯) is on the right page
        for (i, p) in ps.enumerated() { s.frames[i].photoID = p.id }
        s.texts[0].text = "right caption"   // gallery-3's caption sits on the left page
        let rightBefore = try Self.page(s, .right)
        let r = try Self.apply("portraits-2", to: s, side: .left, ps)
        #expect(r.spread.templateID == "pages")
        #expect(r.spread.pageLayouts == ["portraits-2", nil])
        #expect(r.spread.customLayout && r.spread.manuallyEdited)
        #expect(try Self.page(r.spread, .right) == rightBefore)
        #expect(r.unplacedPhotoIDs.isEmpty)
        // The old left page photos (two ▭) go to the new frames; the caption has no slot.
        #expect(Set(try Self.page(r.spread, .left).frames.compactMap(\.photoID)) == ["a1", "a2"])
        #expect(r.droppedTexts.map(\.text) == ["right caption"])

        let one = try Self.apply("full", to: s, side: .left, ps)
        #expect(one.spread.pageLayouts == ["full", nil])
        #expect(one.unplacedPhotoIDs == ["a2"])
        // On the right page.
        let rr = try Self.apply("full", to: s, side: .right, ps)
        #expect(rr.spread.pageLayouts == [nil, "full"])
        #expect(rr.spread.frames.contains { $0.id == "R.photo1" && $0.photoID == "a0" })
        #expect(try Self.page(rr.spread, .left) == Self.page(s, .left))
    }

    @Test func applyingOnBlankMakesGallery() throws {
        let t = try #require(TemplateCatalog.template(id: "blank"))
        let blank = try TemplateLayout.instantiate(t, geometry: Self.geometry(), dayKey: nil, id: "b")
        let r = try Self.apply("framed-1", to: blank, side: .right, [])
        #expect(r.spread.kind == .gallery)
        #expect(r.spread.templateID == "pages")
        #expect(r.spread.pageLayouts == ["empty", "framed-1"])
        #expect(!r.spread.customLayout && r.spread.manuallyEdited)
        #expect(r.spread.frames.map(\.id) == ["R.photo1"])
        #expect(r.spread.frames[0].photoID == nil)
        #expect(r.spread.texts.map(\.id) == ["R.caption"])
    }

    @Test func applyingOnBlankKeepsItemsOnTheOtherPage() throws {
        let t = try #require(TemplateCatalog.template(id: "blank"))
        var blank = try TemplateLayout.instantiate(t, geometry: Self.geometry(), dayKey: nil, id: "b")
        let mine = Frame(id: "mine", rect: Rect(x: 250, y: 20, width: 60, height: 40), photoID: "x",
                         offset: Point(x: 0, y: 0), zoom: 1)
        blank.frames = [mine]
        let r = try Self.apply("framed-1", to: blank, side: .left, [])
        #expect(r.spread.pageLayouts == ["framed-1", nil])
        #expect(r.spread.customLayout && r.spread.manuallyEdited)
        #expect(r.spread.frames.last == mine)
        #expect(r.spread.frames.map(\.id) == ["L.photo1", "mine"])
        // A hand-added text counts too, on the left page when applying to the right.
        var withText = try TemplateLayout.instantiate(t, geometry: Self.geometry(), dayKey: nil, id: "b")
        withText.texts = [TextBox(id: "note", rect: Rect(x: 20, y: 20, width: 60, height: 10), role: .caption, text: "n")]
        let rt = try Self.apply("framed-1", to: withText, side: .right, [])
        #expect(rt.spread.pageLayouts == [nil, "framed-1"])
        #expect(rt.spread.texts.first?.id == "note")
    }

    @Test func applyingFollowsTheMargin() throws {
        let ps = Self.photos("a", [true])
        let s = try Self.spread("full", ps)
        let r = try Self.apply("framed-1", to: s, ps)
        let expected = try PageSpread.compose(left: #require(PageLayoutCatalog.layout(id: "framed-1")),
                                              right: #require(PageLayoutCatalog.layout(id: "empty")),
                                              kind: .gallery, dayKey: Self.day, id: "s",
                                              geometry: Self.geometry(), marginMM: Self.margin)
        #expect(r.spread.frames.map(\.rect) == expected.frames.map(\.rect))
        #expect(r.spread.texts.map(\.rect) == expected.texts.map(\.rect))
    }

    @Test func markingCustomSetsNil() throws {
        let s = try Self.spread("grid-4", [], "portraits-2")
        let left = PageEditing.markingCustom(s, side: .left)
        #expect(left.pageLayouts == [nil, "portraits-2"])
        #expect(left.customLayout && left.manuallyEdited)
        #expect(left.frames == s.frames)
        let right = PageEditing.markingCustom(s, side: .right)
        #expect(right.pageLayouts == ["grid-4", nil])
        // A legacy spread has no page layouts to clear, but is still marked.
        let t = try #require(TemplateCatalog.template(id: "gallery-3"))
        let legacy = PageEditing.markingCustom(try TemplateLayout.instantiate(t, geometry: Self.geometry(), dayKey: nil, id: "g"),
                                               side: .left)
        #expect(legacy.pageLayouts.isEmpty && legacy.customLayout && legacy.manuallyEdited)
    }
}
