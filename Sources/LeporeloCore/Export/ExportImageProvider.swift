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
/// Target width: `min(sourceWidth, minPixelWidth)`. The hint comes from
/// `SpreadRenderer.loadImages`, which computes it from the photo's DRAWN width (cover-fit on the
/// bleed-extended frame, zoom included) at `RenderOptions.imageDPI` (the profile's output DPI), the
/// widest need when a photo is in several frames. There is no second geometry here.
///
/// Cache: one entry per photo, reused when it was made for at least the requested target.
/// `PDFExporter` calls `clearCache()` after each spread, so the two pages of a spread share the
/// work and memory stays bounded to one spread's photos.
actor ExportImageProvider: ImageProvider {
    private let base: ImageProvider
    private let jpegQuality: Double
    private let sourceWidth: [PhotoID: Int]
    private var cache: [PhotoID: (width: Int, image: CGImage)] = [:]

    init(base: ImageProvider, album: Album, jpegQuality: Double) {
        self.base = base
        self.jpegQuality = jpegQuality
        self.sourceWidth = album.photos.mapValues(\.pixelWidth)
    }

    func clearCache() { cache.removeAll() }

    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? {
        let wanted = max(minPixelWidth, 1)
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
}
