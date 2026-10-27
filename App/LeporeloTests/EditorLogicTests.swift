import AppKit
import CoreGraphics
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private func canvaGeometry() throws -> PageGeometry {
    let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
    return PageGeometry(format: format, profile: profile)
}

private func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) < eps }
private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

// MARK: - Canvas layout (view <-> mm)

struct CanvasLayoutTests {
    private let area = Rect(x: -3, y: -3, width: 600, height: 216)  // a 594 x 210 spread with 3 mm bleed

    @Test func fitsTheVisibleAreaWithLetterboxing() {
        // Wide view: the height limits; the content is centred horizontally.
        let layout = CanvasLayout(visibleArea: area, viewSize: CGSize(width: 1000, height: 248), padding: 16)
        #expect(near(layout.scale, 1))  // (248 - 32) / 216
        #expect(near(layout.contentRect.width, 600))
        #expect(near(layout.contentRect.height, 216))
        #expect(near(layout.contentRect.minX, 200))  // (1000 - 600) / 2
        #expect(near(layout.contentRect.minY, 16))

        // Tall view: the width limits; centred vertically.
        let tall = CanvasLayout(visibleArea: area, viewSize: CGSize(width: 632, height: 800), padding: 16)
        #expect(near(tall.scale, 1))
        #expect(near(tall.contentRect.minX, 16))
        #expect(near(tall.contentRect.minY, (800 - 216) / 2))
    }

    @Test func degenerateSizesGiveAnEmptyLayout() {
        let layout = CanvasLayout(visibleArea: area, viewSize: CGSize(width: 10, height: 10), padding: 16)
        #expect(layout.scale == 0)
        #expect(layout.contentRect.isEmpty)
        #expect(layout.mmPoint(CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func mmAndViewPointsRoundTrip() throws {
        let layout = CanvasLayout(visibleArea: area, viewSize: CGSize(width: 1232, height: 464), padding: 16)
        #expect(near(layout.scale, 2))
        // The visible area's top-left corner (bleed included) is the content's top-left.
        let topLeft = layout.viewPoint(Point(x: -3, y: -3))
        #expect(near(topLeft.x, layout.contentRect.minX))
        #expect(near(topLeft.y, layout.contentRect.minY))
        // Trim origin (0, 0) is 3 mm (6 pt) inside.
        let origin = layout.viewPoint(Point(x: 0, y: 0))
        #expect(near(origin.x, layout.contentRect.minX + 6))
        #expect(near(origin.y, layout.contentRect.minY + 6))
        let back = try #require(layout.mmPoint(CGPoint(x: 400, y: 100)))
        let again = layout.viewPoint(back)
        #expect(near(again.x, 400) && near(again.y, 100))
        // Rects keep their size times the scale; y grows downwards like the mm space.
        let r = layout.viewRect(Rect(x: 10, y: 20, width: 30, height: 40))
        #expect(near(r.width, 60) && near(r.height, 80))
        #expect(near(r.minY, layout.viewPoint(Point(x: 10, y: 20)).y))
        // View deltas become mm deltas.
        #expect(layout.mmDelta(CGSize(width: 10, height: -4)) == Point(x: 5, y: -2))
    }

    @Test func rendererTransformMapsTheYUpContextOntoTheContentRect() {
        let layout = CanvasLayout(visibleArea: area, viewSize: CGSize(width: 1232, height: 464), padding: 16)
        let t = layout.rendererTransform
        let c = layout.contentRect
        // The renderer's origin is the bottom-left of the visible area...
        let origin = CGPoint.zero.applying(t)
        #expect(near(origin.x, c.minX) && near(origin.y, c.maxY))
        // ...and its y axis points up (to smaller view y in a flipped view).
        let up = CGPoint(x: c.width, y: c.height).applying(t)
        #expect(near(up.x, c.maxX) && near(up.y, c.minY))
    }

