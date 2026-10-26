import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image provider used by `PDFExporter`: wraps the provider of originals and hands the renderer
/// print-ready images.
///
/// For every request it
/// 1. asks the base provider for the ORIGINAL (`minPixelWidth` = the photo's original pixel width),
/// 2. resamples it to the target width (below), never above the source width,
/// 3. draws it opaque (white under any alpha) into an 8-bit sRGB bitmap, which also converts
///    Display P3 originals to sRGB,
/// 4. encodes that as JPEG at `profile.output.jpegQuality` via ImageIO and
/// 5. returns a `CGImage` decoded from THOSE JPEG bytes (`CGImage(jpegDataProviderSource:)`).
///    Quartz's PDF context embeds such an image's JPEG data unchanged as a `/DCTDecode` stream,
///    so the PDF is not recompressed (verified by `PDFExporterTests.imagesEmbeddedAsJPEG`).
///
/// Target width. The renderer's `minPixelWidth` hint is the widest frame using the photo at the
/// image DPI, i.e. `ceil(frameWidthMM / 25.4 * dpi)`. That is the frame width, not the width of the
/// cover-fitted image: a photo wider than its frame (or zoomed, or bled over the trim edge) is
/// drawn wider than the frame, and resampling it to the frame width would drop it below the output
/// DPI (a 2:1 photo in a square frame would print at 150 DPI instead of 300). So the provider also
/// precomputes, once per export, the need of each photo over all frames of the album:
/// `ceil(imageWidthMM / 25.4 * dpi)` where `imageWidthMM` is the width of `FrameFit.imageRect` on the
/// frame extended by the bleed on its outer edges (same rule as `Preflight` and the renderer), zoom
/// included. The target is `min(sourceWidth, max(hint, need))`.
///
/// Cache: one entry per photo (the target is the album-wide maximum, so all frames of a photo get
/// the same image). `PDFExporter` calls `clearCache()` after each spread, so the two pages of a
/// spread share the work and memory stays bounded to one spread's photos.
actor ExportImageProvider: ImageProvider {
    private let base: ImageProvider
    private let jpegQuality: Double
    private let sourceWidth: [PhotoID: Int]
    private let need: [PhotoID: Int]
    private var cache: [PhotoID: (width: Int, image: CGImage)] = [:]

    init(base: ImageProvider, album: Album, profile: SupplierProfile, format: BookFormat) {
        self.base = base
        self.jpegQuality = profile.output.jpegQuality
        self.sourceWidth = album.photos.mapValues(\.pixelWidth)
        self.need = Self.needs(album: album, profile: profile, format: format)
    }

    func clearCache() { cache.removeAll() }

    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? {
        let wanted = max(minPixelWidth, need[photoID] ?? 0, 1)
        // `width` in the cache is the requested target (before capping at the source width).
        if let hit = cache[photoID], hit.width >= wanted { return hit.image }
        let original = max(sourceWidth[photoID] ?? 0, wanted)
        guard let source = await base.image(for: photoID, minPixelWidth: original) else { return nil }
        let width = min(source.width, wanted)
        guard let image = Self.printImage(source, width: width, quality: jpegQuality) else { return nil }
        cache[photoID] = (wanted, image)
        return image
    }

    // MARK: -

    /// Resampled, opaque, sRGB, JPEG-backed image `width` pixels wide.
    static func printImage(_ source: CGImage, width: Int, quality: Double) -> CGImage? {
        guard let data = jpegData(source, width: width, quality: quality),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    static func jpegData(_ source: CGImage, width: Int, quality: Double) -> Data? {
        let w = max(width, 1)
        let h = max(Int((Double(source.height) * Double(w) / Double(source.width)).rounded()), 1)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let bitmap = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, bitmap, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Album-wide pixel width needed per photo at the output DPI (cover-fit, zoom and bleed included).
    static func needs(album: Album, profile: SupplierProfile, format: BookFormat) -> [PhotoID: Int] {
        let dpi = Double(profile.output.dpi)
        let w = format.pageWidthMM, h = format.pageHeightMM
        let spreadX = profile.pageMode == .singlePages ? [0, w, 2 * w] : [0, 2 * w]
        var result: [PhotoID: Int] = [:]

        func add(_ spread: Spread, outerX: [Double]) {
            for frame in spread.frames {
                guard let id = frame.photoID, let photo = album.photos[id],
                      photo.pixelWidth > 0, photo.pixelHeight > 0 else { continue }
                let printed = bleedExtended(frame.rect, outerX: outerX, outerY: [0, h], bleed: profile.bleedMM)
                let fit = FrameFit.imageRect(imageSize: Size(width: Double(photo.pixelWidth),
                                                             height: Double(photo.pixelHeight)),
                                             in: printed, offset: frame.offset, zoom: frame.zoom)
                let px = Int((fit.size.width / 25.4 * dpi - 1e-9).rounded(.up))
                result[id] = max(result[id] ?? 0, px)
            }
        }
        for spread in album.spreads { add(spread, outerX: spreadX) }
        if let cover = album.cover {
            add(cover.front, outerX: [0, w])
            add(cover.back, outerX: [0, w])
        }
        return result
    }

    private static func bleedExtended(_ r: Rect, outerX: [Double], outerY: [Double], bleed: Double) -> Rect {
        let eps = 0.01
        func on(_ v: Double, _ edges: [Double]) -> Bool { edges.contains { abs($0 - v) < eps } }
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if on(minX, outerX) { minX -= bleed }
        if on(maxX, outerX) { maxX += bleed }
        if on(minY, outerY) { minY -= bleed }
        if on(maxY, outerY) { maxY += bleed }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
