import Foundation

/// The single page-margin rule shared by every layout edit, in one of two modes:
/// - no bleed (`allowsBleed == false`, the default): every frame edge lies at least `margin`
///   from every page edge (the trims and, on a spread, the spine); an edge ON a page edge is not
///   allowed. A frame spanning across the spine is fine: the spine lies inside it.
/// - bleed (`allowsBleed == true`): no frame edge may lie strictly inside the band
///   `0 < distance < margin` from a page edge (an edge ON a page edge is a bleed, an edge at
///   `margin` or farther is a margin).
/// In both modes text stays inside the margin box of its page.
public struct MarginRule: Sendable {
    public static let maxMarginMM = 30.0
    public static let minItemMM = 10.0

    private static let eps = 1e-6

    public let geometry: PageGeometry
    public let marginMM: Double
    /// Whether a frame edge may lie ON a page edge (a photo printed to the page edge). Off for now:
    /// every photo keeps a white margin.
    public let allowsBleed: Bool

    public init(geometry: PageGeometry, marginMM: Double, allowsBleed: Bool = false) {
        self.geometry = geometry
        self.marginMM = marginMM
        self.allowsBleed = allowsBleed
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
    /// dimension and has no edge in the band next to a page edge.
    /// No bleed: an edge in the band (`distance < margin`, on the page edge included) moves to the
    /// margin line inward of that page edge; at the spine a frame's low edge goes to the line after
    /// it and its high edge to the line before it, so the frame stays on its own page.
    /// Bleed: an edge in the band moves to the page edge when it is closer than half the margin,
    /// else to the margin line.
    public func conformFrame(_ rect: Rect, area: PrintArea) -> Rect {
        let xs = pageEdgesX(area), ys = pageEdgesY()
        let (x0, x1) = conformAxis(rect.minX, rect.maxX, edges: xs)
        let (y0, y1) = conformAxis(rect.minY, rect.maxY, edges: ys)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` MOVED (never resized) so that it lies inside the area with no edge in the band next
    /// to a page edge: a frame being dragged or nudged keeps its size. Per axis the position is
    /// first clamped into the area; if an edge then lies in a band, the candidates are the shifts
    /// that put that edge on its margin line (inward side, as in `conformFrame`) or, with bleed,
    /// also on the page edge, and the smallest shift whose result is inside the area with no edge
    /// in any band wins (a tie: the smaller value). An axis no shift can satisfy (too long, or
    /// below `minItemMM`) is conformed as in `conformFrame`.
    ///
    /// `nudge` is the step of an arrow key that produced `rect` (mm, `rect` minus the start). On
    /// an axis where it is not zero a tie goes toward the direction of travel, and a result that
    /// would not advance past the start (the margin rule pulling the frame back) is replaced by
    /// the nearest allowed position beyond the start in that direction, if there is one (an edge
    /// on a margin line, with bleed also on a page edge): so a frame steps from margin line to
    /// margin line (with bleed: from the bleed to the margin line and back) instead of getting
    /// stuck.
    public func conformMovedFrame(_ rect: Rect, area: PrintArea, nudge: Point? = nil) -> Rect {
        let fallback = conformFrame(rect, area: area)
        let (x0, x1) = moveAxis(rect.minX, length: rect.size.width, edges: pageEdgesX(area), nudge: nudge?.x ?? 0)
            ?? (fallback.minX, fallback.maxX)
        let (y0, y1) = moveAxis(rect.minY, length: rect.size.height, edges: pageEdgesY(), nudge: nudge?.y ?? 0)
            ?? (fallback.minY, fallback.maxY)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` fitted into the margin box of the page its centre lies on (the cover: its one page)
    /// by TRIMMING: an edge outside the box is moved onto it while the box stays at least
    /// `minItemMM` (or its own size, if smaller) in that dimension; only the remainder that
    /// trimming cannot take is a move. A text larger than the box becomes the box. Used for a
    /// resize (only the dragged edge is clamped), a new text and a margin change.
    public func conformText(_ rect: Rect, area: PrintArea) -> Rect {
        let box = marginBox(for: rect, area: area)
        let (x0, x1) = trimAxis(rect.minX, rect.maxX, box: (box.minX, box.maxX))
        let (y0, y1) = trimAxis(rect.minY, rect.maxY, box: (box.minY, box.maxY))
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` MOVED inside, and only shrunk when larger than, the margin box of the page its
    /// centre lies on: a text being dragged or nudged keeps its size.
    public func conformMovedText(_ rect: Rect, area: PrintArea) -> Rect {
        let box = marginBox(for: rect, area: area)
        let width = min(rect.size.width, box.size.width)
        let height = min(rect.size.height, box.size.height)
        let x = min(max(rect.minX, box.minX), box.maxX - width)
        let y = min(max(rect.minY, box.minY), box.maxY - height)
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// The margin box of the page `rect`'s centre lies on (the cover: its one page).
    public func marginBox(for rect: Rect, area: PrintArea) -> Rect {
        switch area {
        case .cover:
            return geometry.pageRect(side: .left).insetBy(marginMM)
        case .spread, .page:
            let side: PageSide = rect.minX + rect.size.width / 2 < geometry.format.pageWidthMM ? .left : .right
            return geometry.pageRect(side: side).insetBy(marginMM)
        }
    }

    /// True when an edge of the frame `rect` lies in the band next to a page edge (no bleed:
    /// `distance < margin`, on the page edge included; bleed: `0 < distance < margin`): what the
    /// preflight warns about in books made before the rule.
    public func frameIntrudesMargin(_ rect: Rect, area: PrintArea) -> Bool {
        let xs = pageEdgesX(area), ys = pageEdgesY()
        func inBand(_ v: Double, _ edges: [Double]) -> Bool {
            edges.contains { isInBand(v, $0, tolerance: 1e-3) }
        }
        return inBand(rect.minX, xs) || inBand(rect.maxX, xs) || inBand(rect.minY, ys) || inBand(rect.maxY, ys)
    }

    /// True when the text `rect` is not entirely inside the margin box of its page.
    public func textOutsideMargin(_ rect: Rect, area: PrintArea) -> Bool {
        let box = marginBox(for: rect, area: area)
        let tolerance = 1e-3
        return rect.minX < box.minX - tolerance || rect.maxX > box.maxX + tolerance
            || rect.minY < box.minY - tolerance || rect.maxY > box.maxY + tolerance
    }

    /// `targets` without the lines in a band next to a page edge of `area` (no bleed:
    /// `distance < margin`, so never the trims or the spine; bleed: `0 < distance < margin`): a
    /// frame snapped there would only be conformed elsewhere.
    public func allowedTargets(_ targets: SnapTargets, area: PrintArea) -> SnapTargets {
        let xs = pageEdgesX(area), ys = pageEdgesY()
        func allowed(_ v: Double, _ edges: [Double]) -> Bool {
            !edges.contains { isInBand(v, $0, tolerance: Self.eps) }
        }
        return SnapTargets(x: targets.x.filter { allowed($0.position, xs) },
                           y: targets.y.filter { allowed($0.position, ys) })
    }

    /// `spread` with every frame conformed by `conformFrame` and every text by `conformText`;
    /// photos, crops, roles, texts and flags are untouched. Texts that did not overlap before but
    /// do after conforming (e.g. a journal's date pushed down onto its title by a wide margin)
    /// are separated again: the later one (top to bottom, then left to right) is pushed past the
    /// earlier one keeping their former gap, trimmed while it stays `minItemMM`, else moved.
    public func conform(_ spread: Spread, area: PrintArea) -> Spread {
        var result = spread
        for index in result.frames.indices {
            result.frames[index].rect = conformFrame(result.frames[index].rect, area: area)
        }
        let original = spread.texts.map(\.rect)
        let separated = separated(original.map { conformText($0, area: area) }, original: original, area: area)
        for index in result.texts.indices {
            result.texts[index].rect = separated[index]
        }
        return result
    }

    // MARK: - Texts

    private func separated(_ rects: [Rect], original: [Rect], area: PrintArea) -> [Rect] {
        var rects = rects
        let order = original.indices.sorted {
            (original[$0].minY, original[$0].minX, $0) < (original[$1].minY, original[$1].minX, $1)
        }
        for (n, i) in order.enumerated() {
            for j in order[..<n] where overlaps(rects[i], rects[j]) && !overlaps(original[i], original[j]) {
                let box = marginBox(for: rects[i], area: area)
                if original[j].maxY <= original[i].minY + Self.eps {
                    let gap = original[i].minY - original[j].maxY
                    let (lo, hi) = pushedForward(rects[i].minY, rects[i].maxY, past: rects[j].maxY + gap,
                                                 limit: box.maxY)
                    rects[i] = Rect(x: rects[i].minX, y: lo, width: rects[i].size.width, height: hi - lo)
                } else if original[j].maxX <= original[i].minX + Self.eps {
                    let gap = original[i].minX - original[j].maxX
                    let (lo, hi) = pushedForward(rects[i].minX, rects[i].maxX, past: rects[j].maxX + gap,
                                                 limit: box.maxX)
                    rects[i] = Rect(x: lo, y: rects[i].minY, width: hi - lo, height: rects[i].size.height)
                } else if original[i].maxX <= original[j].minX + Self.eps {
                    let gap = original[j].minX - original[i].maxX
                    let (lo, hi) = pushedForward(-rects[i].maxX, -rects[i].minX, past: -(rects[j].minX - gap),
                                                 limit: -box.minX)
                    rects[i] = Rect(x: -hi, y: rects[i].minY, width: hi - lo, height: rects[i].size.height)
                }
            }
        }
        return rects
    }

    /// (lo, hi) with lo at least `past`: trimmed while the length stays `minItemMM` (or its own
    /// length, if smaller), else moved; never beyond `limit` (then it may still overlap).
    private func pushedForward(_ lo: Double, _ hi: Double, past: Double, limit: Double) -> (Double, Double) {
        guard lo < past else { return (lo, hi) }
        let keep = min(hi - lo, Self.minItemMM)
        if hi - past >= keep - Self.eps { return (past, hi) }
        let end = min(past + keep, max(limit, hi))
        return (end - keep, end)
    }

    private func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        a.minX < b.maxX - Self.eps && b.minX < a.maxX - Self.eps
            && a.minY < b.maxY - Self.eps && b.minY < a.maxY - Self.eps
    }

    /// One axis of `conformText`.
    private func trimAxis(_ lo: Double, _ hi: Double, box: (lo: Double, hi: Double)) -> (Double, Double) {
        let length = hi - lo
        guard length < box.hi - box.lo else { return box }
        let a = max(lo, box.lo), b = min(hi, box.hi)
        let keep = min(length, Self.minItemMM)
        if b - a >= keep - Self.eps { return (a, b) }
        let start = min(max(lo, box.lo), box.hi - keep)
        return (start, start + keep)
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

        // 2. Edges in the band next to a page edge snap to the margin line (bleed: or to the edge).
        a = snap(a, isLow: true, edges: edges)
        b = snap(b, isLow: false, edges: edges)

        // 3. Too small after snapping. No bleed: `minItemMM` long from the margin line next to the
        //    page edge nearest to the centre, on the centre's side. Bleed: a frame in the bleed,
        //    spanning the edge nearest to the centre up to the margin line (or minimum size).
        if b - a < minItem - Self.eps {
            let edge = edges.min { abs($0 - centre) < abs($1 - centre) } ?? 0
            if !allowsBleed {
                let after = edge < limit - Self.eps && (centre >= edge || edge <= Self.eps)
                return after ? (edge + m, edge + m + minItem) : (edge - m - minItem, edge - m)
            }
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
    /// shift works. `nudge` (0: none) is the arrow-key step that produced `lo`.
    private func moveAxis(_ lo: Double, length: Double, edges: [Double], nudge: Double) -> (Double, Double)? {
        let m = marginMM
        let limit = edges.last ?? 0
        guard lo.isFinite, length.isFinite, length >= Self.minItemMM - Self.eps,
              length <= limit + Self.eps else { return nil }
        let a = min(max(lo, 0), limit - length)

        func inBand(_ v: Double) -> Bool {
            edges.contains { isInBand(v, $0, tolerance: Self.eps) }
        }
        func fits(_ start: Double) -> Bool {
            start >= -Self.eps && start + length <= limit + Self.eps && !inBand(start) && !inBand(start + length)
        }
        let sign: Double = nudge > Self.eps ? 1 : nudge < -Self.eps ? -1 : 0

        var result: Double?
        if fits(a) {
            result = a
        } else {
            var shifts: [Double] = []
            for (v, isLow) in [(a, true), (a + length, false)] {
                for e in edges where isInBand(v, e, tolerance: Self.eps) {
                    if allowsBleed {
                        shifts.append(e - v)
                        shifts.append((v > e ? e + m : e - m) - v)
                    } else {
                        shifts.append(marginLine(of: e, isLow: isLow, limit: limit) - v)
                    }
                }
            }
            // A tie: toward the direction of travel, else the smaller value.
            let best = shifts.filter { fits(a + $0) }.min { s, t in
                if abs(abs(s) - abs(t)) > Self.eps { return abs(s) < abs(t) }
                return sign == 0 ? s < t : s * sign > t * sign
            }
            result = best.map { a + $0 }
        }

        // A nudge that does not advance: the nearest allowed position beyond the start.
        if sign != 0, let current = result, (current - (lo - nudge)) * sign <= Self.eps {
            let start = lo - nudge
            var candidates: [Double] = []
            for e in edges {
                for line in allowsBleed ? [e - m, e, e + m] : [e - m, e + m] {
                    candidates.append(line)           // lo on the line
                    candidates.append(line - length)  // hi on the line
                }
            }
            let ahead = candidates.filter { ($0 - start) * sign > Self.eps && fits($0) }
            if let next = ahead.min(by: { abs($0 - start) < abs($1 - start) }) { result = next }
        }
        return result.map { ($0, $0 + length) }
    }

    /// `v` (a frame's low or high edge) moved out of the band of the nearest page edge.
    private func snap(_ v: Double, isLow: Bool, edges: [Double]) -> Double {
        let m = marginMM
        guard let e = edges.min(by: { abs($0 - v) < abs($1 - v) }) else { return v }
        guard isInBand(v, e, tolerance: Self.eps) else { return v }
        if !allowsBleed { return marginLine(of: e, isLow: isLow, limit: edges.last ?? 0) }
        let d = abs(v - e)
        if d < m / 2 { return e }
        return v < e ? e - m : e + m
    }

    /// True when `v` lies in the band of the page edge `e`: no bleed `distance < margin` (on the
    /// edge included), bleed `0 < distance < margin`.
    private func isInBand(_ v: Double, _ e: Double, tolerance: Double) -> Bool {
        let d = abs(v - e)
        return d < marginMM - tolerance && (!allowsBleed || d > tolerance)
    }

    /// The margin line inward of the page edge `e` for a frame's low or high edge: past the first
    /// trim, before the last one, and at an inner page edge (the spine) after it for a low edge
    /// and before it for a high edge.
    private func marginLine(of e: Double, isLow: Bool, limit: Double) -> Double {
        if e <= Self.eps { return marginMM }
        if e >= limit - Self.eps { return limit - marginMM }
        return isLow ? e + marginMM : e - marginMM
    }
}