    @Test func visibleAreaIsTrimPlusBleed() throws {
        let g = try canvaGeometry()
        let bleed = g.profile.bleedMM
        let spread = CanvasLayout.visibleArea(geometry: g, isCover: false)
        #expect(spread == Rect(x: -bleed, y: -bleed, width: g.spreadSize.width + 2 * bleed,
                               height: g.spreadSize.height + 2 * bleed))
        let cover = CanvasLayout.visibleArea(geometry: g, isCover: true)
        #expect(cover.size.width == g.format.pageWidthMM + 2 * bleed)
    }

    /// The real renderer drawn through the layout's transform into a FLIPPED context (like the
    /// canvas NSView) puts a frame exactly where `viewRect` says.
    @Test func rendererDrawsWhereTheLayoutSays() throws {
        let g = try canvaGeometry()
        let area = CanvasLayout.visibleArea(geometry: g, isCover: false)
        let w = 700, h = 300
        let layout = CanvasLayout(visibleArea: area, viewSize: CGSize(width: w, height: h), padding: 10)
        let frameRect = Rect(x: 330, y: 40, width: 120, height: 80)
        let spread = Spread(id: "s", kind: .gallery, templateID: "gallery-1", dayKey: nil,
                            frames: [Frame(id: "f", rect: frameRect, photoID: "p", offset: Point(x: 0, y: 0), zoom: 1)],
                            texts: [], manuallyEdited: false)
        let red = try #require(solidImage(r: 255, g: 0, b: 0, width: 30, height: 20))
        let album = Album(formatVersion: 1, id: "a", title: "T", supplierProfileID: g.profile.id, formatID: g.format.id,
                          world: Workflow.world, cover: nil, spreads: [spread], photos: [:], source: nil,
                          createdAt: Date(timeIntervalSince1970: 0))
        let renderer = SpreadRenderer(album: album, geometry: g, images: PlaceholderImageProvider())
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A flipped view's context: y down from the top.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(layout.rendererTransform)
        renderer.draw(spread, images: ["p": red], into: ctx,
                      options: RenderOptions(showGuides: false, includeBleed: true, pixelsPerMM: layout.scale))
        let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ p: CGPoint) -> (UInt8, UInt8, UInt8) {
            // Row 0 of the bitmap is the top of the flipped view.
            let i = Int(p.y) * w * 4 + Int(p.x) * 4
            return (data[i], data[i + 1], data[i + 2])
        }
        let r = layout.viewRect(frameRect)
        #expect(pixel(CGPoint(x: r.midX, y: r.midY)) == (255, 0, 0))
        #expect(pixel(CGPoint(x: r.minX + 2, y: r.minY + 2)) == (255, 0, 0))
        // Just outside the frame: white paper; outside the content: the black background.
        #expect(pixel(CGPoint(x: r.minX - 3, y: r.midY)) == (255, 255, 255))
        #expect(pixel(CGPoint(x: r.midX, y: r.maxY + 3)) == (255, 255, 255))
        #expect(pixel(CGPoint(x: layout.contentRect.minX - 3, y: layout.contentRect.midY)) == (0, 0, 0))
    }

    private func solidImage(r: UInt8, g: UInt8, b: UInt8, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

// MARK: - Hit testing

struct CanvasHitTests {
    private func spread() -> Spread {
        Spread(id: "s", kind: .journal, templateID: "journal-3", dayKey: nil,
               frames: [
                   Frame(id: "big", rect: Rect(x: 0, y: 0, width: 297, height: 210), photoID: "a",
                         offset: Point(x: 0, y: 0), zoom: 1),
                   Frame(id: "small", rect: Rect(x: 20, y: 20, width: 50, height: 40), photoID: "b",
                         offset: Point(x: 0, y: 0), zoom: 1),
               ],
               texts: [TextBox(id: "body", rect: Rect(x: 30, y: 30, width: 20, height: 10), role: .body, text: "")],
               manuallyEdited: false)
    }

    @Test func textsWinOverFramesAndLaterFramesWinOverEarlier() throws {
        let g = try canvaGeometry()
        let s = spread()
        #expect(CanvasHitTest.hit(s, at: Point(x: 35, y: 35), geometry: g) == .text("body"))
        #expect(CanvasHitTest.hit(s, at: Point(x: 25, y: 25), geometry: g) == .frame("small"))
        #expect(CanvasHitTest.hit(s, at: Point(x: 200, y: 100), geometry: g) == .frame("big"))
        #expect(CanvasHitTest.hit(s, at: Point(x: 400, y: 100), geometry: g) == nil)
    }

    @Test func aFrameOnTheTrimEdgeIsHitInItsBleed() throws {
        let g = try canvaGeometry()
        #expect(CanvasHitTest.hit(spread(), at: Point(x: -1, y: 100), geometry: g) == .frame("big"))
        #expect(CanvasHitTest.hit(spread(), at: Point(x: 150, y: -2), geometry: g) == .frame("big"))
        #expect(CanvasHitTest.hit(spread(), at: Point(x: 400, y: -2), geometry: g) == nil)
    }
}

// MARK: - Crop math

struct CropMathTests {
    // A 4:3 photo in a 100 x 100 frame: cover-fit makes it 133.3 x 100, slack 33.3 mm across.
    private let frame = Rect(x: 0, y: 0, width: 100, height: 100)
    private let photo = Size(width: 4000, height: 3000)

    @Test func slackIsTheOverhangOfTheCoverFittedImage() {
        let s = CropMath.slack(frame: frame, photo: photo, zoom: 1)
        #expect(near(s.width, 100.0 / 3))
        #expect(near(s.height, 0))
        let z = CropMath.slack(frame: frame, photo: photo, zoom: 2)
        #expect(near(z.width, 400.0 / 3 * 2 - 100))
        #expect(near(z.height, 100))
    }

    @Test func dragMovesTheImageByTheDraggedDistance() {
        // Dragging 1/6 of the slack to the right moves the offset by 1/3 (offset spans 2 slack halves).
        let o = CropMath.offset(start: Point(x: 0, y: 0), drag: Point(x: 100.0 / 18, y: 5), frame: frame,
                                photo: photo, zoom: 1)
        #expect(near(o.x, 1.0 / 3))
        #expect(o.y == 0)  // no vertical slack at zoom 1
        // The image follows the pointer exactly (FrameFit's mapping).
        let before = FrameFit.imageRect(imageSize: photo, in: frame, offset: Point(x: 0, y: 0), zoom: 1)
        let after = FrameFit.imageRect(imageSize: photo, in: frame, offset: o, zoom: 1)
        #expect(near(after.minX - before.minX, 100.0 / 18))
        // Clamped to -1...1.
        let far = CropMath.offset(start: Point(x: 0.9, y: 0), drag: Point(x: 500, y: 0), frame: frame,
                                  photo: photo, zoom: 1)
        #expect(far.x == 1)
        // Zoomed in: vertical drags work, downwards is +y like the mm space.
        let down = CropMath.offset(start: Point(x: 0, y: 0), drag: Point(x: 0, y: 25), frame: frame,
                                   photo: photo, zoom: 2)
        #expect(near(down.y, 0.5))
    }

    @Test func zoomIsClampedBetweenOneAndTheMaximum() {
        #expect(CropMath.clampZoom(0.3) == 1)
        #expect(CropMath.clampZoom(9) == CropMath.maxZoom)
        #expect(CropMath.clampZoom(.nan) == 1)
        #expect(CropMath.zoom(1, magnification: 0.5) == 1.5)
        #expect(CropMath.zoom(3.8, magnification: 0.5) == CropMath.maxZoom)
        #expect(CropMath.zoom(1.2, magnification: -0.9) == 1)
        let scrolled = CropMath.zoom(1.5, scrollDelta: 10)
        #expect(scrolled > 1.5)
        #expect(CropMath.zoom(1.5, scrollDelta: -10) < 1.5)
        #expect(near(CropMath.zoom(CropMath.zoom(1.5, scrollDelta: 10), scrollDelta: -10), 1.5))
    }

    @Test func arrowKeysMoveTheImageByAFixedDistance() {
        let right = CropMath.arrowOffset(Point(x: 0, y: 0), dx: 1, dy: 0, stepMM: 1, frame: frame, photo: photo, zoom: 1)
        let before = FrameFit.imageRect(imageSize: photo, in: frame, offset: Point(x: 0, y: 0), zoom: 1)
        let after = FrameFit.imageRect(imageSize: photo, in: frame, offset: right, zoom: 1)
        #expect(near(after.minX - before.minX, 1))
        let up = CropMath.arrowOffset(Point(x: 0, y: 0), dx: 0, dy: -1, stepMM: 1, frame: frame, photo: photo, zoom: 1)
        #expect(up == Point(x: 0, y: 0))  // no vertical slack
    }
}

// MARK: - Layout handles and drags

struct LayoutHandleTests {
    private let rect = Rect(x: 10, y: 20, width: 100, height: 60)

    @Test func handleHitCornersBeforeSides() {
        // Exactly on corners: two edges each.
        #expect(LayoutHandles.hit(Point(x: 10, y: 20), rect: rect, tolerance: 3) == [.minX, .minY])
        #expect(LayoutHandles.hit(Point(x: 111, y: 19), rect: rect, tolerance: 3) == [.maxX, .minY])
        #expect(LayoutHandles.hit(Point(x: 12, y: 79), rect: rect, tolerance: 3) == [.minX, .maxY])
        #expect(LayoutHandles.hit(Point(x: 110, y: 80), rect: rect, tolerance: 3) == [.maxX, .maxY])
        // Side midpoints: one edge.
        #expect(LayoutHandles.hit(Point(x: 60, y: 21), rect: rect, tolerance: 3) == .minY)
        #expect(LayoutHandles.hit(Point(x: 60, y: 80), rect: rect, tolerance: 3) == .maxY)
        #expect(LayoutHandles.hit(Point(x: 9, y: 50), rect: rect, tolerance: 3) == .minX)
        #expect(LayoutHandles.hit(Point(x: 110, y: 50), rect: rect, tolerance: 3) == .maxX)
        // A tiny rect: the corner and side handles overlap, the corner wins.
        let tiny = Rect(x: 0, y: 0, width: 4, height: 4)
        #expect(LayoutHandles.hit(Point(x: 1, y: 0), rect: tiny, tolerance: 3) == [.minX, .minY])
        #expect(LayoutHandles.hit(Point(x: 3, y: 4), rect: tiny, tolerance: 3) == [.maxX, .maxY])
    }

    @Test func handleMissInsideReturnsNil() {
        #expect(LayoutHandles.hit(Point(x: 60, y: 50), rect: rect, tolerance: 3) == nil)
        // On an edge but away from its handles: no handle (the drag moves the item).
        #expect(LayoutHandles.hit(Point(x: 30, y: 20), rect: rect, tolerance: 3) == nil)
        #expect(LayoutHandles.hit(Point(x: 110, y: 30), rect: rect, tolerance: 3) == nil)
        // Far outside.
        #expect(LayoutHandles.hit(Point(x: 200, y: 200), rect: rect, tolerance: 3) == nil)
        #expect(LayoutHandles.hit(Point(x: 10, y: 20), rect: rect, tolerance: .nan) == nil)
    }

    @Test func moveTranslatesWholeRect() {
        let moved = LayoutDrag.rect(from: rect, edges: .all, delta: Point(x: 5, y: -7), keepAspect: true, minSize: 10)
        #expect(moved == Rect(x: 15, y: 13, width: 100, height: 60))
    }

    @Test func resizeMovesOnlyGivenEdges() {
        let right = LayoutDrag.rect(from: rect, edges: .maxX, delta: Point(x: 15, y: 30), keepAspect: false, minSize: 10)
        #expect(right == Rect(x: 10, y: 20, width: 115, height: 60))
        let left = LayoutDrag.rect(from: rect, edges: .minX, delta: Point(x: 15, y: 30), keepAspect: false, minSize: 10)
        #expect(left == Rect(x: 25, y: 20, width: 85, height: 60))
        let topLeft = LayoutDrag.rect(from: rect, edges: [.minX, .minY], delta: Point(x: -5, y: 10),
                                      keepAspect: false, minSize: 10)
        #expect(topLeft == Rect(x: 5, y: 30, width: 105, height: 50))
        // keepAspect has no effect on a side handle.
        let bottom = LayoutDrag.rect(from: rect, edges: .maxY, delta: Point(x: 3, y: 20), keepAspect: true, minSize: 10)
        #expect(bottom == Rect(x: 10, y: 20, width: 100, height: 80))
    }

    @Test func cornerResizeKeepsAspectWithShift() {
        // Bottom-right corner, the x move is the larger relative change: width drives.
        let grown = LayoutDrag.rect(from: rect, edges: [.maxX, .maxY], delta: Point(x: 50, y: 3), keepAspect: true,
                                    minSize: 10)
        #expect(near(grown.minX, 10) && near(grown.minY, 20))
        #expect(near(grown.size.width, 150) && near(grown.size.height, 90))
        // Top-left corner, the y move drives; the bottom-right corner stays.
        let shrunk = LayoutDrag.rect(from: rect, edges: [.minX, .minY], delta: Point(x: 1, y: 30), keepAspect: true,
                                     minSize: 10)
        #expect(near(shrunk.size.height, 30) && near(shrunk.size.width, 50))
        #expect(near(shrunk.maxX, 110) && near(shrunk.maxY, 80))
    }

    @Test func resizeNeverBelowMinimum() {
        // Dragging the left edge past the right one: the right edge stays, the width is the minimum.
        let left = LayoutDrag.rect(from: rect, edges: .minX, delta: Point(x: 500, y: 0), keepAspect: false, minSize: 10)
        #expect(left == Rect(x: 100, y: 20, width: 10, height: 60))
        let bottom = LayoutDrag.rect(from: rect, edges: .maxY, delta: Point(x: 0, y: -500), keepAspect: false,
                                     minSize: 10)
        #expect(bottom == Rect(x: 10, y: 20, width: 100, height: 10))
        // With the aspect kept, the shorter side stops at the minimum and the ratio holds.
        let corner = LayoutDrag.rect(from: rect, edges: [.maxX, .maxY], delta: Point(x: -500, y: -500),
                                     keepAspect: true, minSize: 10)
        #expect(near(corner.size.height, 10) && near(corner.size.width, 100.0 / 6))
        #expect(near(corner.minX, 10) && near(corner.minY, 20))
    }
}

// MARK: - Scroll gestures

struct ScrollZoomTests {
    @Test func phasedGesturesBeginUpdateAndEnd() {
        #expect(ScrollZoom.step(phase: .began, momentumPhase: [], inSession: false)
                == .init(begin: true, update: true, end: false, idleEnd: false))
        #expect(ScrollZoom.step(phase: .changed, momentumPhase: [], inSession: true)
                == .init(begin: false, update: true, end: false, idleEnd: false))
        #expect(ScrollZoom.step(phase: .changed, momentumPhase: [], inSession: false).begin)
        #expect(ScrollZoom.step(phase: .ended, momentumPhase: [], inSession: true)
                == .init(begin: false, update: false, end: true, idleEnd: false))
        #expect(ScrollZoom.step(phase: .cancelled, momentumPhase: [], inSession: true).end)
    }

    @Test func momentumIsIgnoredAndAMouseWheelEndsWhenIdle() {
        #expect(ScrollZoom.step(phase: [], momentumPhase: .changed, inSession: false) == .ignore)
        #expect(ScrollZoom.step(phase: [], momentumPhase: [], inSession: false)
                == .init(begin: true, update: true, end: false, idleEnd: true))
        #expect(ScrollZoom.step(phase: [], momentumPhase: [], inSession: true)
                == .init(begin: false, update: true, end: false, idleEnd: true))
    }
}

