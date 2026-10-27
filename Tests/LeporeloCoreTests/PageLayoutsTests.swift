import Testing
@testable import LeporeloCore

@Suite struct PageLayoutsTests {
    static let order = ["full", "framed-1", "portrait-text", "portraits-2", "portrait-left-2l", "portrait-right-2l",
                        "landscape-2", "grid-4", "mosaic-5", "mosaic-6", "opener-portrait", "opener-2l", "opener-3",
                        "opener-text", "empty"]
    static let favourites = ["portraits-2", "portrait-left-2l", "portrait-right-2l", "grid-4", "mosaic-5", "mosaic-6",
                             "opener-portrait", "opener-2l", "opener-3"]
    static let margin = 10.0

    static func geometry() throws -> PageGeometry {
        let (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        return PageGeometry(format: f, profile: p)
    }

    static func layout(_ id: String) throws -> PageLayout { try #require(PageLayoutCatalog.layout(id: id)) }

    static func compose(_ left: String, _ right: String) throws -> Spread {
        try PageSpread.compose(left: layout(left), right: layout(right), kind: .gallery, dayKey: nil, id: "s",
                               geometry: geometry(), marginMM: margin)
    }

    @Test func catalogOrderAndIDs() {
        #expect(PageLayoutCatalog.all.map(\.id) == Self.order)
        #expect(PageLayoutCatalog.favouriteCandidates == Self.favourites)
        #expect(PageLayoutCatalog.dense.map(\.id) == ["portraits-2", "portrait-left-2l", "portrait-right-2l",
                                                      "grid-4", "mosaic-5", "mosaic-6"])
        #expect(PageLayoutCatalog.layout(id: "nope") == nil)
        #expect(PageLayoutCatalog.all.map(\.photoCount) == [1, 1, 1, 2, 3, 3, 2, 4, 5, 6, 1, 2, 3, 0, 0])
    }

    @Test func fullCoversRightPage() throws {
        let s = try Self.compose("full", "full")
        let r = try #require(s.frames.first { $0.id == "R.photo1" }).rect
        #expect(r == Rect(x: 203.2, y: 0, width: 203.2, height: 152.4))
        #expect(s.templateID == "pages" && s.pageLayouts == ["full", "full"])
        #expect(s.frames.map(\.id) == ["L.photo1", "R.photo1"])
    }

