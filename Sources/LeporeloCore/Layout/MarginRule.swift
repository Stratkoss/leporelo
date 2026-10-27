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

    private func snap(_ v: Double, edges: [Double]) -> Double {
        let m = marginMM
        guard let e = edges.min(by: { abs($0 - v) < abs($1 - v) }) else { return v }
        let d = abs(v - e)
        guard d > Self.eps, d < m - Self.eps else { return v }
        if d < m / 2 { return e }
        return v < e ? e - m : e + m
    }
}