// MARK: - Warnings

struct IssueAnchorTests {
    private let spread = Spread(
        id: "d1-journal", kind: .journal, templateID: "journal-3", dayKey: nil,
        frames: [Frame(id: "photo1", rect: Rect(x: 0, y: 0, width: 10, height: 10), photoID: nil,
                       offset: Point(x: 0, y: 0), zoom: 1)],
        texts: [TextBox(id: "title", rect: Rect(x: 0, y: 0, width: 5, height: 5), role: .title, text: "x"),
                TextBox(id: "body", rect: Rect(x: 0, y: 0, width: 5, height: 5), role: .body, text: "")],
        manuallyEdited: false)

    private func issue(_ id: String, frame: String? = nil, _ severity: PreflightSeverity = .warning) -> PreflightIssue {
        PreflightIssue(id: id, severity: severity, spreadID: "d1-journal", frameID: frame, message: id)
    }

    @Test func groupsIssuesByFrameTextOrBanner() {
        let issues = [issue("emptyFrame:d1-journal:photo1", frame: "photo1", .error),
                      issue("dpi:d1-journal:photo1", frame: "photo1"),
                      issue("textSafe:d1-journal:title"),
                      issue("emptyBody:d1-journal:body"),
                      issue("dpi:d1-journal:gone", frame: "gone")]
        let anchors = IssueAnchors(issues, spread: spread)
        #expect(anchors.byFrame["photo1"]?.count == 2)
        #expect(anchors.byText["title"]?.map(\.id) == ["textSafe:d1-journal:title"])
        // An empty journal body and issues of frames that are gone go to the banner.
        #expect(anchors.unanchored.map(\.id) == ["emptyBody:d1-journal:body", "dpi:d1-journal:gone"])
    }

