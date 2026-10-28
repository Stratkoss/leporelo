import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The look a text is drawn with, every field decided (`SpreadRenderer.resolvedStyle(for:pageWidth:)`).
public struct ResolvedTextStyle: Sendable, Equatable {
    /// The family actually drawn (the role's family when the chosen one is missing).
    public var family: String
    public var sizePt: Double
    public var bold: Bool
    public var italic: Bool
    public var alignment: TextAlignment
    /// "#RRGGBB" in sRGB.
    public var colorHex: String
    /// True when the text's chosen family is not on this Mac and the role's family is used instead.
    public var isFallback: Bool

    public init(family: String, sizePt: Double, bold: Bool, italic: Bool, alignment: TextAlignment,
                colorHex: String, isFallback: Bool) {
        self.family = family
        self.sizePt = sizePt
        self.bold = bold
        self.italic = italic
        self.alignment = alignment
        self.colorHex = colorHex
        self.isFallback = isFallback
    }
}

public struct RenderOptions: Sendable {
    public var showGuides: Bool
    public var includeBleed: Bool
    /// Context units per millimetre (pixels for a bitmap, `72 / 25.4` for a PDF in points).
    public var pixelsPerMM: Double
    /// Resolution used for the image provider's `minPixelWidth` hint. `nil` means
    /// `pixelsPerMM * 25.4`. A PDF context at 72 units/inch passes 300 to request print-quality images.
    public var imageDPI: Double?
    /// Snaps each frame's edges to whole device pixels, so two frames sharing an edge cover the
    /// pixel it falls in without a light seam. For the on-screen canvas only; print output keeps
    /// the exact edges.
    public var pixelAlignFrames: Bool

    public init(showGuides: Bool = false, includeBleed: Bool = true, pixelsPerMM: Double,
                imageDPI: Double? = nil, pixelAlignFrames: Bool = false) {
        self.showGuides = showGuides
        self.includeBleed = includeBleed
        self.pixelsPerMM = pixelsPerMM
        self.imageDPI = imageDPI
        self.pixelAlignFrames = pixelAlignFrames
    }
}

/// Draws spreads, single pages and cover pages with CoreGraphics/CoreText only, so the same code
/// serves bitmap, PDF and on-screen contexts.
///
/// Context contract (all `draw*` / `render*` entry points): the caller passes a normal y-up
/// context whose origin is the BOTTOM-LEFT of the visible area, with one context unit per
/// `1 / pixelsPerMM` mm. The visible area is the trim rect (whole spread, one page, or a cover
/// page), plus the supplier's bleed on every side when `includeBleed` is true; its canvas size is
/// `visibleArea * pixelsPerMM`. The renderer anchors the top from that computed size and never
/// looks at the clip box, so a caller that needs another origin (flipped view, dirty rect,
/// cropping) translates/scales before calling. Fonts are sized in mm because the drawing space is
/// mm; `points(fromMM:)` gives the equivalent size in points.
///
/// Bleed convention (`PageGeometry.bleedExtended`, shared with `Preflight` and the export): a frame
/// edge lying on an outer edge of the print area is stretched by `bleedMM` when `includeBleed` is
/// true. For whole spreads (`.spread`) that is the spread's outer boundary (the spine is not bled
/// across); for `drawPage` (`.page`) every page edge including the spine, so spine-touching frames
/// bleed into the spine-side margin of their own page, and a frame spanning the spine is extended
/// identically on both pages (the two halves line up).
/// A page shows only frames and texts that overlap its trim rect, clipped to its visible area,
/// so it never shows a neighbour page's content in its margin.
///
/// Text convention: each text is drawn with `resolvedStyle(for:pageWidth:)`: its own `TextStyle`
/// where set, the default of its role otherwise. By default `.pageNumber` is drawn like a caption
/// and right aligned when its box lies on the right page of a spread (box centre right of the
/// spine), left aligned otherwise.
public struct SpreadRenderer: Sendable {
    public static let emptyFrameGray = CGColor(srgbRed: 0xE6 / 255.0, green: 0xE6 / 255.0, blue: 0xE6 / 255.0, alpha: 1)

    public let album: Album
    public let geometry: PageGeometry
    public let images: ImageProvider

