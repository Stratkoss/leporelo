import Testing
@testable import LeporeloCore

@Suite struct FrameFitTests {
    let eps = 1e-6

    func covers(_ img: Rect, _ frame: Rect) -> Bool {
        img.minX <= frame.minX + eps && img.minY <= frame.minY + eps
            && img.maxX >= frame.maxX - eps && img.maxY >= frame.maxY - eps
    }

    @Test func portraitInLandscapeFrameCovers() {
        let frame = Rect(x: 10, y: 20, width: 200, height: 100)
        let r = FrameFit.imageRect(imageSize: Size(width: 3000, height: 4000), in: frame,
                                   offset: Point(x: 0, y: 0), zoom: 1)
        #expect(covers(r, frame))
        #expect(abs(r.size.width - 200) < eps)
        #expect(abs(r.size.height - 266.6666667) < 1e-4)
    }

    @Test func offsetNeverRevealsBackground() {
        let frame = Rect(x: 0, y: 0, width: 200, height: 100)
        let img = Size(width: 3000, height: 4000)
        for zoom in [1.0, 1.5, 3.0] {
            for o in [Point(x: 1, y: 1), Point(x: -1, y: -1), Point(x: 9, y: -9), Point(x: 0.3, y: 0.7)] {
                let c = FrameFit.clampedOffset(o, imageSize: img, frame: frame, zoom: zoom)
                #expect(abs(c.x) <= 1 && abs(c.y) <= 1)
                #expect(covers(FrameFit.imageRect(imageSize: img, in: frame, offset: c, zoom: zoom), frame))
                // Even an unclamped offset must not uncover the frame.
                #expect(covers(FrameFit.imageRect(imageSize: img, in: frame, offset: o, zoom: zoom), frame))
            }
        }
        // zoom below 1 is treated as 1.
        #expect(covers(FrameFit.imageRect(imageSize: img, in: frame, offset: Point(x: 0, y: 0), zoom: 0.2), frame))
    }

    @Test func effectiveDPI() {
        let wide = Rect(x: 0, y: 0, width: 338.7, height: 100)
        let d1 = FrameFit.effectiveDPI(pixelWidth: 4000, pixelHeight: 3000, frame: wide, zoom: 1)
        #expect(abs(d1 - 300) < 1)
        let d2 = FrameFit.effectiveDPI(pixelWidth: 4000, pixelHeight: 3000, frame: wide, zoom: 2)
        #expect(abs(d2 - 150) < 0.5)
    }

    @Test func effectiveDPIUsesLimitingAxis() {
        // Portrait 3000x4000 in a 200x100 mm frame: limited by width (3000 px over 200 mm = 381 DPI).
        let f = Rect(x: 0, y: 0, width: 200, height: 100)
        let d = FrameFit.effectiveDPI(pixelWidth: 3000, pixelHeight: 4000, frame: f, zoom: 1)
        #expect(abs(d - 3000 / (200 / 25.4)) < 0.01)
        // Landscape photo in a tall frame: limited by height.
        let tall = Rect(x: 0, y: 0, width: 100, height: 200)
        let d2 = FrameFit.effectiveDPI(pixelWidth: 4000, pixelHeight: 3000, frame: tall, zoom: 1)
        #expect(abs(d2 - 3000 / (200 / 25.4)) < 0.01)
    }
}
