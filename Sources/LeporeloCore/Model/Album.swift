import Foundation

public enum SourceQuery: Sendable, Codable, Equatable {
    case dateRange(start: Date, end: Date)
    case album(identifier: String, name: String)
}

public struct Album: Sendable, Codable, Equatable {
    public static let currentFormatVersion = 1
    /// The page margin (mm) a new or older album gets.
    public static let defaultMarginMM = 6.0

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
    /// Distance (mm) the layout keeps from every page edge (see `MarginRule`).
    public var marginMM: Double

    public init(formatVersion: Int, id: String, title: String, supplierProfileID: String,
                formatID: String, world: String, cover: Cover?, spreads: [Spread],
                photos: [PhotoID: Photo], source: SourceQuery?, createdAt: Date,
                marginMM: Double = Album.defaultMarginMM) {
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
        self.marginMM = marginMM
    }

    /// Albums written before `marginMM` existed decode with `defaultMarginMM`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        supplierProfileID = try c.decode(String.self, forKey: .supplierProfileID)
        formatID = try c.decode(String.self, forKey: .formatID)
        world = try c.decode(String.self, forKey: .world)
        cover = try c.decodeIfPresent(Cover.self, forKey: .cover)
        spreads = try c.decode([Spread].self, forKey: .spreads)
        photos = try c.decode([PhotoID: Photo].self, forKey: .photos)
        source = try c.decodeIfPresent(SourceQuery.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        marginMM = try c.decodeIfPresent(Double.self, forKey: .marginMM) ?? Album.defaultMarginMM
    }

    /// The photos the product shows and counts: everything except videos. An album created by an
    /// earlier version may still hold videos in its stored `photos`; they are never deleted from
    /// the file, but no list, count, recommendation, draft or export uses them.
    public var visiblePhotos: [Photo] {
        photos.values.filter(\.isUsable)
    }

    /// Photos grouped by `dayKey` (videos and photos without one are skipped), sorted by `capturedAt` within a day
    /// (ties broken by id).
    public func photosByDay() -> [DayKey: [Photo]] {
        var result: [DayKey: [Photo]] = [:]
        for photo in photos.values where photo.isUsable {
            guard let key = photo.dayKey else { continue }
            result[key, default: []].append(photo)
        }
        return result.mapValues { $0.sorted(by: Photo.chronological) }
    }

    /// Selected photos (never videos), chronological (ties broken by id).
    public var selectedPhotos: [Photo] {
        photos.values.filter { $0.isUsable && $0.isSelected }.sorted(by: Photo.chronological)
    }

    /// Ids of the photos in any frame of the spreads or the cover (front and back).
    public var placedPhotoIDs: Set<PhotoID> {
        var ids = Set<PhotoID>()
        for spread in spreads + [cover?.front, cover?.back].compactMap({ $0 }) {
            for frame in spread.frames { if let id = frame.photoID { ids.insert(id) } }
        }
        return ids
    }

    /// Selected photos (not videos) that sit in no frame of the spreads or the cover,
    /// chronological. Deleting a spread, a template with fewer frames or a drop that replaces a
    /// photo leaves them; they would silently be missing from the print (Preflight warns).
    public var unplacedSelectedPhotos: [Photo] {
        let placed = placedPhotoIDs
        return selectedPhotos.filter { $0.kind != .video && !placed.contains($0.id) }
    }
}

extension Photo {
    /// False for videos: the product has none (see `Album.visiblePhotos`).
    public var isUsable: Bool { kind != .video }

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
