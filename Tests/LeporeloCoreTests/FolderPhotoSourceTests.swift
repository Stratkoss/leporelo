import Foundation
import Testing
@testable import LeporeloCore

@Suite struct FolderPhotoSourceTests {
    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    let everything = SourceQuery.dateRange(start: .distantPast, end: .distantFuture)

    @Test func readsExifDateOffsetAndGPS() async throws {
        let dir = try tempFolder()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        try JPEGFixtures.write(to: dir.appendingPathComponent("a.jpg"), size: (64, 48), date: date,
                               offset: "+02:00", gps: GeoPoint(latitude: -12.5, longitude: 45.25))
        let photos = try await FolderPhotoSource(folder: dir).photos(matching: everything)
        #expect(photos.count == 1)
        let p = photos[0]
        #expect(p.identifier == "a.jpg")
        #expect(p.timeZoneSeconds == 7200)
        #expect(p.capturedAt == date)
        #expect(abs(p.location!.latitude - -12.5) < 0.0001)
        #expect(abs(p.location!.longitude - 45.25) < 0.0001)
        #expect(p.kind == .photo && !p.isCloudOnly)
        #expect(p.pixelWidth == 64 && p.pixelHeight == 48)
    }

    @Test func noOffsetMeansNilTimeZone() async throws {
        let dir = try tempFolder()
        try JPEGFixtures.write(to: dir.appendingPathComponent("a.jpg"), date: Date(timeIntervalSince1970: 1_750_000_000))
        let p = try await FolderPhotoSource(folder: dir).photos(matching: everything)
        #expect(p[0].timeZoneSeconds == nil)
    }

    @Test func fallsBackToFileDateWithoutExif() async throws {
        let dir = try tempFolder()
        let url = dir.appendingPathComponent("sub/b.jpg")
        try JPEGFixtures.write(to: url)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
        let p = try await FolderPhotoSource(folder: dir).photos(matching: everything)
        #expect(p.count == 1 && p[0].identifier == "sub/b.jpg")
        #expect(abs(p[0].capturedAt.timeIntervalSince(created)) < 1)
        #expect(p[0].timeZoneSeconds == nil && p[0].location == nil)
    }

    @Test func dateRangeQueryFilters() async throws {
        let dir = try tempFolder()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        for i in 0..<3 {
            try JPEGFixtures.write(to: dir.appendingPathComponent("p\(i).jpg"),
                                   date: t0.addingTimeInterval(Double(i) * 3600), offset: "+00:00")
        }
        let src = FolderPhotoSource(folder: dir)
        // half-open: start inclusive, end exclusive
        let r = try await src.photos(matching: .dateRange(start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(7200)))
        #expect(r.map(\.identifier) == ["p1.jpg"])
        let all = try await src.photos(matching: .dateRange(start: t0, end: t0.addingTimeInterval(7201)))
        #expect(all.map(\.identifier) == ["p0.jpg", "p1.jpg", "p2.jpg"])
    }

