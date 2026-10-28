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

// MARK: - Layout handles and drags (mm)

/// The 8 resize handles of a selected frame or text: its 4 corners and the midpoints of its 4
/// sides. A handle is hit within `tolerance` mm on both axes (a square, as drawn).
enum LayoutHandles {
    /// The edges a drag from `p` resizes: two for a corner (corners win over sides, the nearest
    /// corner first), one for a side; nil inside or outside away from every handle.
    static func hit(_ p: Point, rect: Rect, tolerance: Double) -> RectEdges? {
        let midX = rect.minX + rect.size.width / 2, midY = rect.minY + rect.size.height / 2
        let corners: [(Point, RectEdges)] = [
            (Point(x: rect.minX, y: rect.minY), [.minX, .minY]),
            (Point(x: rect.maxX, y: rect.minY), [.maxX, .minY]),
            (Point(x: rect.minX, y: rect.maxY), [.minX, .maxY]),
            (Point(x: rect.maxX, y: rect.maxY), [.maxX, .maxY]),
        ]
        let sides: [(Point, RectEdges)] = [
            (Point(x: midX, y: rect.minY), .minY),
            (Point(x: midX, y: rect.maxY), .maxY),
            (Point(x: rect.minX, y: midY), .minX),
            (Point(x: rect.maxX, y: midY), .maxX),
        ]
        func nearest(_ handles: [(Point, RectEdges)]) -> RectEdges? {
            handles
                .filter { abs($0.0.x - p.x) <= tolerance && abs($0.0.y - p.y) <= tolerance }
                .min { hypot($0.0.x - p.x, $0.0.y - p.y) < hypot($1.0.x - p.x, $1.0.y - p.y) }?.1
        }
        return nearest(corners) ?? nearest(sides)
    }
}

