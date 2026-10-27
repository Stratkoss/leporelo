import AppKit
import CoreGraphics
import Foundation
import LeporeloCore

// Pure decisions of the editor views (Task 21b). The AppKit/SwiftUI views stay thin and call
// these; everything here is unit tested (EditorLogicTests).

// MARK: - Canvas layout: view points <-> millimetres

/// Where the visible area (trim + bleed, in mm, spread coordinates with y DOWN) sits in a FLIPPED
/// view (y down from the top): fitted into the view minus `padding` on each side, centred
/// (letterboxed), one mm = `scale` points.
struct CanvasLayout: Equatable {
    let visibleArea: Rect
    let viewSize: CGSize
    /// Points per millimetre; 0 when the view is too small.
    let scale: CGFloat
    /// The visible area in view coordinates.
    let contentRect: CGRect

    init(visibleArea: Rect, viewSize: CGSize, padding: CGFloat) {
        self.visibleArea = visibleArea
        self.viewSize = viewSize
        let availableW = viewSize.width - 2 * padding, availableH = viewSize.height - 2 * padding
        guard visibleArea.size.width > 0, visibleArea.size.height > 0, availableW > 0, availableH > 0 else {
            scale = 0
            contentRect = .zero
            return
        }
        let s = min(availableW / visibleArea.size.width, availableH / visibleArea.size.height)
        scale = s
        let w = visibleArea.size.width * s, h = visibleArea.size.height * s
        contentRect = CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// The trim plus the supplier's bleed on every side: a whole spread, or one cover page.
    static func visibleArea(geometry: PageGeometry, isCover: Bool) -> Rect {
        let trim = isCover ? geometry.pageRect(side: .left) : Rect(origin: Point(x: 0, y: 0), size: geometry.spreadSize)
        return trim.insetBy(-geometry.profile.bleedMM)
    }

    func viewPoint(_ p: Point) -> CGPoint {
        CGPoint(x: contentRect.minX + (p.x - visibleArea.minX) * scale,
                y: contentRect.minY + (p.y - visibleArea.minY) * scale)
    }

    func viewRect(_ r: Rect) -> CGRect {
        let o = viewPoint(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.size.width * scale, height: r.size.height * scale)
    }

    /// nil when the layout is empty.
    func mmPoint(_ p: CGPoint) -> Point? {
        guard scale > 0 else { return nil }
        return Point(x: visibleArea.minX + (p.x - contentRect.minX) / scale,
                     y: visibleArea.minY + (p.y - contentRect.minY) / scale)
    }

    /// A pointer movement in view points as mm (both y down).
    func mmDelta(_ d: CGSize) -> Point {
        guard scale > 0 else { return Point(x: 0, y: 0) }
        return Point(x: d.width / scale, y: d.height / scale)
    }

    /// Concatenate this onto a flipped view's context before `SpreadRenderer.draw*` (with
    /// `pixelsPerMM = scale`): it establishes the renderer's contract, a y-up space whose origin is
    /// the bottom-left of the visible area (`contentRect`).
    var rendererTransform: CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: contentRect.minX, ty: contentRect.maxY)
    }
}

// MARK: - Hit testing (mm)

enum CanvasHit: Equatable {
    case text(String)
    case frame(String)
}

enum CanvasHitTest {
    /// What lies under `p` (mm): text boxes first (drawn on top), then frames, later frames first.
    /// Frames are hit on their bleed-extended rect, as drawn.
    static func hit(_ spread: Spread, at p: Point, geometry: PageGeometry, area: PrintArea = .spread) -> CanvasHit? {
        func inside(_ r: Rect) -> Bool { p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY }
        if let box = spread.texts.last(where: { inside($0.rect) }) { return .text(box.id) }
        if let frame = spread.frames.last(where: { inside(geometry.bleedExtended($0.rect, area: area)) }) {
            return .frame(frame.id)
        }
        return nil
    }
}

// MARK: - Crop math (offset in slack-relative units, zoom)

enum CropMath {
    /// Upper zoom bound of the editor's gestures (the model only enforces >= 1).
    static let maxZoom = 4.0

