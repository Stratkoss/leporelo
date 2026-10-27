import Testing
import Foundation
@testable import LeporeloCore

@Suite struct MarginRuleTests {
    static func geometry() throws -> PageGeometry {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        return PageGeometry(format: format, profile: profile)
    }

    static func rule(margin: Double = 10) throws -> MarginRule {
        MarginRule(geometry: try geometry(), marginMM: margin)
    }

    static func frame(x0: Double, x1: Double, y0: Double = 50, y1: Double = 150) -> Rect {
        Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    @Test func frameEdgeInBandSnapsToNearerSide() throws {
        let rule = try Self.rule()
        #expect(rule.conformFrame(Self.frame(x0: 4, x1: 100), area: .spread).minX == 0)
        #expect(rule.conformFrame(Self.frame(x0: 7, x1: 100), area: .spread).minX == 10)
    }

    @Test func frameOnPageEdgeAndSpineStays() throws {
        let rule = try Self.rule()
        let right = Rect(x: 297, y: 0, width: 297, height: 210)
        let left = Rect(x: 0, y: 0, width: 297, height: 210)
        #expect(rule.conformFrame(right, area: .spread) == right)
        #expect(rule.conformFrame(left, area: .spread) == left)
    }

    @Test func frameNearSpineSnaps() throws {
        let rule = try Self.rule()
        #expect(rule.conformFrame(Self.frame(x0: 200, x1: 290), area: .spread).maxX == 287)
        #expect(rule.conformFrame(Self.frame(x0: 200, x1: 295), area: .spread).maxX == 297)
        #expect(rule.conformFrame(Self.frame(x0: 300, x1: 400), area: .spread).minX == 297)
        #expect(rule.conformFrame(Self.frame(x0: 305, x1: 400), area: .spread).minX == 307)
    }

    @Test func pageAreaTreatsSpineLikeSpread() throws {
        let rule = try Self.rule()
        #expect(rule.pageEdgesX(.spread) == [0, 297, 594])
        #expect(rule.pageEdgesX(.page) == [0, 297, 594])
        #expect(rule.pageEdgesX(.cover) == [0, 297])
        #expect(rule.conformFrame(Self.frame(x0: 305, x1: 400), area: .page).minX == 307)
    }

    @Test func frameIsClippedToAreaAndKeepsMinimumSize() throws {
        let rule = try Self.rule()
        let cover = rule.conformFrame(Rect(x: 250, y: 50, width: 200, height: 100), area: .cover)
        #expect(cover.maxX <= 297)
        let spread = rule.conformFrame(Rect(x: -20, y: -20, width: 5, height: 5), area: .spread)
        #expect(spread.size.width >= MarginRule.minItemMM && spread.size.height >= MarginRule.minItemMM)
        #expect(spread.minX >= 0 && spread.minY >= 0)
    }

    @Test func textIsClampedInsideMargin() throws {
        let rule = try Self.rule()
        let text = rule.conformText(Rect(x: 2, y: 200, width: 58, height: 9), area: .spread)
        #expect(text.minX == 10)
        #expect(text.maxY == 200)
    }

    @Test func textIsShrunkToTheMarginBoxOfItsPage() throws {
        let rule = try Self.rule()
        let text = rule.conformText(Rect(x: 400, y: 0, width: 500, height: 300), area: .spread)
        #expect(text == Rect(x: 307, y: 10, width: 277, height: 190))
    }

    @Test func tinyFrameInCornerKeepsMinimumSize() throws {
        let rule = try Self.rule(margin: 30)
        let result = rule.conformFrame(Rect(x: 2, y: 2, width: 12, height: 12), area: .spread)
        #expect(result.size.width >= 10 && result.size.height >= 10)
        #expect(Rect(x: 0, y: 0, width: 297, height: 210).contains(result))
        for v in [result.minX, result.maxX, result.minY, result.maxY] {
            #expect(!(v > 0 && v < 30))
        }
    }

    @Test func conformChangesOnlyRectsAndKeepsEverythingElse() throws {
        let rule = try Self.rule()
        let spread = Spread(
            id: "s", kind: .gallery, templateID: "t", dayKey: nil,
            frames: [Frame(id: "f", rect: Self.frame(x0: 4, x1: 100), photoID: "p",
                           offset: Point(x: 0.2, y: -0.1), zoom: 1.5)],
            texts: [TextBox(id: "x", rect: Rect(x: 2, y: 200, width: 58, height: 9), role: .caption, text: "Ahoj")],
            manuallyEdited: true, customLayout: true)
        let result = rule.conform(spread, area: .spread)
        #expect(result.frames[0].rect.minX == 0)
        #expect(result.texts[0].rect.minX == 10)
        var expected = spread
        expected.frames[0].rect = result.frames[0].rect
        expected.texts[0].rect = result.texts[0].rect
        #expect(result == expected)
    }

    @Test func marginIsClampedToSafeZoneAndMaximum() throws {
        let profile = try Self.geometry().profile
        #expect(MarginRule.clampedMargin(2, profile: profile) == 6)
        #expect(MarginRule.clampedMargin(50, profile: profile) == 30)
        #expect(MarginRule.clampedMargin(12, profile: profile) == 12)
    }
}
