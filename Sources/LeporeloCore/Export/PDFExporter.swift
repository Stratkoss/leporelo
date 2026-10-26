import CoreGraphics
import Foundation

public enum ExportError: Error, Equatable {
    /// Preflight found errors; the export did not start. Carries all issues (errors and warnings).
    case preflightFailed([PreflightIssue])
    /// `.wrapWithSpine` covers (Saal) are not built in v1.
    case unsupportedCoverMode
    /// The PDF context or a file could not be created.
    case cannotWrite(String)
}

public struct ExportResult: Sendable, Equatable {
    public var pagesURL: URL
    public var coverURL: URL?
    public var readmeURL: URL
    /// Number of pages in `pages.pdf`.
    public var pageCount: Int

    public init(pagesURL: URL, coverURL: URL?, readmeURL: URL, pageCount: Int) {
        self.pagesURL = pagesURL
        self.coverURL = coverURL
        self.readmeURL = readmeURL
        self.pageCount = pageCount
    }
}

/// Print PDF export per supplier profile (spec 6.5).
///
/// - Refuses with `ExportError.preflightFailed` when `Preflight` reports errors; warnings do not
///   block (the UI has the user accept them before calling `export`).
/// - `pageMode == .singlePages`: every spread becomes two PDF pages (left, right) rendered with
///   `SpreadRenderer.renderPage`, each `(w + 2b) × (h + 2b)` mm. `.spreads`: one PDF page per spread,
///   the size of `PageGeometry.spreadBleedRect`.
/// - `coverMode == .frontOnly`: `cover.pdf` with the front cover page (page size plus bleed).
///   `.none`: no cover. `.wrapWithSpine`: `ExportError.unsupportedCoverMode` (not in v1).
/// - Images go through `ExportImageProvider` (resampled to the placed size at `output.dpi`, sRGB,
///   JPEG at `output.jpegQuality`, embedded as DCT without recompression). Core Text embeds the
///   fonts (subsets) in the PDF.
/// - Files: `pages.pdf`, `cover.pdf`, `co-nahrat-kam.txt` in `directory` (created when missing).
///   Everything is written into a hidden temp folder in `directory` first and moved into place
///   only when complete, so a failed or cancelled export never replaces good files with partial
///   ones; the temp folder is always removed.
///
/// Whether Canva keeps the JPEG quality when it imports the PDF is not verified (spec 10). The
/// image pipeline is independent of the container, so a "JPG pages" alternative can reuse
/// `ExportImageProvider` and the renderer with a bitmap context later.
public struct PDFExporter: Sendable {
    public static let pagesFileName = "pages.pdf"
    public static let coverFileName = "cover.pdf"

    public let album: Album
    public let profile: SupplierProfile
    public let format: BookFormat
    public let images: ImageProvider

    public init(album: Album, profile: SupplierProfile, format: BookFormat, images: ImageProvider) {
        self.album = album
        self.profile = profile
        self.format = format
        self.images = images
    }

    public func export(to directory: URL,
                       progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ExportResult {
        if profile.coverMode == .wrapWithSpine { throw ExportError.unsupportedCoverMode }
        let issues = Preflight.check(album: album, profile: profile, format: format)
        if Preflight.hasErrors(issues) { throw ExportError.preflightFailed(issues) }
        try Task.checkCancellation()

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".leporelo-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }

        let provider = ExportImageProvider(base: images, album: album, profile: profile, format: format)
        let geometry = PageGeometry(format: format, profile: profile)
        let renderer = SpreadRenderer(album: album, geometry: geometry, images: provider)
        let options = RenderOptions(showGuides: false, includeBleed: true, pixelsPerMM: 72 / 25.4,
                                    imageDPI: Double(profile.output.dpi))

        let cover = profile.coverMode == .frontOnly ? album.cover?.front : nil
        let perSpread = profile.pageMode == .singlePages ? 2 : 1
        let pageCount = album.spreads.count * perSpread
        let total = pageCount + (cover == nil ? 0 : 1)
        var done = 0
        func step() {
            done += 1
            progress?(done, total)
        }

        // Inner pages.
        let b = profile.bleedMM
        let pageSize = CGSize(width: SpreadRenderer.points(fromMM: format.pageWidthMM + 2 * b),
                              height: SpreadRenderer.points(fromMM: format.pageHeightMM + 2 * b))
        let spreadSize = CGSize(width: SpreadRenderer.points(fromMM: geometry.spreadBleedRect.size.width),
                                height: SpreadRenderer.points(fromMM: geometry.spreadBleedRect.size.height))
        let tempPages = temp.appendingPathComponent(Self.pagesFileName)
        let pages = try PDFWriter(url: tempPages, title: album.title)
        for spread in album.spreads {
            switch profile.pageMode {
            case .singlePages:
                for side in [PageSide.left, .right] {
                    try Task.checkCancellation()
                    pages.beginPage(size: pageSize)
                    await renderer.renderPage(spread, side: side, into: pages.context, options: options)
                    pages.endPage()
                    step()
                }
            case .spreads:
                try Task.checkCancellation()
                pages.beginPage(size: spreadSize)
                await renderer.render(spread, into: pages.context, options: options)
                pages.endPage()
                step()
            }
            await provider.clearCache()
        }
        pages.close()

        // Cover.
        var tempCover: URL?
        if let cover {
            try Task.checkCancellation()
            let url = temp.appendingPathComponent(Self.coverFileName)
            let writer = try PDFWriter(url: url, title: album.title)
            writer.beginPage(size: pageSize)
            await renderer.renderCover(cover, into: writer.context, options: options)
            writer.endPage()
            writer.close()
            await provider.clearCache()
            tempCover = url
            step()
        }

        // Readme.
        let tempReadme = temp.appendingPathComponent(ExportInstructions.fileName)
        let readme = ExportInstructions.readme(album: album, profile: profile, format: format, pageCount: pageCount)
        try readme.write(to: tempReadme, atomically: false, encoding: .utf8)

        // Move into place only when everything is written.
        try Task.checkCancellation()
        let pagesURL = try Self.moveIntoPlace(tempPages, directory: directory)
        let coverURL = try tempCover.map { try Self.moveIntoPlace($0, directory: directory) }
        let readmeURL = try Self.moveIntoPlace(tempReadme, directory: directory)
        return ExportResult(pagesURL: pagesURL, coverURL: coverURL, readmeURL: readmeURL, pageCount: pageCount)
    }

    /// Replaces `directory/<name>` atomically (same volume) or moves the file there.
    private static func moveIntoPlace(_ file: URL, directory: URL) throws -> URL {
        let dest = directory.appendingPathComponent(file.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: file)
        } else {
            try fm.moveItem(at: file, to: dest)
        }
        return dest
    }
}

/// A Quartz PDF context in PDF points (origin bottom-left, which matches the renderer's contract).
private final class PDFWriter {
    let context: CGContext

    init(url: URL, title: String) throws {
        var box = CGRect.zero
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Leporelo"]
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            throw ExportError.cannotWrite(url.lastPathComponent)
        }
        context = ctx
    }

    func beginPage(size: CGSize) {
        var box = CGRect(origin: .zero, size: size)
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
    }

    func endPage() { context.endPDFPage() }

    func close() { context.closePDF() }
}