    @Test func badgeSitsInTheTopRightCornerInsideTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        let r = WarningBadge.rect(anchor: CGRect(x: 100, y: 50, width: 200, height: 100), bounds: bounds)
        #expect(r == CGRect(x: 300 - WarningBadge.inset - WarningBadge.size, y: 50 + WarningBadge.inset,
                            width: WarningBadge.size, height: WarningBadge.size))
        // A frame running off the visible area keeps its badge visible.
        let off = WarningBadge.rect(anchor: CGRect(x: 400, y: -40, width: 200, height: 100), bounds: bounds)
        #expect(off.maxX <= bounds.maxX && off.minY >= bounds.minY)
        // A tiny anchor still gets a full badge starting at its left edge.
        let tiny = WarningBadge.rect(anchor: CGRect(x: 10, y: 10, width: 8, height: 8), bounds: bounds)
        #expect(tiny.minX == 10 && tiny.width == WarningBadge.size)
    }

    /// Final fix wave A2: a text overflow (no frame, a `textID`) gets its badge in the top-right
    /// corner of its text box; frames keep theirs.
    @Test func textOverflowBadgeSitsOnItsTextBox() {
        let page = Spread(
            id: "s", kind: .journal, templateID: "journal-3", dayKey: nil,
            frames: [Frame(id: "photo1", rect: Rect(x: 0, y: 0, width: 100, height: 50), photoID: "p",
                           offset: Point(x: 0, y: 0), zoom: 1)],
            texts: [TextBox(id: "body", rect: Rect(x: 120, y: 60, width: 80, height: 40), role: .body, text: "x")],
            manuallyEdited: false)
        let overflow = PreflightIssue(id: "textOverflow:s:body", severity: .warning, spreadID: "s", frameID: nil,
                                      textID: "body", message: "Text se nevejde do rámečku, konec se nevytiskne")
        let dpi = PreflightIssue(id: "dpi:s:photo1", severity: .error, spreadID: "s", frameID: "photo1",
                                 message: "Fotka má jen 100 DPI, pro tisk je potřeba 220")
        #expect(IssueAnchors([overflow], spread: page).byText["body"] == [overflow])
        let scale = 2.0
        let placements = WarningBadge.placements(
            [overflow, dpi], spread: page, bounds: CGRect(x: 0, y: 0, width: 1000, height: 600),
            frameRect: { $0.rect },
            viewRect: { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.size.width * scale,
                               height: $0.size.height * scale) })
        #expect(placements.count == 2)
        let text = placements[1]
        #expect(text.rect == CGRect(x: 400 - WarningBadge.inset - WarningBadge.size, y: 120 + WarningBadge.inset,
                                    width: WarningBadge.size, height: WarningBadge.size))
        #expect(text.severity == .warning)
        #expect(text.tooltip == "Text se nevejde do rámečku, konec se nevytiskne")
        #expect(placements[0].severity == .error)
        #expect(placements[0].rect.maxX == 200 - WarningBadge.inset)
    }

    /// Final fix wave A8: the canvas cache drops the least recently shown photos, never the
    /// current page's.
    @Test func canvasCacheEvictsLeastRecentlyUsed() {
        let cached: Set<PhotoID> = ["a", "b", "c", "d", "e"]
        let used = ["a": 3, "b": 1, "c": 5, "d": 2, "e": 5]
        #expect(CanvasImageCache.evictionVictims(cached: cached, lastUsed: used, currentTick: 5, maxEntries: 3)
                == ["b", "d"])
        #expect(CanvasImageCache.evictionVictims(cached: cached, lastUsed: used, currentTick: 5, maxEntries: 5).isEmpty)
        // Never the current page, even when it alone is above the bound.
        #expect(CanvasImageCache.evictionVictims(cached: cached, lastUsed: used, currentTick: 5, maxEntries: 1)
                == ["b", "d", "a"])
        // Unknown use counts as oldest.
        #expect(CanvasImageCache.evictionVictims(cached: ["x", "y"], lastUsed: ["y": 1], currentTick: 2, maxEntries: 1)
                == ["x"])
    }

    @Test func badgeShowsTheWorstSeverityAndAllMessages() {
        let issues = [issue("a", frame: "photo1"), issue("b", frame: "photo1", .error)]
        #expect(WarningBadge.severity(issues) == .error)
        #expect(WarningBadge.severity([issue("a")]) == .warning)
        #expect(WarningBadge.tooltip(issues) == "a\nb")
    }
}

