import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LeporeloCore

/// Writes JPEG files with EXIF / GPS metadata through ImageIO.
enum JPEGFixtures {
    /// `offset` like "+02:00"; `date` is formatted as naive local time in that offset
    /// (UTC when `offset` is nil). `date == nil` writes no EXIF date. `orientation` is the EXIF tag.
    /// `scene == nil` draws a scaled checkerboard; otherwise `ImageFixtures.scene(seed:)` (large,
    /// cheap to encode, sharp enough not to count as defective). `rawDate` writes that exact EXIF
    /// `DateTimeOriginal` text (for invalid dates).
    static func write(to url: URL, size: (Int, Int) = (64, 48), date: Date? = nil,
                      offset: String? = nil, gps: GeoPoint? = nil, orientation: Int? = nil,
                      scene: Int? = nil, rawDate: String? = nil) throws {
        let cg: CGImage
        if let scene {
            cg = ImageFixtures.scene(seed: scene, width: size.0, height: size.1)
        } else {
            let image = ImageFixtures.checkerboard(size: 8)
            let ctx = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8,
                                bytesPerRow: 0, space: ImageFixtures.colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
            cg = ctx.makeImage()!
        }

        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if let date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = TimeZone(secondsFromGMT: offset.map(parseOffset) ?? 0)
            var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: date)]
            if let offset { exif["OffsetTimeOriginal" as CFString] = offset }
            props[kCGImagePropertyExifDictionary] = exif
        }
        if let rawDate {
            var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: rawDate]
            if let offset { exif["OffsetTimeOriginal" as CFString] = offset }
            props[kCGImagePropertyExifDictionary] = exif
        }
        if let gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(gps.latitude),
                kCGImagePropertyGPSLatitudeRef: gps.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(gps.longitude),
                kCGImagePropertyGPSLongitudeRef: gps.longitude < 0 ? "W" : "E",
            ] as [CFString: Any]
        }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func parseOffset(_ s: String) -> Int {
        let sign = s.hasPrefix("-") ? -1 : 1
        let parts = s.dropFirst().split(separator: ":").compactMap { Int($0) }
        return sign * ((parts.first ?? 0) * 3600 + (parts.count > 1 ? parts[1] * 60 : 0))
    }
}
