import Testing
import Foundation
@testable import LeporeloCore

@Suite struct TimeZoneInferenceTests {
    static let positano = GeoPoint(latitude: 40.63, longitude: 14.48)
    static let tokyo = GeoPoint(latitude: 35.68, longitude: 139.69)

    static func photo(_ id: String, _ iso: String, gps: GeoPoint? = nil, tz: Int? = nil, day: DayKey? = nil) -> Photo {
        let date = ISO8601DateFormatter().date(from: iso)!
        return Photo(id: id, sourceIdentifier: id, capturedAt: date, timeZoneSeconds: tz, location: gps,
                     pixelWidth: 4000, pixelHeight: 3000, kind: .photo, analysis: nil, isSelected: false,
                     dayKey: day, placeName: nil, seriesID: nil, originalState: .missing, deletedInSource: false)
    }

    static func zones(_ photos: [Photo], _ places: [PhotoID: Place] = [:]) -> [PhotoID: Int] {
        TimeZoneInference.resolveTimeZones(photos, places: places)
    }

    @Test func midnightInItalyStaysInItalianDay() {
        let rome = Place(name: "Positano", timeZoneIdentifier: "Europe/Rome")
        let a = Self.photo("a", "2026-06-18T21:30:00Z", gps: Self.positano)   // 23:30 local
        let b = Self.photo("b", "2026-06-18T22:30:00Z", gps: Self.positano)   // 00:30 local, next day
        let places = ["a": rome, "b": rome]
        let z = Self.zones([a, b], places)
        #expect(z["a"] == 7200)
        #expect(z["b"] == 7200)
        let groups = DayGrouper.group([a, b], timeZones: z, places: places)
        #expect(groups.map(\.dayKey) == [DayKey(year: 2026, month: 6, day: 18), DayKey(year: 2026, month: 6, day: 19)])
        #expect(DayGrouper.dayKey(for: a.capturedAt, secondsFromGMT: 7200) == DayKey(year: 2026, month: 6, day: 18))
    }

    @Test func midnightInItalyWithoutPlacesUsesNeighbourZone() {
        // a has GPS and its own +2 h offset; b has no GPS, 00:30 local on the 19th (22:30Z).
        // UTC would put b on the 18th.
        let a = Self.photo("a", "2026-06-18T21:30:00Z", gps: Self.positano, tz: 7200)
        let b = Self.photo("b", "2026-06-18T22:30:00Z")
        let z = Self.zones([a, b])
        #expect(z["b"] == 7200)
        let groups = DayGrouper.group([a, b], timeZones: z, places: [:])
        #expect(groups.map(\.dayKey) == [DayKey(year: 2026, month: 6, day: 18), DayKey(year: 2026, month: 6, day: 19)])
    }

    @Test func farZoneIsNotUTCNorMacZone() {
        // 16:00Z = 01:00 next day in Tokyo; UTC and any Mac zone west of +8 say the 18th.
        let t = Self.photo("t", "2026-06-18T16:00:00Z", gps: Self.tokyo)
        let places = ["t": Place(name: "Tokio", timeZoneIdentifier: "Asia/Tokyo")]
        let z = Self.zones([t], places)
        #expect(z["t"] == 32400)
        #expect(DayGrouper.group([t], timeZones: z, places: places)[0].dayKey == DayKey(year: 2026, month: 6, day: 19))
    }

    @Test func photoWithoutGPSInheritsNearestZone() {
        let a = Self.photo("a", "2026-06-18T01:00:00Z", gps: Self.tokyo)
        let b = Self.photo("b", "2026-06-18T04:00:00Z")
        let places = ["a": Place(name: "Tokio", timeZoneIdentifier: "Asia/Tokyo")]
        #expect(Self.zones([a, b], places)["b"] == 32400)
    }

    @Test func ownTimeZoneWinsOverPlace() {
        let a = Self.photo("a", "2026-06-18T01:00:00Z", gps: Self.tokyo, tz: 3600)
        let places = ["a": Place(name: "Tokio", timeZoneIdentifier: "Asia/Tokyo")]
        #expect(Self.zones([a], places)["a"] == 3600)
    }

    @Test func farNeighbourIsIgnoredAndFallsBackToCurrentZone() {
        let a = Self.photo("a", "2026-06-18T01:00:00Z", gps: Self.tokyo)
        let b = Self.photo("b", "2026-06-19T01:00:00Z")
        #expect(Self.zones([a, b])["b"] == TimeZone.current.secondsFromGMT(for: b.capturedAt))
    }

    @Test func longitudeFallback() {
        #expect(TimeZoneInference.secondsFromGMT(forLongitude: 14.4) == 3600)
        #expect(TimeZoneInference.secondsFromGMT(forLongitude: -74) == -18000)
    }

    // Final fix wave C5: the nearest-neighbour search is sorted + binary search.
    @Test func nearestNeighbourTiesAndLimits() {
        let a = Self.photo("a", "2026-06-18T10:00:00Z", tz: 3600)
        let b = Self.photo("b", "2026-06-18T12:00:00Z", tz: 7200)
        let c = Self.photo("c", "2026-06-18T12:00:00Z", tz: 10800)
        // Exactly between a and b/c: the tie goes to the smallest id ("a").
        let mid = Self.photo("m", "2026-06-18T11:00:00Z")
        #expect(Self.zones([c, b, a, mid])["m"] == 3600)
        // Same distance to b and c only: "b".
        let late = Self.photo("z", "2026-06-18T13:00:00Z")
        #expect(Self.zones([c, b, late])["z"] == 7200)
        // More than 12 h away: no neighbour, the Mac's zone.
        let far = Self.photo("f", "2026-06-19T00:00:01Z")
        #expect(Self.zones([b, far])["f"] == TimeZone.current.secondsFromGMT(for: far.capturedAt))
        // Exactly 12 h: still a neighbour.
        let edge = Self.photo("e", "2026-06-19T00:00:00Z")
        #expect(Self.zones([b, edge])["e"] == 7200)
    }

    @Test func threeThousandPhotosResolveQuickly() {
        let start = ISO8601DateFormatter().date(from: "2026-06-10T00:00:00Z")!
        let photos = (0..<3000).map { i -> Photo in
            var p = Self.photo("p\(i)", "2026-06-10T00:00:00Z", gps: i % 2 == 0 ? Self.positano : nil,
                               tz: i % 50 == 0 ? 7200 : nil)
            p.capturedAt = start.addingTimeInterval(Double(i) * 290)
            return p
        }
        let begin = Date()
        let zones = Self.zones(photos)
        let elapsed = Date().timeIntervalSince(begin)
        #expect(zones.count == 3000)
        #expect(zones.values.allSatisfy { $0 == 7200 })
        #expect(elapsed < 0.25, "resolveTimeZones took \(elapsed) s")
    }
}

