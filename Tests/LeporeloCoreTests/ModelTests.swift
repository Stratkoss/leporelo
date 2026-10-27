import Testing
import Foundation
@testable import LeporeloCore

@Suite struct ModelTests {
    static func makePhoto(_ id: String, at seconds: TimeInterval, day: DayKey? = DayKey(year: 2026, month: 7, day: 1)) -> Photo {
        Photo(
            id: id,
            sourceIdentifier: "src-\(id)",
            capturedAt: Date(timeIntervalSince1970: seconds),
            timeZoneSeconds: 7200,
            location: GeoPoint(latitude: 50.0, longitude: 14.4),
            pixelWidth: 4000,
            pixelHeight: 3000,
            kind: .photo,
            analysis: PhotoAnalysis(
                aesthetic: 0.8, sharpness: 0.9, isUtility: false,
                faceRects: [Rect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)],
                closedEyes: false, featurePrint: Data([1, 2, 3])
            ),
            isSelected: true,
            selectionDecidedByUser: true,
            dayKey: day,
            placeName: "Praha",
            seriesID: nil,
            originalState: .stored(relativePath: "originals/\(id).heic"),
            deletedInSource: false
        )
    }

    @Test func albumRoundTripsThroughJSON() throws {
        let p1 = Self.makePhoto("a", at: 1_000.123)
        let p2 = Self.makePhoto("b", at: 2_000)
        let spread = Spread(
            id: "s1", kind: .gallery, templateID: "gallery-2",
            dayKey: DayKey(year: 2026, month: 7, day: 1),
            frames: [Frame(id: "f1", rect: Rect(x: 10, y: 10, width: 100, height: 80),
                           photoID: "a", offset: Point(x: 0, y: 0), zoom: 1)],
            texts: [TextBox(id: "t1", rect: Rect(x: 10, y: 100, width: 100, height: 10),
                            role: .caption, text: "Ahoj")],
            manuallyEdited: false
        )
        let album = Album(
            formatVersion: Album.currentFormatVersion,
            id: "album-1", title: "Léto", supplierProfileID: "saal", formatID: "20x20",
            world: "journal-gallery", cover: nil, spreads: [spread],
            photos: ["a": p1, "b": p2],
            source: .dateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 86_400)),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = AlbumCoding.encoder()
        let decoder = AlbumCoding.decoder()
        let decoded = try decoder.decode(Album.self, from: try encoder.encode(album))
        #expect(decoded == album)
    }

    @Test func photoWithoutSelectionDecidedKeyDecodesAsUndecided() throws {
        // An album.json written before `selectionDecidedByUser` existed.
        var album = Album(
            formatVersion: Album.currentFormatVersion, id: "old", title: "t",
            supplierProfileID: "s", formatID: "f", world: "journal-gallery", cover: nil, spreads: [],
            photos: ["a": Self.makePhoto("a", at: 100)], source: nil,
            createdAt: Date(timeIntervalSince1970: 0))
        let data = try AlbumCoding.encoder().encode(album)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var photos = try #require(json["photos"] as? [String: Any])
        var photo = try #require(photos["a"] as? [String: Any])
        #expect(photo["selectionDecidedByUser"] as? Bool == true)
        photo.removeValue(forKey: "selectionDecidedByUser")
        photos["a"] = photo
        json["photos"] = photos
        let legacy = try JSONSerialization.data(withJSONObject: json)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("selectionDecidedByUser"))

        let decoded = try AlbumCoding.decoder().decode(Album.self, from: legacy)
        #expect(decoded.photos["a"]?.selectionDecidedByUser == false)
        album.photos["a"]?.selectionDecidedByUser = false
        #expect(decoded == album)
    }

    @Test func albumWithoutNewKeysDecodesWithDefaults() throws {
        let spread = Spread(id: "s1", kind: .blank, templateID: "t", dayKey: nil, frames: [], texts: [],
                            manuallyEdited: false)
        let album = Album(
            formatVersion: Album.currentFormatVersion, id: "old", title: "t",
            supplierProfileID: "s", formatID: "f", world: "journal-gallery", cover: nil, spreads: [spread],
            photos: [:], source: nil, createdAt: Date(timeIntervalSince1970: 0))
        let data = try AlbumCoding.encoder().encode(album)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "marginMM")
        var spreads = try #require(json["spreads"] as? [[String: Any]])
        spreads[0].removeValue(forKey: "customLayout")
        json["spreads"] = spreads
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let text = String(decoding: legacy, as: UTF8.self)
        #expect(!text.contains("marginMM") && !text.contains("customLayout"))

        let decoded = try AlbumCoding.decoder().decode(Album.self, from: legacy)
        #expect(decoded.marginMM == 10)
        #expect(decoded.spreads[0].customLayout == false)

        var changed = decoded
        changed.marginMM = 14
        changed.spreads[0].customLayout = true
        let again = try AlbumCoding.decoder().decode(Album.self, from: try AlbumCoding.encoder().encode(changed))
        #expect(again.marginMM == 14)
        #expect(again.spreads[0].customLayout == true)
        #expect(again == changed)
    }

    @Test func photoInitDefaultsToUndecided() {
        let photo = Photo(id: "x", sourceIdentifier: "x", capturedAt: Date(timeIntervalSince1970: 0),
                          timeZoneSeconds: nil, location: nil, pixelWidth: 1, pixelHeight: 1, kind: .photo,
                          analysis: nil, isSelected: true, dayKey: nil, placeName: nil, seriesID: nil,
                          originalState: .missing, deletedInSource: false)
        #expect(photo.selectionDecidedByUser == false)
    }

    @Test func rectInsetAndIntersect() {
        let r = Rect(x: 0, y: 0, width: 100, height: 50).insetBy(3)
        #expect(r.origin == Point(x: 3, y: 3))
        #expect(r.size == Size(width: 94, height: 44))
        let a = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
        let b = Rect(x: 5, y: 5, width: 10, height: 10)
        #expect(a.intersects(b))
    }

    @Test func photosByDaySortsWithinDay() {
        let album = Album(
            formatVersion: Album.currentFormatVersion, id: "x", title: "t",
            supplierProfileID: "s", formatID: "f", world: "journal-gallery",
            cover: nil, spreads: [],
            photos: [
                "a": Self.makePhoto("a", at: 300),
                "b": Self.makePhoto("b", at: 100),
                "c": Self.makePhoto("c", at: 200),
            ],
            source: nil, createdAt: Date(timeIntervalSince1970: 0)
        )
        let day = DayKey(year: 2026, month: 7, day: 1)
        #expect(album.photosByDay()[day]?.map(\.id) == ["b", "c", "a"])
    }
}
