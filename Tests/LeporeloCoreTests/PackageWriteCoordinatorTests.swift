import CoreGraphics
import Foundation
import Testing
@testable import LeporeloCore

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("leporelo-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func emptyAlbum() -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "album-1", title: "Léto", supplierProfileID: "saal",
          formatID: "20x20", world: "journal-gallery", cover: nil, spreads: [], photos: [:], source: nil,
          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private func image() -> CGImage {
    let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
    return ctx.makeImage()!
}

/// Records every coordinated write and performs it (or fails it without running the body).
private final class RecordingCoordinator: PackageWriteCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var existedInBody: [Bool] = []
    var failure: (any Error)?

    var urls: [URL] { lock.withLock { recorded } }
    /// Whether the destination already existed when the body started (the new bytes are moved
    /// into place inside the coordinated block, never written there before it).
    var destinationExistedInBody: [Bool] { lock.withLock { existedInBody } }

    func coordinateWriting(at url: URL, _ write: @escaping @Sendable (URL) throws -> Void) throws {
        lock.withLock { recorded.append(url) }
        if let failure { throw failure }
        lock.withLock { existedInBody.append(FileManager.default.fileExists(atPath: url.path)) }
        try write(url)
    }
}

private struct Refused: Error {}

struct PackageWriteCoordinatorTests {
    @Test func originalAndThumbnailWritesGoThroughTheCoordinatorOnce() throws {
        let url = makeTempDir().appendingPathComponent("Koordinace.leporelo")
        let coordinator = RecordingCoordinator()
        let package = try ProjectPackage.create(at: url, album: emptyAlbum()).coordinated(by: coordinator)

        let relative = try package.storeOriginal(data: Data([1, 2, 3]), ext: "HEIC", for: "p1")
        try package.storeThumbnail(image(), for: "p1")

        #expect(coordinator.urls.map(\.standardizedFileURL) == [
            url.appendingPathComponent(relative).standardizedFileURL,
            url.appendingPathComponent("thumbs/p1.jpg").standardizedFileURL,
        ])
        #expect(coordinator.destinationExistedInBody == [false, false])
        #expect(try Data(contentsOf: url.appendingPathComponent(relative)) == Data([1, 2, 3]))
        #expect(package.thumbnail(for: "p1") != nil)

        // album.json belongs to the open document: `save` is never coordinated by the package.
        try package.save(emptyAlbum())
        #expect(coordinator.urls.count == 2)
    }

    /// Replacing an existing original also happens inside the coordinated block, and no temporary
    /// file is left in the package (the bytes are staged outside it).
    @Test func replacingAnOriginalLeavesNoTemporaryFiles() throws {
        let url = makeTempDir().appendingPathComponent("Nahradit.leporelo")
        let coordinator = RecordingCoordinator()
        let package = try ProjectPackage.create(at: url, album: emptyAlbum()).coordinated(by: coordinator)
        let relative = try package.storeOriginal(data: Data([1]), ext: "jpg", for: "p1")
        _ = try package.storeOriginal(data: Data([2, 2]), ext: "jpg", for: "p1")
        #expect(coordinator.destinationExistedInBody == [false, true])
        #expect(try Data(contentsOf: url.appendingPathComponent(relative)) == Data([2, 2]))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("originals").path)
        #expect(names == ["p1.jpg"])
    }

    /// A refused coordination (e.g. the package is gone) surfaces as a thrown error and leaves
    /// nothing behind.
    @Test func refusedCoordinationThrowsAndWritesNothing() throws {
        let url = makeTempDir().appendingPathComponent("Odmítnuto.leporelo")
        let coordinator = RecordingCoordinator()
        coordinator.failure = Refused()
        let package = try ProjectPackage.create(at: url, album: emptyAlbum()).coordinated(by: coordinator)
        #expect(throws: Refused.self) { _ = try package.storeOriginal(data: Data([1]), ext: "jpg", for: "p1") }
        #expect(throws: Refused.self) { try package.storeThumbnail(image(), for: "p1") }
        for directory in ["originals", "thumbs"] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent(directory).path).isEmpty)
        }
    }

    /// The default (`ProjectPackage.open` / `create`) writes directly, as before.
    @Test func defaultPackageWritesDirectly() throws {
        let url = makeTempDir().appendingPathComponent("Přímo.leporelo")
        _ = try ProjectPackage.create(at: url, album: emptyAlbum())
        let (package, _) = try ProjectPackage.open(url)
        #expect(package.writeCoordinator is DirectPackageWrites)
        let relative = try package.storeOriginal(data: Data([9]), ext: "jpg", for: "p1")
        #expect(try Data(contentsOf: url.appendingPathComponent(relative)) == Data([9]))
    }

    /// The downloader stores through the package it was given, so a coordinated package
    /// coordinates its writes too.
    @Test func downloaderWritesThroughTheCoordinator() async throws {
        let url = makeTempDir().appendingPathComponent("Stahování.leporelo")
        let coordinator = RecordingCoordinator()
        var album = emptyAlbum()
        album.photos["p1"] = Photo(id: "p1", sourceIdentifier: "src-p1", capturedAt: Date(timeIntervalSince1970: 1),
                                   timeZoneSeconds: 0, location: nil, pixelWidth: 4, pixelHeight: 3,
                                   kind: .photo, analysis: nil, isSelected: true, dayKey: nil, placeName: nil,
                                   seriesID: nil, originalState: .missing, deletedInSource: false)
        let package = try ProjectPackage.create(at: url, album: album).coordinated(by: coordinator)
        let downloader = OriginalsDownloader(source: FakePhotoSource(), package: package)
        await downloader.enqueue(["p1"])
        let snapshot = album
        await downloader.run(album: { snapshot }, onStateChange: { _, _ in })
        #expect(coordinator.urls.count == 1)
        #expect(coordinator.urls.first?.deletingLastPathComponent().lastPathComponent == "originals")
    }
}