// MARK: - Strip

struct StripDropTests {
    /// Final fix wave A7: a drop without this strip's spread drag is refused (false); a readable
    /// payload naming the dragged spread moves it at once.
    @Test func dropDecision() {
        #expect(StripDrop.decision(draggingID: nil, payload: "leporelo-spread:a") == .reject)
        #expect(StripDrop.decision(draggingID: "a", payload: "leporelo-spread:a") == .move("a"))
        // Another payload may be a stale pasteboard: the item provider decides (checked async).
        #expect(StripDrop.decision(draggingID: "a", payload: "leporelo-spread:b") == .loadPayload("a"))
        #expect(StripDrop.decision(draggingID: "a", payload: "plain text") == .loadPayload("a"))
        #expect(StripDrop.decision(draggingID: "a", payload: nil) == .loadPayload("a"))
    }

    private let kinds: [SpreadKind] = [.intro, .journal, .gallery, .gallery, .closing]

    @Test func introAndClosingStayInPlace() {
        #expect(StripDrop.allowedGaps(kinds) == 1...4)
        #expect(!StripDrop.canDrag(index: 0, kinds: kinds))
        #expect(!StripDrop.canDrag(index: 4, kinds: kinds))
        #expect(StripDrop.canDrag(index: 2, kinds: kinds))
        #expect(StripDrop.allowedGaps([.journal, .gallery]) == 0...2)
        #expect(StripDrop.allowedGaps([.intro]) == 1...1)
    }

