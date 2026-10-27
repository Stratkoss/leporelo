import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Testing
@testable import LeporeloCore

/// Returns the same image for every photo and records the requested widths.
private final class FixedProvider: ImageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(PhotoID, Int)] = []
    let image: CGImage
    init(image: CGImage) { self.image = image }
    var recorded: [(PhotoID, Int)] { lock.withLock { calls } }
    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? {
        lock.withLock { calls.append((photoID, minPixelWidth)) }
        return image
    }
}

/// Display P3 image with an alpha channel, as a Photos original decoded to RGBA would be.
private func p3Image(width: Int = 1200, height: Int = 900) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    return ctx.makeImage()!
}

private enum Fx {
    static func setup(verified: Bool = true, pageMode: PageMode = .singlePages,
                      coverMode: CoverMode = .frontOnly) throws -> (SupplierProfile, BookFormat) {
        var (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        p.verified = verified
        p.pageMode = pageMode
        p.coverMode = coverMode
        return (p, f)
    }

    static func photo(_ id: String, state: OriginalState = .stored(relativePath: "o.jpg")) -> Photo {
        Photo(id: id, sourceIdentifier: id, capturedAt: Date(timeIntervalSince1970: 0), timeZoneSeconds: 0,
              location: nil, pixelWidth: 1200, pixelHeight: 900, kind: .photo, analysis: nil,
              isSelected: true, dayKey: nil, placeName: nil, seriesID: nil, originalState: state,
              deletedInSource: false)
    }

    static func spread(_ i: Int) -> Spread {
        Spread(id: "s\(i)", kind: .gallery, templateID: "t", dayKey: nil,
               frames: [Frame(id: "f1", rect: Rect(x: 20, y: 20, width: 80, height: 60), photoID: "p1",
                              offset: Point(x: 0, y: 0), zoom: 1),
                        Frame(id: "f2", rect: Rect(x: 320, y: 20, width: 80, height: 60), photoID: "p2",
                              offset: Point(x: 0, y: 0), zoom: 1)],
               texts: [TextBox(id: "c", rect: Rect(x: 20, y: 100, width: 100, height: 10), role: .caption,
                               text: "Popisek \(i)")],
               manuallyEdited: false)
    }

    static func cover() -> Cover {
        let front = Spread(id: "cover-front", kind: .intro, templateID: "cover-front", dayKey: nil,
                           frames: [Frame(id: "photo1", rect: Rect(x: 20, y: 20, width: 80, height: 60),
                                          photoID: "p1", offset: Point(x: 0, y: 0), zoom: 1)],
                           texts: [TextBox(id: "t", rect: Rect(x: 20, y: 120, width: 200, height: 20),
                                           role: .title, text: "Řecko 2026")],
                           manuallyEdited: false)
        let back = Spread(id: "cover-back", kind: .blank, templateID: "blank", dayKey: nil,
                          frames: [], texts: [], manuallyEdited: false)
        return Cover(front: front, back: back)
    }

    static func album(spreads: Int = 10, p1: OriginalState = .stored(relativePath: "o.jpg"),
                      cover: Cover? = cover()) -> Album {
        let photos = [photo("p1", state: p1), photo("p2")]
        return Album(formatVersion: 1, id: "a", title: "Řecko 2026", supplierProfileID: "canva-photobook",
                     formatID: "landscape-a4", world: "journal-gallery", cover: cover,
                     spreads: (1...spreads).map(spread(_:)),
                     photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }), source: nil,
                     createdAt: Date(timeIntervalSince1970: 0))
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("leporelo-export-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }

    static func exporter(album: Album = album(), verified: Bool = true, pageMode: PageMode = .singlePages,
                         coverMode: CoverMode = .frontOnly,
                         provider: ImageProvider = FixedProvider(image: p3Image())) throws -> PDFExporter {
        let (p, f) = try setup(verified: verified, pageMode: pageMode, coverMode: coverMode)
        return PDFExporter(album: album, profile: p, format: f, images: provider)
    }

    static func pt(_ mm: Double) -> Double { mm * 72 / 25.4 }
}

/// Dictionaries of all image XObjects in a PDF written by Quartz (object dictionaries are not
/// compressed; only stream contents are).
private func imageDictionaries(_ data: Data) -> [String] {
    let text = String(data: data, encoding: .isoLatin1) ?? ""
    var result: [String] = []
    var rest = text[...]
    while let objRange = rest.range(of: " obj") {
        let after = rest[objRange.upperBound...]
        let end = [after.range(of: "stream")?.lowerBound, after.range(of: "endobj")?.lowerBound]
            .compactMap { $0 }.min() ?? after.endIndex
        let dict = String(after[..<end])
        if dict.contains("/Subtype /Image") { result.append(dict) }
        rest = after[end...]
    }
    return result
}

@Suite struct PDFExporterTests {
    @Test func singlePagesPDFHasTwoPagesPerSpread() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter().export(to: dir)
        let doc = try #require(PDFDocument(url: result.pagesURL))
        #expect(doc.pageCount == 20)
        #expect(result.pageCount == 20)
        #expect(result.pagesURL.lastPathComponent == "pages.pdf")
        #expect(result.pagesURL.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Řecko 2026")
    }

