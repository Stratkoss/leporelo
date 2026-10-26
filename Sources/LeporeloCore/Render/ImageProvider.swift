import CoreGraphics
import Foundation

public protocol ImageProvider: Sendable {
    /// An image of at least `minPixelWidth` pixels across when available. `nil` means "no image".
    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage?
}

/// Returns no image: frames render as empty grey boxes.
public struct PlaceholderImageProvider: ImageProvider {
    public init() {}

    public func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? { nil }
}
