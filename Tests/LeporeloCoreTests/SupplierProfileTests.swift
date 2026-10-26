import Testing
@testable import LeporeloCore

@Suite struct SupplierProfileTests {
    @Test func canvaProfileLoads() throws {
        let p = try ProfileCatalog.profile(id: "canva-photobook")
        #expect(p.bleedMM == 3)
        #expect(p.safeMM == 6)
        #expect(p.pageMode == .singlePages)
        #expect(p.formats.count >= 2)
        #expect(p.formats.contains { $0.id.contains("square") && $0.pageWidthMM == $0.pageHeightMM })
        #expect((3...5).contains(p.uploadSteps.count))
    }

    @Test func pageGeometrySinglePages() throws {
        let (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        #expect(f.pageWidthMM == 297 && f.pageHeightMM == 210)
        let g = PageGeometry(format: f, profile: p)
        #expect(g.spreadSize == Size(width: 594, height: 210))
        #expect(g.bleedRect(side: .left) == Rect(x: -3, y: -3, width: 303, height: 216))
        #expect(g.bleedRect(side: .right) == Rect(x: 294, y: -3, width: 303, height: 216))
        #expect(g.safeRect(side: .left) == Rect(x: 6, y: 6, width: 285, height: 198))
        #expect(g.spreadBleedRect == Rect(x: -3, y: -3, width: 600, height: 216))
    }

    @Test func catalogListsCanvaAndRejectsUnknown() throws {
        #expect(try ProfileCatalog.all().contains { $0.id == "canva-photobook" })
        #expect(throws: ProfileCatalogError.profileNotFound("nope")) {
            try ProfileCatalog.profile(id: "nope")
        }
    }

    @Test func spreadsModeBleedIsOuterEdgesOnly() throws {
        var (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        p.pageMode = .spreads
        let g = PageGeometry(format: f, profile: p)
        #expect(g.bleedRect(side: .left) == Rect(x: -3, y: -3, width: 300, height: 216))
        #expect(g.bleedRect(side: .right) == Rect(x: 297, y: -3, width: 300, height: 216))
    }

    @Test func pageCountRuleNextValid() {
        let r = PageCountRule(min: 20, max: nil, multipleOf: 2)
        #expect(r.nextValid(atLeast: 13) == 20)
        #expect(r.nextValid(atLeast: 21) == 22)
        #expect(r.isSatisfied(by: 22))
        #expect(!r.isSatisfied(by: 21))
    }
}