    @Test func pageSizeIncludesBleed() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir)
        let doc = try #require(PDFDocument(url: result.pagesURL))
        for i in 0..<doc.pageCount {
            let box = try #require(doc.page(at: i)).bounds(for: .mediaBox)
            #expect(abs(box.width - Fx.pt(303)) <= 0.5)
            #expect(abs(box.height - Fx.pt(216)) <= 0.5)
        }
    }

    @Test func spreadsModeHasOnePagePerSpreadWithSpreadBleedSize() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(album: Fx.album(spreads: 10), pageMode: .spreads).export(to: dir)
        let doc = try #require(PDFDocument(url: result.pagesURL))
        #expect(doc.pageCount == 10)
        #expect(result.pageCount == 10)
        let box = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - Fx.pt(600)) <= 0.5)
        #expect(abs(box.height - Fx.pt(216)) <= 0.5)
    }

    @Test func imagesEmbeddedAsJPEG() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir)
        for url in [result.pagesURL, try #require(result.coverURL)] {
            let data = try Data(contentsOf: url)
            #expect(data.range(of: Data("DCTDecode".utf8)) != nil)
            let images = imageDictionaries(data)
            #expect(!images.isEmpty)
            for dict in images {
                #expect(dict.contains("/Filter /DCTDecode"), "image XObject not DCT: \(dict)")
                #expect(!dict.contains("FlateDecode"), "image XObject re-encoded: \(dict)")
                #expect(!dict.contains("/SMask"), "image has an alpha mask: \(dict)")
            }
        }
    }

    @Test func imagesAreResampledToPlacedSizeInSRGB() async throws {
        let base = FixedProvider(image: p3Image(width: 4000, height: 3000))
        var album = Fx.album(spreads: 1)
        album.photos["p1"]?.pixelWidth = 4000
        album.photos["p1"]?.pixelHeight = 3000
        let provider = ExportImageProvider(base: base, album: album, jpegQuality: 0.92)
        // Frame 80 x 60 mm, 4:3 photo: the cover-fit image is 80 mm wide -> ceil(80 / 25.4 * 300) = 945 px.
        let img = try #require(await provider.image(for: "p1", minPixelWidth: 945))
        #expect(img.width == 945)
        #expect(img.height == 709)
        #expect(img.colorSpace?.name == CGColorSpace.sRGB)
        #expect(img.alphaInfo == .none || img.alphaInfo == .noneSkipLast || img.alphaInfo == .noneSkipFirst)
        // The original was requested.
        #expect((base.recorded.first?.1 ?? 0) >= 4000)
        // Never upscaled above the source.
        let small = ExportImageProvider(base: FixedProvider(image: p3Image(width: 600, height: 450)),
                                        album: Fx.album(spreads: 1), jpegQuality: 0.92)
        let s = try #require(await small.image(for: "p2", minPixelWidth: 945))
        #expect(s.width == 600)
    }

    @Test func wideImageUsesCoverFitWidthNotFrameWidth() async throws {
        let (p, f) = try Fx.setup()
        var album = Fx.album(spreads: 1)
        // Square 60 x 60 mm frame, 2:1 photo: the renderer's hint is the drawn width, 120 mm ->
        // ceil(120 / 25.4 * 300) = 1418 px, and the export provider resamples to exactly that.
        album.spreads[0].frames[0].rect = Rect(x: 20, y: 20, width: 60, height: 60)
        album.photos["p1"]?.pixelWidth = 4000
        album.photos["p1"]?.pixelHeight = 2000
        let base = FixedProvider(image: p3Image(width: 4000, height: 2000))
        let provider = ExportImageProvider(base: base, album: album, jpegQuality: 0.92)
        let renderer = SpreadRenderer(album: album, geometry: PageGeometry(format: f, profile: p), images: provider)
        let options = RenderOptions(includeBleed: true, pixelsPerMM: 72 / 25.4, imageDPI: 300)
        let loaded = await renderer.loadImages(for: album.spreads[0], options: options, area: .page)
        #expect(try #require(loaded["p1"]).width == 1418)
    }

    @Test func preflightErrorBlocksExport() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = try Fx.exporter(album: Fx.album(p1: .missing))
        await #expect {
            _ = try await exporter.export(to: dir)
        } throws: { error in
            guard case ExportError.preflightFailed(let issues) = error else { return false }
            return Preflight.hasErrors(issues)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pages.pdf").path))
    }

    @Test func warningsDoNotBlockExport() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(verified: false).export(to: dir)
        #expect(result.pageCount == 20)
    }

    @Test func readmeMentionsFormatAndPages() async throws {
        let (p, f) = try Fx.setup(verified: false)
        let text = ExportInstructions.readme(album: Fx.album(), profile: p, format: f, pageCount: 20)
        #expect(text.contains(f.name))
        #expect(text.contains("20 stran"))
        #expect(text.contains("Řecko 2026"))
        for step in p.uploadSteps { #expect(text.contains(step)) }
        #expect(text.contains("Rozměry formátu nejsou ověřené, zkontrolujte je v Canvě"))
        let verified = ExportInstructions.readme(album: Fx.album(), profile: try Fx.setup().0, format: f, pageCount: 20)
        #expect(!verified.contains("nejsou ověřené"))

        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(verified: false).export(to: dir)
        #expect(result.readmeURL.lastPathComponent == "co-nahrat-kam.txt")
        let written = try String(contentsOf: result.readmeURL, encoding: .utf8)
        #expect(written == text)
    }

    @Test func coverWrittenWhenFrontOnly() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir)
        let url = try #require(result.coverURL)
        #expect(url.lastPathComponent == "cover.pdf")
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 1)
        let box = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - Fx.pt(303)) <= 0.5)
        #expect(abs(box.height - Fx.pt(216)) <= 0.5)
        #expect(doc.string?.contains("Řecko 2026") == true)
    }

    @Test func noCoverWhenCoverModeNone() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(album: Fx.album(cover: nil), coverMode: .none).export(to: dir)
        #expect(result.coverURL == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cover.pdf").path))
    }

    @Test func wrapWithSpineIsUnsupported() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = try Fx.exporter(coverMode: .wrapWithSpine)
        await #expect(throws: ExportError.unsupportedCoverMode) {
            _ = try await exporter.export(to: dir)
        }
    }

    @Test func progressReportsEveryPage() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Recorder()
        _ = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir) { done, total in
            seen.add(done, total)
        }
        let values = seen.values
        // 20 inner pages + 1 cover page.
        #expect(values.map(\.0) == Array(1...21))
        #expect(values.allSatisfy { $0.1 == 21 })
    }

    @Test func overwritesExistingFilesAndLeavesNoTempFiles() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("pages.pdf"))
        let result = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir)
        #expect(PDFDocument(url: result.pagesURL)?.pageCount == 20)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["co-nahrat-kam.txt", "cover.pdf", "pages.pdf"])
    }

    @Test func cancelledExportKeepsPreviousFilesAndLeavesNoTempFiles() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("pages.pdf"))
        // Cancels the exporting task from inside the 3rd image request, i.e. mid-render.
        let provider = CancellingProvider(image: p3Image(), cancelAt: 3)
        let exporter = try Fx.exporter(album: Fx.album(spreads: 10), provider: provider)
        await #expect(throws: CancellationError.self) { _ = try await exporter.export(to: dir) }
        #expect(provider.calls >= 3)
        #expect(provider.calls < 20)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["pages.pdf"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("pages.pdf")) == Data("old".utf8))
    }

    @Test func pagesAreLeftThenRight() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir)
        let doc = try #require(PDFDocument(url: result.pagesURL))
        // The caption "Popisek i" of spread i sits on its left page only.
        for i in 1...10 {
            let left = doc.page(at: 2 * (i - 1))?.string ?? ""
            let right = doc.page(at: 2 * (i - 1) + 1)?.string ?? ""
            #expect(left.contains("Popisek \(i)"), "page \(2 * (i - 1))")
            #expect(!right.contains("Popisek"), "page \(2 * (i - 1) + 1)")
        }
    }

    @Test func staleTempFoldersAreSwept() async throws {
        let dir = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let stale = dir.appendingPathComponent(".leporelo-export-stale", isDirectory: true)
        let fresh = dir.appendingPathComponent(".leporelo-export-fresh", isDirectory: true)
        let other = dir.appendingPathComponent("holiday-old", isDirectory: true)
        for d in [stale, fresh, other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600)
        try fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: stale.path)
        try fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: other.path)
        _ = try await Fx.exporter(album: Fx.album(spreads: 10)).export(to: dir)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: other.path))
    }
}

