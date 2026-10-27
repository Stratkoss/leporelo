import Foundation

public enum TimeZoneInference {
    /// Neighbour photos further away than this (in seconds) do not lend their zone.
    static let maxNeighbourDistance: TimeInterval = 12 * 3600

    public static func secondsFromGMT(forLongitude lon: Double) -> Int {
        Int((lon / 15).rounded()) * 3600
    }

    /// Priority per photo: own `timeZoneSeconds`, zone of its resolved place, zone of the nearest
    /// photo in time (within 12 h) that has a known zone or GPS, zone from own longitude (GPS only),
    /// finally `TimeZone.current`.
    public static func resolveTimeZones(_ photos: [Photo], places: [PhotoID: Place]) -> [PhotoID: Int] {
        var result: [PhotoID: Int] = [:]

        // Pass 1: definite zones (recorded offset or place time zone).
        for photo in photos {
            if let own = photo.timeZoneSeconds {
                result[photo.id] = own
            } else if let identifier = places[photo.id]?.timeZoneIdentifier,
                      let zone = TimeZone(identifier: identifier) {
                result[photo.id] = zone.secondsFromGMT(for: photo.capturedAt)
            }
        }
        let definite = TimeIndex(photos.filter { result[$0.id] != nil })

        // Pass 2: photos with GPS but no definite zone: nearest definite neighbour, else longitude.
        for photo in photos where result[photo.id] == nil {
            guard let location = photo.location else { continue }
            if let neighbour = definite.nearest(to: photo) {
                result[photo.id] = result[neighbour.id]
            } else {
                // Coarse by design: Italy (15°E zone is +1 h) comes out as +1 h even in summer (+2 h).
                result[photo.id] = secondsFromGMT(forLongitude: location.longitude)
            }
        }

        // Pass 3: photos without GPS: nearest photo that has a zone by now, else the Mac's zone.
        let known = TimeIndex(photos.filter { result[$0.id] != nil })
        for photo in photos where result[photo.id] == nil {
            if let neighbour = known.nearest(to: photo) {
                result[photo.id] = result[neighbour.id]
            } else {
                result[photo.id] = TimeZone.current.secondsFromGMT(for: photo.capturedAt)
            }
        }
        return result
    }

    /// Candidates sorted by capture time once, so each nearest-neighbour query is a binary search
    /// plus a short walk outwards (was a scan of every candidate per photo: quadratic).
    struct TimeIndex {
        private let photos: [Photo]
        private let times: [TimeInterval]

        init(_ candidates: [Photo]) {
            photos = candidates.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
            times = photos.map(\.capturedAt.timeIntervalSinceReferenceDate)
        }

        /// The candidate nearest in time to `photo` (not `photo` itself, by id) within
        /// `maxNeighbourDistance`; ties: the smaller id.
        func nearest(to photo: Photo) -> Photo? {
            let t = photo.capturedAt.timeIntervalSinceReferenceDate
            // First index with time >= t.
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < t { low = mid + 1 } else { high = mid }
            }
            var best: (distance: TimeInterval, photo: Photo)?
            func consider(_ i: Int) -> Bool {
                let distance = abs(times[i] - t)
                if distance > maxNeighbourDistance { return false }
                if let best, distance > best.distance { return false }
                let candidate = photos[i]
                if candidate.id != photo.id,
                   best.map({ (distance, candidate.id) < ($0.distance, $0.photo.id) }) ?? true {
                    best = (distance, candidate)
                }
                return true
            }
            var i = low
            while i < times.count, consider(i) { i += 1 }
            var j = low - 1
            while j >= 0, consider(j) { j -= 1 }
            return best?.photo
        }
    }
}
