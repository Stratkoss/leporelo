import Foundation

/// Cover-fit of a photo into a frame. All rects share one coordinate space (millimetres in practice).
public enum FrameFit {
    private static func effectiveZoom(_ zoom: Double) -> Double {
        zoom.isFinite ? max(zoom, 1) : 1
    }

    /// Image size after cover-fit and zoom: scale = max(frameW / imageW, frameH / imageH) * zoom.
    private static func coverSize(imageSize: Size, frame: Rect, zoom: Double) -> Size {
        guard imageSize.width > 0, imageSize.height > 0 else { return frame.size }
        let s = max(frame.size.width / imageSize.width, frame.size.height / imageSize.height)
            * effectiveZoom(zoom)
        return Size(width: imageSize.width * s, height: imageSize.height * s)
    }

    /// The image rectangle placed in the frame. It always covers the frame: the offset is
    /// clamped to -1...1 and the origin is clamped so no edge of the frame can be left uncovered.
    /// Offset 0 centres the image, +1 aligns the image's left/top edge with the frame's,
    /// -1 aligns its right/bottom edge.
    public static func imageRect(imageSize: Size, in frame: Rect, offset: Point, zoom: Double) -> Rect {
        let size = coverSize(imageSize: imageSize, frame: frame, zoom: zoom)
        let o = clampedOffset(offset, imageSize: imageSize, frame: frame, zoom: zoom)
        let slackX = max(size.width - frame.size.width, 0)
        let slackY = max(size.height - frame.size.height, 0)
        var x = frame.minX - slackX / 2 + o.x * slackX / 2
        var y = frame.minY - slackY / 2 + o.y * slackY / 2
        // Guard against rounding: keep the image covering the frame exactly.
        x = min(frame.minX, max(x, frame.maxX - size.width))
        y = min(frame.minY, max(y, frame.maxY - size.height))
        return Rect(origin: Point(x: x, y: y), size: size)
    }

    /// Offset limited to -1...1 per axis (non-finite values become 0). Because `imageRect` maps
    /// the offset range onto the available slack, any clamped offset keeps the frame covered.
    public static func clampedOffset(_ offset: Point, imageSize: Size, frame: Rect, zoom: Double) -> Point {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, -1), 1) : 0 }
        return Point(x: clamp(offset.x), y: clamp(offset.y))
    }

    /// Effective resolution of the photo in the frame, in pixels per inch (frame in mm).
    ///
    /// The photo is cover-fitted, so the limiting axis decides: the image is scaled by
    /// `s = max(frameW / pixelW, frameH / pixelH) * zoom` mm per pixel, and
    /// `DPI = 25.4 / s`. For a frame that is limited by width this equals
    /// `pixelWidth / (frameWidth in inches / zoom)`.
    public static func effectiveDPI(pixelWidth: Int, pixelHeight: Int, frame: Rect, zoom: Double) -> Double {
        guard pixelWidth > 0, pixelHeight > 0, frame.size.width > 0, frame.size.height > 0 else { return 0 }
        let s = max(frame.size.width / Double(pixelWidth), frame.size.height / Double(pixelHeight))
            * effectiveZoom(zoom)
        return 25.4 / s
    }
}