/// A JPEG of `width` x `height`, one colour.
private func jpegData(width: Int, height: Int) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, p3Image(width: width, height: height), nil)
    precondition(CGImageDestinationFinalize(dest))
    return data as Data
}

/// A real package with 2000 x 1500 originals and 1024 px thumbnails for p1 and p2, frames large
/// enough (140 x 105 mm, ~1654 px at 300 DPI) that the thumbnail is not enough for print.
private func packageAlbum(in dir: URL) throws -> (ProjectPackage, Album) {
    var album = Fx.album(spreads: 10)
    for id in ["p1", "p2"] {
        album.photos[id]?.pixelWidth = 2000
        album.photos[id]?.pixelHeight = 1500
    }
    for s in album.spreads.indices {
        album.spreads[s].frames[0].rect = Rect(x: 20, y: 20, width: 140, height: 105)
        album.spreads[s].frames[1].rect = Rect(x: 320, y: 20, width: 140, height: 105)
    }
    let package = try ProjectPackage.create(at: dir.appendingPathComponent("a.leporelo"), album: album)
    for id in ["p1", "p2"] {
        let rel = try package.storeOriginal(data: jpegData(width: 2000, height: 1500), ext: "jpg", for: id)
        try package.storeThumbnail(p3Image(width: 1024, height: 768), for: id)
        album.photos[id]?.originalState = .stored(relativePath: rel)
    }
    try package.save(album)
    return (package, album)
}