    public init(album: Album, geometry: PageGeometry, images: ImageProvider) {
        self.album = album
        self.geometry = geometry
        self.images = images
    }

    public static func points(fromMM mm: Double) -> Double { mm * 72 / 25.4 }

    // MARK: Regions

    private struct Region {
        var trim: Rect
        var safeRects: [Rect]
        var spineX: Double?
        var area: PrintArea
    }

    private var spreadRegion: Region {
        Region(trim: Rect(origin: Point(x: 0, y: 0), size: geometry.spreadSize),
               safeRects: [geometry.safeRect(side: .left), geometry.safeRect(side: .right)],
               spineX: geometry.format.pageWidthMM, area: .spread)
    }

    private func pageRegion(_ side: PageSide) -> Region {
        Region(trim: geometry.pageRect(side: side), safeRects: [geometry.safeRect(side: side)],
               spineX: geometry.format.pageWidthMM, area: .page)
    }

    private var coverRegion: Region {
        Region(trim: geometry.pageRect(side: .left), safeRects: [geometry.safeRect(side: .left)], spineX: nil,
               area: .cover)
    }

    /// Visible area in spread (or cover page) coordinates, in mm.
    private func visibleArea(_ region: Region, _ options: RenderOptions) -> Rect {
        options.includeBleed ? region.trim.insetBy(-geometry.profile.bleedMM) : region.trim
    }

    // MARK: Image loading

    /// Loads each distinct photo of the spread once (frames sharing a photo share the image).
    ///
    /// The size hint is the widest DRAWN width of the photo at `imageDPI` (default
    /// `pixelsPerMM * 25.4`): `ceil(w / 25.4 * dpi)` where `w` is the width in mm of
    /// `FrameFit.imageRect` on the frame extended by the bleed of `area` (when `includeBleed`), with
    /// the photo's `pixelWidth`/`pixelHeight` from the album and the frame's offset and zoom. That
    /// is what the cover-fitted image actually spans, so a photo wider than its frame, a zoomed one
    /// or one bled over the trim edge is requested large enough. A photo the album does not know (or
    /// without pixel sizes) falls back to the extended frame width.
    /// `area` must match how the spread is drawn: `.spread` for `draw`/`render`, `.page` for
    /// `drawPage`/`renderPage`, `.cover` for `drawCover`/`renderCover`.
    public func loadImages(for spread: Spread, options: RenderOptions,
                           area: PrintArea = .spread) async -> [PhotoID: CGImage] {
        let dpi = options.imageDPI ?? options.pixelsPerMM * 25.4
        var widest: [PhotoID: Double] = [:]
        var order: [PhotoID] = []
        for frame in spread.frames {
            guard let id = frame.photoID else { continue }
            if widest[id] == nil { order.append(id) }
            widest[id] = max(widest[id] ?? 0, drawnWidth(frame, photoID: id, area: area, options: options))
        }
        var result: [PhotoID: CGImage] = [:]
        for id in order {
            let minWidth = Self.pixelHint(mm: widest[id] ?? 0, dpi: dpi)
            if let image = await images.image(for: id, minPixelWidth: minWidth) {
                result[id] = image
            }
        }
        return result
    }

    /// The largest pixel width the renderer ever asks for (well above any camera original).
    static let maxPixelHint = 100_000

    /// `ceil(mm / 25.4 * dpi)` clamped to 1...`maxPixelHint`; a NaN, infinite or huge value (a
    /// corrupt frame rect or zoom) gives a safe number instead of trapping in the `Int` conversion.
    static func pixelHint(mm: Double, dpi: Double) -> Int {
        let pixels = (mm / 25.4 * dpi).rounded(.up)
        guard pixels.isFinite else { return pixels == .infinity ? maxPixelHint : 1 }
        return Int(min(Double(maxPixelHint), max(1, pixels)))
    }

    /// Width in mm the photo of `frame` is drawn at (cover-fit on the bleed-extended frame, zoom included).
    private func drawnWidth(_ frame: Frame, photoID: PhotoID, area: PrintArea, options: RenderOptions) -> Double {
        let printed = geometry.bleedExtended(frame.rect, area: area, includeBleed: options.includeBleed)
        guard let photo = album.photos[photoID], photo.pixelWidth > 0, photo.pixelHeight > 0 else {
            return printed.size.width
        }
        let fit = FrameFit.imageRect(imageSize: Size(width: Double(photo.pixelWidth), height: Double(photo.pixelHeight)),
                                     in: printed, offset: frame.offset, zoom: frame.zoom)
        return fit.size.width
    }

