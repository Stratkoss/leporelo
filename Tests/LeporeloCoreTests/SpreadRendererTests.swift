import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import LeporeloCore

private struct SolidProvider: ImageProvider {
    let image: CGImage
    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? { image }
}

private struct RGBA { var r: Int; var g: Int; var b: Int }

private struct Bitmap {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(png: Data) {
        let src = CGImageSourceCreateWithData(png as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        width = w
        height = h
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        data = buf
    }

    /// Row 0 is the top row.
    func pixel(x: Int, y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
    }
}

private func near(_ p: RGBA, _ r: Int, _ g: Int, _ b: Int, tol: Int = 3) -> Bool {
    abs(p.r - r) <= tol && abs(p.g - g) <= tol && abs(p.b - b) <= tol
}

/// Solid red in sRGB (the fixtures use device RGB, which converts to a different sRGB value).
private func redImage(width: Int = 256, height: Int = 256) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private let ppmm = 4.0
private let bleed = 3.0

private func makeRenderer(images: ImageProvider = PlaceholderImageProvider()) throws -> (SpreadRenderer, PageGeometry) {
    let (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
    let geo = PageGeometry(format: f, profile: p)
    let album = Album(formatVersion: 1, id: "a", title: "Amalfi", supplierProfileID: p.id, formatID: f.id,
                      world: "journal-gallery", cover: nil, spreads: [], photos: [:], source: nil,
                      createdAt: Date(timeIntervalSince1970: 0))
    return (SpreadRenderer(album: album, geometry: geo, images: images), geo)
}

private func spread(frames: [Frame] = [], texts: [TextBox] = []) -> Spread {
    Spread(id: "s", kind: .journal, templateID: "t", dayKey: nil, frames: frames, texts: texts,
           manuallyEdited: false)
}

private func frame(_ id: String, _ r: Rect, photo: PhotoID? = nil) -> Frame {
    Frame(id: id, rect: r, photoID: photo, offset: Point(x: 0, y: 0), zoom: 1)
}

/// Pixel index for an mm coordinate in a PNG rendered with or without bleed.
private func px(_ mm: Double, includeBleed: Bool) -> Int {
    Int(((mm + (includeBleed ? bleed : 0)) * ppmm).rounded(.down))
}

@Suite struct SpreadRendererTests {
    @Test func fontsRegister() {
        FontRegistry.registerBundledFonts()
        FontRegistry.registerBundledFonts()
        let title = CTFontCreateWithName("Fraunces" as CFString, 12, nil)
        #expect(CTFontCopyFamilyName(title) as String == "Fraunces")
        let text = CTFontCreateWithName("Schibsted Grotesk" as CFString, 12, nil)
        #expect(CTFontCopyFamilyName(text) as String == "Schibsted Grotesk")
        #expect(abs(SpreadRenderer.points(fromMM: 25.4) - 72) < 1e-9)
    }

    @Test func emptyFrameRendersGray() async throws {
        let (r, _) = try makeRenderer()
        let s = spread(frames: [frame("f", Rect(x: 20, y: 20, width: 100, height: 80))])
        let bmp = Bitmap(png: await r.renderPNG(s, options: RenderOptions(includeBleed: false, pixelsPerMM: ppmm)))
        #expect(bmp.width == Int(594 * ppmm) && bmp.height == Int(210 * ppmm))
        #expect(near(bmp.pixel(x: px(70, includeBleed: false), y: px(60, includeBleed: false)), 0xE6, 0xE6, 0xE6))
        #expect(near(bmp.pixel(x: px(300, includeBleed: false), y: px(150, includeBleed: false)), 255, 255, 255))
    }

    @Test func photoRendersIntoFrameWithTopLeftOrigin() async throws {
        let red = redImage(width: 300, height: 200)
        let (r, _) = try makeRenderer(images: SolidProvider(image: red))
        let s = spread(frames: [frame("f", Rect(x: 20, y: 20, width: 100, height: 80), photo: "p1")])
        let bmp = Bitmap(png: await r.renderPNG(s, options: RenderOptions(includeBleed: false, pixelsPerMM: ppmm)))
        #expect(near(bmp.pixel(x: px(70, includeBleed: false), y: px(60, includeBleed: false)), 255, 0, 0))
        // Top-left frame: red near its top-left corner, white at the bottom-left of the bitmap.
        #expect(near(bmp.pixel(x: px(21, includeBleed: false), y: px(21, includeBleed: false)), 255, 0, 0))
        #expect(near(bmp.pixel(x: px(21, includeBleed: false), y: px(190, includeBleed: false)), 255, 255, 255))
    }

    @Test func bleedingFrameStretchesIntoBleedOnlyWhenRequested() async throws {
        let red = redImage()
        let (r, geo) = try makeRenderer(images: SolidProvider(image: red))
        let s = spread(frames: [frame("f", Rect(x: 297, y: 0, width: 297, height: 210), photo: "p1")])
        let withBleed = Bitmap(png: await r.renderPNG(s, options: RenderOptions(includeBleed: true, pixelsPerMM: ppmm)))
        #expect(withBleed.width == Int(geo.spreadBleedRect.size.width * ppmm))
        // 1.5 mm outside the trim edge on the right, and above the top edge.
        #expect(near(withBleed.pixel(x: px(595.5, includeBleed: true), y: px(100, includeBleed: true)), 255, 0, 0))
        #expect(near(withBleed.pixel(x: px(400, includeBleed: true), y: px(-1.5, includeBleed: true)), 255, 0, 0))
        // The spine side does not bleed into the left page.
        #expect(near(withBleed.pixel(x: px(295.5, includeBleed: true), y: px(100, includeBleed: true)), 255, 255, 255))
        let noBleed = Bitmap(png: await r.renderPNG(s, options: RenderOptions(includeBleed: false, pixelsPerMM: ppmm)))
        #expect(noBleed.width == Int(594 * ppmm))
        #expect(near(noBleed.pixel(x: px(400, includeBleed: false), y: px(100, includeBleed: false)), 255, 0, 0))
    }

    @Test func guidesOnlyWhenRequested() async throws {
        let (r, _) = try makeRenderer()
        let s = spread()
        // Trim edge (x = 0) with bleed included sits at 3 mm.
        let x = px(0, includeBleed: true), y = px(100, includeBleed: true)
        let off = Bitmap(png: await r.renderPNG(s, options: RenderOptions(showGuides: false, includeBleed: true, pixelsPerMM: ppmm)))
        #expect(near(off.pixel(x: x, y: y), 255, 255, 255))
        let on = Bitmap(png: await r.renderPNG(s, options: RenderOptions(showGuides: true, includeBleed: true, pixelsPerMM: ppmm)))
        let p = on.pixel(x: x, y: y)
        #expect(p.r > 200 && p.g < 120 && p.b < 120)
        // Safe zone (6 mm in) is blue.
        let q = on.pixel(x: px(6, includeBleed: true), y: y)
        #expect(q.b > 200 && q.r < 120 && q.g < 120)
        // Spine (x = 297) is grey.
        let g = on.pixel(x: px(297, includeBleed: true), y: y)
        #expect(abs(g.r - g.g) < 10 && abs(g.g - g.b) < 10 && g.r < 200)
    }

    @Test func textDrawsSomething() async throws {
        let (r, _) = try makeRenderer()
        let box = Rect(x: 320, y: 100, width: 200, height: 30)
        let s = spread(texts: [TextBox(id: "t", rect: box, role: .title, text: "Amalfi")])
        let bmp = Bitmap(png: await r.renderPNG(s, options: RenderOptions(includeBleed: false, pixelsPerMM: ppmm)))
        var found = false
        for y in px(box.minY, includeBleed: false)..<px(box.maxY, includeBleed: false) {
            for x in px(box.minX, includeBleed: false)..<px(box.maxX, includeBleed: false)
            where !near(bmp.pixel(x: x, y: y), 255, 255, 255, tol: 40) { found = true }
        }
        #expect(found)
        // Nothing outside the box.
        #expect(near(bmp.pixel(x: px(100, includeBleed: false), y: px(50, includeBleed: false)), 255, 255, 255))
    }

    @Test func coverPageRendersSinglePage() async throws {
        let red = redImage()
        let (r, _) = try makeRenderer(images: SolidProvider(image: red))
        let page = spread(frames: [frame("f", Rect(x: 0, y: 0, width: 297, height: 210), photo: "p1")])
        let ctxW = Int((297 + 2 * bleed) * ppmm), ctxH = Int((210 + 2 * bleed) * ppmm)
        let ctx = CGContext(data: nil, width: ctxW, height: ctxH, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        await r.renderCover(page, into: ctx, options: RenderOptions(includeBleed: true, pixelsPerMM: ppmm))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        // Corner pixel inside the bleed is red (full-page photo is stretched into bleed on all sides).
        #expect(data[0] == 255 && data[1] == 0 && data[2] == 0)
    }
}
