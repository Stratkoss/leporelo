import Testing
import Foundation
@testable import LeporeloCore

@Suite struct RetemplateTests {
    typealias D = AlbumDrafterTests
    static let lax = PageCountRule(min: 2, max: nil, multipleOf: 2)

    static func geometry() throws -> PageGeometry {
        let (p, f) = try D.canva(Self.lax)
        return PageGeometry(format: f, profile: p)
    }

    /// A spread instantiated from `templateID` with `photos` assigned like the drafter does.
    static func spread(_ templateID: String, _ photos: [Photo], texts: [String: String] = [:],
                       id: String = "s1", day: DayKey? = D.june18) throws -> Spread {
        let t = try #require(TemplateCatalog.template(id: templateID))
        var s = TemplateLayout.instantiate(t, geometry: try geometry(), dayKey: day, id: id)
        let assignment = TemplateLayout.assign(t.frames, photos: photos)
        for i in s.frames.indices { s.frames[i].photoID = assignment[s.frames[i].id] }
        for i in s.texts.indices { s.texts[i].text = texts[s.texts[i].id] ?? "" }
        return s
    }

    static func byID(_ photos: [Photo]) -> [PhotoID: Photo] {
        Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    static func assignment(_ s: Spread) -> [String: PhotoID] {
        Dictionary(uniqueKeysWithValues: s.frames.compactMap { f in f.photoID.map { (f.id, $0) } })
    }

    @Test func moreFramesKeepIdDayAndUseTheDrafterAssignment() throws {
        let ps = [D.photo("a", day: D.june18, minute: 0, aesthetic: 0.4),
                  D.photo("b", day: D.june18, minute: 1, landscape: false, aesthetic: 0.9)]
        var old = try Self.spread("gallery-2", ps, texts: ["caption": "Ravello"], id: "2026-06-18-gallery")
        old.frames[0].offset = Point(x: 0.5, y: -0.5)
        old.frames[0].zoom = 2
        let target = try #require(TemplateCatalog.template(id: "gallery-3"))

        let r = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))

