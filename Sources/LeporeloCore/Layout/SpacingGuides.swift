import Foundation

/// A distance to draw: along `axis` from `from` to `to` (`from` < `to`), at the perpendicular
/// position `at`. `isEqual` marks a gap equal to another gap in the same axis.
public struct Gap: Sendable, Equatable {
    public var axis: SnapAxis
    public var from: Double
    public var to: Double
    public var at: Double
    public var isEqual: Bool

    public init(axis: SnapAxis, from: Double, to: Double, at: Double, isEqual: Bool) {
        self.axis = axis
        self.from = from
        self.to = to
        self.at = at
        self.isEqual = isEqual
    }
}

/// A rectangle whose width (`.x`) or height (`.y`) is `length` and equals another one's.
public struct SizeMatch: Sendable, Equatable {
    public var axis: SnapAxis
    public var rect: Rect
    public var length: Double

    public init(axis: SnapAxis, rect: Rect, length: Double) {
        self.axis = axis
        self.rect = rect
        self.length = length
    }
}

/// Equal spacing and equal size: the snap lines that give them and the gaps and sizes to draw.
/// All lines are tier `.items`; the caller merges them with `SnapEngine.targets`.
///
/// A neighbour of a rectangle in x is the nearest other on that side (by centre) that overlaps
/// it in y, and the other way round. Spacing only counts the `others` whose centre lies on
/// `page` (the trim rect of the rectangle's page): the spine separates. Values are millimetres.
public enum SpacingGuides {
    private static let eps = 1e-6

    /// Lines that give equal gaps. A move (both edges of an axis in `edges`) gets a `.min` line
    /// that centres the rect between its two neighbours and, for every gap between two other
    /// neighbours on the page, a `.min` line at that gap after the neighbour before it and a
    /// `.max` line at that gap before the neighbour after it (unless the rect would then run
    /// into the opposite neighbour). A resize looks only at the dragged edge: the gap on the far
    /// side copied to the dragged side, and the gaps between other neighbours.
    public static func spacingLines(for rect: Rect, moving edges: RectEdges, others: [Rect], page: Rect) -> SnapTargets {
        let others = others.filter { centre(of: $0, isOn: page) }
        return SnapTargets(x: spacingLines(rect, edges, others, .x), y: spacingLines(rect, edges, others, .y))
    }

    /// Lines that make the dragged edge give a width (height) equal to another's: `.max` at
    /// minX + width when maxX is dragged, `.min` at maxX − width when minX is. None for a move.
    public static func sizeLines(for rect: Rect, moving edges: RectEdges, others: [Rect]) -> SnapTargets {
        guard edges != .all else { return SnapTargets(x: [], y: []) }
        func lines(_ axis: SnapAxis) -> [SnapLine] {
            let (lo, hi) = edgeNames(axis)
            let s = span(rect, axis)
            var result: [SnapLine] = []
            for other in others {
                let length = span(other, axis).length
                guard length > eps else { continue }
                if edges.contains(hi) { result.append(line(s.lo + length, .max, .equalSize)) }
                if edges.contains(lo) { result.append(line(s.hi - length, .min, .equalSize)) }
            }
            return unique(result)
        }
        return SnapTargets(x: lines(.x), y: lines(.y))
    }