@Suite struct ExportFailsClosedTests {
    private func expectMissingOriginals(_ broken: (ProjectPackage, URL) throws -> Void) async throws {
        let root = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (package, album) = try packageAlbum(in: root)
        try broken(package, try #require(package.originalURL(for: "p1", album: album)))
        let out = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: out.appendingPathComponent("pages.pdf"))
        let (p, f) = try Fx.setup()
        let exporter = PDFExporter(album: album, profile: p, format: f,
                                   images: PackageImageProvider(package: package, album: album))
        #expect(!Preflight.hasErrors(Preflight.check(album: album, profile: p, format: f)))
        await #expect(throws: ExportError.missingOriginals(["p1"])) { _ = try await exporter.export(to: out) }
        // Nothing moved into place, the previous file is untouched, no temp folder is left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["pages.pdf"])
        #expect(try Data(contentsOf: out.appendingPathComponent("pages.pdf")) == Data("old".utf8))
    }

    @Test func deletedOriginalFailsTheExport() async throws {
        try await expectMissingOriginals { _, url in try FileManager.default.removeItem(at: url) }
    }

    @Test func corruptOriginalFailsTheExport() async throws {
        try await expectMissingOriginals { _, url in
            try Data(repeating: 0x5A, count: 4096).write(to: url)
        }
    }

    // A TRUNCATED JPEG with a valid header is not detected: ImageIO decodes it at full size (the
    // missing part grey) and reports it complete. Originals are written atomically and synced
    // (`ProjectPackage.storeOriginal`), so only an outside edit can truncate one.

    @Test func intactPackageExports() async throws {
        let root = Fx.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (package, album) = try packageAlbum(in: root)
        let (p, f) = try Fx.setup()
        let result = try await PDFExporter(album: album, profile: p, format: f,
                                           images: PackageImageProvider(package: package, album: album))
            .export(to: root.appendingPathComponent("export"))
        #expect(result.pageCount == 20)
    }

    @Test func missingOriginalsMessageIsCzech() {
        #expect(ExportError.missingOriginals(["a"]).localizedDescription
                == "Originál 1 fotky v projektu chybí nebo nejde přečíst, export se nezapsal")
        #expect(ExportError.missingOriginals(["a", "b", "c"]).localizedDescription
                == "Originály 3 fotek v projektu chybí nebo nejdou přečíst, export se nezapsal")
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int)] = []
    func add(_ a: Int, _ b: Int) { lock.withLock { items.append((a, b)) } }
    var values: [(Int, Int)] { lock.withLock { items } }
}

/// Cancels the current task during the `cancelAt`-th image request.
private final class CancellingProvider: ImageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let image: CGImage
    let cancelAt: Int
    init(image: CGImage, cancelAt: Int) {
        self.image = image
        self.cancelAt = cancelAt
    }
    var calls: Int { lock.withLock { count } }
    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? {
        let n = lock.withLock { () -> Int in
            count += 1
            return count
        }
        if n == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
        return image
    }
}
