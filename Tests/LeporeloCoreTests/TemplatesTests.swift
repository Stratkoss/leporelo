import Testing
@testable import LeporeloCore

@Suite struct TemplatesTests {
    static func canva() throws -> PageGeometry {
        let (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        return PageGeometry(format: f, profile: p)
    }

    @Test func everyTemplateFramesInsideSpread() {
        let unit = Rect(x: 0, y: 0, width: 1, height: 1)
        for t in TemplateCatalog.all {
            for f in t.frames { #expect(unit.contains(f.rect), "\(t.id) \(f.id)") }
            for x in t.texts { #expect(unit.contains(x.rect), "\(t.id) \(x.id)") }
            for (i, a) in t.frames.enumerated() {
                for b in t.frames[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(t.id) \(a.id)/\(b.id)") }
            }
            #expect(t.frames.count == t.photoCount, "\(t.id)")
            let ids = t.frames.map(\.id) + t.texts.map(\.id)
            #expect(Set(ids).count == ids.count, "\(t.id) ids unique")
        }
    }

    @Test func squareFitsBoth() {
        let square = AlbumDrafterTests.photo("sq", day: AlbumDrafterTests.june18, minute: 0, pixels: (3000, 3000))
        #expect(TemplateLayout.fits(square, .landscape) && TemplateLayout.fits(square, .portrait))
        #expect(TemplateLayout.fits(square, .any))
        let wide = AlbumDrafterTests.photo("w", day: AlbumDrafterTests.june18, minute: 0)
        #expect(TemplateLayout.fits(wide, .landscape) && !TemplateLayout.fits(wide, .portrait))
    }

    @Test func templatesPerKind() {
        #expect(TemplateCatalog.templates(kind: .journal).count == 3)
        #expect(TemplateCatalog.templates(kind: .gallery).count == 3)
        #expect(TemplateCatalog.templates(kind: .intro).count == 1)
        #expect(TemplateCatalog.templates(kind: .closing).count == 1)
        #expect(TemplateCatalog.templates(kind: .blank).count == 1)
        #expect(TemplateCatalog.template(id: "journal-4")?.photoCount == 4)
        #expect(TemplateCatalog.template(id: "nope") == nil)
    }

    @Test func mainFrameAndOrientationMix() {
        for t in TemplateCatalog.all where !t.frames.isEmpty {
            #expect(t.frames.filter { $0.priority == 0 }.count == 1, "\(t.id)")
        }
        for id in ["journal-3", "journal-4", "journal-5", "gallery-2", "gallery-3"] {
            let t = TemplateCatalog.template(id: id)!
            #expect(t.frames.contains { $0.orientation == .portrait }, "\(id)")
            #expect(t.frames.contains { $0.orientation == .landscape }, "\(id)")
        }
    }

    @Test func journalTextsOnLeftPage() {
        for t in TemplateCatalog.templates(kind: .journal) {
            let roles = Set(t.texts.map(\.role))
            #expect(roles == [.date, .title, .body])
            for x in t.texts { #expect(x.rect.maxX <= 0.5, "\(t.id) \(x.id)") }
        }
    }

    @Test func instantiateScalesToMM() throws {
        let g = try Self.canva()
        let t = TemplateCatalog.template(id: "gallery-1")!
        let s = TemplateLayout.instantiate(t, geometry: g, dayKey: nil, id: "s1")
        let main = s.frames.first!
        #expect(main.rect.minX >= 297)
        #expect(main.rect.maxX == 594 && main.rect.maxY == 210 && main.rect.minY == 0)
        #expect(main.photoID == nil && main.zoom == 1 && main.offset == Point(x: 0, y: 0))
        #expect(s.id == "s1" && s.templateID == "gallery-1" && s.kind == .gallery && !s.manuallyEdited)
        #expect(s.frames.map(\.id) == t.frames.map(\.id))
        #expect(s.texts.allSatisfy { $0.text.isEmpty })
    }

    @Test func textsStayInSafeZoneOnCanva() throws {
        let g = try Self.canva()
        let safeL = g.safeRect(side: .left)
        let safeR = g.safeRect(side: .right)
        for t in TemplateCatalog.all {
            let s = TemplateLayout.instantiate(t, geometry: g, dayKey: nil)
            for x in s.texts {
                #expect(safeL.contains(x.rect) || safeR.contains(x.rect), "\(t.id) \(x.id)")
            }
            for (f, slot) in zip(s.frames, t.frames) where !slot.bleeds {
                #expect(safeL.contains(f.rect) || safeR.contains(f.rect), "\(t.id) \(f.id)")
            }
        }
    }

    @Test func bleedingFramesTouchEdge() {
        for t in TemplateCatalog.all {
            for f in t.frames where f.bleeds {
                let r = f.rect
                let touches = r.minX == 0 || r.maxX == 1 || r.minY == 0 || r.maxY == 1
                #expect(touches, "\(t.id) \(f.id)")
            }
        }
    }

    /// True when no edge of `rect` lies strictly inside the band (0, margin) from a page edge.
    static func hasNoEdgeInBand(_ rect: Rect, edgesX: [Double], height: Double, margin: Double) -> Bool {
        let eps = 1e-6
        func inBand(_ v: Double, _ edges: [Double]) -> Bool {
            edges.contains { abs(v - $0) > eps && abs(v - $0) < margin - eps }
        }
        return ![rect.minX, rect.maxX].contains { inBand($0, edgesX) }
            && ![rect.minY, rect.maxY].contains { inBand($0, [0, height]) }
    }

    @Test func instantiateConformsTemplateToMargin() throws {
        let (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        let g = PageGeometry(format: f, profile: p)
        let rule = MarginRule(geometry: g, marginMM: 10)
        let edges = rule.pageEdgesX(.spread)
        let journal = TemplateLayout.instantiate(try #require(TemplateCatalog.template(id: "journal-3")),
                                                 geometry: g, dayKey: nil, id: "s", marginMM: 10)
        #expect(journal.texts.count == 3 && journal.frames.count == 3)
        for r in journal.frames.map(\.rect) + journal.texts.map(\.rect) {
            #expect(Self.hasNoEdgeInBand(r, edgesX: edges, height: g.format.pageHeightMM, margin: 10), "\(r)")
        }
        let gallery = TemplateLayout.instantiate(try #require(TemplateCatalog.template(id: "gallery-1")),
                                                 geometry: g, dayKey: nil, id: "s", marginMM: 10)
        let frame = try #require(gallery.frames.first).rect
        #expect(abs(frame.minX - 203.2) < 1e-9 && abs(frame.maxX - 406.4) < 1e-9)
        #expect(frame.minY == 0 && abs(frame.maxY - 152.4) < 1e-9)
    }

    @Test func instantiateDefaultMarginIsTheAlbumDefault() throws {
        let g = try Self.canva()
        let t = try #require(TemplateCatalog.template(id: "journal-3"))
        #expect(TemplateLayout.instantiate(t, geometry: g, dayKey: nil, id: "s")
                == TemplateLayout.instantiate(t, geometry: g, dayKey: nil, id: "s", marginMM: Album.defaultMarginMM))
    }
}
