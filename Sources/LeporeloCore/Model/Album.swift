import Foundation

public enum SourceQuery: Sendable, Codable, Equatable {
    case dateRange(start: Date, end: Date)
    case album(identifier: String, name: String)
}

public struct Album: Sendable, Codable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    public var title: String
    public var supplierProfileID: String
    public var formatID: String
    /// e.g. "journal-gallery"
    public var world: String
    public var cover: Cover?
    public var spreads: [Spread]
    public var photos: [PhotoID: Photo]
    public var source: SourceQuery?
    public var createdAt: Date

    public init(formatVersion: Int, id: String, title: String, supplierProfileID: String,
                formatID: String, world: String, cover: Cover?, spreads: [Spread],
                photos: [PhotoID: Photo], source: SourceQuery?, createdAt: Date) {
        self.formatVersion = formatVersion
        self.id = id
        self.title = title
        self.supplierProfileID = supplierProfileID
        self.formatID = formatID
        self.world = world
        self.cover = cover
        self.spreads = spreads
        self.photos = photos
        self.source = source
        self.createdAt = createdAt
    }

    /// Photos grouped by `dayKey` (photos without one are skipped), sorted by `capturedAt` within a day
    /// (ties broken by id).
    public func photosByDay() -> [DayKey: [Photo]] {
        var result: [DayKey: [Photo]] = [:]
        for photo in photos.values {
            guard let key = photo.dayKey else { continue }
            result[key, default: []].append(photo)
        }
        return result.mapValues { $0.sorted(by: Photo.chronological) }
    }

    /// Selected photos, chronological (ties broken by id).
    public var selectedPhotos: [Photo] {
        photos.values.filter(\.isSelected).sorted(by: Photo.chronological)
    }
}

extension Photo {
    /// Deterministic chronological order: `capturedAt`, then `id`.
    public static func chronological(_ a: Photo, _ b: Photo) -> Bool {
        (a.capturedAt, a.id) < (b.capturedAt, b.id)
    }
}