    /// The distances to draw around `rect`: left, right, top, bottom, each to the nearest
    /// neighbour on that side, else to the edge of `page` (none when it would not be positive).
    /// A gap to a neighbour is `isEqual` when another neighbour gap of `rect` in that axis, or
    /// a gap between two other neighbours on the page, is equal within `tolerance`; those other
    /// gaps follow the four, so every equal gap can be drawn.
    public static func gaps(for rect: Rect, others: [Rect], page: Rect, tolerance: Double = 0.05) -> [Gap] {
        let others = others.filter { centre(of: $0, isOn: page) }
        var own: [Gap] = [], equalOthers: [Gap] = []
        for axis in [SnapAxis.x, .y] {
            let s = span(rect, axis), p = span(rect, axis.other), pageSpan = span(page, axis)
            let (before, after) = neighbours(of: rect, among: others, axis)
            let pairGaps = pairs(others, obstacle: rect, axis).map { a, b in
                Gap(axis: axis, from: span(a, axis).hi, to: span(b, axis).lo, at: overlapMid(a, b, axis), isEqual: false)
            }
            var sides: [(gap: Gap, toNeighbour: Bool)] = []
            if let before {
                sides.append((Gap(axis: axis, from: span(before, axis).hi, to: s.lo,
                                  at: overlapMid(before, rect, axis), isEqual: false), true))
            } else {
                sides.append((Gap(axis: axis, from: pageSpan.lo, to: s.lo, at: p.mid, isEqual: false), false))
            }
            if let after {
                sides.append((Gap(axis: axis, from: s.hi, to: span(after, axis).lo,
                                  at: overlapMid(rect, after, axis), isEqual: false), true))
            } else {
                sides.append((Gap(axis: axis, from: s.hi, to: pageSpan.hi, at: p.mid, isEqual: false), false))
            }
            sides = sides.filter { $0.gap.length > eps }
            let neighbourLengths = sides.filter(\.toNeighbour).map(\.gap.length)
            for (index, side) in sides.enumerated() {
                var gap = side.gap
                if side.toNeighbour {
                    let rest = sides.enumerated().filter { $0.offset != index && $0.element.toNeighbour }
                        .map(\.element.gap.length) + pairGaps.map(\.length)
                    gap.isEqual = rest.contains { abs($0 - gap.length) <= tolerance }
                }
                own.append(gap)
            }
            for var gap in pairGaps where neighbourLengths.contains(where: { abs($0 - gap.length) <= tolerance }) {
                gap.isEqual = true
                equalOthers.append(gap)
            }
        }
        return own + equalOthers
    }

    /// Per axis where some other's width (height) equals `rect`'s within `tolerance`: `rect`
    /// first, then each such other, each with its own length.
    public static func sizeMatches(for rect: Rect, others: [Rect], tolerance: Double = 0.05) -> [SizeMatch] {
        var result: [SizeMatch] = []
        for axis in [SnapAxis.x, .y] {
            let length = span(rect, axis).length
            let matching = others.filter { abs(span($0, axis).length - length) <= tolerance }
            guard !matching.isEmpty else { continue }
            result.append(SizeMatch(axis: axis, rect: rect, length: length))
            result += matching.map { SizeMatch(axis: axis, rect: $0, length: span($0, axis).length) }
        }
        return result
    }

    // MARK: - One axis

    private static func spacingLines(_ rect: Rect, _ edges: RectEdges, _ others: [Rect], _ axis: SnapAxis) -> [SnapLine] {
        let (loEdge, hiEdge) = edgeNames(axis)
        let movesLo = edges.contains(loEdge), movesHi = edges.contains(hiEdge)
        guard movesLo || movesHi else { return [] }
        let s = span(rect, axis)
        let (before, after) = neighbours(of: rect, among: others, axis)
        let gaps = pairs(others, obstacle: rect, axis).map { span($1, axis).lo - span($0, axis).hi }
        var lines: [SnapLine] = []

        if movesLo && movesHi {
            if let before, let after {
                let gap = (span(after, axis).lo - span(before, axis).hi - s.length) / 2
                if gap > eps { lines.append(line(span(before, axis).hi + gap, .min, .equalSpacing)) }
            }
            for gap in gaps {
                if let before {
                    let v = span(before, axis).hi + gap
                    if after.map({ v + s.length <= span($0, axis).lo + eps }) ?? true {
                        lines.append(line(v, .min, .equalSpacing))
                    }
                }
                if let after {
                    let v = span(after, axis).lo - gap
                    if before.map({ v - s.length >= span($0, axis).hi - eps }) ?? true {
                        lines.append(line(v, .max, .equalSpacing))
                    }
                }
            }
        } else if movesHi, let after {
            var copied = gaps
            if let before, s.lo - span(before, axis).hi > eps { copied.insert(s.lo - span(before, axis).hi, at: 0) }
            for gap in copied {
                let v = span(after, axis).lo - gap
                if v > s.lo + eps { lines.append(line(v, .max, .equalSpacing)) }
            }
        } else if movesLo, let before {
            var copied = gaps
            if let after, span(after, axis).lo - s.hi > eps { copied.insert(span(after, axis).lo - s.hi, at: 0) }
            for gap in copied {
                let v = span(before, axis).hi + gap
                if v < s.hi - eps { lines.append(line(v, .min, .equalSpacing)) }
            }
        }
        return unique(lines)
    }