    @Test func gapIsBeforeOrAfterTheHoveredItem() {
        #expect(StripDrop.gap(hoverIndex: 2, trailingHalf: false) == 2)
        #expect(StripDrop.gap(hoverIndex: 2, trailingHalf: true) == 3)
    }

    @Test func moveIndexAccountsForTheRemovedItem() {
        // Move index 1 to the gap before index 3 (between the two galleries): ends at index 2.
        #expect(StripDrop.moveIndex(from: 1, gap: 3, kinds: kinds) == 2)
        // Move index 3 to the gap after the intro.
        #expect(StripDrop.moveIndex(from: 3, gap: 1, kinds: kinds) == 1)
        // Its own position (both neighbouring gaps): no move.
        #expect(StripDrop.moveIndex(from: 2, gap: 2, kinds: kinds) == nil)
        #expect(StripDrop.moveIndex(from: 2, gap: 3, kinds: kinds) == nil)
        // Before the intro or after the closing: refused.
        #expect(StripDrop.moveIndex(from: 2, gap: 0, kinds: kinds) == nil)
        #expect(StripDrop.moveIndex(from: 2, gap: 5, kinds: kinds) == nil)
        // The intro and the closing themselves never move.
        #expect(StripDrop.moveIndex(from: 0, gap: 3, kinds: kinds) == nil)
        #expect(StripDrop.moveIndex(from: 4, gap: 2, kinds: kinds) == nil)
        #expect(StripDrop.moveIndex(from: 1, gap: 4, kinds: kinds) == 3)
    }
}

struct SpreadThumbnailKeyTests {
    private func photo(_ id: String, analysed: Bool) -> Photo {
        Photo(id: id, sourceIdentifier: id, capturedAt: Date(timeIntervalSince1970: 0), timeZoneSeconds: 0,
              location: nil, pixelWidth: 400, pixelHeight: 300, kind: .photo,
              analysis: analysed ? PhotoAnalysis(aesthetic: 0.5, sharpness: 500, isUtility: false, faceRects: [],
                                                 closedEyes: false, featurePrint: nil) : nil,
              isSelected: true, dayKey: nil, placeName: nil, seriesID: nil, originalState: .missing,
              deletedInSource: false)
    }

    @Test func keyChangesWithContentGeometryAndThumbnails() throws {
        let g = try canvaGeometry()
        var s = TemplateLayout.instantiate(try #require(TemplateCatalog.template(id: "gallery-1")), geometry: g,
                                           dayKey: nil, id: "s")
        s.frames[0].photoID = "p"
        let pending = ["p": photo("p", analysed: false)]
        let ready = ["p": photo("p", analysed: true)]
        let key = SpreadThumbnailKey(spread: s, geometry: g, photos: pending, pixelsPerMM: 1)
        #expect(key == SpreadThumbnailKey(spread: s, geometry: g, photos: pending, pixelsPerMM: 1))
        // The thumbnail arrived: render again.
        #expect(key != SpreadThumbnailKey(spread: s, geometry: g, photos: ready, pixelsPerMM: 1))
        var edited = s
        edited.texts[0].text = "Ravello"
        #expect(key != SpreadThumbnailKey(spread: edited, geometry: g, photos: pending, pixelsPerMM: 1))
        #expect(key != SpreadThumbnailKey(spread: s, geometry: g, photos: pending, pixelsPerMM: 2))
        let (profile, square) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "square-21")
        #expect(key != SpreadThumbnailKey(spread: s, geometry: PageGeometry(format: square, profile: profile),
                                          photos: pending, pixelsPerMM: 1))
    }

    @Test func thumbnailScaleFillsTheStripHeight() {
        #expect(near(SpreadThumbnailKey.pixelsPerMM(height: 60, backingScale: 2, visibleHeightMM: 216),
                     120.0 / 216))
    }
}

// MARK: - Undo routing, window modes, texts, pasteboard

struct UndoRouterTests {
    @Test func editorWindowOrResponderChain() {
        #expect(UndoRouter.route(mode: .editor, hasEditor: true, hasUndoManager: true) == .editor)
        #expect(UndoRouter.route(mode: .editor, hasEditor: true, hasUndoManager: false) == .editor)
        #expect(UndoRouter.route(mode: .triage, hasEditor: true, hasUndoManager: true) == .window)
        #expect(UndoRouter.route(mode: .editor, hasEditor: false, hasUndoManager: true) == .window)
        #expect(UndoRouter.route(mode: .triage, hasEditor: false, hasUndoManager: false) == .responderChain)
        // No album window in front (e.g. the "Nové album" window's text field): its own undo.
        #expect(UndoRouter.route(mode: nil, hasEditor: false, hasUndoManager: false) == .responderChain)
    }