    /// How far the cover-fitted, zoomed image overhangs the frame on each axis (mm), as
    /// `FrameFit.imageRect` computes it.
    static func slack(frame: Rect, photo: Size, zoom: Double) -> Size {
        guard photo.width > 0, photo.height > 0 else { return Size(width: 0, height: 0) }
        let s = max(frame.size.width / photo.width, frame.size.height / photo.height) * clampZoom(zoom)
        return Size(width: max(photo.width * s - frame.size.width, 0),
                    height: max(photo.height * s - frame.size.height, 0))
    }

    /// The offset after dragging the image by `drag` mm from `start`: the image follows the
    /// pointer (an offset step of 1 moves it by half the slack), clamped to -1...1; an axis
    /// without slack stays.
    static func offset(start: Point, drag: Point, frame: Rect, photo: Size, zoom: Double) -> Point {
        let s = slack(frame: frame, photo: photo, zoom: zoom)
        func axis(_ o: Double, _ d: Double, _ slack: Double) -> Double {
            guard slack > 1e-9, d.isFinite else { return o }
            return min(max(o + 2 * d / slack, -1), 1)
        }
        return Point(x: axis(start.x, drag.x, s.width), y: axis(start.y, drag.y, s.height))
    }

    /// Arrow keys: moves the image by `stepMM` in the direction (dx, dy) in {-1, 0, 1}.
    static func arrowOffset(_ current: Point, dx: Int, dy: Int, stepMM: Double, frame: Rect, photo: Size,
                            zoom: Double) -> Point {
        offset(start: current, drag: Point(x: Double(dx) * stepMM, y: Double(dy) * stepMM), frame: frame,
               photo: photo, zoom: zoom)
    }

    static func clampZoom(_ zoom: Double) -> Double {
        zoom.isFinite ? min(max(zoom, 1), maxZoom) : 1
    }

    /// Pinch: `magnification` as `NSEvent.magnification` (relative change per event).
    static func zoom(_ current: Double, magnification: Double) -> Double {
        clampZoom(current * (1 + magnification))
    }

    /// Scroll wheel / two-finger scroll: exponential, so scrolling back returns to the same zoom.
    static func zoom(_ current: Double, scrollDelta: Double) -> Double {
        clampZoom(current * exp(scrollDelta * 0.01))
    }
}

/// How a scroll-wheel event drives a crop session (zoom over a frame). Trackpads deliver phases
/// (began, changed, ended); their momentum events are ignored. A classic mouse wheel has no
/// phase: every event updates, and the session ends after a short idle time.
enum ScrollZoom {
    struct Step: Equatable {
        var begin: Bool
        var update: Bool
        var end: Bool
        var idleEnd: Bool

        static let ignore = Step(begin: false, update: false, end: false, idleEnd: false)
    }

    static func step(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, inSession: Bool) -> Step {
        if !momentumPhase.isEmpty { return .ignore }
        if phase.isEmpty { return Step(begin: !inSession, update: true, end: false, idleEnd: true) }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            return Step(begin: false, update: false, end: inSession, idleEnd: false)
        }
        if phase.contains(.began) { return Step(begin: true, update: true, end: false, idleEnd: false) }
        if phase.contains(.changed) { return Step(begin: !inSession, update: true, end: false, idleEnd: false) }
        return .ignore
    }
}

// MARK: - Warnings on the canvas

/// The issues of one spread by where the canvas shows them: on a frame (frameID), on a text box
/// (text rules carry the text id at the end of the issue id) or in the banner above the canvas
/// (everything else, including the empty journal body and frames that no longer exist).
struct IssueAnchors {
    var byFrame: [String: [PreflightIssue]] = [:]
    var byText: [String: [PreflightIssue]] = [:]
    var unanchored: [PreflightIssue] = []

    init(_ issues: [PreflightIssue], spread: Spread) {
        let frameIDs = Set(spread.frames.map(\.id))
        for issue in issues {
            if let frame = issue.frameID, frameIDs.contains(frame) {
                byFrame[frame, default: []].append(issue)
            } else if issue.frameID == nil, !issue.id.hasPrefix("emptyBody:"),
                      let text = spread.texts.first(where: { issue.id.hasSuffix(":" + $0.id) }) {
                byText[text.id, default: []].append(issue)
            } else {
                unanchored.append(issue)
            }
        }
    }
}

/// The warning icon in a frame's (or text box's) top-right corner.
enum WarningBadge {
    static let size: CGFloat = 18
    static let inset: CGFloat = 4

