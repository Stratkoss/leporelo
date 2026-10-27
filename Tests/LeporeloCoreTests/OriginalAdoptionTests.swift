import Foundation
import Testing
@testable import LeporeloCore

private func photo(_ id: String, _ state: OriginalState) -> Photo {
    Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: 1), timeZoneSeconds: 0,
          location: nil, pixelWidth: 4, pixelHeight: 3, kind: .photo, analysis: nil, isSelected: true,
          dayKey: nil, placeName: nil, seriesID: nil, originalState: state, deletedInSource: false)
}

private func album(_ photos: [Photo]) -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "a", title: "A", supplierProfileID: "saal",
          formatID: "20x20", world: "journal-gallery", cover: nil, spreads: [],
          photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }), source: nil,
          createdAt: Date(timeIntervalSince1970: 1))
}

/// A file renamed into `originals/` is complete (atomic rename), so a photo whose state was never
/// recorded (work cancelled before its flush) adopts it instead of downloading again.
struct OriginalAdoptionTests {
    @Test func adoptsCompleteFilesByExactIDPrefix() {
        var a = album([photo("abc", .missing), photo("abcd", .downloading), photo("heic", .unavailable),
                       photo("empty", .missing), photo("none", .missing),
                       photo("kept", .stored(relativePath: "originals/kept.jpg")),
                       photo("zero", .stored(relativePath: "originals/zero.jpg"))])
        let files = ["abcd.jpg": 10, "heic.HEIC": 0, "heic.heic": 7, "empty.jpg": 0, "stray.txt": 5,
                     "abc.e.jpg": 3, ".tmp123.tmp": 9, "kept.jpg": 4, "zero.jpg": 0, "abc.png": 2]
        let changed = ProjectPackage.adoptOriginals(in: &a, fileSizes: files)

        #expect(a.photos["abc"]?.originalState == .stored(relativePath: "originals/abc.png"))  // not "abcd.jpg", not "abc.e.jpg"
        #expect(a.photos["abcd"]?.originalState == .stored(relativePath: "originals/abcd.jpg"))
        #expect(a.photos["heic"]?.originalState == .stored(relativePath: "originals/heic.heic"))  // non-empty one
        #expect(a.photos["empty"]?.originalState == .missing)   // zero-length is never adopted
        #expect(a.photos["none"]?.originalState == .missing)
        #expect(a.photos["kept"]?.originalState == .stored(relativePath: "originals/kept.jpg"))
        #expect(a.photos["zero"]?.originalState == .missing)    // a zero-length stored file is no original
        #expect(changed == ["abc", "abcd", "heic", "zero"])
    }

    @Test func listsTheOriginalsDirectory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString).leporelo")
        let package = try ProjectPackage.create(at: url, album: album([]))
        _ = try package.storeOriginal(data: Data([1, 2, 3]), ext: "jpg", for: "p1")
        FileManager.default.createFile(atPath: url.appendingPathComponent("originals/p2.jpg").path, contents: Data())
        try FileManager.default.createDirectory(at: url.appendingPathComponent("originals/dir.jpg"),
                                                withIntermediateDirectories: true)
        #expect(package.originalFileSizes() == ["p1.jpg": 3, "p2.jpg": 0])
    }

    @Test func severalExtensionsPickTheFirstName() {
        var a = album([photo("x", .missing)])
        ProjectPackage.adoptOriginals(in: &a, fileSizes: ["x.jpg": 1, "x.heic": 1, "x.HEIC": 1, "x.tiff": 1])
        #expect(a.photos["x"]?.originalState == .stored(relativePath: "originals/x.HEIC"))
    }

    @Test func idWithADotTakesItsOwnFile() {
        var a = album([photo("abc", .missing), photo("abc.e", .missing)])
        ProjectPackage.adoptOriginals(in: &a, fileSizes: ["abc.e.jpg": 3])
        #expect(a.photos["abc"]?.originalState == .missing)
        #expect(a.photos["abc.e"]?.originalState == .stored(relativePath: "originals/abc.e.jpg"))
    }

    /// 3 000 photos x 600 files: one index, not a sort per photo (was ~9 s in Debug).
    @Test func isFastWithThousandsOfPhotosAndFiles() {
        var a = album((0..<3000).map { photo("photo-\($0)", .missing) })
        var files: [String: Int] = [:]
        for i in 0..<600 { files["photo-\(i * 5).jpg"] = 1000 }
        let start = Date()
        let changed = ProjectPackage.adoptOriginals(in: &a, fileSizes: files)
        let elapsed = Date().timeIntervalSince(start)
        #expect(changed.count == 600)
        #expect(elapsed < 0.5, "adoptOriginals took \(elapsed) s")
    }
}
