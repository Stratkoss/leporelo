import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LeporeloCore

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("leporelo-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makePhoto(_ id: String, w: Int = 40, h: Int = 20, state: OriginalState = .missing) -> Photo {
    Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
          timeZoneSeconds: 0, location: nil, pixelWidth: w, pixelHeight: h, kind: .photo,
          analysis: nil, isSelected: true, dayKey: nil, placeName: nil, seriesID: nil,
          originalState: state, deletedInSource: false)
}

private func makeAlbum(photos: [Photo] = [], version: Int = Album.currentFormatVersion,
                       title: String = "Léto") -> Album {
    Album(formatVersion: version, id: "album-1", title: title, supplierProfileID: "saal",
          formatID: "20x20", world: "journal-gallery", cover: nil, spreads: [],
          photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }), source: nil,
          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

/// JPEG whose stored pixel buffer is `width` x `height` with the given EXIF orientation
/// (6 = rotate 90 CW on display, so a 40x20 buffer is displayed 20x40).
private func orientedJPEG(width: Int, height: Int, orientation: Int = 6) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image,
                               [kCGImagePropertyOrientation: orientation] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return data as Data
}

private func solidImage(width: Int, height: Int) -> CGImage {
    ImageFixtures.solid(width: width, height: height)
}

@Suite struct ProjectPackageTests {
    @Test func createOpenRoundTrip() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Léto.leporelo")
        let album = makeAlbum(photos: [makePhoto("a"), makePhoto("b")])
        let pkg = try ProjectPackage.create(at: url, album: album)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("originals").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("thumbs").path, isDirectory: &isDir) && isDir.boolValue)
        let (opened, loaded) = try ProjectPackage.open(pkg.url)
        #expect(loaded == album)
        #expect(opened.url == pkg.url)
        #expect(throws: ProjectError.alreadyExists) { try ProjectPackage.create(at: url, album: album) }
    }

    @Test func jsonIsSortedAndPretty() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let text = try String(contentsOf: pkg.url.appendingPathComponent("album.json"), encoding: .utf8)
        #expect(text.contains("\n  \"createdAt\""))
        #expect(text.contains("2023-11-14T22:13:20.000Z"))
    }

    @Test func fractionalSecondsSurviveSaveAndOpen() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var photo = makePhoto("a")
        photo.capturedAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let album = makeAlbum(photos: [photo])
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: album)
        let loaded = try ProjectPackage.open(pkg.url).1
        let json = try String(contentsOf: pkg.url.appendingPathComponent("album.json"), encoding: .utf8)
        #expect(json.contains("20.123Z"))
        #expect(loaded == album)
        #expect(loaded.photos["a"]?.capturedAt == photo.capturedAt)
    }

    @Test func fileWithoutFractionsStillOpens() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let file = pkg.url.appendingPathComponent("album.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        let plain = text.replacingOccurrences(of: ".000Z", with: "Z")
        #expect(plain != text)
        try plain.write(to: file, atomically: true, encoding: .utf8)
        #expect(try ProjectPackage.open(pkg.url).1 == makeAlbum())
    }

    @Test func saveIsAtomic() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        try pkg.save(makeAlbum(title: "Nové"))
        let names = try FileManager.default.contentsOfDirectory(atPath: pkg.url.path).sorted()
        #expect(names == ["album.json", "originals", "thumbs"])
        let data = try Data(contentsOf: pkg.url.appendingPathComponent("album.json"))
        _ = try JSONSerialization.jsonObject(with: data)
        #expect(try ProjectPackage.open(pkg.url).1.title == "Nové")
    }

    @Test func failedEncodeKeepsPreviousFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let file = pkg.url.appendingPathComponent("album.json")
        let before = try Data(contentsOf: file)
        var bad = makeAlbum(title: "Špatné")
        bad.spreads = [Spread(id: "s", kind: .gallery, templateID: "t", dayKey: nil,
                              frames: [Frame(id: "f", rect: Rect(x: 0, y: 0, width: 1, height: 1),
                                             photoID: "a", offset: Point(x: 0, y: 0), zoom: .nan)],
                              texts: [], manuallyEdited: false)]
        #expect(throws: (any Error).self) { try pkg.save(bad) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pkg.url.path).sorted()
                == ["album.json", "originals", "thumbs"])
    }

    @Test func failedWriteKeepsPreviousFile() throws {
        let dir = makeTempDir()
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let file = pkg.url.appendingPathComponent("album.json")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pkg.url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pkg.url.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(throws: (any Error).self) { try pkg.save(makeAlbum(title: "Jiné")) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func storeOriginalUpdatesPath() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let rel = try pkg.storeOriginal(data: Data([1, 2, 3]), ext: "JPG", for: "a")
        #expect(rel == "originals/a.jpg")
        var photo = makePhoto("a", state: .stored(relativePath: rel))
        let album = makeAlbum(photos: [photo])
        let url = try #require(pkg.originalURL(for: "a", album: album))
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: pkg.url.appendingPathComponent(rel).path))
        photo.originalState = .missing
        #expect(pkg.originalURL(for: "a", album: makeAlbum(photos: [photo])) == nil)
        #expect(pkg.originalURL(for: "zzz", album: album) == nil)
        let ghost = makePhoto("g", state: .stored(relativePath: "originals/g.jpg"))
        #expect(pkg.originalURL(for: "g", album: makeAlbum(photos: [ghost])) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pkg.url.appendingPathComponent("originals").path) == ["a.jpg"])
    }

    @Test func invalidNamesAreRejected() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        for id in ["../evil", "a/b", "..", "", "a\\b"] {
            #expect(throws: ProjectError.invalidName) { try pkg.storeOriginal(data: Data([1]), ext: "jpg", for: id) }
            #expect(throws: ProjectError.invalidName) { try pkg.storeThumbnail(solidImage(width: 4, height: 4), for: id) }
        }
        for ext in ["", "j/g", "..", "toolongext1", "jp g", "../x"] {
            #expect(throws: ProjectError.invalidName) { try pkg.storeOriginal(data: Data([1]), ext: ext, for: "a") }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.jpg").path))
    }

    @Test func originalURLCannotEscapePackage() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([9]).write(to: dir.appendingPathComponent("secret.txt"))
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let evil = makePhoto("e", state: .stored(relativePath: "../secret.txt"))
        #expect(pkg.originalURL(for: "e", album: makeAlbum(photos: [evil])) == nil)
        let abs = makePhoto("f", state: .stored(relativePath: dir.appendingPathComponent("secret.txt").path))
        #expect(pkg.originalURL(for: "f", album: makeAlbum(photos: [abs])) == nil)
    }

    @Test func thumbnailRoundTrip() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        #expect(pkg.thumbnail(for: "a") == nil)
        try pkg.storeThumbnail(solidImage(width: 3000, height: 2000), for: "a")
        let big = try #require(pkg.thumbnail(for: "a"))
        #expect(big.width == 1024)
        #expect(abs(big.height - 683) <= 1)
        try pkg.storeThumbnail(solidImage(width: 300, height: 600), for: "b")
        let small = try #require(pkg.thumbnail(for: "b"))
        #expect(small.width == 300 && small.height == 600)
        try Data([1, 2, 3]).write(to: pkg.url.appendingPathComponent("thumbs/c.jpg"))
        #expect(pkg.thumbnail(for: "c") == nil)
        #expect(pkg.thumbnail(for: "../x") == nil)
    }

    @Test func newerFormatVersionThrows() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let enc = AlbumCoding.encoder()
        let newer = try enc.encode(makeAlbum(version: Album.currentFormatVersion + 1))
        #expect(throws: ProjectError.unsupportedVersion(Album.currentFormatVersion + 1)) { try pkg.migrate(newer) }
        let older = try enc.encode(makeAlbum(version: 0))
        #expect(throws: ProjectError.unsupportedVersion(0)) { try pkg.migrate(older) }
        try newer.write(to: pkg.url.appendingPathComponent("album.json"))
        #expect(throws: ProjectError.unsupportedVersion(Album.currentFormatVersion + 1)) { try ProjectPackage.open(pkg.url) }
    }

    @Test func openErrors() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.leporelo")
        try Data([1]).write(to: file)
        #expect(throws: ProjectError.notAPackage) { try ProjectPackage.open(file) }
        #expect(throws: ProjectError.notAPackage) { try ProjectPackage.open(dir.appendingPathComponent("nope.leporelo")) }
        let empty = dir.appendingPathComponent("e.leporelo")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ProjectError.missingAlbumFile) { try ProjectPackage.open(empty) }
        try Data("{ not json".utf8).write(to: empty.appendingPathComponent("album.json"))
        do {
            _ = try ProjectPackage.open(empty)
            Issue.record("expected corrupt")
        } catch let ProjectError.corrupt(message) {
            #expect(!message.isEmpty)
        }
    }

    @Test func providerPrefersThumbForSmallRequests() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let rel = try pkg.storeOriginal(data: orientedJPEG(width: 4000, height: 2000, orientation: 1), ext: "jpg", for: "a")
        try pkg.storeThumbnail(solidImage(width: 1024, height: 512), for: "a")
        let album = makeAlbum(photos: [makePhoto("a", w: 4000, h: 2000, state: .stored(relativePath: rel))])
        let provider = PackageImageProvider(package: pkg, album: album)
        let small = try #require(await provider.image(for: "a", minPixelWidth: 800))
        #expect(small.width == 1024)
        let edge = try #require(await provider.image(for: "a", minPixelWidth: 1024))
        #expect(edge.width == 1024)
        let big = try #require(await provider.image(for: "a", minPixelWidth: 3000))
        #expect(big.width >= 3000 && big.width <= 4000 && abs(big.width - big.height * 2) <= 2)
        let full = try #require(await provider.image(for: "a", minPixelWidth: 9000))
        #expect(full.width == 4000 && full.height == 2000) // never upscaled
        #expect(await provider.image(for: "nope", minPixelWidth: 100) == nil)
    }

    @Test func providerAppliesExifOrientation() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let rel = try pkg.storeOriginal(data: orientedJPEG(width: 40, height: 20), ext: "jpg", for: "a")
        try pkg.storeThumbnail(solidImage(width: 10, height: 20), for: "a") // differs from the original path
        let album = makeAlbum(photos: [makePhoto("a", w: 20, h: 40, state: .stored(relativePath: rel))])
        let provider = PackageImageProvider(package: pkg, album: album)
        let img = try #require(await provider.image(for: "a", minPixelWidth: 2000))
        #expect(img.width == 20 && img.height == 40)
    }

    @Test func providerDownscalesRotatedOriginalOnUprightWidth() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        let rel = try pkg.storeOriginal(data: orientedJPEG(width: 4000, height: 2000), ext: "jpg", for: "a")
        try pkg.storeThumbnail(solidImage(width: 512, height: 1024), for: "a")
        let album = makeAlbum(photos: [makePhoto("a", w: 2000, h: 4000, state: .stored(relativePath: rel))])
        let provider = PackageImageProvider(package: pkg, album: album)
        let img = try #require(await provider.image(for: "a", minPixelWidth: 1500))
        #expect(img.width >= 1500 && img.width <= 1510)
        #expect(abs(img.height - img.width * 2) <= 2 && img.height >= 3000)
        let full = try #require(await provider.image(for: "a", minPixelWidth: 9000))
        #expect(full.width == 2000 && full.height == 4000)
    }

    @Test func providerFallsBackToThumbWhenOriginalMissing() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try ProjectPackage.create(at: dir.appendingPathComponent("x.leporelo"), album: makeAlbum())
        try pkg.storeThumbnail(solidImage(width: 100, height: 50), for: "a")
        let album = makeAlbum(photos: [makePhoto("a", w: 4000, h: 2000)])
        let provider = PackageImageProvider(package: pkg, album: album)
        let img = try #require(await provider.image(for: "a", minPixelWidth: 3000))
        #expect(img.width == 100)
    }
}
