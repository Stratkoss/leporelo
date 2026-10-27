import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RenderOptions: Sendable {
    public var showGuides: Bool
    public var includeBleed: Bool
    /// Context units per millimetre (pixels for a bitmap, `72 / 25.4` for a PDF in points).
    public var pixelsPerMM: Double
    /// Resolution used for the image provider's `minPixelWidth` hint. `nil` means
    /// `pixelsPerMM * 25.4`. A PDF context at 72 units/inch passes 300 to request print-quality images.
    public var imageDPI: Double?

    public init(showGuides: Bool = false, includeBleed: Bool = true, pixelsPerMM: Double,
                imageDPI: Double? = nil) {
        self.showGuides = showGuides
        self.includeBleed = includeBleed
        self.pixelsPerMM = pixelsPerMM
        self.imageDPI = imageDPI
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
/// Text convention: `.pageNumber` is drawn like a caption and right aligned when its box lies on
/// the right page (box centre right of the spine), left aligned otherwise.
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
            let minWidth = Int(((widest[id] ?? 0) / 25.4 * dpi).rounded(.up))
            if let image = await images.image(for: id, minPixelWidth: max(minWidth, 1)) {
                result[id] = image
            }
        }
        return result
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
            drawFrame(frame, rect: rect, image: frame.photoID.flatMap { images[$0] }, in: ctx)
        }
        for box in spread.texts where box.rect.intersects(trim) {
            drawText(box, in: ctx, pageWidth: geometry.format.pageWidthMM, isSpread: region.spineX != nil)
        }
        if options.showGuides {
            drawGuides(in: ctx, trim: trim, safeRects: region.safeRects, spineX: region.spineX, scale: scale)
        }
    }

    private func cgRect(_ r: Rect) -> CGRect {
        CGRect(x: r.minX, y: r.minY, width: r.size.width, height: r.size.height)
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

    private func drawText(_ box: TextBox, in ctx: CGContext, pageWidth: Double, isSpread: Bool) {
        guard !box.text.isEmpty, box.rect.size.width > 0, box.rect.size.height > 0 else { return }
        let spec = Self.font(for: box.role)
        let ctFont = CTFontCreateWithName(spec.name as CFString, spec.size, nil)
        let rightAligned = box.role == .pageNumber && isSpread && (box.rect.minX + box.rect.size.width / 2) >= pageWidth

        var alignment: CTTextAlignment = rightAligned ? .right : .left
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
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        ]
        let string = NSAttributedString(string: box.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let w = box.rect.size.width, h = box.rect.size.height
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

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
