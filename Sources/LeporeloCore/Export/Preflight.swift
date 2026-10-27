import Foundation

public enum PreflightSeverity: Sendable, Equatable { case error, warning }

public struct PreflightIssue: Sendable, Equatable, Identifiable {
    /// Stable and deterministic: "<rule>:<spreadID>:<frameID or textID>" (parts that do not apply are
    /// left out), so a UI can diff two lists.
    public var id: String
    public var severity: PreflightSeverity
    public var spreadID: String?
    public var frameID: String?
    /// The text box the issue is about (text rules), nil otherwise.
    public var textID: String?
    public var message: String

    public init(id: String, severity: PreflightSeverity, spreadID: String?, frameID: String?,
                textID: String? = nil, message: String) {
        self.id = id
        self.severity = severity
        self.spreadID = spreadID
        self.frameID = frameID
        self.textID = textID
        self.message = message
    }
}

/// Pre-export print checks (spec 6.5). Errors block the export, warnings can be accepted.
///
/// Order of the result (deterministic): the issues of each spread in `album.spreads` order (frames in
/// order, then texts in order), then the cover front and back, then the album-level issues: missing
/// cover, page count, selected photos not in the album (once spreads exist), unverified format.
/// Within one frame: original, DPI, faces, photo used twice, then margin. Within one text: bleed,
/// safe zone or margin (at most one of them), then overflow.
///
/// "Rámeček zasahuje do okraje" (`margin:<spreadID>:<frameID>`, warning) flags a frame (empty or
/// not) with an edge strictly inside the band next to a page edge (`MarginRule.frameIntrudesMargin`
/// with `album.marginMM`); "Text zasahuje do okraje" (`margin:<spreadID>:<textID>`, warning) a
/// non-empty text inside the safe zone but not inside the margin box of its page. Books made
/// before the margin rule are not conformed on open, so this is where they show. The cover pages
/// use the cover area (one page).
///
/// "Fotka je v knize víckrát" (`duplicatePhoto:<spreadID>:<frameID>`, warning) flags every occurrence
/// of a photo except the first among the frames of the `.journal` and `.gallery` spreads, in album
/// order. Intro, closing and cover repeat day photos on purpose, so they neither count nor are flagged.
///
/// "Text se nevejde do rámečku" (`textOverflow:<spreadID>:<textID>`, warning) uses
/// `SpreadRenderer.textOverflows`, i.e. the renderer's fonts and sizes; it is only checked for
/// non-empty texts and skipped when the bundled fonts are not available.
///
/// DPI matches what the renderer prints: a frame edge lying on the outer boundary of the page area is
/// stretched by `bleedMM`, so the DPI is computed on the frame extended on those sides. The outer
/// boundary is the spread's outer edge, and also the spine when the profile exports single pages
/// (`pageMode == .singlePages`, per-page rendering). The cover is one page in page coordinates.
/// A photo that is just enough for the trim but short for the bleed is therefore flagged.
public enum Preflight {
    public static let errorDPI = 150.0
    public static let warningDPI = 220.0
    private static let eps = 0.01

