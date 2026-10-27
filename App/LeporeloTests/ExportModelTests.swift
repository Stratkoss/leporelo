import CoreGraphics
import Foundation
import PDFKit
import Testing
import LeporeloCore
@testable import Leporelo

private let day1 = DayKey(year: 2026, month: 6, day: 18)
private let day2 = DayKey(year: 2026, month: 6, day: 19)

private func photo(_ id: String, day: DayKey, minute: Int, selected: Bool = true) -> Photo {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                  hour: 9, minute: minute))!
    return Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: date, timeZoneSeconds: 0, location: nil,
                 pixelWidth: 6000, pixelHeight: 4500, kind: .photo,
                 analysis: PhotoAnalysis(aesthetic: 0.3 + Double(minute % 5) * 0.1, sharpness: 500, isUtility: false,
                                         faceRects: [], closedEyes: false, featurePrint: nil),
                 isSelected: selected, dayKey: day, placeName: nil, seriesID: nil,
                 originalState: .stored(relativePath: "originals/\(id).jpg"), deletedInSource: false)
}

/// Canva A4 landscape with a lax page-count rule (drafts are not padded); unverified by default,
/// so the "Rozměry formátu nejsou ověřené" warning is there.
private func laxGeometry(verified: Bool = false) throws -> PageGeometry {
    var (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
    profile.pageCount = PageCountRule(min: 2, max: nil, multipleOf: 2)
    profile.verified = verified
    return PageGeometry(format: format, profile: profile)
}

/// Two days of photos plus one unselected photo ("u"), drafted, every text filled.
private func draftedAlbum() throws -> Album {
    let photos = (0..<5).map { photo("a\($0)", day: day1, minute: $0) }
        + (0..<3).map { photo("b\($0)", day: day2, minute: $0) }
        + [photo("u", day: day2, minute: 30, selected: false)]
    let album = Album(formatVersion: Album.currentFormatVersion, id: "album-1", title: "Amalfi",
                      supplierProfileID: "canva-photobook", formatID: "landscape-a4", world: Workflow.world,
                      cover: nil, spreads: [], photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
                      source: nil, createdAt: Date(timeIntervalSince1970: 1_000))
    let g = try laxGeometry()
    var drafted = Workflow.draft(album: album, profile: g.profile, format: g.format)
    // Fill every text so only the warnings a test asks for are there.
    for s in drafted.spreads.indices {
        for t in drafted.spreads[s].texts.indices where drafted.spreads[s].texts[t].text.isEmpty {
            drafted.spreads[s].texts[t].text = "Text"
        }
    }
    return drafted
}

/// One solid colour for every photo, optionally slow (to cancel mid-export).
private struct FakeImageProvider: ImageProvider {
    var delay: Duration?
    func image(for photoID: PhotoID, minPixelWidth: Int) async -> CGImage? {
        if let delay { try? await Task.sleep(for: delay) }
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return ctx.makeImage()
    }
}

@MainActor
private func makeModel(_ album: Album? = nil, verified: Bool = false, images: FakeImageProvider = .init(),
                       onJump: (@MainActor (String, String?) -> Void)? = nil) throws -> (ExportModel, AlbumStore) {
    let album = try album ?? draftedAlbum()
    let url = makeTempDir().appendingPathComponent("Export.leporelo")
    let package = try ProjectPackage.create(at: url, album: album)
    let store = AlbumStore(album: album, package: package)
    let g = try laxGeometry(verified: verified)
    let model = ExportModel(store: store, geometry: { g }, runner: .pdf(images: { _ in images }),
                            onJump: onJump)
    model.preflightDebounce = .milliseconds(10)
    return (model, store)
}

/// Polls the main actor until `condition` holds (at most ~3 s).
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func firstFrame(_ album: Album) -> (spread: String, frame: String) {
    let s = album.spreads.first { $0.frames.contains { $0.photoID != nil } }!
    return (s.id, s.frames.first { $0.photoID != nil }!.id)
}

@MainActor
struct ExportModelTests {
    // MARK: Gate

    @Test func canExportFalseWithErrors() async throws {
        let (model, store) = try makeModel()
        await model.runPreflight().value
        model.acceptedWarnings = true
        #expect(model.canExport)

        let f = firstFrame(store.album)
        try store.applyWithoutUndo(.setFramePhoto(spreadID: f.spread, frameID: f.frame, photoID: nil))
        await model.runPreflight().value
        model.acceptedWarnings = true
        #expect(Preflight.hasErrors(model.issues))
        #expect(!model.canExport)
    }

    @Test func warningsRequireAcceptance() async throws {
        let (model, _) = try makeModel()
        await model.runPreflight().value
        #expect(!Preflight.hasErrors(model.issues))
        #expect(model.issues.contains { $0.id == "unverified" && $0.severity == .warning })
        #expect(!model.acceptedWarnings)
        #expect(!model.canExport)
        model.acceptedWarnings = true
        #expect(model.canExport)
    }

    @Test func noWarningsNeedNoAcceptance() async throws {
        let (model, _) = try makeModel(verified: true)
        await model.runPreflight().value
        #expect(model.issues.isEmpty)
        #expect(model.canExport)
    }

    @Test func acceptanceResetsWhenWarningsChange() async throws {
        let (model, store) = try makeModel()
        await model.runPreflight().value
        model.acceptedWarnings = true
        // Same warnings again: acceptance stays.
        await model.runPreflight().value
        #expect(model.acceptedWarnings)
        // A new warning (a selected photo that is not in the album) must be accepted again.
        try store.applyWithoutUndo(.setSelected("u", true))
        await model.runPreflight().value
        #expect(model.issues.contains { $0.id == "unplacedSelected" })
        #expect(!model.acceptedWarnings)
        #expect(!model.canExport)
    }

    @Test func waitingForOriginalsLabelAndCount() async throws {
        var album = try draftedAlbum()
        let placed = album.placedPhotoIDs.sorted()
        album.photos[placed[0]]?.originalState = .missing
        album.photos[placed[1]]?.originalState = .downloading
        album.photos[placed[2]]?.originalState = .unavailable
        album.photos["u"]?.originalState = .missing  // not in the album: not waited for
        let (model, _) = try makeModel(album)
        await model.runPreflight().value
        model.acceptedWarnings = true
        #expect(model.waitingForOriginals == 2)
        #expect(model.exportButtonTitle == "Čekám na originály (2)")
        #expect(!model.canExport)
        #expect(model.rows.contains { $0.text == "Originál není dostupný" && $0.issue.severity == .error })
    }

    @Test func unavailableOriginalIsNotWaiting() async throws {
        var album = try draftedAlbum()
        album.photos[album.placedPhotoIDs.sorted()[0]]?.originalState = .unavailable
        let (model, _) = try makeModel(album)
        await model.runPreflight().value
        #expect(model.waitingForOriginals == 0)
        #expect(model.exportButtonTitle == "Exportovat pro Canva")
        #expect(!model.canExport)
    }

    @Test func titleFollowsProfile() throws {
        let (model, _) = try makeModel()
        #expect(model.title == "Exportovat pro Canva")
        var profile = try laxGeometry().profile
        profile.name = "Saal Digital – fotokniha"
        #expect(ExportLogic.supplierShortName(profile) == "Saal")
    }

    @Test func spreadRowsNameTheSpreadAndJump() async throws {
        var jumped: [(String, String?)] = []
        let (model, store) = try makeModel(onJump: { jumped.append(($0, $1)) })
        let f = firstFrame(store.album)
        let index = store.album.spreads.firstIndex { $0.id == f.spread }!
        try store.applyWithoutUndo(.setFramePhoto(spreadID: f.spread, frameID: f.frame, photoID: nil))
        await model.runPreflight().value
        let row = try #require(model.rows.first { $0.issue.id.hasPrefix("emptyFrame:") })
        #expect(row.place == "Dvoustrana \(index + 1)")
        #expect(row.canJump)
        model.jump(to: row)
        #expect(jumped.count == 1)
        #expect(jumped.first?.0 == f.spread)
        #expect(jumped.first?.1 == f.frame)

        let albumLevel = try #require(model.rows.first { $0.issue.id == "unverified" })
        #expect(albumLevel.place == nil)
        #expect(!albumLevel.canJump)
        model.jump(to: albumLevel)
        #expect(jumped.count == 1)
    }

    @Test func preflightRerunsWhenAlbumChanges() async throws {
        let (model, store) = try makeModel()
        model.startObserving()
        defer { model.close() }
        await waitUntil { model.hasPreflight }
        #expect(!Preflight.hasErrors(model.issues))
        let f = firstFrame(store.album)
        try store.applyWithoutUndo(.setFramePhoto(spreadID: f.spread, frameID: f.frame, photoID: nil))
        await waitUntil { Preflight.hasErrors(model.issues) }
        #expect(Preflight.hasErrors(model.issues))
        #expect(model.issuesRevision == store.revision)
    }

    // MARK: Location

    @Test func destinationInsidePackageRejected() throws {
        let dir = makeTempDir()
        let package = dir.appendingPathComponent("Trip.leporelo", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("originals"),
                                                withIntermediateDirectories: true)
        #expect(ExportLogic.destinationProblem(package, packageURL: package) != nil)
        #expect(ExportLogic.destinationProblem(package.appendingPathComponent("originals"), packageURL: package) != nil)
        #expect(ExportLogic.destinationProblem(package.appendingPathComponent("thumbs/x"), packageURL: package) != nil)
        #expect(ExportLogic.destinationProblem(dir, packageURL: package) == nil)
        #expect(ExportLogic.destinationProblem(dir.appendingPathComponent("Trip.leporelo export"),
                                               packageURL: package) == nil)
        // Through a symlink and a non-standard path.
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        #expect(ExportLogic.destinationProblem(link.appendingPathComponent("originals"), packageURL: package) != nil)
        #expect(ExportLogic.destinationProblem(URL(fileURLWithPath: package.path + "/originals/.."),
                                               packageURL: package) != nil)
        #expect(ExportLogic.destinationProblem(URL(fileURLWithPath: package.path + "/.."),
                                               packageURL: package) == nil)
    }

    @Test func existingExportFilesDetected() throws {
        let dir = makeTempDir()
        #expect(ExportLogic.existingExportFiles(in: dir).isEmpty)
        try Data().write(to: dir.appendingPathComponent("cover.pdf"))
        try Data().write(to: dir.appendingPathComponent("co-nahrat-kam.txt"))
        try Data().write(to: dir.appendingPathComponent("jine.pdf"))
        #expect(ExportLogic.existingExportFiles(in: dir) == ["cover.pdf", "co-nahrat-kam.txt"])
        try Data().write(to: dir.appendingPathComponent("pages.pdf"))
        #expect(ExportLogic.existingExportFiles(in: dir) == ["pages.pdf", "cover.pdf", "co-nahrat-kam.txt"])
    }

    // MARK: Export

    @Test func exportWritesFilesViaCore() async throws {
        let (model, store) = try makeModel()
        await model.runPreflight().value
        model.acceptedWarnings = true
        let dir = makeTempDir().appendingPathComponent("Vystup", isDirectory: true)
        let result = try await model.export(to: dir)
        let doc = try #require(PDFDocument(url: result.pagesURL))
        #expect(doc.pageCount == store.album.spreads.count * 2)
        #expect(result.pageCount == doc.pageCount)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pages.pdf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cover.pdf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("co-nahrat-kam.txt").path))
        guard case let .finished(summary) = model.phase else {
            Issue.record("not finished: \(model.phase)")
            return
        }
        #expect(summary.headline == "Exportováno: pages.pdf (\(CzechPlural.pages(doc.pageCount))), cover.pdf")
        #expect(!summary.headline.contains("!"))
        #expect(summary.folderPath == dir.path)
        #expect(summary.steps.first?.hasPrefix("1. ") == true)
        #expect(!model.isExporting)
    }

    @Test func exportFlushesPendingEditsBeforeSnapshot() async throws {
        let (model, store) = try makeModel()
        await model.runPreflight().value
        model.acceptedWarnings = true
        var flushed = false
        store.addPendingEditsFlusher { flushed = true }
        _ = try await model.export(to: makeTempDir())
        #expect(flushed)
    }

    @Test func exportRefusesWhenAlbumGotErrorsSincePreflight() async throws {
        let (model, store) = try makeModel()
        await model.runPreflight().value
        model.acceptedWarnings = true
        #expect(model.canExport)
        let f = firstFrame(store.album)
        try store.applyWithoutUndo(.setFramePhoto(spreadID: f.spread, frameID: f.frame, photoID: nil))
        let dir = makeTempDir()
        await #expect(throws: ExportFailure.self) { try await model.export(to: dir) }
        #expect(Preflight.hasErrors(model.issues))
        #expect(model.issuesRevision == store.revision)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pages.pdf").path))
    }

    @Test func exportRefusesWhenNewWarningIsNotAccepted() async throws {
        let (model, store) = try makeModel()
        await model.runPreflight().value
        model.acceptedWarnings = true
        try store.applyWithoutUndo(.setSelected("u", true))
        let dir = makeTempDir()
        await #expect(throws: ExportFailure.self) { try await model.export(to: dir) }
        #expect(!model.acceptedWarnings)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pages.pdf").path))
    }

    @Test func cancelReturnsToIdleWithNoFiles() async throws {
        let (model, store) = try makeModel(images: FakeImageProvider(delay: .milliseconds(40)))
        await model.runPreflight().value
        model.acceptedWarnings = true
        let dir = makeTempDir()
        model.startExport(to: dir)
        #expect(model.isExporting)
        await waitUntil {
            if case let .exporting(done, _) = model.phase { return done >= 1 }
            return false
        }
        if case let .exporting(_, total) = model.phase {
            #expect(total == store.album.spreads.count * 2 + 1)
        } else {
            Issue.record("no progress: \(model.phase)")
        }
        model.cancelExport()
        await model.exportTask?.value
        #expect(model.phase == .idle)
        #expect(model.notice == "Export byl zrušen")
        #expect(!model.isExporting)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty)
    }

    @Test func failuresMapToCzech() {
        let pre = ExportLogic.failure(for: ExportError.preflightFailed([]))
        #expect(pre.message == "Kontrola před exportem našla chyby. Opravte je a zkuste to znovu.")
        #expect(ExportLogic.failure(for: ExportError.unsupportedCoverMode).message.contains("obálk"))
        let write = ExportLogic.failure(for: ExportError.cannotWrite("pages.pdf"))
        #expect(write.message.contains("pages.pdf"))
        struct Boom: Error {}
        let other = ExportLogic.failure(for: Boom())
        #expect(other.message == "Export se nepodařil.")
        #expect(other.detail?.isEmpty == false)
        #expect(other.errorDescription == other.message)
        for f in [pre, write, other] { #expect(!f.message.contains("!")) }
    }
}
