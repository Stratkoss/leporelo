import Foundation
import PDFKit
import Testing
@testable import LeporeloCore

/// Phase 1 end to end: a folder of JPEGs -> project package -> analysis -> recommendations ->
/// draft -> originals -> preflight -> PDF, through the same `Workflow` steps the CLI uses.
@Suite struct EndToEndTests {
    @Test func folderToPDFEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leporelo-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("photos", isDirectory: true)

        // 30 photos, 3 local days (+02:00, explicit offset => grouping independent of the Mac's zone),
        // 10 per day, 25 min apart from 09:00 local. 3000x2000 px: enough for 150+ DPI full-page frames.
        let firstDay = 1_782_864_000.0 - 7200 + 9 * 3600  // 2026-07-01 09:00 +02:00
        for day in 0..<3 {
            for i in 0..<10 {
                let date = Date(timeIntervalSince1970: firstDay + Double(day) * 86_400 + Double(i) * 1500)
                let gps = GeoPoint(latitude: 40.6 + Double(day) * 0.1, longitude: 14.6 + Double(i) * 0.01)
                try JPEGFixtures.write(to: folder.appendingPathComponent(String(format: "d%d-%02d.jpg", day, i)),
                                       size: (3000, 2000), date: date, offset: "+02:00", gps: gps,
                                       scene: day * 10 + i)
            }
        }

        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        let source = FolderPhotoSource(folder: folder)
        let query = SourceQuery.dateRange(start: .distantPast, end: .distantFuture)
        let package = try Workflow.createPackage(at: root.appendingPathComponent("Výlet.leporelo"), title: "Výlet",
                                                 profileID: profile.id, formatID: format.id)

        var album = try await Workflow.buildAlbum(
            from: source, query: query, title: "Výlet", profileID: profile.id, formatID: format.id,
            package: package, resolver: InMemoryPlaceResolver([]))
        #expect(album.photos.count == 30)
        #expect(Set(album.photos.values.compactMap(\.dayKey)) ==
                [DayKey(year: 2026, month: 7, day: 1), DayKey(year: 2026, month: 7, day: 2),
                 DayKey(year: 2026, month: 7, day: 3)])

        album = await Workflow.analyze(album: album, source: source, package: package)
        #expect(album.photos.values.allSatisfy { $0.analysis != nil })

        album = Workflow.recommendAndDraft(album: album, profile: profile, format: format)
        let selected = album.photos.values.filter(\.isSelected)
        #expect(selected.count == 3 * Recommender.targetCount(photoCount: 10))

        album = await Workflow.downloadSelectedOriginals(album: album, source: source, package: package)
        try package.save(album)
        for photo in album.photos.values {
            if photo.isSelected {
                guard case .stored = photo.originalState,
                      let url = package.originalURL(for: photo.id, album: album) else {
                    Issue.record("selected photo \(photo.sourceIdentifier) not stored: \(photo.originalState)")
                    continue
                }
                #expect(FileManager.default.fileExists(atPath: url.path))
            } else {
                #expect(photo.originalState == .missing)  // unselected originals are not copied
            }
        }

        let issues = Preflight.check(album: album, profile: profile, format: format)
        #expect(!Preflight.hasErrors(issues), "preflight errors: \(issues.filter { $0.severity == .error })")

        let exportDir = root.appendingPathComponent("export", isDirectory: true)
        let result = try await PDFExporter(album: album, profile: profile, format: format,
                                           images: PackageImageProvider(package: package, album: album))
            .export(to: exportDir)
        let pagesURL = exportDir.appendingPathComponent(PDFExporter.pagesFileName)
        #expect(result.pagesURL.standardizedFileURL == pagesURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: pagesURL.path))
        let pdf = try #require(PDFDocument(url: pagesURL))
        #expect(pdf.pageCount == 2 * album.spreads.count)
        #expect(pdf.pageCount == result.pageCount)
        #expect(profile.pageCount.isSatisfied(by: pdf.pageCount))
        #expect(PDFDocument(url: exportDir.appendingPathComponent(PDFExporter.coverFileName))?.pageCount == 1)
    }
}