    // MARK: Synchronous drawing (for NSView.draw and other sync callers)

    /// Draws a whole two-page spread with already loaded images.
    public func draw(_ spread: Spread, images: [PhotoID: CGImage], into ctx: CGContext, options: RenderOptions) {
        drawRegion(spread, spreadRegion, images: images, into: ctx, options: options)
    }

    /// Draws one page (left or right) of a spread with already loaded images.
    public func drawPage(_ spread: Spread, side: PageSide, images: [PhotoID: CGImage],
                         into ctx: CGContext, options: RenderOptions) {
        drawRegion(spread, pageRegion(side), images: images, into: ctx, options: options)
    }

    /// Draws a cover side (rects in single-page coordinates).
    public func drawCover(_ page: Spread, images: [PhotoID: CGImage], into ctx: CGContext, options: RenderOptions) {
        drawRegion(page, coverRegion, images: images, into: ctx, options: options)
    }

    // MARK: Async wrappers

    public func render(_ spread: Spread, into ctx: CGContext, options: RenderOptions) async {
        let loaded = await loadImages(for: spread, options: options, area: .spread)
        draw(spread, images: loaded, into: ctx, options: options)
    }

    /// One page of a spread; used per page for PDF export.
    public func renderPage(_ spread: Spread, side: PageSide, into ctx: CGContext, options: RenderOptions) async {
        let loaded = await loadImages(for: spread, options: options, area: .page)
        drawPage(spread, side: side, images: loaded, into: ctx, options: options)
    }

    /// ONE cover page (front or back).
    public func renderCover(_ page: Spread, into ctx: CGContext, options: RenderOptions) async {
        let loaded = await loadImages(for: page, options: options, area: .cover)
        drawCover(page, images: loaded, into: ctx, options: options)
    }

    // MARK: PNG

    /// PNG of the whole spread; row 0 is the top. `nil` on failure.
    public func renderPNG(_ spread: Spread, options: RenderOptions) async -> Data? {
        await png(region: spreadRegion, options: options) { ctx in
            await self.render(spread, into: ctx, options: options)
        }
    }

    public func renderPagePNG(_ spread: Spread, side: PageSide, options: RenderOptions) async -> Data? {
        await png(region: pageRegion(side), options: options) { ctx in
            await self.renderPage(spread, side: side, into: ctx, options: options)
        }
    }

    public func renderCoverPNG(_ page: Spread, options: RenderOptions) async -> Data? {
        await png(region: coverRegion, options: options) { ctx in
            await self.renderCover(page, into: ctx, options: options)
        }
    }

