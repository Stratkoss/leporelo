import Foundation
import LeporeloCore

/// One export failure as the user sees it: a short Czech message, the technical detail for a
/// disclosure, and the preflight issues when the exporter refused because of them.
struct ExportFailure: LocalizedError, Equatable {
    var message: String
    var detail: String?
    var issues: [PreflightIssue]?

    var errorDescription: String? { message }
    var failureReason: String? { detail }
}

/// One line of the problem list in the export sheet.
struct ExportIssueRow: Identifiable, Equatable {
    var issue: PreflightIssue
    /// What the list shows (the Core message, or a shorter app text for some issues).
    var text: String
    /// "Dvoustrana 3", "Přední strana obálky"; nil for album-level issues.
    var place: String?
    /// A second line with what to do, when the message alone does not say it.
    var hint: String?
    /// The spread the editor can show for this issue; nil when there is nothing to jump to
    /// (album-level issues, the cover, a spread that no longer exists).
    var jumpSpreadID: String?

    var id: String { issue.id }
    var canJump: Bool { jumpSpreadID != nil }
}

/// What the user picked in the folder panel means for the export.
enum ExportDestinationCheck: Equatable {
    case ok
    /// The folder must not be used (Czech message).
    case invalid(String)
    /// Files of an earlier export are there; ask before replacing them (file names).
    case needsOverwrite([String])
}

/// The finished export as the sheet shows it.
struct ExportSummary: Equatable {
    var result: ExportResult
    /// "Exportováno: pages.pdf (40 stran), cover.pdf"
    var headline: String
    var folderPath: String
    /// The first upload steps from `co-nahrat-kam.txt` ("1. Otevři Canvu…").
    var steps: [String]

    var folderURL: URL { result.pagesURL.deletingLastPathComponent() }
}

/// Pure helpers of the export flow (tested without UI).
enum ExportLogic {
    static let exportFileNames = [PDFExporter.pagesFileName, PDFExporter.coverFileName, ExportInstructions.fileName]
    static let cancelledNotice = "Export byl zrušen"
    static let overwriteTitle = "Ve složce už jsou soubory z dřívějšího exportu. Přepsat?"
    static let insidePackageMessage =
        "Do balíku alba nejde exportovat, soubory by ho poškodily. Vyberte jinou složku, třeba v Dokumentech."

    /// The supplier's short name for "Exportovat pro …": the first word of the profile name
    /// ("Canva Print – fotokniha" -> "Canva").
    static func supplierShortName(_ profile: SupplierProfile) -> String {
        profile.name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? profile.name
    }

    static func title(_ profile: SupplierProfile?) -> String {
        profile.map { "Exportovat pro \(supplierShortName($0))" } ?? "Exportovat"
    }

    static func waitingTitle(_ n: Int) -> String { "Čekám na originály (\(n))" }

    /// Photos in the album (spreads and cover) whose original is not in the project yet but is
    /// coming (`.missing`, `.downloading`). `.unavailable` is not waiting: the user has to act.
    static func waitingForOriginals(_ album: Album) -> Int {
        album.placedPhotoIDs.reduce(0) { n, id in
            switch album.photos[id]?.originalState {
            case .missing?, .downloading?: n + 1
            default: n
            }
        }
    }

    /// Preflight plus the waiting count, for one album snapshot (runs off the main actor).
    static func evaluate(album: Album, profile: SupplierProfile, format: BookFormat)
        -> (issues: [PreflightIssue], waiting: Int) {
        (Preflight.check(album: album, profile: profile, format: format), waitingForOriginals(album))
    }

    /// The identity of a warning for "accepted": a changed message (e.g. other DPI) is a new one.
    static func warningKeys(_ issues: [PreflightIssue]) -> Set<String> {
        Set(issues.filter { $0.severity == .warning }.map { "\($0.id)\u{1F}\($0.message)" })
    }

