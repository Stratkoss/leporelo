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
        let places = await lookUpPlaces(of: photos, resolver: resolver, stopOnCancel: false).places

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
    /// blocks the UI), as two steps: `resolvePlaces` (slow, async, does not touch the album) and
    /// `applyRefinement` (fast, synchronous). This function is their composition on one album; it
    /// suits callers that own the album for the whole await (CLI, tests).
    ///
    /// Intended app flow (the user can edit the album while geocoding runs for minutes):
    /// 1. take a snapshot of the store's album;
    /// 2. `await resolvePlaces(of: snapshot, resolver:)` off the main actor;
    /// 3. in ONE synchronous main-actor step, `applyRefinement(places, completed:, to: &liveAlbum)`
    ///    on the store's CURRENT album and write it back through the no-undo API (Task 17
    ///    contract; this is not a user edit).
    /// Never write the snapshot (or a refined copy of it) back: the guarantee that days the user
    /// moved are kept relies on `applyRefinement` seeing the live album, including moves made
    /// during step 2.
    @discardableResult
    public static func refinePlaces(in album: inout Album, resolver: PlaceResolver) async -> PlaceRefinement {
        let (places, completed) = await resolvePlaces(of: album, resolver: resolver)
        return applyRefinement(places, completed: completed, to: &album)
    }

    /// Places of the album's photos with GPS, keyed by photo. Does not change `album`.
    ///
    /// Lookups as in `assignDays`: each `PlaceKey` is requested at most once per call and failed
    /// lookups are not retried within the call. Cancellation is checked before every resolver call:
    /// once the task is cancelled the lookups stop and the places found so far are returned with
    /// `completed == false`.
    public static func resolvePlaces(of album: Album, resolver: PlaceResolver) async
        -> (places: [PhotoID: Place], completed: Bool) {
        let result = await lookUpPlaces(of: chronological(album), resolver: resolver, stopOnCancel: true)
        return (result.places, result.complete)
    }

    /// Applies places from `resolvePlaces` to `album`, which should be the LIVE album (see
    /// `refinePlaces` for the app flow). Synchronous, so a caller can run it atomically.
    ///
    /// 1. Sets `placeName` where it is still `nil` (a name set earlier is never overwritten).
    ///    Places of photos no longer in `album` are ignored.
    /// 2. Only when `completed`: corrects auto-assigned days. For every photo with a `dayKey`, if it
    ///    still equals the day computed from `album` WITHOUT places (zones from EXIF, neighbours,
    ///    longitude: what the fast pass assigned), it becomes the day computed WITH the places
    ///    (place time zones, e.g. Europe/Rome +2 h in summer where the longitude said +1 h). A
    ///    `dayKey` that differs from that auto day was set by the user or another route and is left
    ///    alone; photos without a `dayKey` are left to `assignDays`. Days are local to the place
    ///    (Review Focus 1), never UTC or the Mac's zone (except as the last fallback of
    ///    `TimeZoneInference`).
    ///    With `completed == false` days are not touched (a partial set of zones could move photos
    ///    half-way); a later complete run still corrects them.
    @discardableResult
    public static func applyRefinement(_ places: [PhotoID: Place], completed: Bool,
                                       to album: inout Album) -> PlaceRefinement {
        let places = places.filter { album.photos[$0.key] != nil }
        var named = 0
        for id in places.keys.sorted() where album.photos[id]?.placeName == nil {
            album.photos[id]?.placeName = places[id]?.name
            named += 1
        }
        guard completed else {
            return PlaceRefinement(changedDays: 0, namedPhotos: named, completed: false)
        }

        let photos = chronological(album)
        let oldZones = TimeZoneInference.resolveTimeZones(photos, places: [:])
        let newZones = TimeZoneInference.resolveTimeZones(photos, places: places)
        var changed = 0
        for photo in photos {
            guard let current = photo.dayKey, current == autoDay(of: photo, zones: oldZones) else { continue }
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
    private static func lookUpPlaces(of photos: [Photo], resolver: PlaceResolver,
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
