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

    public init(showGuides: Bool = false, includeBleed: Bool = true, pixelsPerMM: Double) {
        self.showGuides = showGuides
        self.includeBleed = includeBleed
        self.pixelsPerMM = pixelsPerMM
    }
}

/// Draws spreads (and single cover pages) with CoreGraphics/CoreText only, so the same code
/// serves bitmap, PDF and on-screen contexts.
///
/// Context contract: one context unit is `1 / pixelsPerMM` mm. The context shows the trim area,
/// or the trim area plus the supplier's bleed on every outer side when `includeBleed` is true
/// (size = `visibleArea * pixelsPerMM`). The top of the visible area is the top of the context
/// (anchored via the context's clip-box height). Fonts are sized in mm because the drawing space
/// is mm; `points(fromMM:)` gives the equivalent point size at 72 dpi.
///
/// Bleed convention: a frame edge lying on the outer boundary of the spread (or page for covers)
/// is stretched by `bleedMM` when `includeBleed` is true. The spine is never bled across.
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

    // MARK: Public API

    /// Draws a two-page spread. The context must be `spreadVisibleArea(options) * pixelsPerMM` large.
    public func render(_ spread: Spread, into ctx: CGContext, options: RenderOptions) async {
        let trim = Rect(origin: Point(x: 0, y: 0), size: geometry.spreadSize)
        let loaded = await loadImages(spread, options: options)
        let pageW = geometry.format.pageWidthMM
        draw(spread, images: loaded, into: ctx, options: options, trim: trim,
             safeRects: [geometry.safeRect(side: .left), geometry.safeRect(side: .right)], spineX: pageW)
    }

    /// Draws ONE page (cover front or back; rects in single-page coordinates).
    public func renderCover(_ page: Spread, into ctx: CGContext, options: RenderOptions) async {
        let trim = geometry.pageRect(side: .left)
        let loaded = await loadImages(page, options: options)
        draw(page, images: loaded, into: ctx, options: options, trim: trim,
             safeRects: [geometry.safeRect(side: .left)], spineX: nil)
    }

    /// PNG of the visible area at `options.pixelsPerMM`; row 0 is the top of the spread.
    public func renderPNG(_ spread: Spread, options: RenderOptions) async -> Data {
        let trim = Rect(origin: Point(x: 0, y: 0), size: geometry.spreadSize)
        return await png(for: trim, options: options) { ctx in
            await self.render(spread, into: ctx, options: options)
        }
    }

    /// PNG of one cover page.
    public func renderCoverPNG(_ page: Spread, options: RenderOptions) async -> Data {
        let trim = geometry.pageRect(side: .left)
        return await png(for: trim, options: options) { ctx in
            await self.renderCover(page, into: ctx, options: options)
        }
    }

    // MARK: Internals

    private func visibleArea(trim: Rect, options: RenderOptions) -> Rect {
        options.includeBleed ? trim.insetBy(-geometry.profile.bleedMM) : trim
    }

    private func png(for trim: Rect, options: RenderOptions,
                     draw: (CGContext) async -> Void) async -> Data {
        let area = visibleArea(trim: trim, options: options)
        let w = max(Int((area.size.width * options.pixelsPerMM).rounded()), 1)
        let h = max(Int((area.size.height * options.pixelsPerMM).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        await draw(ctx)
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Loads the photo of each frame (keyed by frame id), asking for enough pixels for the options' resolution.
    private func loadImages(_ spread: Spread, options: RenderOptions) async -> [String: CGImage] {
        FontRegistry.registerBundledFonts()
        let dpiHint = options.pixelsPerMM * 25.4
        var result: [String: CGImage] = [:]
        for frame in spread.frames {
            guard let id = frame.photoID else { continue }
            let minWidth = Int((frame.rect.size.width / 25.4 * dpiHint).rounded(.up))
            if let image = await images.image(for: id, minPixelWidth: max(minWidth, 1)) {
                result[frame.id] = image
            }
        }
        return result
    }

    private func draw(_ spread: Spread, images: [String: CGImage], into ctx: CGContext,
                      options: RenderOptions, trim: Rect, safeRects: [Rect], spineX: Double?) {
        let area = visibleArea(trim: trim, options: options)
        let scale = options.pixelsPerMM
        let bleed = options.includeBleed ? geometry.profile.bleedMM : 0

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // mm space, origin at the top-left of the visible area, y down.
        let height = ctx.boundingBoxOfClipPath.height
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)

        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(cgRect(area))
        ctx.clip(to: cgRect(area))

        for frame in spread.frames {
            drawFrame(frame, image: images[frame.id], in: ctx, trim: trim, bleed: bleed)
        }
        for box in spread.texts {
            drawText(box, in: ctx, pageWidth: geometry.format.pageWidthMM, isSpread: spineX != nil)
        }
        if options.showGuides {
            drawGuides(in: ctx, trim: trim, safeRects: safeRects, spineX: spineX, scale: scale)
        }
    }

    private func cgRect(_ r: Rect) -> CGRect {
        CGRect(x: r.minX, y: r.minY, width: r.size.width, height: r.size.height)
    }

    /// Frame rect with outer-boundary edges stretched by `bleed`.
    private func bleedExtended(_ r: Rect, trim: Rect, bleed: Double) -> Rect {
        guard bleed > 0 else { return r }
        let eps = 0.01
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if abs(minX - trim.minX) < eps { minX -= bleed }
        if abs(maxX - trim.maxX) < eps { maxX += bleed }
        if abs(minY - trim.minY) < eps { minY -= bleed }
        if abs(maxY - trim.maxY) < eps { maxY += bleed }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drawFrame(_ frame: Frame, image: CGImage?, in ctx: CGContext, trim: Rect, bleed: Double) {
        let rect = bleedExtended(frame.rect, trim: trim, bleed: bleed)
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

    private func font(for role: TextRole) -> (name: String, size: Double) {
        switch role {
        case .title: return (FontRegistry.titleFont, 9.9)
        case .date: return (FontRegistry.textFont, 3.2)
        case .body: return (FontRegistry.textFont, 3.5)
        case .caption, .pageNumber: return (FontRegistry.textFont, 3.0)
        }
    }

    private func drawText(_ box: TextBox, in ctx: CGContext, pageWidth: Double, isSpread: Bool) {
        guard !box.text.isEmpty, box.rect.size.width > 0, box.rect.size.height > 0 else { return }
        let spec = font(for: box.role)
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