    /// Final fix wave A1: a sheet of the album window or a foreign text field keeps ⌘Z.
    @Test func sheetsAndForeignTextFieldsUseTheResponderChain() {
        let sheet = UndoFocus(keyWindowIsSheet: true, text: .none)
        let sheetField = UndoFocus(keyWindowIsSheet: true, text: .other)
        let field = UndoFocus(keyWindowIsSheet: false, text: .other)
        let overlay = UndoFocus(keyWindowIsSheet: false, text: .canvasOverlay)
        let plain = UndoFocus(keyWindowIsSheet: false, text: .none)
        for mode in [WindowMode.editor, .triage] {
            #expect(UndoRouter.route(mode: mode, hasEditor: true, hasUndoManager: true, focus: sheet) == .responderChain)
            #expect(UndoRouter.route(mode: mode, hasEditor: true, hasUndoManager: true, focus: sheetField) == .responderChain)
            #expect(UndoRouter.route(mode: mode, hasEditor: true, hasUndoManager: true, focus: field) == .responderChain)
        }
        // The canvas text overlay is the album's own text: the editor's undo.
        #expect(UndoRouter.route(mode: .editor, hasEditor: true, hasUndoManager: true, focus: overlay) == .editor)
        #expect(UndoRouter.route(mode: .editor, hasEditor: true, hasUndoManager: true, focus: plain) == .editor)
        #expect(UndoRouter.route(mode: .triage, hasEditor: true, hasUndoManager: true, focus: plain) == .window)
        // No key window: as before.
        #expect(UndoRouter.route(mode: .editor, hasEditor: true, hasUndoManager: true, focus: nil) == .editor)
        #expect(UndoRouter.route(mode: nil, hasEditor: false, hasUndoManager: false, focus: nil) == .responderChain)
    }

    @Test func menuTitlesNameTheAction() {
        #expect(UndoRouter.undoTitle("Upravit text") == "Odvolat: Upravit text")
        #expect(UndoRouter.undoTitle("") == "Odvolat")
        #expect(UndoRouter.redoTitle("Vložit fotku") == "Znovu: Vložit fotku")
        #expect(UndoRouter.redoTitle("") == "Znovu")
    }

    /// The items are never disabled (a stale disabled item would swallow ⌘Z; the model and the
    /// undo manager guard themselves). A session WITH changes names itself; an open but unchanged
    /// session names the step that ⌘Z will really undo.
    @Test func menuItemsPerRoute() {
        // Editor, a text session with changes.
        #expect(UndoRouter.undoItem(route: .editor, pendingAction: "Upravit text", undoActionName: "Vložit fotku")
                == UndoMenuItem(title: "Odvolat: Upravit text", isEnabled: true))
        #expect(UndoRouter.redoItem(route: .editor, pendingAction: "Upravit text", redoActionName: "Vložit fotku")
                == UndoMenuItem(title: "Znovu", isEnabled: true))
        // Editor, no changed session.
        #expect(UndoRouter.undoItem(route: .editor, pendingAction: nil, undoActionName: "Vložit fotku")
                == UndoMenuItem(title: "Odvolat: Vložit fotku", isEnabled: true))
        #expect(UndoRouter.redoItem(route: .editor, pendingAction: nil, redoActionName: "Prohodit fotky")
                == UndoMenuItem(title: "Znovu: Prohodit fotky", isEnabled: true))
        // Triage: the window's manager; a pending action is irrelevant there.
        #expect(UndoRouter.undoItem(route: .window, pendingAction: "Upravit text", undoActionName: "Vybrat fotku")
                == UndoMenuItem(title: "Odvolat: Vybrat fotku", isEnabled: true))
        #expect(UndoRouter.undoItem(route: .window, pendingAction: nil, undoActionName: "")
                == UndoMenuItem(title: "Odvolat", isEnabled: true))
        // No album window in front: plain titles, the responder chain decides.
        #expect(UndoRouter.undoItem(route: .responderChain, pendingAction: nil, undoActionName: "x")
                == UndoMenuItem(title: "Odvolat", isEnabled: true))
        #expect(UndoRouter.redoItem(route: .responderChain, pendingAction: nil, redoActionName: "x")
                == UndoMenuItem(title: "Znovu", isEnabled: true))
    }
}

struct WindowModeTests {
    @Test func startsInTheEditorWhenTheAlbumHasSpreads() {
        #expect(WindowModeLogic.resolve(requested: nil, hasSpreads: true) == .editor)
        #expect(WindowModeLogic.resolve(requested: nil, hasSpreads: false) == .triage)
        #expect(WindowModeLogic.resolve(requested: .triage, hasSpreads: true) == .triage)
        // The editor needs spreads (e.g. after undoing "Navrhnout album").
        #expect(WindowModeLogic.resolve(requested: .editor, hasSpreads: false) == .triage)
    }

    @Test func proposeOpensTheEditorOnceThereAreSpreads() {
        #expect(WindowModeLogic.afterPropose(hasSpreads: true) == .editor)
        #expect(WindowModeLogic.afterPropose(hasSpreads: false) == nil)
    }
}