    public static func hasErrors(_ issues: [PreflightIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    public static func check(album: Album, profile: SupplierProfile, format: BookFormat) -> [PreflightIssue] {
        check(album: album, profile: profile, format: format, fontsAvailable: nil)
    }

    /// `fontsAvailable` overrides `FontRegistry.areBundledFontsAvailable` (tests); nil asks the
    /// registry, at most once per call and only when a non-empty text is checked.
    static func check(album: Album, profile: SupplierProfile, format: BookFormat,
                      fontsAvailable: Bool?) -> [PreflightIssue] {
        let geometry = PageGeometry(format: format, profile: profile)
        var issues: [PreflightIssue] = []
        var cachedFonts = fontsAvailable
        let fonts: () -> Bool = {
            if let cachedFonts { return cachedFonts }
            let available = FontRegistry.areBundledFontsAvailable
            cachedFonts = available
            return available
        }

        let w = format.pageWidthMM, h = format.pageHeightMM
        let spreadArea = Area(
            trim: Rect(x: 0, y: 0, width: 2 * w, height: h),
            safe: [geometry.safeRect(side: .left), geometry.safeRect(side: .right)],
            printArea: geometry.spreadPrintArea, spineX: w)
        let coverArea = Area(
            trim: Rect(x: 0, y: 0, width: w, height: h),
            safe: [geometry.safeRect(side: .left)], printArea: .cover, spineX: nil)
        let margin = MarginRule(geometry: geometry, marginMM: album.marginMM)

        let firstUse = firstDayUse(in: album)
        for spread in album.spreads {
            issues += check(spread, area: spreadArea, album: album, geometry: geometry, margin: margin,
                            firstUse: firstUse, fontsAvailable: fonts)
        }
        if let cover = album.cover {
            issues += check(cover.front, area: coverArea, album: album, geometry: geometry, margin: margin,
                            firstUse: [:], fontsAvailable: fonts)
            issues += check(cover.back, area: coverArea, album: album, geometry: geometry, margin: margin,
                            firstUse: [:], fontsAvailable: fonts)
        } else if profile.coverMode != .none {
            issues.append(PreflightIssue(id: "noCover", severity: .error, spreadID: nil, frameID: nil,
                                         message: "Album nemá obálku"))
        }

        let pages = album.spreads.count * 2
        if !profile.pageCount.isSatisfied(by: pages) {
            issues.append(PreflightIssue(
                id: "pageCount", severity: .error, spreadID: nil, frameID: nil,
                message: "Album má \(CzechPlural.pages(pages)), dodavatel chce \(describe(profile.pageCount))"))
        }
        // Only once there is a layout: before the first draft nothing is placed yet.
        let unplaced = album.spreads.isEmpty ? 0 : album.unplacedSelectedPhotos.count
        if unplaced > 0 {
            issues.append(PreflightIssue(id: "unplacedSelected", severity: .warning, spreadID: nil, frameID: nil,
                                         message: unplacedMessage(unplaced)))
        }
        if !profile.verified {
            issues.append(PreflightIssue(id: "unverified", severity: .warning, spreadID: nil, frameID: nil,
                                         message: "Rozměry formátu nejsou ověřené"))
        }
        return issues
    }

    /// "1 vybraná fotka není v albu", "3 vybrané fotky nejsou v albu", "5 vybraných fotek není v albu".
    static func unplacedMessage(_ n: Int) -> String {
        let adjective = CzechPlural.choose(n, one: "vybraná", few: "vybrané", many: "vybraných")
        let noun = CzechPlural.choose(n, one: "fotka", few: "fotky", many: "fotek")
        let verb = CzechPlural.choose(n, one: "není", few: "nejsou", many: "není")
        return "\(CzechPlural.grouped(n)) \(adjective) \(noun) \(verb) v albu"
    }

    /// "min. 20 stran, max. 98 stran, sudý počet" (always "stran": the abbreviated form).
    static func describe(_ rule: PageCountRule) -> String {
        var parts = ["min. \(rule.min) stran"]
        if let max = rule.max { parts.append("max. \(max) stran") }
        if rule.multipleOf == 2 {
            parts.append("sudý počet")
        } else if rule.multipleOf > 2 {
            parts.append("násobek \(rule.multipleOf)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: -

    /// Where a photo is first used in the day spreads (`.journal`, `.gallery`).
    private struct FirstUse {
        var spreadNumber: Int // 1-based position in `album.spreads`
        var spreadID: String
        var frameID: String
    }

    private static func firstDayUse(in album: Album) -> [PhotoID: FirstUse] {
        var first: [PhotoID: FirstUse] = [:]
        for (index, spread) in album.spreads.enumerated() where spread.kind == .journal || spread.kind == .gallery {
            for frame in spread.frames {
                guard let photoID = frame.photoID, first[photoID] == nil else { continue }
                first[photoID] = FirstUse(spreadNumber: index + 1, spreadID: spread.id, frameID: frame.id)
            }
        }
        return first
    }

    private struct Area {
        var trim: Rect
        var safe: [Rect]
        /// Where frames get bleed (`PageGeometry.bleedExtended`).
        var printArea: PrintArea
        var spineX: Double?
    }

    /// The overflow rule measures with the bundled fonts; without them (a broken install) Core Text
    /// would measure a fallback font, so the rule is skipped. Asked at most once per spread.
    private static func check(_ spread: Spread, area: Area, album: Album,
                              geometry: PageGeometry, margin: MarginRule, firstUse: [PhotoID: FirstUse],
                              fontsAvailable: () -> Bool) -> [PreflightIssue] {
        let profile = geometry.profile
        var issues: [PreflightIssue] = []
        func add(_ rule: String, _ severity: PreflightSeverity, frame: String? = nil, text: String? = nil,
                 _ message: String) {
            let id = ([rule, spread.id] + [text ?? frame].compactMap { $0 }).joined(separator: ":")
            issues.append(PreflightIssue(id: id, severity: severity, spreadID: spread.id, frameID: frame,
                                         textID: text, message: message))
        }

        /// The checks of the frame's photo: emptiness, original, DPI, faces, photo used twice.
        func photoChecks(_ frame: Frame) {
            guard let photoID = frame.photoID else {
                if spread.kind != .blank {
                    add("emptyFrame", .error, frame: frame.id,
                        "Rámeček je prázdný, vyberte fotku nebo dvoustranu smažte")
                }
                return
            }
            guard let photo = album.photos[photoID] else {
                add("missingPhoto", .error, frame: frame.id, "Fotka chybí v albu")
                return
            }
            if photo.kind == .video {
                add("video", .error, frame: frame.id, "Video nelze vložit do alba")
                return
            }
            switch photo.originalState {
            case .stored: break
            case .missing: add("original", .error, frame: frame.id, "Originál fotky ještě není v projektu")
            case .downloading: add("original", .error, frame: frame.id, "Originál fotky se ještě stahuje")
            case .unavailable:
                add("original", .error, frame: frame.id, photo.deletedInSource
                    ? "Fotka už není ve Fotkách a originál nebyl stažen"
                    : "Originál fotky není dostupný v iCloudu")
            }

            let printed = geometry.bleedExtended(frame.rect, area: area.printArea)
            let dpi = FrameFit.effectiveDPI(pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight,
                                            frame: printed, zoom: frame.zoom)
            if dpi < warningDPI {
                add("dpi", dpi < errorDPI ? .error : .warning, frame: frame.id,
                    "Fotka má jen \(Int(dpi.rounded(.down))) DPI, pro tisk je potřeba 220")
            }

            issues += faceIssues(photo: photo, frame: frame, printed: printed, area: area,
                                 safeMM: profile.safeMM, spreadID: spread.id)

            // `firstUse` holds day spreads only, so the intro, closing and cover never match it.
            if spread.kind == .journal || spread.kind == .gallery, let first = firstUse[photoID],
               first.spreadID != spread.id || first.frameID != frame.id {
                add("duplicatePhoto", .warning, frame: frame.id,
                    "Fotka je v knize víckrát (poprvé na dvoustraně \(first.spreadNumber))")
            }
        }

        for frame in spread.frames {
            photoChecks(frame)
            if margin.frameIntrudesMargin(frame.rect, area: area.printArea) {
                add("margin", .warning, frame: frame.id, "Rámeček zasahuje do okraje")
            }
        }

        for text in spread.texts where !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !contains(area.trim, text.rect) {
                add("textBleed", .warning, text: text.id, "Text zasahuje do zóny spadávky")
            } else if !area.safe.contains(where: { contains($0, text.rect) }) {
                add("textSafe", .warning, text: text.id, "Text leží mimo bezpečnou zónu")
            } else if margin.textOutsideMargin(text.rect, area: area.printArea) {
                add("margin", .warning, text: text.id, "Text zasahuje do okraje")
            }
            if fontsAvailable(), SpreadRenderer.textOverflows(text) {
                add("textOverflow", .warning, text: text.id,
                    "Text se nevejde do rámečku, konec se nevytiskne")
            }
        }

        if spread.kind == .journal {
            let hasBody = spread.texts.contains {
                $0.role == .body && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !hasBody {
                let key = spread.texts.first { $0.role == .body }?.id
                add("emptyBody", .warning, text: key, "Text deníkové dvoustrany je prázdný")
            }
        }
        return issues
    }

    private static func faceIssues(photo: Photo, frame: Frame, printed: Rect, area: Area, safeMM: Double,
                                   spreadID: String) -> [PreflightIssue] {
        guard let faces = photo.analysis?.faceRects, !faces.isEmpty else { return [] }
        let image = FrameFit.imageRect(imageSize: Size(width: Double(photo.pixelWidth), height: Double(photo.pixelHeight)),
                                       in: printed, offset: frame.offset, zoom: frame.zoom)
        var inBleed = false, nearSpine = false
        for f in faces {
            // faceRects are normalised, top-left origin, like the image rect's y axis here.
            let projected = Rect(x: image.minX + f.minX * image.size.width,
                                 y: image.minY + f.minY * image.size.height,
                                 width: f.size.width * image.size.width, height: f.size.height * image.size.height)
            // Only the part of the face that is visible in the frame matters.
            let minX = max(projected.minX, printed.minX), maxX = min(projected.maxX, printed.maxX)
            let minY = max(projected.minY, printed.minY), maxY = min(projected.maxY, printed.maxY)
            guard maxX > minX, maxY > minY else { continue }
            let visible = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if !contains(area.trim, visible) { inBleed = true }
            if let spine = area.spineX, visible.minX < spine + safeMM - eps, visible.maxX > spine - safeMM + eps {
                nearSpine = true
            }
        }
        var out: [PreflightIssue] = []
        if inBleed {
            out.append(PreflightIssue(id: "faceBleed:\(spreadID):\(frame.id)", severity: .warning,
                                      spreadID: spreadID, frameID: frame.id,
                                      message: "Obličej zasahuje do zóny spadávky a při ořezu se může ztratit"))
        }
        if nearSpine {
            out.append(PreflightIssue(id: "faceSpine:\(spreadID):\(frame.id)", severity: .warning,
                                      spreadID: spreadID, frameID: frame.id,
                                      message: "Obličej je blízko hřbetu a může zapadnout do vazby"))
        }
        return out
    }

    private static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.minX >= outer.minX - eps && inner.maxX <= outer.maxX + eps
            && inner.minY >= outer.minY - eps && inner.maxY <= outer.maxY + eps
    }
}