        #expect(r.spread.id == "2026-06-18-gallery")
        #expect(r.spread.dayKey == D.june18)
        #expect(r.spread.kind == .gallery)
        #expect(r.spread.templateID == "gallery-3")
        #expect(r.spread.manuallyEdited)
        #expect(Self.assignment(r.spread) == TemplateLayout.assign(target.frames, photos: ps))
        #expect(r.spread.frames.filter { $0.photoID == nil }.count == 1)  // the extra frame stays empty
        #expect(r.spread.frames.allSatisfy { $0.offset == Point(x: 0, y: 0) && $0.zoom == 1 })
        #expect(r.spread.texts.first { $0.id == "caption" }?.text == "Ravello")
        #expect(r.unplacedPhotoIDs.isEmpty)
        #expect(r.droppedTexts.isEmpty)
        // Same frames as a fresh instance of the template for this geometry.
        let fresh = TemplateLayout.instantiate(target, geometry: try Self.geometry(), dayKey: D.june18, id: "x")
        #expect(r.spread.frames.map(\.rect) == fresh.frames.map(\.rect))
    }

    @Test func fewerFramesReportTheWeakestPhotosChronologically() throws {
        let scores = [0.9, 0.1, 0.8, 0.2, 0.7]
        let ps = (0..<5).map { D.photo("p\($0)", day: D.june18, minute: $0, aesthetic: scores[$0]) }
        let old = try Self.spread("journal-5", ps, texts: ["date": "Den", "title": "Ravello", "body": "Text"])
        let target = try #require(TemplateCatalog.template(id: "journal-3"))

        let r = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))

        #expect(Set(r.spread.frames.compactMap(\.photoID)) == ["p0", "p2", "p4"])
        #expect(r.unplacedPhotoIDs == ["p1", "p3"])
        #expect(r.droppedTexts.isEmpty)  // journal to journal keeps date, title and body
        #expect(r.spread.texts.map(\.text) == ["Den", "Ravello", "Text"])
    }

    @Test func textsWithoutASlotAreReportedNotLost() throws {
        let ps = (0..<3).map { D.photo("p\($0)", day: D.june18, minute: $0) }
        let old = try Self.spread("journal-3", ps, texts: ["date": "Den", "title": "Ravello", "body": "  "])
        let target = try #require(TemplateCatalog.template(id: "gallery-3"))

        let r = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))

        #expect(r.spread.kind == .gallery)
        #expect(r.droppedTexts.map(\.id) == ["date", "title"])  // a whitespace-only body is not content
        #expect(r.droppedTexts.map(\.text) == ["Den", "Ravello"])
        #expect(r.spread.texts.map(\.id) == ["caption"])
        #expect(r.spread.texts[0].text == "")
        #expect(Set(r.spread.frames.compactMap(\.photoID)) == ["p0", "p1", "p2"])
    }

    @Test func textsMoveBySlotIdThenRole() throws {
        let ps = [D.photo("a", day: D.june18, minute: 0)]
        var old = try Self.spread("gallery-1", ps, texts: ["caption": "Minori"])
        old.texts[0].id = "legacy-caption"  // same role, other id
        let target = try #require(TemplateCatalog.template(id: "gallery-2"))

        let r = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))

        #expect(r.spread.texts.first { $0.role == .caption }?.text == "Minori")
        #expect(r.droppedTexts.isEmpty)
        #expect(r.spread.frames.filter { $0.photoID == nil }.count == 1)
    }

    @Test func retemplateCarriesStyle() throws {
        let ps = [D.photo("a", day: D.june18, minute: 0)]
        var old = try Self.spread("gallery-1", ps, texts: ["caption": "Minori"])
        let style = TextStyle(fontFamily: "Georgia", sizePt: 18, italic: true, colorHex: "#112233")
        old.texts[0].style = style
        let target = try #require(TemplateCatalog.template(id: "gallery-2"))

        // By slot id.
        let byID = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))
        #expect(byID.spread.texts.first { $0.role == .caption }?.style == style)
        // By role, when the id differs.
        old.texts[0].id = "legacy-caption"
        let byRole = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))
        #expect(byRole.spread.texts.first { $0.role == .caption }?.style == style)
        #expect(byRole.spread.texts.first { $0.role == .caption }?.text == "Minori")
    }

    @Test func photosMissingFromTheAlbumAreNotPlaced() throws {
        let ps = [D.photo("a", day: D.june18, minute: 0), D.photo("b", day: D.june18, minute: 1)]
        let old = try Self.spread("gallery-2", ps)
        let target = try #require(TemplateCatalog.template(id: "gallery-2"))
        let r = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID([ps[0]]))
        #expect(r.spread.frames.compactMap(\.photoID) == ["a"])
        #expect(r.unplacedPhotoIDs.isEmpty)
    }

    // The drafter's pages give the main frame (photo1) the page's best photo that fits it, like
    // `TemplateLayout.assign` on templates.
    @Test func drafterPutsTheBestFittingPhotoInEachMainFrame() throws {
        let (p, f) = try D.canva(Self.lax, formatID: "landscape-8x6in")
        let ps = D.mixedPhotos("p", D.june18, count: 12)
        let a = D.draft([D.day(D.june18, ps)], profile: p, format: f)
        let pages = D.pages(D.daySpreads(a)).filter { !$0.photos.isEmpty }
        #expect(!pages.isEmpty)
        let byID = Self.byID(ps)
        for page in pages {
            let layout = try #require(PageLayoutCatalog.layout(id: page.layout))
            let main = layout.frames[0]
            #expect(main.priority == 0)
            let best = page.photos.map { byID[$0]! }.filter { TemplateLayout.fits($0, main.orientation) }
                .sorted(by: TemplateLayout.rank).first
            #expect(page.photos.first == best?.id, "\(page.layout)")
        }
    }

    @Test func retemplateClearsCustomLayout() throws {
        let ps = [D.photo("a", day: D.june18, minute: 0), D.photo("b", day: D.june18, minute: 1)]
        var old = try Self.spread("gallery-2", ps)
        old.customLayout = true
        let target = try #require(TemplateCatalog.template(id: "gallery-3"))
        let r = TemplateLayout.retemplate(old, to: target, geometry: try Self.geometry(), photos: Self.byID(ps))
        #expect(!r.spread.customLayout)
        #expect(r.spread.manuallyEdited)
    }

    @Test func retemplateConformsToTheMargin() throws {
        let ps = [D.photo("a", day: D.june18, minute: 0)]
        let old = try Self.spread("gallery-1", ps)
        let target = try #require(TemplateCatalog.template(id: "journal-3"))
        let g = try Self.geometry()
        let r = TemplateLayout.retemplate(old, to: target, geometry: g, photos: Self.byID(ps), marginMM: 25)
        let fresh = TemplateLayout.instantiate(target, geometry: g, dayKey: D.june18, id: "x", marginMM: 25)
        #expect(r.spread.frames.map(\.rect) == fresh.frames.map(\.rect))
        #expect(r.spread.texts.map(\.rect) == fresh.texts.map(\.rect))
    }
}
