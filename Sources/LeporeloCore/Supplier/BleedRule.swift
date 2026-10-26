import Foundation

/// What is being printed or rendered as one sheet, which decides where the bleed goes.
public enum PrintArea: Sendable, Equatable {
    /// A whole two-page spread (spread coordinates): the outer edges are the spread's boundary,
    /// the spine is not bled across.
    case spread
    /// One page of a spread rendered on its own (spread coordinates): every page edge is outer,
    /// including the spine, so a spine-touching frame bleeds into its own page's spine-side margin.
    case page
    /// One cover page (single-page coordinates).
    case cover
}

/// The single bleed rule shared by `SpreadRenderer`, `Preflight` and the export image pipeline:
/// a frame edge lying on an outer edge of the print area is stretched by `profile.bleedMM`.
extension PageGeometry {
    /// x coordinates of the outer edges of `area` (the y edges are always 0 and the page height).
    public func outerEdgesX(_ area: PrintArea) -> [Double] {
        let w = format.pageWidthMM
        switch area {
        case .spread: return [0, 2 * w]
        case .page: return [0, w, 2 * w]
        case .cover: return [0, w]
        }
    }

    /// The area a profile prints spreads as: `.page` for `.singlePages`, `.spread` for `.spreads`.
    public var spreadPrintArea: PrintArea {
        profile.pageMode == .singlePages ? .page : .spread
    }

    /// `rect` with every edge that lies on an outer edge of `area` moved out by `bleedMM`
    /// (unchanged when `includeBleed` is false or the bleed is 0).
    public func bleedExtended(_ rect: Rect, area: PrintArea, includeBleed: Bool = true) -> Rect {
        let bleed = profile.bleedMM
        guard includeBleed, bleed > 0 else { return rect }
        let eps = 0.01
        func on(_ v: Double, _ edges: [Double]) -> Bool { edges.contains { abs($0 - v) < eps } }
        let xs = outerEdgesX(area), ys = [0, format.pageHeightMM]
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if on(minX, xs) { minX -= bleed }
        if on(maxX, xs) { maxX += bleed }
        if on(minY, ys) { minY -= bleed }
        if on(maxY, ys) { maxY += bleed }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