    private func png(region: Region, options: RenderOptions, draw: (CGContext) async -> Void) async -> Data? {
        let area = visibleArea(region, options)
        let w = max(Int((area.size.width * options.pixelsPerMM).rounded()), 1)
        let h = max(Int((area.size.height * options.pixelsPerMM).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        await draw(ctx)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Drawing core

    private func drawRegion(_ spread: Spread, _ region: Region, images: [PhotoID: CGImage],
                            into ctx: CGContext, options: RenderOptions) {
        FontRegistry.registerBundledFonts()
        let area = visibleArea(region, options)
        let scale = options.pixelsPerMM
        let trim = region.trim

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // mm space, origin at the top-left of the visible area, y down. The canvas height is
        // computed from the visible area, never read from the context.
        ctx.translateBy(x: 0, y: area.size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)

        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(cgRect(area))
        ctx.clip(to: cgRect(area))

        for frame in spread.frames where frame.rect.intersects(trim) {
            let rect = geometry.bleedExtended(frame.rect, area: region.area, includeBleed: options.includeBleed)
            drawFrame(frame, rect: options.pixelAlignFrames ? pixelAligned(rect, in: ctx) : rect,
                      image: frame.photoID.flatMap { images[$0] }, in: ctx)
        }
        for box in spread.texts where box.rect.intersects(trim) {
            drawText(box, in: ctx, pageWidth: region.spineX)
        }
        if options.showGuides {
            drawGuides(in: ctx, trim: trim, safeRects: region.safeRects, spineX: region.spineX, scale: scale)
        }
    }

    private func cgRect(_ r: Rect) -> CGRect {
        CGRect(x: r.minX, y: r.minY, width: r.size.width, height: r.size.height)
    }

    /// `rect` with each edge moved to the nearest whole device pixel of `ctx`. A shared edge rounds
    /// the same for both frames, so they meet on a pixel boundary.
    private func pixelAligned(_ rect: Rect, in ctx: CGContext) -> Rect {
        let device = ctx.convertToDeviceSpace(cgRect(rect))
        let snapped = CGRect(x: device.minX.rounded(), y: device.minY.rounded(),
                             width: device.maxX.rounded() - device.minX.rounded(),
                             height: device.maxY.rounded() - device.minY.rounded())
        let user = ctx.convertToUserSpace(snapped)
        return Rect(x: user.minX, y: user.minY, width: user.width, height: user.height)
    }

    /// `rect` is the frame extended by the bleed (`PageGeometry.bleedExtended`).
    private func drawFrame(_ frame: Frame, rect: Rect, image: CGImage?, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: cgRect(rect))
        guard let image else {
            ctx.setFillColor(Self.emptyFrameGray)
            ctx.fill(cgRect(rect))
            return
        }
        let fit = FrameFit.imageRect(imageSize: Size(width: Double(image.width), height: Double(image.height)),
                                     in: rect, offset: frame.offset, zoom: frame.zoom)
        ctx.interpolationQuality = .high
        // Flip locally: the context is y-down, CGContext.draw expects y-up images.
        ctx.translateBy(x: fit.minX, y: fit.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: fit.size.width, height: fit.size.height))
    }

    /// The font of a text role: PostScript/family name and size in MILLIMETRES (the drawing space
    /// is mm; multiply by the points per mm of a view for an on-screen editor that matches).
    public static func font(for role: TextRole) -> (name: String, size: Double) {
        switch role {
        case .title: return (FontRegistry.titleFont, 9.9)
        case .date: return (FontRegistry.textFont, 3.2)
        case .body: return (FontRegistry.textFont, 3.5)
        case .caption, .pageNumber: return (FontRegistry.textFont, 3.0)
        }
    }

    /// The default text colour, a near-black.
    public static let defaultColorHex = "#1A1A1A"

    /// The look `box` is drawn with: each field of its `TextStyle` where set, the role's default
    /// otherwise (family and size of `font(for:)`, regular, `defaultColorHex`). A size is clamped to
    /// `TextStyle.sizeRangePt`. A family this Mac does not have falls back to the role's family and
    /// sets `isFallback` (the stored choice is kept). `pageWidth` is the spine position on a spread
    /// (nil on a cover page): a page number without its own alignment is right aligned when its box
    /// centre lies right of it, left aligned otherwise.
    public static func resolvedStyle(for box: TextBox, pageWidth: Double?) -> ResolvedTextStyle {
        let role = font(for: box.role)
        let style = box.style ?? TextStyle()
        var family = role.name
        var isFallback = false
        if let wanted = style.fontFamily {
            if FontRegistry.isFamilyAvailable(wanted) { family = wanted } else { isFallback = true }
        }
        let range = TextStyle.sizeRangePt
        let size = style.sizePt.flatMap { $0.isFinite ? min(max($0, range.lowerBound), range.upperBound) : nil }
            ?? points(fromMM: role.size)
        let onRightPage = pageWidth.map { box.rect.minX + box.rect.size.width / 2 >= $0 } ?? false
        let alignment = style.alignment ?? (box.role == .pageNumber && onRightPage ? .right : .left)
        return ResolvedTextStyle(family: family, sizePt: size, bold: style.bold, italic: style.italic,
                                 alignment: alignment, colorHex: style.colorHex ?? defaultColorHex,
                                 isFallback: isFallback)
    }

    /// The Core Text font of `style`, sized in MILLIMETRES (`sizePt * 25.4 / 72`, rounded to a
    /// billionth of a mm so a role's default size comes back exactly, e.g. 3.2 and not
    /// 3.1999999999999997, and an unstyled text draws as it did before styles). The face is
    /// matched by family, then italic by trait (the book fonts' italic files are faces of their
    /// families). Bold sets the `wght` axis to 700 on a variable family and picks the bold face
    /// otherwise. A trait the family lacks is left out.
    public static func ctFont(for style: ResolvedTextStyle) -> CTFont {
        FontRegistry.registerBundledFonts()
        let size = (style.sizePt * 25.4 / 72 * 1e9).rounded() / 1e9
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: style.family] as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        if style.italic, let italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) {
            font = italic
        }
        guard style.bold else { return font }
        if let maxWeight = FontRegistry.weightAxisMax(font), maxWeight >= 700 {
            let variation = [NSNumber(value: FontRegistry.weightAxisTag): NSNumber(value: 700)]
            let bold = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
            return CTFontCreateCopyWithAttributes(font, size, nil, bold)
        }
        return CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
    }

    /// sRGB colour of a "#RRGGBB" string; the default colour (and anything unreadable) is the
    /// renderer's original near-black, sRGB 0.1 0.1 0.1.
    public static func color(hex: String) -> CGColor {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard hex != defaultColorHex, digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        }
        return CGColor(srgbRed: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                       blue: Double(value & 0xFF) / 255, alpha: 1)
    }

    /// The text of `box` styled exactly as it is drawn (`resolvedStyle`: font, size, alignment,
    /// colour; word wrapping). `pageWidth` as in `resolvedStyle`.
    static func attributedText(_ box: TextBox, pageWidth: Double?) -> NSAttributedString {
        let resolved = resolvedStyle(for: box, pageWidth: pageWidth)
        var alignment: CTTextAlignment = switch resolved.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var lineBreak: CTLineBreakMode = .byWordWrapping
        let style: CTParagraphStyle = withUnsafeBytes(of: &alignment) { alignBytes in
            withUnsafeBytes(of: &lineBreak) { breakBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                            value: alignBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size,
                                            value: breakBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont(for: resolved),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex: resolved.colorHex),
        ]
        return NSAttributedString(string: box.text, attributes: attributes)
    }

    private static func textFrame(_ string: NSAttributedString, width: Double, height: Double) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    }

    /// True when part of the text (trailing whitespace aside) does not fit its box and so is cut
    /// from the print: Core Text lays it out with the text's resolved font and size in the box and the
    /// visible range ends before the text does. An empty text never overflows.
    public static func textOverflows(_ box: TextBox) -> Bool {
        let trimmed = String(box.text.reversed().drop(while: \.isWhitespace).reversed())
        let needed = (trimmed as NSString).length
        guard needed > 0 else { return false }
        guard box.rect.size.width > 0, box.rect.size.height > 0 else { return true }
        FontRegistry.registerBundledFonts()
        let frame = textFrame(attributedText(box, pageWidth: nil),
                              width: box.rect.size.width, height: box.rect.size.height)
        return CTFrameGetVisibleStringRange(frame).length < needed
    }

    /// `pageWidth` is the spine position on a spread, nil on a cover page.
    private func drawText(_ box: TextBox, in ctx: CGContext, pageWidth: Double?) {
        guard !box.text.isEmpty, box.rect.size.width > 0, box.rect.size.height > 0 else { return }
        let frame = Self.textFrame(Self.attributedText(box, pageWidth: pageWidth),
                                   width: box.rect.size.width, height: box.rect.size.height)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: cgRect(box.rect))
        // Local y-up space with its origin at the bottom-left of the box.
        ctx.translateBy(x: box.rect.minX, y: box.rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
    }

    private func drawGuides(in ctx: CGContext, trim: Rect, safeRects: [Rect], spineX: Double?, scale: Double) {
        let lineWidth = max(0.25, 1.5 / scale)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(lineWidth)

        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        for safe in safeRects { ctx.stroke(cgRect(safe)) }

        if let spineX {
            ctx.setStrokeColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.move(to: CGPoint(x: spineX, y: trim.minY))
            ctx.addLine(to: CGPoint(x: spineX, y: trim.maxY))
            ctx.strokePath()
        }

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.stroke(cgRect(trim))
    }
}