    /// Top-right inside `anchor` (view coordinates, y down), never left of the anchor's left edge,
    /// and moved inside `bounds` (the canvas) so a frame running off screen keeps its icon visible.
    static func rect(anchor: CGRect, bounds: CGRect) -> CGRect {
        var x = max(anchor.maxX - inset - size, anchor.minX)
        var y = anchor.minY + inset
        x = min(max(x, bounds.minX + inset), bounds.maxX - inset - size)
        y = min(max(y, bounds.minY + inset), bounds.maxY - inset - size)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    static func severity(_ issues: [PreflightIssue]) -> PreflightSeverity {
        issues.contains { $0.severity == .error } ? .error : .warning
    }

    static func tooltip(_ issues: [PreflightIssue]) -> String {
        issues.map(\.message).joined(separator: "\n")
    }
}

// MARK: - Strip: reordering

/// Drag-reorder in the strip. Gaps are insertion points 0...count (gap i is before item i). A
/// leading intro and a trailing closing cannot be dragged, and nothing can be dropped before the
/// intro or after the closing (`EditorModel.moveSpread` would clamp; the strip refuses instead).
enum StripDrop {
    static func allowedGaps(_ kinds: [SpreadKind]) -> ClosedRange<Int> {
        let lower = kinds.first == .intro ? 1 : 0
        let upper = kinds.count > 1 && kinds.last == .closing ? kinds.count - 1 : kinds.count
        return lower...max(lower, upper)
    }

    static func canDrag(index: Int, kinds: [SpreadKind]) -> Bool {
        guard kinds.indices.contains(index) else { return false }
        if index == 0 && kinds[0] == .intro { return false }
        if index == kinds.count - 1 && kinds.count > 1 && kinds[index] == .closing { return false }
        return true
    }

    static func gap(hoverIndex: Int, trailingHalf: Bool) -> Int {
        hoverIndex + (trailingHalf ? 1 : 0)
    }

    /// The `moveSpread(_, to:)` index for dropping item `from` into `gap`; nil when the drop is
    /// not allowed or changes nothing.
    static func moveIndex(from: Int, gap: Int, kinds: [SpreadKind]) -> Int? {
        guard canDrag(index: from, kinds: kinds), allowedGaps(kinds).contains(gap) else { return nil }
        let to = gap > from ? gap - 1 : gap
        return to == from ? nil : to
    }
}

/// Cache key of a strip thumbnail: the spread's whole content, the geometry, the render scale
/// and which of its photos have a thumbnail in the package yet (analysis writes it, so a photo
/// whose analysis landed renders again).
struct SpreadThumbnailKey: Hashable {
    let content: Data
    let profileID: String
    let formatID: String
    let pixelsPerMM: Double
    let readyPhotos: [Bool]

    init(spread: Spread, geometry: PageGeometry, photos: [PhotoID: Photo], pixelsPerMM: Double) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        content = (try? encoder.encode(spread)) ?? Data(spread.id.utf8)
        profileID = geometry.profile.id
        formatID = geometry.format.id
        self.pixelsPerMM = pixelsPerMM
        readyPhotos = spread.frames.map { frame in frame.photoID.flatMap { photos[$0]?.analysis } != nil }
    }

    /// Render scale so the thumbnail's visible height fills `height` points at `backingScale`.
    static func pixelsPerMM(height: CGFloat, backingScale: CGFloat, visibleHeightMM: Double) -> Double {
        guard visibleHeightMM > 0 else { return 1 }
        return Double(height * backingScale) / visibleHeightMM
    }
}

// MARK: - Undo routing

/// Where Edit > Undo/Redo (⌘Z, ⇧⌘Z) goes. The app replaces the system Undo/Redo menu items:
/// - an album window in editor mode: `EditorModel.undo()/redo()`, which commit a running text or
///   crop session first (the text overlay has no undo of its own: `allowsUndo` is off);
/// - an album window in triage: the window's undo manager;
/// - anything else (no album window in front, e.g. the "Nové album" window): the responder chain
///   (`undo:`), so text fields there keep their own undo.
enum UndoRoute: Equatable {
    case editor, window, responderChain
}

/// One Edit menu item. Never disabled on purpose: a disabled item whose Commands body SwiftUI
/// did not re-evaluate would swallow ⌘Z; `EditorModel.undo()` and `UndoManager` do nothing when
/// there is nothing to undo.
struct UndoMenuItem: Equatable {
    var title: String
    var isEnabled: Bool
}

