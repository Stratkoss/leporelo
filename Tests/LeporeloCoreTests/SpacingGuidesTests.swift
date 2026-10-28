import Testing
import Foundation
@testable import LeporeloCore

/// A4 landscape spread, margin 10; `page` is the left page trim 0…297 × 0…210.
@Suite struct SpacingGuidesTests {
    static let page = Rect(x: 0, y: 0, width: 297, height: 210)

    static func line(_ position: Double, _ anchor: SnapAnchor, _ reason: SnapReason = .equalSpacing) -> SnapLine {
        SnapLine(position: position, tier: .items, anchor: anchor, reason: reason)
    }

    /// A rect spanning x `lo…hi` in the row y 50…100.
    static func inRow(_ lo: Double, _ hi: Double) -> Rect {
        Rect(x: lo, y: 50, width: hi - lo, height: 50)
    }

    // MARK: Equal spacing

    @Test func centresBetweenTwoNeighbours() {
        let moving = Rect(x: 85, y: 60, width: 60, height: 30)
        let lines = SpacingGuides.spacingLines(for: moving, moving: .all,
                                               others: [Self.inRow(10, 60), Self.inRow(160, 210)], page: Self.page)
        #expect(lines.x.contains(Self.line(80, .min)))
        #expect(lines.x.allSatisfy { $0.tier == .items && $0.reason == .equalSpacing })
    }

    @Test func matchesAnExistingGap() {
        let others = [Self.inRow(10, 60), Self.inRow(70, 120), Self.inRow(200, 250)]
        let moving = Rect(x: 140, y: 60, width: 40, height: 30)
        let lines = SpacingGuides.spacingLines(for: moving, moving: .all, others: others, page: Self.page)
        #expect(lines.x.contains(Self.line(130, .min)))   // gap 10 to B, as A–B
        #expect(lines.x.contains(Self.line(190, .max)))   // gap 10 to C, as A–B
        // The B–C gap (80) would push the rect into C or B: not offered.
        #expect(!lines.x.contains(Self.line(200, .min)))
        #expect(!lines.x.contains(Self.line(120, .max)))
    }

    @Test func neighboursMustOverlapPerpendicular() {
        let others = [Rect(x: 10, y: 150, width: 50, height: 40), Self.inRow(160, 210)]
        let moving = Rect(x: 85, y: 60, width: 60, height: 30)
        let lines = SpacingGuides.spacingLines(for: moving, moving: .all, others: others, page: Self.page)
        #expect(lines.x.isEmpty)
    }

    @Test func otherPageIgnored() {
        // The right neighbour and the pair beside it lie on the right page.
        let others = [Self.inRow(10, 60), Self.inRow(310, 360), Self.inRow(380, 430)]
        let moving = Rect(x: 150, y: 60, width: 60, height: 30)
        let lines = SpacingGuides.spacingLines(for: moving, moving: .all, others: others, page: Self.page)
        #expect(lines.x.isEmpty)
        #expect(lines.y.isEmpty)
    }

    @Test func resizeSpacingOnlyForTheDraggedEdge() {
        let others = [Self.inRow(10, 60), Self.inRow(160, 210)]
        // minX 80 is 20 from the left neighbour: dragging maxX offers 140 (20 to the right one).
        let lines = SpacingGuides.spacingLines(for: Rect(x: 80, y: 60, width: 50, height: 30), moving: .maxX,
                                               others: others, page: Self.page)
        #expect(lines.x == [Self.line(140, .max)])
        #expect(lines.y.isEmpty)
    }

    @Test func spacingInY() {
        let others = [Rect(x: 50, y: 10, width: 60, height: 40), Rect(x: 50, y: 150, width: 60, height: 40)]
        let lines = SpacingGuides.spacingLines(for: Rect(x: 60, y: 75, width: 30, height: 60), moving: .all,
                                               others: others, page: Self.page)
        #expect(lines.y.contains(Self.line(70, .min)))   // gaps 20 and 20
        #expect(lines.x.isEmpty)
    }

    // MARK: Equal size

