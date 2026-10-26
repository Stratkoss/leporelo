import Foundation

public struct Series: Sendable, Equatable {
    public var id: String
    public var photoIDs: [PhotoID]

    public init(id: String, photoIDs: [PhotoID]) {
        self.id = id
        self.photoIDs = photoIDs
    }
}

public enum SeriesDetector {
    public static let maxGap: TimeInterval = 60
    public static let maxGapWithoutFeaturePrint: TimeInterval = 3
    public static let maxDistance: Float = 0.5

    /// Input may be unsorted. Returns only series of 2+ photos, in chronological order.
    /// Series id is `"series-" + id of the first photo`; apply it to photos with `apply`.
    public static func detect(_ photos: [Photo], distance: (Data, Data) -> Float) -> [Series] {
        let sorted = photos.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
        var result: [Series] = []
        var current: [Photo] = []
        func flush() {
            if current.count >= 2 {
                result.append(Series(id: "series-" + current[0].id, photoIDs: current.map(\.id)))
            }
            current = []
        }
        for photo in sorted {
            if let last = current.last, similar(last, photo, distance) {
                current.append(photo)
            } else {
                flush()
                current = [photo]
            }
        }
        flush()
        return result
    }

    /// Returns `photos` with `seriesID` set for members (and cleared for non-members).
    public static func apply(_ series: [Series], to photos: [Photo]) -> [Photo] {
        var map: [PhotoID: String] = [:]
        for s in series { for id in s.photoIDs { map[id] = s.id } }
        return photos.map { var p = $0; p.seriesID = map[p.id]; return p }
    }

    private static func similar(_ a: Photo, _ b: Photo, _ distance: (Data, Data) -> Float) -> Bool {
        let gap = b.capturedAt.timeIntervalSince(a.capturedAt)
        let fa = a.analysis?.featurePrint, fb = b.analysis?.featurePrint
        switch (fa, fb) {
        case let (x?, y?): return gap <= maxGap && distance(x, y) < maxDistance
        case (nil, nil): return gap <= maxGapWithoutFeaturePrint
        default: return false
        }
    }
}