    static func rows(issues: [PreflightIssue], album: Album) -> [ExportIssueRow] {
        var index: [String: Int] = [:]
        for (i, s) in album.spreads.enumerated() { index[s.id] = i }
        return issues.map { issue in
            var row = ExportIssueRow(issue: issue, text: issue.message)
            if let spreadID = issue.spreadID {
                if let i = index[spreadID] {
                    row.place = "Dvoustrana \(i + 1)"
                    row.jumpSpreadID = spreadID
                } else if spreadID == album.cover?.front.id {
                    row.place = "Přední strana obálky"
                } else if spreadID == album.cover?.back.id {
                    row.place = "Zadní strana obálky"
                }
            }
            if issue.id.hasPrefix("original:"), photoState(of: issue, in: album) == .unavailable {
                row.text = "Originál není dostupný"
                row.hint = "Fotku nejde stáhnout z iCloudu. Nahraďte ji jinou nebo rámeček vyprázdněte a dvoustranu upravte."
            }
            return row
        }
    }

    private static func photoState(of issue: PreflightIssue, in album: Album) -> OriginalState? {
        let pages = album.spreads + [album.cover?.front, album.cover?.back].compactMap { $0 }
        guard let page = pages.first(where: { $0.id == issue.spreadID }),
              let photoID = page.frames.first(where: { $0.id == issue.frameID })?.photoID else { return nil }
        return album.photos[photoID]?.originalState
    }

    /// Nil when `directory` can take the export, else a Czech message. The open package (and so its
    /// originals and thumbnails) is off limits: export files inside it would corrupt the document.
    /// Paths are compared standardized and with symlinks resolved.
    static func destinationProblem(_ directory: URL, packageURL: URL) -> String? {
        let dir = canonicalComponents(directory), package = canonicalComponents(packageURL)
        return dir.starts(with: package) ? insidePackageMessage : nil
    }

    /// Which of the three export files already exist in `directory`, in export order.
    static func existingExportFiles(in directory: URL) -> [String] {
        exportFileNames.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func check(destination: URL, packageURL: URL) -> ExportDestinationCheck {
        if let problem = destinationProblem(destination, packageURL: packageURL) { return .invalid(problem) }
        let existing = existingExportFiles(in: destination)
        return existing.isEmpty ? .ok : .needsOverwrite(existing)
    }

    /// The path components with `..`/`.` removed and symlinks resolved: `realpath` of the longest
    /// existing ancestor (the panel only returns existing folders), the rest appended as is.
    static func canonicalComponents(_ url: URL) -> [String] {
        var components = url.standardizedFileURL.pathComponents
        var rest: [String] = []
        while !components.isEmpty {
            let path = NSString.path(withComponents: components)
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                let base = URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL.pathComponents
                return base + rest.reversed()
            }
            rest.append(components.removeLast())
        }
        return url.standardizedFileURL.pathComponents
    }

    static func failure(for error: Error) -> ExportFailure {
        if let failure = error as? ExportFailure { return failure }
        switch error as? ExportError {
        case let .preflightFailed(issues)?:
            return ExportFailure(message: "Kontrola před exportem našla chyby. Opravte je a zkuste to znovu.",
                                 detail: nil, issues: issues)
        case .unsupportedCoverMode?:
            return ExportFailure(message: "Tento dodavatel chce obálku se hřbetem a tu Leporelo zatím neumí vytvořit.",
                                 detail: nil)
        case let .cannotWrite(name)?:
            return ExportFailure(message: "Soubor \(name) nejde zapsat. Zkontrolujte, že do složky můžete zapisovat a je na disku místo.",
                                 detail: name)
        case nil:
            let ns = error as NSError
            return ExportFailure(message: "Export se nepodařil.",
                                 detail: "\(ns.localizedDescription) (\(ns.domain) \(ns.code)) \(String(describing: error))")
        }
    }

    /// "Exportováno: pages.pdf (40 stran), cover.pdf"
    static func headline(_ result: ExportResult) -> String {
        var text = "Exportováno: \(result.pagesURL.lastPathComponent) (\(CzechPlural.pages(result.pageCount)))"
        if let cover = result.coverURL { text += ", \(cover.lastPathComponent)" }
        return text
    }

    /// The numbered lines under "Postup:" of the readme, at most `limit`.
    static func uploadSteps(fromReadme text: String, limit: Int = 3) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "Postup:") else { return [] }
        let steps = lines[(start + 1)...].prefix { !$0.isEmpty }
        return Array(steps.prefix(limit))
    }
}