    @Test func albumsAndAlbumQuery() async throws {
        let dir = try tempFolder()
        try JPEGFixtures.write(to: dir.appendingPathComponent("Trip/a.jpg"))
        try JPEGFixtures.write(to: dir.appendingPathComponent("Trip/deep/b.jpg"))
        try JPEGFixtures.write(to: dir.appendingPathComponent("Other/c.jpg"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try JPEGFixtures.write(to: dir.appendingPathComponent(".hidden/h.jpg"))
        try JPEGFixtures.write(to: dir.appendingPathComponent("X.leporelo/t.jpg"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Trip/notes.txt"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("Trip/broken.jpg"))
        let src = FolderPhotoSource(folder: dir)
        let albums = try await src.albums()
        #expect(albums.map(\.name).sorted() == ["Other", "Trip"])
        let trip = albums.first { $0.name == "Trip" }!
        #expect(trip.identifier == "Trip" && trip.count == 2 && !trip.isShared)
        let ph = try await src.photos(matching: .album(identifier: "Trip", name: "Trip"))
        #expect(Set(ph.map(\.identifier)) == ["Trip/a.jpg", "Trip/deep/b.jpg"])
        let all = try await src.photos(matching: everything)
        #expect(all.count == 3)
    }

    @Test func thumbnailRespectsMaxPixelAndIsUpright() async throws {
        let dir = try tempFolder()
        try JPEGFixtures.write(to: dir.appendingPathComponent("big.jpg"), size: (400, 200), orientation: 6)
        try JPEGFixtures.write(to: dir.appendingPathComponent("small.jpg"), size: (40, 20))
        let src = FolderPhotoSource(folder: dir)
        let t = try await src.thumbnail(for: "big.jpg", maxPixel: 100)
        #expect(max(t.width, t.height) <= 100)
        #expect(t.height > t.width)   // orientation 6 => upright portrait
        let s = try await src.thumbnail(for: "small.jpg", maxPixel: 100)
        #expect(s.width == 40 && s.height == 20)   // never upscaled
        let p = try await src.photos(matching: everything)
        let big = p.first { $0.identifier == "big.jpg" }!
        #expect(big.pixelWidth == 200 && big.pixelHeight == 400)
    }

    @Test func originalReturnsBytesAndExt() async throws {
        let dir = try tempFolder()
        let url = dir.appendingPathComponent("A.JPG")
        try JPEGFixtures.write(to: url)
        let o = try await FolderPhotoSource(folder: dir).original(for: "A.JPG")
        #expect(o.data == (try Data(contentsOf: url)))
        #expect(o.ext == "jpg")
    }

    @Test func rejectsUnsafeIdentifiers() async throws {
        let dir = try tempFolder()
        let outside = try tempFolder()
        try JPEGFixtures.write(to: outside.appendingPathComponent("o.jpg"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("f.jpg"),
                                                   withDestinationURL: outside.appendingPathComponent("o.jpg"))
        let src = FolderPhotoSource(folder: dir)
        for id in ["../x.jpg", "/etc/passwd", "link/o.jpg", "f.jpg", "missing.jpg", "a/../../x"] {
            await #expect(throws: PhotoSourceError.self) { _ = try await src.original(for: id) }
            await #expect(throws: PhotoSourceError.self) { _ = try await src.thumbnail(for: id, maxPixel: 50) }
        }
        let all = try await src.photos(matching: everything)
        #expect(all.isEmpty)
    }

    @Test func photoInitFromSource() {
        let s = SourcePhoto(identifier: "x/y.jpg", capturedAt: Date(timeIntervalSince1970: 5), timeZoneSeconds: 3600,
                            location: GeoPoint(latitude: 1, longitude: 2), pixelWidth: 10, pixelHeight: 20,
                            kind: .photo, isCloudOnly: false)
        let a = Photo(source: s), b = Photo(source: s)
        #expect(a.id != b.id && UUID(uuidString: a.id) != nil)
        #expect(a.sourceIdentifier == "x/y.jpg" && a.originalState == .missing)
        #expect(!a.isSelected && a.analysis == nil && a.dayKey == nil && !a.deletedInSource)
        #expect(a.pixelWidth == 10 && a.timeZoneSeconds == 3600)
    }

    // Final fix wave C4: untrusted EXIF dates never crash and never produce an unreadable album.
    @Test(arguments: [("0000:00:00 00:00:00", nil), ("99999:01:01 12:00:00", "+02:00"),
                      ("2026:13:01 12:00:00", nil), ("2026:06:18 25:00:00", "+01:00"),
                      ("2026:06:00 12:00:00", nil), ("garbage", nil)] as [(String, String?)])
    func invalidExifDateFallsBackToFileDate(raw: String, offset: String?) async throws {
        let dir = try tempFolder()
        let url = dir.appendingPathComponent("bad.jpg")
        try JPEGFixtures.write(to: url, offset: offset, rawDate: raw)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
        let photos = try await FolderPhotoSource(folder: dir).photos(matching: everything)
        #expect(photos.count == 1)
        #expect(abs(photos[0].capturedAt.timeIntervalSince(created)) < 1, "\(raw)")
        #expect(photos[0].timeZoneSeconds == nil)
    }

    @Test func validRawExifDateStillWorks() async throws {
        let dir = try tempFolder()
        try JPEGFixtures.write(to: dir.appendingPathComponent("ok.jpg"), offset: "+02:00", rawDate: "2026:06:18 14:30:00")
        let photos = try await FolderPhotoSource(folder: dir).photos(matching: everything)
        #expect(photos[0].capturedAt == Date(timeIntervalSince1970: 1_781_785_800))
        #expect(photos[0].timeZoneSeconds == 7200)
    }

    @Test func parseNaiveRanges() {
        #expect(FolderPhotoSource.parseNaive("2026:06:18 14:30:59") != nil)
        #expect(FolderPhotoSource.parseNaive("0001:01:01 00:00:00") != nil)
        #expect(FolderPhotoSource.parseNaive("9999:12:31 23:59:59") != nil)
        for bad in ["0000:00:00 00:00:00", "10000:01:01 00:00:00", "2026:00:10 10:00:00", "2026:01:32 10:00:00",
                    "2026:01:10 24:00:00", "2026:01:10 10:60:00", "2026:01:10 10:00:60", "2026:01:10 10:00",
                    "-2026:01:10 10:00:00", "    :  :     :  :  "] {
            #expect(FolderPhotoSource.parseNaive(bad) == nil, "\(bad)")
        }
    }

    /// The fallback date (here: a file with a zero EXIF date) saves and reopens.
    @Test func albumWithFallbackDateRoundTrips() async throws {
        let dir = try tempFolder()
        let url = dir.appendingPathComponent("zero.jpg")
        try JPEGFixtures.write(to: url, rawDate: "0000:00:00 00:00:00")
        let source = try await FolderPhotoSource(folder: dir).photos(matching: everything)[0]
        let photo = Photo(id: "p1", sourceIdentifier: source.identifier, capturedAt: source.capturedAt,
                          timeZoneSeconds: source.timeZoneSeconds, location: nil, pixelWidth: source.pixelWidth,
                          pixelHeight: source.pixelHeight, kind: .photo, analysis: nil, isSelected: true,
                          dayKey: nil, placeName: nil, seriesID: nil, originalState: .missing, deletedInSource: false)
        let album = Album(formatVersion: Album.currentFormatVersion, id: "a", title: "A", supplierProfileID: "saal",
                          formatID: "20x20", world: "journal-gallery", cover: nil, spreads: [],
                          photos: ["p1": photo], source: nil, createdAt: Date(timeIntervalSince1970: 0))
        let package = try ProjectPackage.create(at: dir.appendingPathComponent("a.leporelo"), album: album)
        let (_, reopened) = try ProjectPackage.open(package.url)
        // The file date has sub-microsecond digits that ISO 8601 does not keep; the rest is equal.
        let reopenedDate = try #require(reopened.photos["p1"]?.capturedAt)
        #expect(abs(reopenedDate.timeIntervalSince(source.capturedAt)) < 0.001)
        #expect(reopenedDate > Date(timeIntervalSince1970: 1_000_000_000))
        var normalized = reopened
        normalized.photos["p1"]?.capturedAt = source.capturedAt
        #expect(normalized == album)
        // And the fallback of last resort (1970) round-trips too.
        var epoch = album
        epoch.photos["p1"]?.capturedAt = Date(timeIntervalSince1970: 0)
        try package.save(epoch)
        #expect(try ProjectPackage.open(package.url).1 == epoch)
    }
}