/// The rectangle of a frame or text during a mouse drag, from its rectangle at the start.
enum LayoutDrag {
    /// `.all` moves `start` by `delta`; otherwise only the given edges follow the pointer and the
    /// opposite ones stay. `keepAspect` on a corner keeps `start`'s width/height ratio: the larger
    /// relative change of the two drives. No side ever gets below `minSize` (a shrink past it
    /// stops there, the opposite edge stays).
    static func rect(from start: Rect, edges: RectEdges, delta: Point, keepAspect: Bool, minSize: Double) -> Rect {
        if edges == .all {
            return Rect(x: start.minX + delta.x, y: start.minY + delta.y, width: start.size.width,
                        height: start.size.height)
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.minX) { minX = min(start.minX + delta.x, start.maxX - minSize) }
        if edges.contains(.maxX) { maxX = max(start.maxX + delta.x, start.minX + minSize) }
        if edges.contains(.minY) { minY = min(start.minY + delta.y, start.maxY - minSize) }
        if edges.contains(.maxY) { maxY = max(start.maxY + delta.y, start.minY + minSize) }

        let isCorner = (edges.contains(.minX) || edges.contains(.maxX)) && (edges.contains(.minY) || edges.contains(.maxY))
        let w = start.size.width, h = start.size.height
        guard keepAspect, isCorner, w > 0, h > 0 else {
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        // Scale factors from the raw (unclamped) pointer position, the larger change drives.
        let fx = (edges.contains(.minX) ? w - delta.x : w + delta.x) / w
        let fy = (edges.contains(.minY) ? h - delta.y : h + delta.y) / h
        var f = abs(fx - 1) >= abs(fy - 1) ? fx : fy
        f = max(f, minSize / w, minSize / h)
        let newW = w * f, newH = h * f
        let x = edges.contains(.minX) ? start.maxX - newW : start.minX
        let y = edges.contains(.minY) ? start.maxY - newH : start.minY
        return Rect(x: x, y: y, width: newW, height: newH)
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
                      let text = spread.texts.first(where: { $0.id == issue.textID })
                        ?? spread.texts.first(where: { issue.id.hasSuffix(":" + $0.id) }) {
                // Text rules ("textOverflow", "textSafe", "textBleed") name their box in `textID`.
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

    struct Placement: Equatable {
        var rect: CGRect
        var severity: PreflightSeverity
        var tooltip: String
    }

    /// Every badge of `spread`: one per frame with issues (anchored on the frame as printed,
    /// `frameRect`), then one per text box with issues (anchored on the box: a text that does not
    /// fit, or lies outside the safe zone, gets its icon in the box's top-right corner).
    /// `viewRect` maps millimetres to view coordinates.
    static func placements(_ issues: [PreflightIssue], spread: Spread, bounds: CGRect,
                           frameRect: (Frame) -> Rect, viewRect: (Rect) -> CGRect) -> [Placement] {
        let anchors = IssueAnchors(issues, spread: spread)
        var result: [Placement] = []
        for frame in spread.frames {
            guard let list = anchors.byFrame[frame.id] else { continue }
            result.append(Placement(rect: rect(anchor: viewRect(frameRect(frame)), bounds: bounds),
                                    severity: severity(list), tooltip: tooltip(list)))
        }
        for box in spread.texts {
            guard let list = anchors.byText[box.id] else { continue }
            result.append(Placement(rect: rect(anchor: viewRect(box.rect), bounds: bounds),
                                    severity: severity(list), tooltip: tooltip(list)))
        }
        return result
    }
}

// MARK: - Strip: reordering

/// Drag-reorder in the strip. Gaps are insertion points 0...count (gap i is before item i). A
/// leading intro and a trailing closing cannot be dragged, and nothing can be dropped before the
/// intro or after the closing (`EditorModel.moveSpread` would clamp; the strip refuses instead).
enum StripDrop {
    enum Decision: Equatable {
        /// Not a spread drag of this strip.
        case reject
        /// The drag pasteboard already names the dragged spread: move it now.
        case move(String)
        /// The payload is not readable synchronously (or the pasteboard still holds an earlier
        /// drag's text): load it from the item provider and move only if it names this spread.
        case loadPayload(String)
    }

    /// What a drop on the strip does: `draggingID` is the spread this strip started dragging,
    /// `payload` the drag pasteboard's plain text when it can be read synchronously. A payload
    /// that names another spread is not trusted to reject (it may be left over from an earlier
    /// drag); the item provider decides then.
    static func decision(draggingID: String?, payload: String?) -> Decision {
        guard let id = draggingID else { return .reject }
        if let payload, SpreadDrag.spreadID(from: payload) == id { return .move(id) }
        return .loadPayload(id)
    }

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
///   (`undo:`), so text fields there keep their own undo;
/// - also the responder chain while a SHEET of the album window is key ("Nové album…", export,
///   template picker, alerts) or while a text field other than the canvas text overlay has focus:
///   ⌘Z there belongs to that field, never to the album behind it.
enum UndoRoute: Equatable {
    case editor, window, responderChain
}

/// Where the keyboard is when Edit > Undo is chosen (`UndoFocus.current()` reads it from AppKit).
struct UndoFocus: Equatable {
    enum Text: Equatable {
        /// No text view has focus.
        case none
        /// The editor's canvas text overlay (`CanvasTextView`): its undo is the album's.
        case canvasOverlay
        /// Any other text field or text view (its own undo).
        case other
    }

    var keyWindowIsSheet: Bool
    var text: Text

    /// The key window's state, nil without a key window.
    @MainActor static func current() -> UndoFocus? {
        guard let window = NSApp.keyWindow else { return nil }
        let text: Text
        if let responder = window.firstResponder as? NSText {
            text = responder is CanvasTextView ? .canvasOverlay : .other
        } else {
            text = .none
        }
        return UndoFocus(keyWindowIsSheet: window.sheetParent != nil, text: text)
    }
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

    /// `focus`: the key window (nil: none, or not known); a sheet or a foreign text field takes
    /// ⌘Z to the responder chain.
    static func route(mode: WindowMode?, hasEditor: Bool, hasUndoManager: Bool,
                      focus: UndoFocus? = nil) -> UndoRoute {
        if let focus, focus.keyWindowIsSheet || focus.text == .other { return .responderChain }
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

// MARK: - Snap style

/// The colour of everything snapping draws (guides, distances, sizes): one purple, the same on
/// paper and in dark mode; the accent colour stays for the selection and the current page.
enum SnapStyle {
    static let purple = NSColor(srgbRed: 0xA0 / 255.0, green: 0x20 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
}

// MARK: - Texts

/// Texts of the editor (Czech, sentence case, no exclamation marks).
enum EditorText {
    static let triage = "Třídění"
    static let spreads = "Dvoustrany"
    static let backToTriage = "Zpět do třídění"
    static let redraft = "Navrhnout znovu"
    static let export = "Exportovat…"
    static let changeTemplate = "Doporučené rozložení…"
    static let applyLayoutQuestion = "Použít doporučené rozložení?"
    static let applyLayout = "Použít"
    /// The undo action name of applying a recommended layout (a template) to a spread.
    static let applyLayoutAction = "Použít doporučené rozložení"
    static let tryAnother = "Zkusit jinak"
    /// The undo action name of "Zkusit jinak".
    static let tryAnotherAction = "Zkusit jinak"
    static let clickPage = "Klikni na stránku"
    static let noOtherLayout = "Pro tyhle fotky jiné rozložení není"
    static let replaceLayoutQuestion = "Ruční rozložení se nahradí doporučeným."
    static let replaceLayout = "Nahradit"
    static let recommendedLayouts = "Doporučená rozložení"
    static let insertAfter = "Vložit dvoustranu za"
    static let deleteSpread = "Smazat dvoustranu"
    static let wholeSelection = "Celý výběr"
    static let tray = "Zásobník"
    static let cover = "Obálka"
    static let coverReadOnly = "Obálku zatím nejde upravovat, jen prohlížet."
    static let formatMenu = "Formát"
    static let formatChange = "Změnit formát?"
    static let formatMessage = "Rozložení se přepočítá, obsah zůstane."
    static let canvasHint = "Tažením rámeček posunete, za rohy změníte velikost (⇧ drží poměr, ⌘ vypne přichytávání). Dvojklikem upravíte výřez fotky, s klávesou ⌥ fotku přetáhnete do jiného rámečku. Dvojklik na text ho upraví."
    static let addFrame = "Přidat rámeček"
    static let addText = "Přidat text"
    static let deleteItem = "Smazat"
    static let removePhoto = "Odebrat fotku"
    static let editCrop = "Upravit výřez"
    static let resetCrop = "Obnovit výřez"
    static let grid = "Mřížka"
    static let snap = "Přichytávat"

    /// The help of the "Zkusit jinak" button: why it is disabled, else its name.
    static func tryAnotherHelp(_ availability: TryAnotherAvailability) -> String {
        switch availability {
        case .noPage: clickPage
        case .noAlternative: noOtherLayout
        case .available, .notApplicable: tryAnother
        }
    }

    /// The picker's group heading of page layouts with `n` photos: "1 fotka", "2 fotky", "Bez fotek".
    static func pageLayoutGroup(_ n: Int) -> String {
        n == 0 ? "Bez fotek" : CzechPlural.photos(n)
    }

    /// "Čtyři, 4 fotky" (VoiceOver label of a page layout in the picker).
    static func pageLayoutLabel(_ layout: PageLayout) -> String {
        "\(layout.name), \(photoCount(layout.photoCount))"
    }

    /// "12,5 mm": a distance or size label of snapping, one decimal and a decimal comma.
    static func millimetres(_ mm: Double) -> String {
        String(format: "%.1f mm", mm).replacingOccurrences(of: ".", with: ",")
    }

    /// "Okraj: 10 mm" (the toolbar's margin stepper).
    static func margin(_ mm: Double) -> String { "Okraj: \(Int(mm)) mm" }

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

    /// The template's placeholder for an empty text box ("Co jsme dnes dělali"). On a spread of
    /// pages (`PageSpread.templateID`) a text made from a catalog slot (`L.caption`, `R.date`) shows
    /// that slot's placeholder ("Popisek", "Datum").
    static func placeholder(templateID: String, textID: String) -> String? {
        if templateID == PageSpread.templateID {
            guard let slot = [PageSide.left, .right].lazy.map(PageSpread.prefix)
                .first(where: { textID.hasPrefix($0) }).map({ String(textID.dropFirst($0.count)) }) else { return nil }
            return PageLayoutCatalog.all.lazy.flatMap(\.texts).first { $0.id == slot }?.placeholder
        }
        return TemplateCatalog.template(id: templateID)?.texts.first { $0.id == textID }?.placeholder
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