enum UndoRouter {
    /// `pendingAction`: the action name of an editor session that has CHANGES (committing it is
    /// what ⌘Z undoes first); an open but unchanged session is nil, so the title names the step
    /// that will really be undone.
    static func undoItem(route: UndoRoute, pendingAction: String?, undoActionName: String) -> UndoMenuItem {
        switch route {
        case .editor: UndoMenuItem(title: undoTitle(pendingAction ?? undoActionName), isEnabled: true)
        case .window: UndoMenuItem(title: undoTitle(undoActionName), isEnabled: true)
        case .responderChain: UndoMenuItem(title: undoTitle(""), isEnabled: true)
        }
    }

    /// A changed session is a new change: committing it leaves nothing to redo, so the plain title.
    static func redoItem(route: UndoRoute, pendingAction: String?, redoActionName: String) -> UndoMenuItem {
        switch route {
        case .editor: UndoMenuItem(title: redoTitle(pendingAction == nil ? redoActionName : ""), isEnabled: true)
        case .window: UndoMenuItem(title: redoTitle(redoActionName), isEnabled: true)
        case .responderChain: UndoMenuItem(title: redoTitle(""), isEnabled: true)
        }
    }

    static func route(mode: WindowMode?, hasEditor: Bool, hasUndoManager: Bool) -> UndoRoute {
        guard let mode else { return .responderChain }
        if mode == .editor && hasEditor { return .editor }
        return hasUndoManager ? .window : .responderChain
    }

    static func undoTitle(_ actionName: String) -> String {
        actionName.isEmpty ? "Odvolat" : "Odvolat: \(actionName)"
    }

    static func redoTitle(_ actionName: String) -> String {
        actionName.isEmpty ? "Znovu" : "Znovu: \(actionName)"
    }
}

// MARK: - Window modes

/// One album window shows either triage (Třídění) or the editor (Dvoustrany).
enum WindowMode: Hashable {
    case triage, editor
}

enum WindowModeLogic {
    /// The mode to show: the user's choice, else the editor when the album already has spreads;
    /// the editor needs spreads (an undone "Navrhnout album" goes back to triage).
    static func resolve(requested: WindowMode?, hasSpreads: Bool) -> WindowMode {
        guard hasSpreads else { return .triage }
        return requested ?? .editor
    }

    /// After "Navrhnout album" (drafted, or the album already had spreads): the editor; nil
    /// (stay) when there are still no spreads (nothing selected).
    static func afterPropose(hasSpreads: Bool) -> WindowMode? {
        hasSpreads ? .editor : nil
    }
}

// MARK: - Drag payloads

/// A photo on the drag pasteboard: the custom type `com.stratkoss.leporelo.photo-id` (UTF-8 id)
/// plus the triage grid's plain-text payload (`PhotoDrag`), which is what a SwiftUI drag (the
/// tray) reliably carries. Readers try the custom type first.
enum PhotoPasteboard {
    static let typeIdentifier = "com.stratkoss.leporelo.photo-id"
    static let type = NSPasteboard.PasteboardType(typeIdentifier)

    static func item(for id: PhotoID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(id.utf8), forType: type)
        item.setString(PhotoDrag.payload(for: id), forType: .string)
        return item
    }

    static func photoID(from pasteboard: NSPasteboard) -> PhotoID? {
        if let data = pasteboard.data(forType: type), let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        return pasteboard.string(forType: .string).flatMap(PhotoDrag.photoID(from:))
    }
}

/// A spread dragged in the strip (plain text with a prefix, never mistaken for a photo).
enum SpreadDrag {
    static let prefix = "leporelo-spread:"

    static func payload(for id: String) -> String { prefix + id }

