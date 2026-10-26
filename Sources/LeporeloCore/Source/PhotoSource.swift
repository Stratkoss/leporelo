import CoreGraphics
import Foundation

/// A photo as reported by a source. `pixelWidth`/`pixelHeight` are the UPRIGHT dimensions
/// (EXIF orientation applied), matching the images the providers deliver.
public struct SourcePhoto: Sendable, Equatable {
    public var identifier: String
    public var capturedAt: Date
    public var timeZoneSeconds: Int?
    public var location: GeoPoint?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var kind: PhotoKind
    public var isCloudOnly: Bool

    public init(identifier: String, capturedAt: Date, timeZoneSeconds: Int?, location: GeoPoint?,
                pixelWidth: Int, pixelHeight: Int, kind: PhotoKind, isCloudOnly: Bool) {
        self.identifier = identifier
        self.capturedAt = capturedAt
        self.timeZoneSeconds = timeZoneSeconds
        self.location = location
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.isCloudOnly = isCloudOnly
    }
}

public struct SourceAlbum: Sendable, Equatable {
    public var identifier: String
    public var name: String
    public var count: Int
    public var isShared: Bool

    public init(identifier: String, name: String, count: Int, isShared: Bool) {
        self.identifier = identifier
        self.name = name
        self.count = count
        self.isShared = isShared
    }
}

public enum PhotoSourceError: Error, Equatable {
    case notAuthorized
    case notFound(String)
    case cloudUnavailable(String)
}

public protocol PhotoSource: Sendable {
    func albums() async throws -> [SourceAlbum]
    func photos(matching: SourceQuery) async throws -> [SourcePhoto]
    /// Upright image, longest side <= maxPixel, never upscaled.
    func thumbnail(for identifier: String, maxPixel: Int) async throws -> CGImage
    /// Original file bytes as-is plus the lowercased file extension.
    func original(for identifier: String) async throws -> (data: Data, ext: String)
}

public extension Photo {
    init(source: SourcePhoto) {
        self.init(id: UUID().uuidString, sourceIdentifier: source.identifier,
                  capturedAt: source.capturedAt, timeZoneSeconds: source.timeZoneSeconds,
                  location: source.location, pixelWidth: source.pixelWidth,
                  pixelHeight: source.pixelHeight, kind: source.kind, analysis: nil,
                  isSelected: false, dayKey: nil, placeName: nil, seriesID: nil,
                  originalState: .missing, deletedInSource: false)
    }
}
