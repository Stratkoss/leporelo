import Foundation

/// Which kinds of snap targets the editor offers.
public struct SnapSettings: Sendable, Equatable {
    public var grid: Bool
    public var objects: Bool
    public var gridMM: Double
    public var gapMM: Double

    public init(grid: Bool, objects: Bool, gridMM: Double = 5, gapMM: Double = 4) {
        self.grid = grid
        self.objects = objects
        self.gridMM = gridMM
        self.gapMM = gapMM
    }
}

/// The edges of a rectangle that take part in a snap. `.all` is a move, anything less a resize.
public struct RectEdges: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let minX = RectEdges(rawValue: 1 << 0)
    public static let maxX = RectEdges(rawValue: 1 << 1)
    public static let minY = RectEdges(rawValue: 1 << 2)
    public static let maxY = RectEdges(rawValue: 1 << 3)
    public static let all: RectEdges = [.minX, .maxX, .minY, .maxY]
}

public enum SnapAxis: Sendable, Hashable {
    case x, y
}

/// A guide line to draw; `.x` is a vertical line at x = `position`, `.y` a horizontal one.
public struct SnapGuide: Sendable, Equatable {
    public var axis: SnapAxis
    public var position: Double

    public init(axis: SnapAxis, position: Double) {
        self.axis = axis
        self.position = position
    }
}

/// The floor a snap line belongs to: a tier is searched only when no line of the tiers before
/// it is in reach, so a neighbour's edge beats a slightly closer page or grid line.
public enum SnapTier: Int, Sendable, Hashable, CaseIterable, Comparable {
    case items = 0, page = 1, grid = 2

