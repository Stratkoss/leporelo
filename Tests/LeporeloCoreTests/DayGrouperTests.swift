import Testing
import Foundation
@testable import LeporeloCore

@Suite struct DayGrouperTests {
    typealias T = TimeZoneInferenceTests

    @Test func groupOrdersDaysAndPlaces() {
        let ps = [
            T.photo("p5", "2026-06-19T09:00:00Z"),
            T.photo("p1", "2026-06-18T08:00:00Z"),
            T.photo("p3", "2026-06-18T12:00:00Z"),
            T.photo("p2", "2026-06-18T10:00:00Z"),
            T.photo("p4", "2026-06-19T07:00:00Z"),
        ]
        let places: [PhotoID: Place] = [
            "p1": Place(name: "Positano", timeZoneIdentifier: nil),
            "p2": Place(name: "Amalfi", timeZoneIdentifier: nil),
            "p3": Place(name: "Positano", timeZoneIdentifier: nil),
            "p4": Place(name: "Amalfi", timeZoneIdentifier: nil),
            "p5": Place(name: "Amalfi", timeZoneIdentifier: nil),
        ]
        let zones = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, 7200) })
        let groups = DayGrouper.group(ps, timeZones: zones, places: places)
        #expect(groups.count == 2)
        #expect(groups[0].dayKey == DayKey(year: 2026, month: 6, day: 18))
        #expect(groups[0].photos.map(\.id) == ["p1", "p2", "p3"])
        #expect(groups[0].placeNames == ["Positano", "Amalfi"])
        #expect(groups[1].photos.map(\.id) == ["p4", "p5"])
        #expect(groups[1].placeNames == ["Amalfi"])
        #expect(groups[0].timeZoneSeconds == 7200)
    }

    @Test func manualDayKeyWins() {
        let manual = DayKey(year: 2026, month: 6, day: 25)
        let a = T.photo("a", "2026-06-18T08:00:00Z", day: manual)
        let b = T.photo("b", "2026-06-18T09:00:00Z")
        let groups = DayGrouper.group([a, b], timeZones: ["a": 7200, "b": 7200], places: [:])
        #expect(groups.map(\.dayKey) == [DayKey(year: 2026, month: 6, day: 18), manual])
        #expect(groups[1].photos.map(\.id) == ["a"])
    }

    @Test func equalTimestampsOrderedById() {
        let ps = [T.photo("b", "2026-06-18T08:00:00Z"), T.photo("a", "2026-06-18T08:00:00Z")]
        let g = DayGrouper.group(ps, timeZones: ["a": 0, "b": 0], places: [:])
        #expect(g[0].photos.map(\.id) == ["a", "b"])
    }

    @Test func assignDaysSetsOnlyMissingDayKeysAndPlaceNames() async {
        let positano = T.positano
        let resolver = InMemoryPlaceResolver([(positano, Place(name: "Positano", timeZoneIdentifier: "Europe/Rome"))])
        let a = T.photo("a", "2026-06-18T22:30:00Z", gps: positano)
        let manual = DayKey(year: 2026, month: 1, day: 1)
        let b = T.photo("b", "2026-06-18T22:40:00Z", gps: positano, day: manual)
        var album = Album(formatVersion: Album.currentFormatVersion, id: "x", title: "t", supplierProfileID: "s",
                          formatID: "f", world: "w", cover: nil, spreads: [], photos: ["a": a, "b": b],
                          source: nil, createdAt: Date(timeIntervalSince1970: 0))
        await GroupingService.assignDays(to: &album, resolver: resolver)
        #expect(album.photos["a"]?.dayKey == DayKey(year: 2026, month: 6, day: 19))
        #expect(album.photos["b"]?.dayKey == manual)
        #expect(album.photos["a"]?.placeName == "Positano")
    }

    @Test func inMemoryResolverRoundsToTwoDecimals() async {
        let r = InMemoryPlaceResolver([(GeoPoint(latitude: 40.63, longitude: 14.48), Place(name: "P", timeZoneIdentifier: nil))])
        #expect(await r.place(for: GeoPoint(latitude: 40.6312, longitude: 14.4789))?.name == "P")
        #expect(await r.place(for: GeoPoint(latitude: 41, longitude: 14.48)) == nil)
    }
}
