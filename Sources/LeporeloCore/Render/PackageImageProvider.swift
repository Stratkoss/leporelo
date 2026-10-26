import CoreGraphics
import Foundation
import ImageIO

/// Serves photo pixels from a `.leporelo` package, honouring the `ImageProvider` contract
/// (upright, aspect of `Photo.pixelWidth/pixelHeight`, never upscaled).
///
/// - `minPixelWidth <= 1024`: the stored thumbnail (nil when there is none).
/// - larger: the original decoded with ImageIO (EXIF orientation applied, `shouldCache` off),
///   scaled down only as far as `minPixelWidth` requires. If the original is missing or
///   unreadable it falls back to the thumbnail: better a low-res image than a crash.
///   Preflight, not this provider, is what blocks exports with missing originals.
///
/// It snapshots the `Album` at init: rebuild it when originals change (Task 17).
public struct PackageImageProvider: ImageProvider {
    private let package: ProjectPackage
    private let album: Album

    public init(package: ProjectPackage, album: Album) {
        self.package = package
        self.album = album
    }

    public func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? {
        if minPixelWidth <= ProjectPackage.thumbnailMaxPixelSize {
            return package.thumbnail(for: photoID)
        }
        if let url = package.originalURL(for: photoID, album: album),
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = Self.decode(source, minPixelWidth: minPixelWidth) {
            return image
        }
        return package.thumbnail(for: photoID)
    }

    private static func decode(_ source: CGImageSource, minPixelWidth: Int) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let uprightWidth = orientation >= 5 ? h : w  // orientations 5...8 swap the axes
        let longSide = max(w, h)
        let needed: Int
        if minPixelWidth >= uprightWidth {
            needed = longSide
        } else {
            needed = Int((Double(minPixelWidth) * Double(longSide) / Double(uprightWidth)).rounded(.up)) + 1
        }
        return ProjectPackage.decodeUpright(source, maxLongSide: needed)
    }
}
