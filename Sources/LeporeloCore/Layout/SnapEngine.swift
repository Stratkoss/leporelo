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

public enum SnapAxis: Sendable {
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

public struct SnapTargets: Sendable, Equatable {
    public var x: [Double]
    public var y: [Double]

    public init(x: [Double], y: [Double]) {
        self.x = x
        self.y = y
    }
}

public struct SnapResult: Sendable, Equatable {
    public var rect: Rect
    public var guides: [SnapGuide]

    public init(rect: Rect, guides: [SnapGuide]) {
        self.rect = rect
        self.guides = guides
    }
}

/// Pure snapping: collects target lines for a drag and moves a rectangle (or some of its
/// edges) onto the nearest one within a threshold. All values are millimetres.
public enum SnapEngine {
    public static func targets(
        geometry: PageGeometry, marginMM: Double, area: PrintArea,
        others: [Rect], settings: SnapSettings
    ) -> SnapTargets {
        var xs: [Double] = [], ys: [Double] = []
        let height = geometry.format.pageHeightMM
        let edgesX = MarginRule(geometry: geometry, marginMM: marginMM).pageEdgesX(area)
        let pages = zip(edgesX, edgesX.dropFirst()).map { ($0, $1) }

        if settings.objects {
            for (lo, hi) in pages {
                xs += [lo, hi, (lo + hi) / 2]
                for edge in [lo, hi] {
                    for candidate in [edge - marginMM, edge + marginMM] where candidate >= lo && candidate <= hi {
                        xs.append(candidate)
                    }
                }
            }
            ys += [0, height, height / 2]
            for candidate in [marginMM, height - marginMM] where candidate >= 0 && candidate <= height {
                ys.append(candidate)
            }
            for other in others {
                xs += [other.minX, other.minX + other.size.width / 2, other.maxX,
                       other.minX - settings.gapMM, other.maxX + settings.gapMM]
                ys += [other.minY, other.minY + other.size.height / 2, other.maxY,
                       other.minY - settings.gapMM, other.maxY + settings.gapMM]
            }
        }

        if settings.grid, settings.gridMM > 0 {
            let step = settings.gridMM
            for (lo, hi) in pages {
                var k = 0
                while lo + Double(k) * step <= hi {
                    xs.append(lo + Double(k) * step)
                    k += 1
                }
            }
            var k = 0
            while Double(k) * step <= height {
                ys.append(Double(k) * step)
                k += 1
            }
        }

        return SnapTargets(x: Array(Set(xs)).sorted(), y: Array(Set(ys)).sorted())
    }

    /// `rect` with `edges` snapped to the nearest target within `threshold` (inclusive).
    /// With `.all` the whole rectangle moves so that its min, centre or max (whichever is
    /// closest to a target, per axis) lands on it; otherwise each edge in `edges` snaps
    /// on its own and the others stay. Ties go to the smaller target position.
    public static func snap(_ rect: Rect, moving edges: RectEdges, to targets: SnapTargets, threshold: Double) -> SnapResult {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var guides: [SnapGuide] = []

        func add(_ axis: SnapAxis, _ position: Double) {
            let guide = SnapGuide(axis: axis, position: position)
            if !guides.contains(guide) { guides.append(guide) }
        }

        if edges == .all {
            if let hit = best(of: [minX, (minX + maxX) / 2, maxX], in: targets.x, threshold: threshold) {
                minX += hit.delta
                maxX += hit.delta
                add(.x, hit.target)
            }
            if let hit = best(of: [minY, (minY + maxY) / 2, maxY], in: targets.y, threshold: threshold) {
                minY += hit.delta
                maxY += hit.delta
                add(.y, hit.target)
            }
        } else {
            if edges.contains(.minX), let hit = best(of: [minX], in: targets.x, threshold: threshold),
               hit.target < maxX {
                minX = hit.target
                add(.x, hit.target)
            }
            if edges.contains(.maxX), let hit = best(of: [maxX], in: targets.x, threshold: threshold),
               hit.target > minX {
                maxX = hit.target
                add(.x, hit.target)
            }
            if edges.contains(.minY), let hit = best(of: [minY], in: targets.y, threshold: threshold),
               hit.target < maxY {
                minY = hit.target
                add(.y, hit.target)
            }
            if edges.contains(.maxY), let hit = best(of: [maxY], in: targets.y, threshold: threshold),
               hit.target > minY {
                maxY = hit.target
                add(.y, hit.target)
            }
        }

        let snapped = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return SnapResult(rect: snapped, guides: guides)
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

    /// The (point, target) pair with the smallest distance not above `threshold`;
    /// among equal distances the smaller target wins. `delta` moves the point onto the target.
    private static func best(of points: [Double], in targets: [Double], threshold: Double) -> (target: Double, delta: Double)? {
        var result: (target: Double, delta: Double)?
        var bestDistance = Double.infinity
        for point in points {
            for target in targets {
                let distance = abs(target - point)
                guard distance <= threshold else { continue }
                if distance < bestDistance || (distance == bestDistance && target < (result?.target ?? .infinity)) {
                    bestDistance = distance
                    result = (target, target - point)
                }
            }
        }
        return result
    }
}
