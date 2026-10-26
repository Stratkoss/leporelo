import Foundation

public typealias PhotoID = String

public struct DayKey: Sendable, Codable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public struct GeoPoint: Sendable, Codable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum PhotoKind: String, Sendable, Codable, Equatable {
    case photo, livePhoto, video
}

public struct PhotoAnalysis: Sendable, Codable, Equatable {
    public var aesthetic: Double
    public var sharpness: Double
    public var isUtility: Bool
    /// Normalised 0..1 rects.
    public var faceRects: [Rect]
    public var closedEyes: Bool
    public var featurePrint: Data?

    public init(aesthetic: Double, sharpness: Double, isUtility: Bool, faceRects: [Rect],
                closedEyes: Bool, featurePrint: Data?) {
        self.aesthetic = aesthetic
        self.sharpness = sharpness
        self.isUtility = isUtility
        self.faceRects = faceRects
        self.closedEyes = closedEyes
        self.featurePrint = featurePrint
    }
}

public enum OriginalState: Sendable, Codable, Equatable {
    case missing
    case downloading
    case stored(relativePath: String)
    case unavailable
}

public struct Photo: Sendable, Codable, Equatable {
    public var id: PhotoID
    public var sourceIdentifier: String
    public var capturedAt: Date
    public var timeZoneSeconds: Int?
    public var location: GeoPoint?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var kind: PhotoKind
    public var analysis: PhotoAnalysis?
    public var isSelected: Bool
    public var dayKey: DayKey?
    public var placeName: String?
    public var seriesID: String?
    public var originalState: OriginalState
    public var deletedInSource: Bool

    public init(id: PhotoID, sourceIdentifier: String, capturedAt: Date, timeZoneSeconds: Int?,
                location: GeoPoint?, pixelWidth: Int, pixelHeight: Int, kind: PhotoKind,
                analysis: PhotoAnalysis?, isSelected: Bool, dayKey: DayKey?, placeName: String?,
                seriesID: String?, originalState: OriginalState, deletedInSource: Bool) {
        self.id = id
        self.sourceIdentifier = sourceIdentifier
        self.capturedAt = capturedAt
        self.timeZoneSeconds = timeZoneSeconds
        self.location = location
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.analysis = analysis
        self.isSelected = isSelected
        self.dayKey = dayKey
        self.placeName = placeName
        self.seriesID = seriesID
        self.originalState = originalState
        self.deletedInSource = deletedInSource
    }

    public var isLandscape: Bool { pixelWidth > pixelHeight }
}