    @Test func sizeLinesForResize() {
        let others = [Rect(x: 150, y: 20, width: 85, height: 40)]
        let rect = Rect(x: 20, y: 120, width: 80, height: 50)
        let resize = SpacingGuides.sizeLines(for: rect, moving: .maxX, others: others)
        #expect(resize.x == [Self.line(105, .max, .equalSize)])
        #expect(resize.y.isEmpty)
        let fromMinY = SpacingGuides.sizeLines(for: rect, moving: .minY, others: others)
        #expect(fromMinY.y == [Self.line(130, .min, .equalSize)])
        let move = SpacingGuides.sizeLines(for: rect, moving: .all, others: others)
        #expect(move.x.isEmpty && move.y.isEmpty)
    }

    @Test func sizeMatchesWithinTolerance() {
        let rect = Rect(x: 20, y: 120, width: 85, height: 50)
        let same = Rect(x: 150, y: 20, width: 85.03, height: 40)
        let matches = SpacingGuides.sizeMatches(for: rect, others: [same, Rect(x: 0, y: 0, width: 85.1, height: 10)])
        #expect(matches == [SizeMatch(axis: .x, rect: rect, length: 85),
                            SizeMatch(axis: .x, rect: same, length: 85.03)])
    }

    // MARK: Gaps to draw

    @Test func gapsToNeighboursAndPageEdge() {
        let neighbour = Self.inRow(10, 60)
        // Another pair on the page, 20.03 apart (equal to the left gap within 0.05).
        let p = Rect(x: 150, y: 150, width: 50, height: 30), q = Rect(x: 220.03, y: 150, width: 50, height: 30)
        let rect = Rect(x: 80, y: 60, width: 60, height: 30)
        let gaps = SpacingGuides.gaps(for: rect, others: [neighbour, p, q], page: Self.page)
        #expect(gaps == [
            Gap(axis: .x, from: 60, to: 80, at: 75, isEqual: true),
            Gap(axis: .x, from: 140, to: 297, at: 75, isEqual: false),
            Gap(axis: .y, from: 0, to: 60, at: 110, isEqual: false),
            Gap(axis: .y, from: 90, to: 210, at: 110, isEqual: false),
            Gap(axis: .x, from: 200, to: 220.03, at: 165, isEqual: true),
        ])
    }

    @Test func equalGapsBetweenTwoNeighbours() {
        let gaps = SpacingGuides.gaps(for: Rect(x: 80, y: 60, width: 60, height: 30),
                                      others: [Self.inRow(10, 60), Self.inRow(160, 210)], page: Self.page)
        #expect(gaps.filter(\.isEqual) == [Gap(axis: .x, from: 60, to: 80, at: 75, isEqual: true),
                                           Gap(axis: .x, from: 140, to: 160, at: 75, isEqual: true)])
    }

    /// The caller's pipeline: alignment targets merged with spacing lines, then snapped. The
    /// left page centre (148.5, tier `.page`) is closer to the rect's centre than the equal
    /// spacing line is to its minX, but the spacing line is an item line and wins.
    @Test func snapLandsOnEqualSpacing() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        let geometry = PageGeometry(format: format, profile: profile)
        let others = [Self.inRow(40, 90), Self.inRow(200, 250)]
        let moving = Rect(x: 115, y: 60, width: 64, height: 30)   // centre 147 (1.5 from 148.5), minX 2 from 113
        var targets = SnapEngine.targets(geometry: geometry, marginMM: 10, area: .spread, others: others,
                                         settings: SnapSettings(grid: false, objects: true))
        let spacing = SpacingGuides.spacingLines(for: moving, moving: .all, others: others, page: Self.page)
        targets.x += spacing.x
        targets.y += spacing.y
        let result = SnapEngine.snap(moving, moving: .all, to: targets, threshold: 3)
        #expect(result.rect.minX == 113)
        #expect(result.reasons[.x] == .equalSpacing)
    }

    // MARK: The margin rule

    @Test func equalSpacingTargetInMarginBandIsDropped() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        let rule = MarginRule(geometry: PageGeometry(format: format, profile: profile), marginMM: 10)
        let raw = SnapTargets(x: [Self.line(4, .min), Self.line(80, .min)], y: [])
        #expect(rule.allowedTargets(raw, area: .spread).x == [Self.line(80, .min)])
    }
}