    public static func < (lhs: SnapTier, rhs: SnapTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which point of the moving rectangle a line may catch: `.any` for alignment lines,
/// `.min`/`.max`/`.centre` for equal spacing and equal size.
public enum SnapAnchor: Sendable, Hashable {
    case any, min, centre, max
}

/// Why a line is a target: it is the edge or centre of something, or it gives an equal gap
/// or an equal size.
public enum SnapReason: Sendable, Hashable {
    case alignment, equalSpacing, equalSize
}

/// One target line: at `position` (x for the `x` lines, y for the `y` lines), in `tier`.
public struct SnapLine: Sendable, Hashable {
    public var position: Double
    public var tier: SnapTier
    public var anchor: SnapAnchor
    public var reason: SnapReason

    public init(position: Double, tier: SnapTier, anchor: SnapAnchor = .any, reason: SnapReason = .alignment) {
        self.position = position
        self.tier = tier
        self.anchor = anchor
        self.reason = reason
    }
}

public struct SnapTargets: Sendable, Equatable {
    public var x: [SnapLine]
    public var y: [SnapLine]

    public init(x: [SnapLine], y: [SnapLine]) {
        self.x = x
        self.y = y
    }
}

public struct SnapResult: Sendable, Equatable {
    public var rect: Rect
    public var guides: [SnapGuide]
    /// Per axis that snapped, the reason of the line it snapped to.
    public var reasons: [SnapAxis: SnapReason]

    public init(rect: Rect, guides: [SnapGuide], reasons: [SnapAxis: SnapReason] = [:]) {
        self.rect = rect
        self.guides = guides
        self.reasons = reasons
    }
}

/// Pure snapping: collects target lines for a drag and moves a rectangle (or some of its
/// edges) onto the best one within a threshold. All values are millimetres.
public enum SnapEngine {
    /// The alignment lines of a drag. `.items`: the edges and centres of `others`; `.page`: the
    /// trim and spine, the margin lines, the page centres and the lines `gapMM` beside `others`
    /// (both only with `settings.objects`); `.grid`: the grid (with `settings.grid`). One line
    /// per position, the lowest tier kept, sorted by position.
    public static func targets(
        geometry: PageGeometry, marginMM: Double, area: PrintArea,
        others: [Rect], settings: SnapSettings
    ) -> SnapTargets {
        var xs: [Double: SnapTier] = [:], ys: [Double: SnapTier] = [:]
        func add(_ v: Double, _ tier: SnapTier, to lines: inout [Double: SnapTier]) {
            lines[v] = min(lines[v] ?? tier, tier)
        }
        let height = geometry.format.pageHeightMM
        let edgesX = MarginRule(geometry: geometry, marginMM: marginMM).pageEdgesX(area)
        let pages = zip(edgesX, edgesX.dropFirst()).map { ($0, $1) }

        if settings.objects {
            for other in others {
                for v in [other.minX, other.minX + other.size.width / 2, other.maxX] { add(v, .items, to: &xs) }
                for v in [other.minY, other.minY + other.size.height / 2, other.maxY] { add(v, .items, to: &ys) }
            }
            for (lo, hi) in pages {
                for v in [lo, hi, (lo + hi) / 2] { add(v, .page, to: &xs) }
                for edge in [lo, hi] {
                    for candidate in [edge - marginMM, edge + marginMM] where candidate >= lo && candidate <= hi {
                        add(candidate, .page, to: &xs)
                    }
                }
            }
            for v in [0, height, height / 2] { add(v, .page, to: &ys) }
            for candidate in [marginMM, height - marginMM] where candidate >= 0 && candidate <= height {
                add(candidate, .page, to: &ys)
            }
            for other in others {
                for v in [other.minX - settings.gapMM, other.maxX + settings.gapMM] { add(v, .page, to: &xs) }
                for v in [other.minY - settings.gapMM, other.maxY + settings.gapMM] { add(v, .page, to: &ys) }
            }
        }

        if settings.grid, settings.gridMM > 0 {
            let step = settings.gridMM
            for (lo, hi) in pages {
                var k = 0
                while lo + Double(k) * step <= hi {
                    add(lo + Double(k) * step, .grid, to: &xs)
                    k += 1
                }
            }
            var k = 0
            while Double(k) * step <= height {
                add(Double(k) * step, .grid, to: &ys)
                k += 1
            }
        }

        func lines(_ tiers: [Double: SnapTier]) -> [SnapLine] {
            tiers.sorted { $0.key < $1.key }.map { SnapLine(position: $0.key, tier: $0.value) }
        }
        return SnapTargets(x: lines(xs), y: lines(ys))
    }

    /// `rect` with `edges` snapped onto a line within `threshold` (inclusive). The tiers are
    /// searched in order and the first with a line in reach is used; inside it the nearest line
    /// wins, a tie goes to an edge point (min/max) before the centre, then to the smaller
    /// position. With `.all` the whole rectangle moves (its size kept) so that its min, centre
    /// or max lands exactly on the line; otherwise each edge in `edges` snaps on its own and the
    /// others stay. A line anchored `.min`/`.centre`/`.max` only catches that point, and a line
    /// that would turn a resized rectangle inside out is no target.
    public static func snap(_ rect: Rect, moving edges: RectEdges, to targets: SnapTargets, threshold: Double) -> SnapResult {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var width = rect.size.width, height = rect.size.height
        var guides: [SnapGuide] = []
        var reasons: [SnapAxis: SnapReason] = [:]

        func record(_ axis: SnapAxis, _ line: SnapLine) {
            let guide = SnapGuide(axis: axis, position: line.position)
            if !guides.contains(guide) { guides.append(guide) }
            reasons[axis] = line.reason
        }

        if edges == .all {
            if let hit = best(of: [(minX, .min), (minX + width / 2, .centre), (maxX, .max)], in: targets.x,
                              threshold: threshold) {
                minX = start(of: hit, length: width)
                record(.x, hit.line)
            }
            if let hit = best(of: [(minY, .min), (minY + height / 2, .centre), (maxY, .max)], in: targets.y,
                              threshold: threshold) {
                minY = start(of: hit, length: height)
                record(.y, hit.line)
            }
        } else {
            if edges.contains(.minX),
               let hit = best(of: [(minX, .min)], in: targets.x, threshold: threshold, where: { $0 < maxX }) {
                minX = hit.line.position
                width = maxX - minX
                record(.x, hit.line)
            }
            if edges.contains(.maxX),
               let hit = best(of: [(maxX, .max)], in: targets.x, threshold: threshold, where: { $0 > minX }) {
                maxX = hit.line.position
                width = maxX - minX
                record(.x, hit.line)
            }
            if edges.contains(.minY),
               let hit = best(of: [(minY, .min)], in: targets.y, threshold: threshold, where: { $0 < maxY }) {
                minY = hit.line.position
                height = maxY - minY
                record(.y, hit.line)
            }
            if edges.contains(.maxY),
               let hit = best(of: [(maxY, .max)], in: targets.y, threshold: threshold, where: { $0 > minY }) {
                maxY = hit.line.position
                height = maxY - minY
                record(.y, hit.line)
            }
        }

        let snapped = Rect(x: minX, y: minY, width: width, height: height)
        return SnapResult(rect: snapped, guides: guides, reasons: reasons)
    }

    /// The guides of `guides` that lie on an edge or the centre of `rect` (within `tolerance`
    /// mm): after the margin rule has conformed the snapped rectangle, only the guides it still
    /// touches are drawn, so a guide never shows a line the item does not sit on.
    public static func guides(_ guides: [SnapGuide], touching rect: Rect, tolerance: Double = 1e-3) -> [SnapGuide] {
        guides.filter { guide in
            let lines = guide.axis == .x
                ? [rect.minX, rect.minX + rect.size.width / 2, rect.maxX]
                : [rect.minY, rect.minY + rect.size.height / 2, rect.maxY]
            return lines.contains { abs($0 - guide.position) <= tolerance }
        }
    }

    /// The line a point snapped to and which point (`.min`, `.centre` or `.max`) it was.
    private struct Hit {
        var line: SnapLine
        var point: SnapAnchor
    }

    /// The new min of a moved axis of `length` whose `hit.point` lands on the line.
    private static func start(of hit: Hit, length: Double) -> Double {
        switch hit.point {
        case .centre: return hit.line.position - length / 2
        case .max: return hit.line.position - length
        case .min, .any: return hit.line.position
        }
    }

    /// The best (point, line) pair: the first tier with a line not farther than `threshold`
    /// from a point it may catch (and whose position passes `allowed`); inside that tier the
    /// smallest distance, then an edge point before the centre, then the smaller position.
    private static func best(
        of points: [(value: Double, anchor: SnapAnchor)], in lines: [SnapLine], threshold: Double,
        where allowed: (Double) -> Bool = { _ in true }
    ) -> Hit? {
        let tieTolerance = 1e-9
        for tier in SnapTier.allCases {
            var result: Hit?
            var bestDistance = Double.infinity
            for point in points {
                let isEdge = point.anchor != .centre
                for line in lines where line.tier == tier && (line.anchor == .any || line.anchor == point.anchor) {
                    let distance = abs(line.position - point.value)
                    guard distance <= threshold, allowed(line.position) else { continue }
                    let better: Bool
                    if let current = result, abs(distance - bestDistance) <= tieTolerance {
                        let currentIsEdge = current.point != .centre
                        better = isEdge != currentIsEdge ? isEdge : line.position < current.line.position
                    } else {
                        better = distance < bestDistance
                    }
                    if better {
                        bestDistance = distance
                        result = Hit(line: line, point: point.anchor)
                    }
                }
            }
            if let result { return result }
        }
        return nil
    }
}
