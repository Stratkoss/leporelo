import Testing
import Foundation
@testable import LeporeloCore

@Suite struct SnapEngineTests {
    static func geometry() throws -> PageGeometry {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        return PageGeometry(format: format, profile: profile)
    }

    static func targets(
        area: PrintArea = .spread, others: [Rect] = [], grid: Bool = false, objects: Bool = true
    ) throws -> SnapTargets {
        SnapEngine.targets(
            geometry: try geometry(), marginMM: 10, area: area, others: others,
            settings: SnapSettings(grid: grid, objects: objects))
    }

    @Test func moveSnapsLeftEdgeToMargin() throws {
        let t = try Self.targets()
        let rect = Rect(x: 11.5, y: 50, width: 80, height: 60)
        let result = SnapEngine.snap(rect, moving: .all, to: t, threshold: 2)
        #expect(result.rect.minX == 10)
        #expect(result.rect.size == rect.size)
        #expect(result.guides.contains(SnapGuide(axis: .x, position: 10)))
    }

    @Test func moveSnapsCenterToPageCenter() throws {
        let t = try Self.targets()
        // centre x = 150, page centre of the right page is 445.5, of the left 148.5
        let rect = Rect(x: 110, y: 50, width: 80, height: 60)
        let result = SnapEngine.snap(rect, moving: .all, to: t, threshold: 2)
        #expect(result.rect.minX == 108.5)
        #expect(result.rect.midXForTest == 148.5)
        #expect(result.guides.contains(SnapGuide(axis: .x, position: 148.5)))
    }

    @Test func noSnapBeyondThreshold() throws {
        let t = try Self.targets()
        let rect = Rect(x: 60, y: 50, width: 40, height: 30)
        let result = SnapEngine.snap(rect, moving: .all, to: t, threshold: 2)
        #expect(result.rect == rect)
        #expect(result.guides.isEmpty)
    }

    @Test func resizeSnapsOnlyMovingEdge() throws {
        let t = try Self.targets()
        // minX is at the 10 mm margin target already; moving maxX near 287 snaps, minX untouched
        let rect = Rect(x: 10.5, y: 50, width: 276, height: 60)
        let result = SnapEngine.snap(rect, moving: .maxX, to: t, threshold: 2)
        #expect(result.rect.minX == 10.5)
        #expect(result.rect.maxX == 287)
        #expect(result.rect.minY == 50)
        #expect(result.rect.size.height == 60)
        #expect(result.guides == [SnapGuide(axis: .x, position: 287)])
    }

    @Test func gridTargetsOnlyWhenGridOn() throws {
        let off = try Self.targets(grid: false)
        #expect(!off.x.contains(5))
        #expect(!off.x.contains(302))
        let on = try Self.targets(grid: true, objects: false)
        #expect(on.x.contains(5))
        #expect(on.x.contains(302))
        #expect(on.y.contains(205))
        #expect(!on.x.contains(0.5))
    }

    @Test func gapTargetsBesideOtherFrames() throws {
        let other = Rect(x: 100, y: 20, width: 50, height: 40)
        let t = try Self.targets(others: [other])
        #expect(t.x.contains(96))
        #expect(t.x.contains(154))
        #expect(t.x.contains(100) && t.x.contains(125) && t.x.contains(150))
        #expect(t.y.contains(16) && t.y.contains(64))
    }

    @Test func noTargetsWhenBothOff() throws {
        let t = try Self.targets(others: [Rect(x: 1, y: 1, width: 5, height: 5)], grid: false, objects: false)
        #expect(t.x.isEmpty)
        #expect(t.y.isEmpty)
    }

    @Test func pageTargetsForSpreadAndCover() throws {
        let spread = try Self.targets(area: .spread)
        for x in [0, 10, 148.5, 287, 297, 307, 445.5, 584, 594] as [Double] { #expect(spread.x.contains(x)) }
        for y in [0, 10, 105, 200, 210] as [Double] { #expect(spread.y.contains(y)) }
        let cover = try Self.targets(area: .cover)
        #expect(cover.x.contains(148.5))
        #expect(!cover.x.contains(445.5))
        #expect(!cover.x.contains(307))
        #expect(cover.x.max() == 297)
    }

    @Test func tieGoesToSmallerTarget() {
        let t = SnapTargets(x: [10, 14], y: [])
        let result = SnapEngine.snap(Rect(x: 12, y: 0, width: 0, height: 1), moving: .all, to: t, threshold: 3)
        #expect(result.rect.minX == 10)
    }

    @Test func bestOfMinMidMaxWins() {
        let t = SnapTargets(x: [100, 200], y: [])
        // minX 98.5 (d 1.5 to 100), maxX 199.5 (d 0.5 to 200) -> maxX wins
        let result = SnapEngine.snap(Rect(x: 98.5, y: 0, width: 101, height: 10), moving: .all, to: t, threshold: 2)
        #expect(result.rect.maxX == 200)
        #expect(result.guides == [SnapGuide(axis: .x, position: 200)])
    }

    @Test func resizeDoesNotInvertRect() {
        let t = SnapTargets(x: [50], y: [])
        let rect = Rect(x: 51, y: 0, width: 5, height: 5)
        let result = SnapEngine.snap(rect, moving: .maxX, to: t, threshold: 10)
        #expect(result.rect == rect)
    }
}

private extension Rect {
    var midXForTest: Double { minX + size.width / 2 }
}
