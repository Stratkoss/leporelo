import Foundation

public struct DayGroup: Sendable, Equatable {
    public var dayKey: DayKey
    /// Chronological (ties broken by id).
    public var photos: [Photo]
    /// Unique, in order of first occurrence.
    public var placeNames: [String]
    public var timeZoneSeconds: Int

    public init(dayKey: DayKey, photos: [Photo], placeNames: [String], timeZoneSeconds: Int) {
        self.dayKey = dayKey
        self.photos = photos
        self.placeNames = placeNames
        self.timeZoneSeconds = timeZoneSeconds
    }
}

public enum DayGrouper {
    /// Calendar day of `date` as seen in a zone with the given offset (not UTC, not the Mac's zone).
    public static func dayKey(for date: Date, secondsFromGMT: Int) -> DayKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT) ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return DayKey(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Days ascending. A `dayKey` already set on a photo wins over the computed one.
    public static func group(_ photos: [Photo], timeZones: [PhotoID: Int], places: [PhotoID: Place]) -> [DayGroup] {
        let sorted = photos.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
        var byDay: [DayKey: [Photo]] = [:]
        for photo in sorted {
            byDay[dayOf(photo, timeZones), default: []].append(photo)
        }
        return byDay.keys.sorted().map { key in
            let members = byDay[key]!
            var names: [String] = []
            for photo in members {
                if let name = places[photo.id]?.name ?? photo.placeName, !names.contains(name) {
                    names.append(name)
                }
            }
            return DayGroup(dayKey: key, photos: members, placeNames: names,
                            timeZoneSeconds: zone(of: members[0], timeZones))
        }
    }

    private static func zone(of photo: Photo, _ timeZones: [PhotoID: Int]) -> Int {
        timeZones[photo.id] ?? photo.timeZoneSeconds ?? TimeZone.current.secondsFromGMT(for: photo.capturedAt)
    }

    private static func dayOf(_ photo: Photo, _ timeZones: [PhotoID: Int]) -> DayKey {
        photo.dayKey ?? dayKey(for: photo.capturedAt, secondsFromGMT: zone(of: photo, timeZones))
    }
}

public enum GroupingService {
    /// Resolves places for photos with GPS (one lookup per `PlaceKey`), infers zones, then fills
    /// `dayKey` and `placeName` where they are still `nil`.
    public static func assignDays(to album: inout Album, resolver: PlaceResolver) async {
        let photos = album.photos.values.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }

        var resolved: [PlaceKey: Place] = [:]
        var places: [PhotoID: Place] = [:]
        for photo in photos {
            guard let location = photo.location else { continue }
            let key = PlaceKey(location)
            if resolved[key] == nil, let place = await resolver.place(for: location) {
                resolved[key] = place
            }
            if let place = resolved[key] { places[photo.id] = place }
        }

        let zones = TimeZoneInference.resolveTimeZones(photos, places: places)
        for photo in photos {
            guard var updated = album.photos[photo.id] else { continue }
            if updated.dayKey == nil {
                updated.dayKey = DayGrouper.dayKey(
                    for: photo.capturedAt,
                    secondsFromGMT: zones[photo.id] ?? TimeZone.current.secondsFromGMT(for: photo.capturedAt))
            }
            if updated.placeName == nil, let name = places[photo.id]?.name {
                updated.placeName = name
            }
            album.photos[photo.id] = updated
        }
    }
}
