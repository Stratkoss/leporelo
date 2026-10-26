import CoreGraphics
import Foundation

/// Supplies photo pixels to the renderer and the exporter.
///
/// Contract for every implementation (Task 13's `PackageImageProvider` must follow it):
/// - The returned image is UPRIGHT: the EXIF / Photos orientation is already applied, so it is
///   drawn as is.
/// - Its aspect ratio matches `Photo.pixelWidth / Photo.pixelHeight` (both in upright
///   orientation), because the layout, `FrameFit` and `Preflight` compute with those sizes.
/// - It is at least `minPixelWidth` pixels wide where the source allows it (a smaller source
///   is returned as is, never upscaled). The renderer computes the hint from the photo's drawn
///   width at the requested DPI; the export asks for the full original.
public protocol ImageProvider: Sendable {
    /// An image of at least `minPixelWidth` pixels across when available. `nil` means "no image".
    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage?
}

/// Returns no image: frames render as empty grey boxes.
public struct PlaceholderImageProvider: ImageProvider {
    public init() {}

    public func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? { nil }
}
