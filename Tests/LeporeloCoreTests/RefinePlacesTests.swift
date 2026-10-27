import Testing
import Foundation
@testable import LeporeloCore

/// `GroupingService.refinePlaces`: the background pass after a fast `assignDays` with an empty
/// resolver. No network: resolvers are in-memory fakes.
@Suite struct RefinePlacesTests {
    typealias T = TimeZoneInferenceTests
    static let rome = Place(name: "Positano", timeZoneIdentifier: "Europe/Rome")
    static let june18 = DayKey(year: 2026, month: 6, day: 18)
    static let june19 = DayKey(year: 2026, month: 6, day: 19)

    static func album(_ photos: [Photo]) -> Album {
        Album(formatVersion: Album.currentFormatVersion, id: "x", title: "t", supplierProfileID: "s",
              formatID: "f", world: "w", cover: nil, spreads: [],
              photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
              source: nil, createdAt: Date(timeIntervalSince1970: 0))
    }

    /// The fast first pass the app runs when an album is created.
    static func quickAssigned(_ photos: [Photo]) async -> Album {
        var album = album(photos)
        await GroupingService.assignDays(to: &album, resolver: InMemoryPlaceResolver([]))
        return album
    }

    actor CountingResolver: PlaceResolver {
        private(set) var requested: [PlaceKey] = []
        private let places: [PlaceKey: Place]
        private let cancelAfter: Int?
        init(_ entries: [(GeoPoint, Place)], cancelAfter: Int? = nil) {
            var map: [PlaceKey: Place] = [:]
            for (point, place) in entries { map[PlaceKey(point)] = place }
            places = map
            self.cancelAfter = cancelAfter
        }
        func place(for point: GeoPoint) async -> Place? {
            requested.append(PlaceKey(point))
            if let cancelAfter, requested.count >= cancelAfter {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return places[PlaceKey(point)]
        }
    }

    // (a) Review Focus 1: 00:30 local in Italy belongs to the 19th, the longitude zone said the 18th.
    @Test func localPlaceZoneMovesAutoAssignedDayAndNamesPhoto() async {
        let photo = T.photo("a", "2026-06-18T22:30:00Z", gps: T.positano)
        var album = await Self.quickAssigned([photo])
        #expect(album.photos["a"]?.dayKey == Self.june18)   // +1 h from longitude: 23:30 on the 18th
        #expect(album.photos["a"]?.placeName == nil)

        let result = await GroupingService.refinePlaces(
            in: &album, resolver: InMemoryPlaceResolver([(T.positano, Self.rome)]))
        #expect(album.photos["a"]?.dayKey == Self.june19)   // Europe/Rome +2 h: 00:30 on the 19th
        #expect(album.photos["a"]?.placeName == "Positano")
        #expect(result == PlaceRefinement(changedDays: 1, namedPhotos: 1, completed: true))
    }

    // (a') A photo without GPS next to it follows the corrected zone too.
    @Test func neighbourWithoutGPSFollowsResolvedZone() async {
        let a = T.photo("a", "2026-06-18T22:20:00Z", gps: T.positano)
        let b = T.photo("b", "2026-06-18T22:30:00Z")
        var album = await Self.quickAssigned([a, b])
        #expect(album.photos["b"]?.dayKey == Self.june18)
        await GroupingService.refinePlaces(in: &album, resolver: InMemoryPlaceResolver([(T.positano, Self.rome)]))
        #expect(album.photos["a"]?.dayKey == Self.june19)
        #expect(album.photos["b"]?.dayKey == Self.june19)
        #expect(album.photos["b"]?.placeName == nil)
    }

    // (b) Days set by the user (or another route) and photos without a day are left alone.
    @Test func movedAndUndatedPhotosStay() async throws {
        let moved = DayKey(year: 2026, month: 6, day: 25)
        var album = await Self.quickAssigned([
            T.photo("moved", "2026-06-18T22:30:00Z", gps: T.positano),
            T.photo("undated", "2026-06-18T22:40:00Z", gps: T.positano),
        ])
        album = try album.applying(.setPhotoDay("moved", moved)).album
        album = try album.applying(.setPhotoDay("undated", nil)).album

        let result = await GroupingService.refinePlaces(
            in: &album, resolver: InMemoryPlaceResolver([(T.positano, Self.rome)]))
        #expect(album.photos["moved"]?.dayKey == moved)
        #expect(album.photos["undated"]?.dayKey == nil)
        #expect(album.photos["moved"]?.placeName == "Positano")   // names are still filled in
        #expect(result.changedDays == 0)
    }

    // (c) A name set earlier is never overwritten.
    @Test func existingPlaceNameIsKept() async {
        var named = T.photo("named", "2026-06-18T10:00:00Z", gps: T.positano)
        named.placeName = "Amalfi"
        var album = await Self.quickAssigned([named, T.photo("other", "2026-06-18T11:00:00Z", gps: T.positano)])
        let result = await GroupingService.refinePlaces(
            in: &album, resolver: InMemoryPlaceResolver([(T.positano, Self.rome)]))
        #expect(album.photos["named"]?.placeName == "Amalfi")
        #expect(album.photos["other"]?.placeName == "Positano")
        #expect(result.namedPhotos == 1)
    }

    // (d) Each place key is requested at most once per call, failed lookups included.
    @Test func eachPlaceKeyResolvedOnce() async {
        let unknown = GeoPoint(latitude: 10, longitude: 20)
        var album = await Self.quickAssigned([
            T.photo("a", "2026-06-18T08:00:00Z", gps: T.positano),
            T.photo("b", "2026-06-18T09:00:00Z", gps: GeoPoint(latitude: 40.6312, longitude: 14.4789)),
            T.photo("c", "2026-06-18T10:00:00Z", gps: unknown),
            T.photo("d", "2026-06-18T11:00:00Z", gps: unknown),
            T.photo("e", "2026-06-18T12:00:00Z"),
        ])
        let resolver = CountingResolver([(T.positano, Self.rome)])
        await GroupingService.refinePlaces(in: &album, resolver: resolver)
        let requested = await resolver.requested
        #expect(requested.count == 2)
        #expect(Set(requested) == [PlaceKey(T.positano), PlaceKey(unknown)])
        #expect(album.photos["b"]?.placeName == "Positano")
        #expect(album.photos["c"]?.placeName == nil)
    }

    // (e) Cancelled between lookups: names found so far are kept, days are not re-derived from a
    // partial set of zones (a later full run still refines them), nothing else changes.
    @Test func cancellationKeepsAlbumConsistent() async {
        let amalfi = GeoPoint(latitude: 40.63, longitude: 14.60)
        let tokyo = T.tokyo
        let amalfiPlace = Place(name: "Amalfi", timeZoneIdentifier: "Europe/Rome")
        let photos = [
            T.photo("a", "2026-06-18T22:30:00Z", gps: T.positano),
            T.photo("b", "2026-06-18T23:30:00Z", gps: amalfi),
            T.photo("c", "2026-06-25T10:00:00Z", gps: tokyo),
        ]
        let quick = await Self.quickAssigned(photos)
        let resolver = CountingResolver([(T.positano, Self.rome), (amalfi, amalfiPlace),
                                         (tokyo, Place(name: "Tokio", timeZoneIdentifier: "Asia/Tokyo"))],
                                        cancelAfter: 1)
        let (album, result) = await Task {
            var album = quick
            let result = await GroupingService.refinePlaces(in: &album, resolver: resolver)
            return (album, result)
        }.value
        #expect(await resolver.requested.count == 1)
        #expect(result == PlaceRefinement(changedDays: 0, namedPhotos: 1, completed: false))
        #expect(album.photos["a"]?.placeName == "Positano")
        #expect(album.photos["b"]?.placeName == nil && album.photos["c"]?.placeName == nil)
        var expected = quick
        expected.photos["a"]?.placeName = "Positano"
        #expect(album == expected)

        // Resuming with a full run finishes the job.
        var resumed = album
        let second = await GroupingService.refinePlaces(
            in: &resumed, resolver: CountingResolver([(T.positano, Self.rome), (amalfi, amalfiPlace)]))
        #expect(second.completed)
        #expect(resumed.photos["a"]?.dayKey == Self.june19)
        #expect(resumed.photos["b"]?.dayKey == Self.june19)
        #expect(resumed.photos["a"]?.placeName == "Positano")
        #expect(resumed.photos["b"]?.placeName == "Amalfi")
    }

    // (f) Review Focus 1 the other way round: 23:30 local in Italy stays on its day.
    @Test func lateEveningInItalyStaysOnItsDay() async {
        let photo = T.photo("a", "2026-06-18T21:30:00Z", gps: T.positano)   // 23:30 Europe/Rome
        var album = await Self.quickAssigned([photo])
        #expect(album.photos["a"]?.dayKey == Self.june18)
        let result = await GroupingService.refinePlaces(
            in: &album, resolver: InMemoryPlaceResolver([(T.positano, Self.rome)]))
        #expect(album.photos["a"]?.dayKey == Self.june18)
        #expect(result.changedDays == 0)
    }

    // A recorded offset beats the place zone, before and after refinement.
    @Test func recordedOffsetIsNotOverriddenByPlace() async {
        let photo = T.photo("a", "2026-06-18T22:30:00Z", gps: T.positano, tz: 3600)   // 23:30 at +1
        var album = await Self.quickAssigned([photo])
        await GroupingService.refinePlaces(in: &album, resolver: InMemoryPlaceResolver([(T.positano, Self.rome)]))
        #expect(album.photos["a"]?.dayKey == Self.june18)
    }

    @Test func emptyResolverChangesNothing() async {
        let quick = await Self.quickAssigned([T.photo("a", "2026-06-18T22:30:00Z", gps: T.positano)])
        var album = quick
        let result = await GroupingService.refinePlaces(in: &album, resolver: InMemoryPlaceResolver([]))
        #expect(album == quick)
        #expect(result == PlaceRefinement(changedDays: 0, namedPhotos: 0, completed: true))
    }
}
