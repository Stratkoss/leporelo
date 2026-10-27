import Foundation

/// The single page-margin rule shared by every layout edit: no frame edge may lie strictly
/// inside the band `0 < distance < margin` from a page edge (an edge ON a page edge is a bleed,
/// an edge at `margin` or farther is a margin), and text stays inside the margin box of its page.
public struct MarginRule: Sendable {
    public static let maxMarginMM = 30.0
    public static let minItemMM = 10.0

    private static let eps = 1e-6

    public let geometry: PageGeometry
    public let marginMM: Double

    public init(geometry: PageGeometry, marginMM: Double) {
        self.geometry = geometry
        self.marginMM = marginMM
    }

    /// `mm` limited to the supplier's safe zone from below and `maxMarginMM` from above.
    public static func clampedMargin(_ mm: Double, profile: SupplierProfile) -> Double {
        max(profile.safeMM, min(mm, maxMarginMM))
    }

    /// x coordinates of the page edges of `area`. `.spread` and `.page` are a two-page spread
    /// (the spine is a page edge of both pages), `.cover` one page.
    public func pageEdgesX(_ area: PrintArea) -> [Double] {
        let w = geometry.format.pageWidthMM
        switch area {
        case .spread, .page: return [0, w, 2 * w]
        case .cover: return [0, w]
        }
    }

    private func pageEdgesY() -> [Double] { [0, geometry.format.pageHeightMM] }

    /// `rect` moved and resized so that it lies inside the area, is at least `minItemMM` in each
    /// dimension and has no edge in the band next to a page edge. An edge in the band moves to
    /// the page edge when it is closer than half the margin, else to the margin line.
    public func conformFrame(_ rect: Rect, area: PrintArea) -> Rect {
        let xs = pageEdgesX(area), ys = pageEdgesY()
        let (x0, x1) = conformAxis(rect.minX, rect.maxX, edges: xs)
        let (y0, y1) = conformAxis(rect.minY, rect.maxY, edges: ys)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` MOVED (never resized) so that it lies inside the area with no edge in the band next
    /// to a page edge: a frame being dragged or nudged keeps its size. Per axis the position is
    /// first clamped into the area; if an edge then lies in a band, the candidates are the shifts
    /// that put that edge on the page edge or on its margin line (inward side), and the smallest
    /// shift whose result is inside the area with no edge in any band wins (a tie: the smaller
    /// value). An axis no shift can satisfy (too long, or below `minItemMM`) is conformed as in
    /// `conformFrame`.
    public func conformMovedFrame(_ rect: Rect, area: PrintArea) -> Rect {
        let fallback = conformFrame(rect, area: area)
        let (x0, x1) = moveAxis(rect.minX, length: rect.size.width, edges: pageEdgesX(area))
            ?? (fallback.minX, fallback.maxX)
        let (y0, y1) = moveAxis(rect.minY, length: rect.size.height, edges: pageEdgesY())
            ?? (fallback.minY, fallback.maxY)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` moved inside, and shrunk to, the margin box of the page its centre lies on.
    public func conformText(_ rect: Rect, area: PrintArea) -> Rect {
        let box: Rect
        switch area {
        case .cover:
            box = geometry.pageRect(side: .left).insetBy(marginMM)
        case .spread, .page:
            let side: PageSide = rect.minX + rect.size.width / 2 < geometry.format.pageWidthMM ? .left : .right
            box = geometry.pageRect(side: side).insetBy(marginMM)
        }
        let width = min(rect.size.width, box.size.width)
        let height = min(rect.size.height, box.size.height)
        let x = min(max(rect.minX, box.minX), box.maxX - width)
        let y = min(max(rect.minY, box.minY), box.maxY - height)
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// `spread` with every frame conformed by `conformFrame` and every text by `conformText`;
    /// photos, crops, roles, texts and flags are untouched.
    public func conform(_ spread: Spread, area: PrintArea) -> Spread {
        var result = spread
        for index in result.frames.indices {
            result.frames[index].rect = conformFrame(result.frames[index].rect, area: area)
        }
        for index in result.texts.indices {
            result.texts[index].rect = conformText(result.texts[index].rect, area: area)
        }
        return result
    }

    // MARK: - One axis

    private func conformAxis(_ lo: Double, _ hi: Double, edges: [Double]) -> (Double, Double) {
        let m = marginMM
        let minItem = Self.minItemMM
        let limit = edges.last ?? 0

        // 1. Clip to the area and grow to the minimum size by moving inward.
        var a = min(max(lo, 0), limit)
        var b = min(max(hi, 0), limit)
        if b - a < minItem {
            let centre = (a + b) / 2
            a = min(max(centre - minItem / 2, 0), limit - minItem)
            b = a + minItem
        }
        let centre = (a + b) / 2

        // 2. Edges in the band next to a page edge snap to it or to the margin line.
        a = snap(a, edges: edges)
        b = snap(b, edges: edges)

        // 3. Too small after snapping: a frame in the bleed, spanning the edge nearest to the
        //    centre up to the margin line (or minimum size), with no edge in the band.
        if b - a < minItem - Self.eps {
            let edge = edges.min { abs($0 - centre) < abs($1 - centre) } ?? 0
            let length = max(m, minItem)
            if centre >= edge {
                a = edge
                b = edge + length
            } else {
                a = edge - length
                b = edge
            }
        }
        return (a, b)
    }

    /// One axis of `conformMovedFrame`: the new (lo, hi) with the length kept, or nil when no
    /// shift works.
    private func moveAxis(_ lo: Double, length: Double, edges: [Double]) -> (Double, Double)? {
        let m = marginMM
        let limit = edges.last ?? 0
        guard lo.isFinite, length.isFinite, length >= Self.minItemMM - Self.eps,
              length <= limit + Self.eps else { return nil }
        let a = min(max(lo, 0), limit - length)

        func inBand(_ v: Double) -> Bool {
            edges.contains { abs(v - $0) > Self.eps && abs(v - $0) < m - Self.eps }
        }
        func fits(_ start: Double) -> Bool {
            start >= -Self.eps && start + length <= limit + Self.eps && !inBand(start) && !inBand(start + length)
        }
        if fits(a) { return (a, a + length) }

        var shifts: [Double] = []
        for v in [a, a + length] {
            for e in edges where abs(v - e) > Self.eps && abs(v - e) < m - Self.eps {
                shifts.append(e - v)
                shifts.append((v > e ? e + m : e - m) - v)
            }
        }
        let best = shifts.filter { fits(a + $0) }.min { s, t in
            abs(abs(s) - abs(t)) > Self.eps ? abs(s) < abs(t) : s < t
        }
        return best.map { (a + $0, a + $0 + length) }
    }

    private func snap(_ v: Double, edges: [Double]) -> Double {
        let m = marginMM
        guard let e = edges.min(by: { abs($0 - v) < abs($1 - v) }) else { return v }
        let d = abs(v - e)
        guard d > Self.eps, d < m - Self.eps else { return v }
        if d < m / 2 { return e }
        return v < e ? e - m : e + m
    }
}
