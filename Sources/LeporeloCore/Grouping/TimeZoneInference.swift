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
        let definite = photos.filter { result[$0.id] != nil }

        // Pass 2: photos with GPS but no definite zone: nearest definite neighbour, else longitude.
        for photo in photos where result[photo.id] == nil {
            guard let location = photo.location else { continue }
            if let neighbour = nearest(to: photo, in: definite) {
                result[photo.id] = result[neighbour.id]
            } else {
                result[photo.id] = secondsFromGMT(forLongitude: location.longitude)
            }
        }

        // Pass 3: photos without GPS: nearest photo that has a zone by now, else the Mac's zone.
        let known = photos.filter { result[$0.id] != nil }
        for photo in photos where result[photo.id] == nil {
            if let neighbour = nearest(to: photo, in: known) {
                result[photo.id] = result[neighbour.id]
            } else {
                result[photo.id] = TimeZone.current.secondsFromGMT(for: photo.capturedAt)
            }
        }
        return result
    }

    private static func nearest(to photo: Photo, in candidates: [Photo]) -> Photo? {
        candidates
            .filter { $0.id != photo.id }
            .map { ($0, abs($0.capturedAt.timeIntervalSince(photo.capturedAt))) }
            .filter { $0.1 <= maxNeighbourDistance }
            .min { ($0.1, $0.0.id) < ($1.1, $1.0.id) }?.0
    }
}