struct EditorTextTests {
    @Test func czechCountsAgree() {
        #expect(EditorText.problems(1) == "1 problém")
        #expect(EditorText.problems(3) == "3 problémy")
        #expect(EditorText.problems(5) == "5 problémů")
        #expect(EditorText.issueBanner(2) == "2 problémy na této dvoustraně")
        #expect(EditorText.redraftMessage(1) == "Zachovám 1 ručně upravenou dvoustranu. Pokračovat?")
        #expect(EditorText.redraftMessage(3) == "Zachovám 3 ručně upravené dvoustrany. Pokračovat?")
        #expect(EditorText.redraftMessage(0) == "Žádná dvoustrana není ručně upravená, navrhnu znovu všechny. Pokračovat?")
        #expect(EditorText.redraftMessage(5) == "Zachovám 5 ručně upravených dvoustran. Pokračovat?")
        #expect(EditorText.photoCount(0) == "bez fotek")
        #expect(EditorText.photoCount(3) == "3 fotky")
    }

    @Test func stripAccessibilityLabel() {
        let day = DayKey(year: 2026, month: 6, day: 18)
        #expect(EditorText.stripLabel(index: 2, kind: .journal, day: day, issues: 2)
                == "Dvoustrana 3, Deník, čtvrtek 18. června 2026, 2 problémy")
        #expect(EditorText.stripLabel(index: 0, kind: .intro, day: nil, issues: 0) == "Dvoustrana 1, Úvod")
    }

    @Test func textLossNamesTheTexts() {
        let texts = [TextBox(id: "a", rect: Rect(x: 0, y: 0, width: 1, height: 1), role: .body, text: "Pláž\na moře"),
                     TextBox(id: "b", rect: Rect(x: 0, y: 0, width: 1, height: 1), role: .caption,
                             text: String(repeating: "x", count: 80))]
        let message = EditorText.textLoss(texts)
        #expect(message.hasPrefix("Tyto texty by se ztratily: „Pláž a moře“, „"))
        #expect(message.contains("…“"))
    }

    @Test func singleLineRolesEndOnReturn() {
        #expect(EditorText.isMultiline(.body))
        #expect(!EditorText.isMultiline(.caption))
        #expect(!EditorText.isMultiline(.date))
    }

    @Test func placeholderComesFromTheTemplate() {
        #expect(EditorText.placeholder(templateID: "journal-3", textID: "body") == "Co jsme dnes dělali")
        #expect(EditorText.placeholder(templateID: "nope", textID: "body") == nil)
    }

    @Test func placeholderOfAPageSpreadComesFromTheCatalogSlot() {
        #expect(EditorText.placeholder(templateID: PageSpread.templateID, textID: "L.caption") == "Popisek")
        #expect(EditorText.placeholder(templateID: PageSpread.templateID, textID: "R.date") == "Datum")
        #expect(EditorText.placeholder(templateID: PageSpread.templateID, textID: "L.body") == "Co jsme dnes dělali")
        #expect(EditorText.placeholder(templateID: PageSpread.templateID, textID: "text-1") == nil)
        #expect(EditorText.placeholder(templateID: PageSpread.templateID, textID: "caption") == nil)
    }

    @Test func pickerGroupsPageLayoutsByPhotoCountWithoutPhotosLast() {
        let groups = TemplatePicker.groups(PageLayoutCatalog.all.filter { $0.role != .empty })
        #expect(groups.map(\.count) == [1, 2, 3, 4, 5, 6, 0])
        #expect(groups[0].layouts.map(\.id) == ["full", "framed-1", "portrait-text", "opener-portrait"])
    }

    @Test func tryAnotherHelpAndGroupTexts() {
        #expect(EditorText.tryAnotherHelp(.noPage) == "Klikni na stránku")
        #expect(EditorText.tryAnotherHelp(.noAlternative) == "Pro tyhle fotky jiné rozložení není")
        #expect(EditorText.tryAnotherHelp(.available) == "Zkusit jinak")
        #expect(EditorText.pageLayoutGroup(1) == "1 fotka")
        #expect(EditorText.pageLayoutGroup(3) == "3 fotky")
        #expect(EditorText.pageLayoutGroup(5) == "5 fotek")
        #expect(EditorText.pageLayoutGroup(0) == "Bez fotek")
    }
}

@MainActor
struct PhotoPasteboardTests {
    @Test func customTypeAndPlainTextBothCarryThePhoto() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("leporelo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([PhotoPasteboard.item(for: "photo-7")])
        #expect(pasteboard.types?.contains(PhotoPasteboard.type) == true)
        #expect(PhotoPasteboard.photoID(from: pasteboard) == "photo-7")

        // Plain text from SwiftUI drags (the tray): same payload as the triage grid.
        pasteboard.clearContents()
        pasteboard.setString(PhotoDrag.payload(for: "photo-8"), forType: .string)
        #expect(PhotoPasteboard.photoID(from: pasteboard) == "photo-8")

        // Other text (or a spread from the strip) is not a photo.
        pasteboard.clearContents()
        pasteboard.setString(SpreadDrag.payload(for: "d1-journal"), forType: .string)
        #expect(PhotoPasteboard.photoID(from: pasteboard) == nil)
        #expect(SpreadDrag.spreadID(from: SpreadDrag.payload(for: "d1-journal")) == "d1-journal")
        #expect(SpreadDrag.spreadID(from: "hello") == nil)
    }
}
