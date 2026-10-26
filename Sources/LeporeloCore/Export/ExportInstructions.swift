import Foundation

/// The "co nahrát kam" text file written next to the exported PDFs (Czech, user facing).
public enum ExportInstructions {
    public static let fileName = "co-nahrat-kam.txt"

    public static func readme(album: Album, profile: SupplierProfile, format: BookFormat, pageCount: Int) -> String {
        let hasCover = profile.coverMode == .frontOnly && album.cover != nil
        let unit = profile.pageMode == .singlePages ? "jedna strana PDF = jedna strana knihy"
                                                    : "jedna strana PDF = jedna dvoustrana knihy"
        var lines: [String] = []
        lines.append("Leporelo – co nahrát kam")
        lines.append("")
        lines.append("Album: \(album.title)")
        lines.append("Dodavatel: \(profile.name)")
        lines.append("Formát: \(format.name) (strana \(mm(format.pageWidthMM)) × \(mm(format.pageHeightMM)) mm, "
            + "spadávka \(mm(profile.bleedMM)) mm na každé straně)")
        lines.append("Počet stran: \(pageCount) stran")
        lines.append("")
        lines.append("Soubory:")
        lines.append("- \(PDFExporter.pagesFileName): vnitřní strany v pořadí (\(unit))")
        if hasCover {
            lines.append("- \(PDFExporter.coverFileName): přední strana obálky")
        }
        lines.append("")
        lines.append("Postup:")
        for (i, step) in profile.uploadSteps.enumerated() {
            lines.append("\(i + 1). \(step)")
        }
        if !profile.verified {
            lines.append("")
            lines.append("Pozor: Rozměry formátu nejsou ověřené, zkontrolujte je v Canvě.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "297", "203,2" (Czech decimal comma, at most one decimal).
    private static func mm(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }
}