    /// The nearest other before and after `rect` along `axis` (by centre) that overlaps it on
    /// the perpendicular axis.
    private static func neighbours(of rect: Rect, among others: [Rect], _ axis: SnapAxis) -> (before: Rect?, after: Rect?) {
        let mid = span(rect, axis).mid
        let beside = others.filter { overlapsAcross($0, rect, axis) }
        let before = beside.filter { span($0, axis).mid < mid }.max { span($0, axis).hi < span($1, axis).hi }
        let after = beside.filter { span($0, axis).mid > mid }.min { span($0, axis).lo < span($1, axis).lo }
        return (before, after)
    }

    /// Pairs (a, b) of `others` where b is a's neighbour after it along `axis` with a positive
    /// gap; a pair with `obstacle` (the rect being dragged) nearer to a than b does not count.
    private static func pairs(_ others: [Rect], obstacle: Rect, _ axis: SnapAxis) -> [(Rect, Rect)] {
        var result: [(Rect, Rect)] = []
        for (index, a) in others.enumerated() {
            let rest = others.enumerated().filter { $0.offset != index }.map(\.element)
            guard let b = neighbours(of: a, among: rest, axis).after,
                  span(b, axis).lo - span(a, axis).hi > eps else { continue }
            let blocked = overlapsAcross(obstacle, a, axis) && span(obstacle, axis).mid > span(a, axis).mid
                && span(obstacle, axis).lo < span(b, axis).lo
            if !blocked { result.append((a, b)) }
        }
        return result
    }

    // MARK: - Helpers

    private struct Span {
        var lo: Double
        var hi: Double
        var length: Double { hi - lo }
        var mid: Double { lo + length / 2 }
    }

    private static func span(_ rect: Rect, _ axis: SnapAxis) -> Span {
        axis == .x ? Span(lo: rect.minX, hi: rect.maxX) : Span(lo: rect.minY, hi: rect.maxY)
    }

    private static func edgeNames(_ axis: SnapAxis) -> (lo: RectEdges, hi: RectEdges) {
        axis == .x ? (.minX, .maxX) : (.minY, .maxY)
    }

    /// True when `a` and `b` overlap on the axis perpendicular to `axis`.
    private static func overlapsAcross(_ a: Rect, _ b: Rect, _ axis: SnapAxis) -> Bool {
        let p = span(a, axis.other), q = span(b, axis.other)
        return p.lo < q.hi - eps && q.lo < p.hi - eps
    }

    /// The middle of the overlap of `a` and `b` on the axis perpendicular to `axis`.
    private static func overlapMid(_ a: Rect, _ b: Rect, _ axis: SnapAxis) -> Double {
        let p = span(a, axis.other), q = span(b, axis.other)
        let lo = max(p.lo, q.lo), hi = min(p.hi, q.hi)
        return lo + (hi - lo) / 2
    }

    /// True when the centre of `rect` lies on `page` (its right edge belongs to the next page).
    private static func centre(of rect: Rect, isOn page: Rect) -> Bool {
        let x = span(rect, .x).mid, y = span(rect, .y).mid
        return x >= page.minX && x < page.maxX && y >= page.minY && y <= page.maxY
    }

    private static func line(_ position: Double, _ anchor: SnapAnchor, _ reason: SnapReason) -> SnapLine {
        SnapLine(position: position, tier: .items, anchor: anchor, reason: reason)
    }

    private static func unique(_ lines: [SnapLine]) -> [SnapLine] {
        var seen = Set<SnapLine>()
        return lines.filter { seen.insert($0).inserted }
    }
}

private extension SnapAxis {
    var other: SnapAxis { self == .x ? .y : .x }
}

private extension Gap {
    var length: Double { to - from }
}
