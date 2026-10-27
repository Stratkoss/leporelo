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
        let photos = chronological(album)
        let places = await resolvePlaces(of: photos, resolver: resolver, stopOnCancel: false).places

        let zones = TimeZoneInference.resolveTimeZones(photos, places: places)
        for photo in photos {
            guard var updated = album.photos[photo.id] else { continue }
            if updated.dayKey == nil {
                updated.dayKey = autoDay(of: photo, zones: zones)
            }
            if updated.placeName == nil, let name = places[photo.id]?.name {
                updated.placeName = name
            }
            album.photos[photo.id] = updated
        }
    }

    /// The background pass after a fast `assignDays` with an empty resolver (spec: geocoding never
    /// blocks the UI). Resolves places for the photos with GPS through `resolver` and:
    ///
    /// 1. sets `placeName` where it is still `nil` (a name set earlier is never overwritten);
    /// 2. corrects auto-assigned days: for every photo with a `dayKey`, if it still equals the day
    ///    computed WITHOUT places (zones from EXIF, neighbours, longitude: what the fast pass
    ///    assigned), it becomes the day computed WITH the resolved places (place time zones, e.g.
    ///    Europe/Rome +2 h in summer where the longitude said +1 h). A `dayKey` that differs from
    ///    that auto day was set by the user or another route and is left alone; photos without a
    ///    `dayKey` are left to `assignDays`. Days are always local to the place (Review Focus 1),
    ///    never UTC or the Mac's zone (except as the last fallback of `TimeZoneInference`).
    ///
    /// Lookups as in `assignDays`: each `PlaceKey` is requested at most once per call and failed
    /// lookups are not retried within the call.
    ///
    /// Cancellation: checked before every resolver call. When the task is cancelled the lookups stop,
    /// the names found so far are applied, and days are NOT re-derived (a partial set of zones could
    /// move photos half-way); `completed` is then `false`. The album stays consistent, and running
    /// this again later still corrects the days, as they are untouched.
    ///
    /// Pure album in / album out: the caller applies the result to its store through the no-undo
    /// APIs (Task 17 contract), since this is not a user edit.
    @discardableResult
    public static func refinePlaces(in album: inout Album, resolver: PlaceResolver) async -> PlaceRefinement {
        let photos = chronological(album)
        let (places, completed) = await resolvePlaces(of: photos, resolver: resolver, stopOnCancel: true)

        var named = 0
        for (id, place) in places where album.photos[id]?.placeName == nil {
            album.photos[id]?.placeName = place.name
            named += 1
        }
        guard completed else {
            return PlaceRefinement(changedDays: 0, namedPhotos: named, completed: false)
        }

        let oldZones = TimeZoneInference.resolveTimeZones(photos, places: [:])
        let newZones = TimeZoneInference.resolveTimeZones(photos, places: places)
        var changed = 0
        for photo in photos {
            guard let current = album.photos[photo.id]?.dayKey,
                  current == autoDay(of: photo, zones: oldZones) else { continue }
            let refined = autoDay(of: photo, zones: newZones)
            if refined != current {
                album.photos[photo.id]?.dayKey = refined
                changed += 1
            }
        }
        return PlaceRefinement(changedDays: changed, namedPhotos: named, completed: true)
    }

    private static func chronological(_ album: Album) -> [Photo] {
        album.photos.values.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
    }

    /// The day `assignDays` would give `photo` with these zones.
    private static func autoDay(of photo: Photo, zones: [PhotoID: Int]) -> DayKey {
        DayGrouper.dayKey(for: photo.capturedAt,
                          secondsFromGMT: zones[photo.id] ?? TimeZone.current.secondsFromGMT(for: photo.capturedAt))
    }

    /// Places of the photos with GPS, one resolver call per `PlaceKey` (failed lookups are not
    /// retried within one call). With `stopOnCancel`, stops before the next resolver call once the
    /// task is cancelled and reports `complete == false`.
    private static func resolvePlaces(of photos: [Photo], resolver: PlaceResolver,
                                      stopOnCancel: Bool) async -> (places: [PhotoID: Place], complete: Bool) {
        var resolved: [PlaceKey: Place] = [:]
        var attempted: Set<PlaceKey> = []
        var places: [PhotoID: Place] = [:]
        for photo in photos {
            guard let location = photo.location else { continue }
            let key = PlaceKey(location)
            if !attempted.contains(key) {
                if stopOnCancel && Task.isCancelled { return (places, false) }
                attempted.insert(key)
                if let place = await resolver.place(for: location) { resolved[key] = place }
            }
            if let place = resolved[key] { places[photo.id] = place }
        }
        return (places, true)
    }
}

/// What `GroupingService.refinePlaces` changed, for the UI.
public struct PlaceRefinement: Sendable, Equatable {
    /// Photos whose auto-assigned day was corrected.
    public var changedDays: Int
    /// Photos that got a `placeName`.
    public var namedPhotos: Int
    /// `false` when the task was cancelled before every place was looked up (days then unchanged).
    public var completed: Bool

    public init(changedDays: Int, namedPhotos: Int, completed: Bool) {
        self.changedDays = changedDays
        self.namedPhotos = namedPhotos
        self.completed = completed
    }
}
