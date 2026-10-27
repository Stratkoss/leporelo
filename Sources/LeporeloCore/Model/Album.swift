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

extension Album {
    /// This album (a user-step snapshot an undo or redo restores) with the background-owned photo
    /// fields taken from `current`, the album as it is now.
    ///
    /// Background work (analysis, place names, series marking, originals, source refresh) writes
    /// `analysis`, `placeName`, `seriesID`, `originalState` and `deletedInSource` without undo; an
    /// undo of a whole-album step must not revert them. So for photos in both albums those five
    /// fields come from `current` and everything else (selection, day, spreads, cover, title, ...)
    /// from `self`. Photos only in `self` keep their stored values; photos only in `current`
    /// (added by a refresh after the snapshot) are kept as they are, because dropping them on undo
    /// would lose data.
    public func keepingBackgroundFields(of current: Album) -> Album {
        var result = self
        for (id, now) in current.photos {
            guard var photo = result.photos[id] else {
                result.photos[id] = now
                continue
            }
            photo.analysis = now.analysis
            photo.placeName = now.placeName
            photo.seriesID = now.seriesID
            photo.originalState = now.originalState
            photo.deletedInSource = now.deletedInSource
            result.photos[id] = photo
        }
        return result
    }
}
