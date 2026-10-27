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
    /// `true` once the user selected or deselected the photo themselves. Recommendations
    /// (`Workflow.recommendAndDraft`) only change `isSelected` of undecided photos.
    /// Missing in album files written before it existed; decodes as `false`.
    public var selectionDecidedByUser: Bool
    public var dayKey: DayKey?
    public var placeName: String?
    public var seriesID: String?
    public var originalState: OriginalState
    public var deletedInSource: Bool

    public init(id: PhotoID, sourceIdentifier: String, capturedAt: Date, timeZoneSeconds: Int?,
                location: GeoPoint?, pixelWidth: Int, pixelHeight: Int, kind: PhotoKind,
                analysis: PhotoAnalysis?, isSelected: Bool, selectionDecidedByUser: Bool = false,
                dayKey: DayKey?, placeName: String?,
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
        self.selectionDecidedByUser = selectionDecidedByUser
        self.dayKey = dayKey
        self.placeName = placeName
        self.seriesID = seriesID
        self.originalState = originalState
        self.deletedInSource = deletedInSource
    }

    public var isLandscape: Bool { pixelWidth > pixelHeight }

    /// Synthesized decoding, except that `selectionDecidedByUser` may be missing (older files).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PhotoID.self, forKey: .id)
        sourceIdentifier = try c.decode(String.self, forKey: .sourceIdentifier)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        timeZoneSeconds = try c.decodeIfPresent(Int.self, forKey: .timeZoneSeconds)
        location = try c.decodeIfPresent(GeoPoint.self, forKey: .location)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        kind = try c.decode(PhotoKind.self, forKey: .kind)
        analysis = try c.decodeIfPresent(PhotoAnalysis.self, forKey: .analysis)
        isSelected = try c.decode(Bool.self, forKey: .isSelected)
        selectionDecidedByUser = try c.decodeIfPresent(Bool.self, forKey: .selectionDecidedByUser) ?? false
        dayKey = try c.decodeIfPresent(DayKey.self, forKey: .dayKey)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
        seriesID = try c.decodeIfPresent(String.self, forKey: .seriesID)
        originalState = try c.decode(OriginalState.self, forKey: .originalState)
        deletedInSource = try c.decode(Bool.self, forKey: .deletedInSource)
    }
}