    static func spreadID(from string: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        let id = String(string.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

// MARK: - Texts

/// Texts of the editor (Czech, sentence case, no exclamation marks).
enum EditorText {
    static let triage = "Třídění"
    static let spreads = "Dvoustrany"
    static let backToTriage = "Zpět do třídění"
    static let redraft = "Navrhnout znovu"
    static let export = "Exportovat…"
    static let changeTemplate = "Změnit šablonu…"
    static let insertAfter = "Vložit dvoustranu za"
    static let deleteSpread = "Smazat dvoustranu"
    static let wholeSelection = "Celý výběr"
    static let tray = "Zásobník"
    static let cover = "Obálka"
    static let coverReadOnly = "Obálku zatím nejde upravovat, jen prohlížet."
    static let formatMenu = "Formát"
    static let formatChange = "Změnit formát?"
    static let formatMessage = "Rozložení se přepočítá, obsah zůstane."
    static let canvasHint = "Tažením posunete výřez, kolečkem nebo sevřením přiblížíte, s klávesou ⌥ fotku přetáhnete do jiného rámečku. Dvojklik na text ho upraví, dvojklik na fotku vrátí výřez."

    static func kindName(_ kind: SpreadKind) -> String {
        switch kind {
        case .intro: "Úvod"
        case .journal: "Deník"
        case .gallery: "Galerie"
        case .closing: "Závěr"
        case .blank: "Prázdná"
        }
    }

    /// Kinds offered by "Vložit dvoustranu za".
    static let insertableKinds: [SpreadKind] = [.gallery, .journal, .blank]

    static func insertKindName(_ kind: SpreadKind) -> String {
        switch kind {
        case .gallery: "Galerie"
        case .journal: "Deník"
        default: "Prázdná"
        }
    }

    static func problems(_ n: Int) -> String {
        CzechPlural.count(n, one: "problém", few: "problémy", many: "problémů")
    }

    static func issueBanner(_ n: Int) -> String {
        "\(problems(n)) na této dvoustraně"
    }

    static func redraftMessage(_ kept: Int) -> String {
        if kept == 0 { return "Žádná dvoustrana není ručně upravená, navrhnu znovu všechny. Pokračovat?" }
        let phrase = CzechPlural.choose(kept, one: "ručně upravenou dvoustranu", few: "ručně upravené dvoustrany",
                                        many: "ručně upravených dvoustran")
        return "Zachovám \(CzechPlural.grouped(kept)) \(phrase). Pokračovat?"
    }

    static func photoCount(_ n: Int) -> String {
        n == 0 ? "bez fotek" : CzechPlural.photos(n)
    }

    /// "Deník, 3 fotky".
    static func templateLabel(_ t: SpreadTemplate) -> String {
        "\(kindName(t.kind)), \(photoCount(t.frames.count))"
    }

    /// VoiceOver label of a strip item: "Dvoustrana 3, Deník, čtvrtek 18. června 2026, 2 problémy".
    static func stripLabel(index: Int, kind: SpreadKind, day: DayKey?, issues: Int) -> String {
        var parts = ["Dvoustrana \(index + 1)", kindName(kind)]
        if let day { parts.append(AlbumDrafter.czechDate(day)) }
        if issues > 0 { parts.append(problems(issues)) }
        return parts.joined(separator: ", ")
    }

    /// "Tyto texty by se ztratily: „Pláž a moře“, „…“" (each text on one line, at most 40 characters).
    static func textLoss(_ texts: [TextBox]) -> String {
        let quoted = texts.map { box -> String in
            let line = box.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            let short = line.count > 40 ? String(line.prefix(40)) + "…" : line
            return "„\(short)“"
        }
        return "Tyto texty by se ztratily: " + quoted.joined(separator: ", ")
    }

    /// The body text wraps and takes Return as a new line; the other roles end editing on Return.
    static func isMultiline(_ role: TextRole) -> Bool {
        role == .body
    }

    /// The template's placeholder for an empty text box ("Co jsme dnes dělali").
    static func placeholder(templateID: String, textID: String) -> String? {
        TemplateCatalog.template(id: templateID)?.texts.first { $0.id == textID }?.placeholder
    }

    /// "čt 18. 6. · 9:05" (the photo's own time zone), for lists of photos.
    static func photoLabel(_ photo: Photo) -> String {
        let day = photo.dayKey.map(TriageText.shortDate) ?? TriageText.undated
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: photo.timeZoneSeconds ?? 0) ?? .gmt
        let c = calendar.dateComponents([.hour, .minute], from: photo.capturedAt)
        return String(format: "%@ · %d:%02d", day, c.hour ?? 0, c.minute ?? 0)
    }

    static func deleteTitle() -> String { "Smazat dvoustranu?" }
    static let deleteMessage = "Fotky zůstanou vybrané a najdete je v zásobníku. Smazání jde vrátit zpět."
}