    @Test func gridFourHasThreeMillimetreGutters() throws {
        let s = try Self.compose("grid-4", "empty")
        func rect(_ id: String) throws -> Rect { try #require(s.frames.first { $0.id == id }).rect }
        for id in ["L.photo1", "L.photo2", "L.photo3", "L.photo4"] {
            let r = try rect(id)
            #expect(abs(r.size.width - (203.2 - 3) / 2) < 0.001, "\(id)")
            #expect(abs(r.size.height - (152.4 - 3) / 2) < 0.001, "\(id)")
        }
        #expect(abs(try rect("L.photo2").minX - rect("L.photo1").maxX - 3) < 0.001)
        #expect(abs(try rect("L.photo3").minY - rect("L.photo1").maxY - 3) < 0.001)
    }

    @Test func denseAndHeroCoverage() throws {
        let g = try Self.geometry()
        let page = g.format.pageWidthMM * g.format.pageHeightMM
        for l in PageLayoutCatalog.all where l.role == .hero || l.role == .dense {
            let area = l.frames.reduce(0.0) {
                let r = PageSpread.slotRect($1.area, side: .left, geometry: g, marginMM: Self.margin)
                return $0 + r.size.width * r.size.height
            }
            #expect(area >= 0.85 * page, "\(l.id)")
        }
    }

    @Test func slotsMatchOrientation() throws {
        let g = try Self.geometry()
        for l in PageLayoutCatalog.all {
            for f in l.frames {
                let r = PageSpread.slotRect(f.area, side: .left, geometry: g, marginMM: Self.margin)
                switch f.orientation {
                case .portrait: #expect(r.size.height > r.size.width, "\(l.id) \(f.id)")
                case .landscape: #expect(r.size.width > r.size.height, "\(l.id) \(f.id)")
                case .any: Issue.record("\(l.id) \(f.id) has no orientation")
                }
            }
        }
    }

    @Test func noOverlaps() throws {
        let g = try Self.geometry()
        for side in [PageSide.left, .right] {
            let page = g.pageRect(side: side)
            for l in PageLayoutCatalog.all {
                let rects = (l.frames.map(\.area) + l.texts.map(\.area)).map {
                    PageSpread.slotRect($0, side: side, geometry: g, marginMM: Self.margin)
                }
                for (i, a) in rects.enumerated() {
                    #expect(page.contains(a), "\(l.id)")
                    for b in rects[(i + 1)...] { #expect(!a.intersects(b), "\(l.id)") }
                }
                let ids = l.frames.map(\.id) + l.texts.map(\.id)
                #expect(Set(ids).count == ids.count, "\(l.id) ids unique")
                #expect(l.frames.map(\.priority) == Array(0..<l.frames.count), "\(l.id)")
            }
        }
    }

    @Test func composeConformsToMargin() throws {
        let g = try Self.geometry()
        for margin in [10.0, 14.0, 30.0] {
            let rule = MarginRule(geometry: g, marginMM: margin)
            for l in PageLayoutCatalog.all {
                for pair in [(l, l), (l, try Self.layout("full")), (try Self.layout("full"), l)] {
                    let s = PageSpread.compose(left: pair.0, right: pair.1, kind: .gallery, dayKey: nil, id: "s",
                                               geometry: g, marginMM: margin)
                    #expect(rule.conform(s, area: .spread) == s, "\(pair.0.id) \(pair.1.id) \(margin)")
                }
            }
        }
    }

    @Test func sideOfRectFollowsCentre() throws {
        let g = try Self.geometry()
        #expect(PageSpread.side(of: Rect(x: 0, y: 0, width: 100, height: 10), geometry: g) == .left)
        #expect(PageSpread.side(of: Rect(x: 300, y: 0, width: 100, height: 10), geometry: g) == .right)
        // Centre exactly on the spine.
        #expect(PageSpread.side(of: Rect(x: 153.2, y: 0, width: 100, height: 10), geometry: g) == .right)
        #expect(PageSpread.prefix(.left) == "L." && PageSpread.prefix(.right) == "R.")
    }

    @Test func pageItemsAreEmptyAndPrefixed() throws {
        let g = try Self.geometry()
        let items = PageSpread.pageItems(try Self.layout("opener-3"), side: .right, geometry: g, marginMM: Self.margin)
        #expect(items.frames.map(\.id) == ["R.photo1", "R.photo2", "R.photo3"])
        #expect(items.frames.allSatisfy { $0.photoID == nil && $0.zoom == 1 && $0.offset == Point(x: 0, y: 0) })
        #expect(items.texts.map(\.id) == ["R.date", "R.title", "R.body"])
        #expect(items.texts.map(\.role) == [.date, .title, .body])
        #expect(items.texts.allSatisfy { $0.text.isEmpty })
        #expect(PageSpread.templateID == "pages")
    }

    @Test func placeholdersAndRoles() throws {
        let opener = try Self.layout("opener-text")
        #expect(opener.texts.map(\.placeholder) == ["Datum", "Titulek", "Co jsme dnes dělali"])
        #expect(try Self.layout("framed-1").texts.map(\.placeholder) == ["Popisek"])
        #expect(try Self.layout("full").role == .hero)
        #expect(try Self.layout("empty").role == .empty)
        #expect(try Self.layout("landscape-2").role == .sparse)
        #expect(try Self.layout("opener-2l").role == .opener)
        #expect(try Self.layout("grid-4").role == .dense)
    }
}
