import AppKit
import LeporeloCore
import SwiftUI
import os

/// What the canvas shows: a spread (editable) or one cover page (read-only for now).
enum CanvasContent: Equatable {
    case spread(Spread)
    case cover(Spread)

    var page: Spread {
        switch self {
        case .spread(let s), .cover(let s): s
        }
    }

    var isCover: Bool {
        if case .cover = self { return true }
        return false
    }
}

/// The big spread in the middle of the editor (spec 6.4), an AppKit view wrapped for SwiftUI.
///
/// Rendering: the SYNC `SpreadRenderer.draw`/`drawCover` with `showGuides` (trim, safe zone,
/// spine) and the bleed included, through `CanvasLayout.rendererTransform` (y-up contract on a
/// flipped view). Images come from `CanvasImageCache` (thumbnails loaded off the main thread);
/// frames whose image is not loaded yet are grey, and the view redraws when images arrive.
///
/// Interaction (all through `EditorModel`, every gesture one undo step):
/// click = select a frame (ring), click on the background = deselect; drag in a frame = move the
/// crop (`beginTransform`/`nudge`/`endTransform` on mouse up); scroll wheel or pinch over a photo
/// = zoom (one session per gesture); ⌥-drag = carry the photo to another frame (swap); drop a
/// photo from the tray = `dropPhoto`; double-click a photo = "Obnovit výřez"; double-click a text
/// = overlay editor (`beginTextEditing`/`updateText`/`endTextEditing`); Delete = "Odebrat
/// fotku"; arrows = move the crop (one step per key press-and-hold), without a selection they
/// switch spreads; Escape = deselect. Sessions end on mouse up, selection change, focus loss,
/// window resign key, window close and app termination.
struct SpreadCanvasView: NSViewRepresentable {
    let content: CanvasContent?
    let album: Album
    let revision: Int
    let geometry: PageGeometry
    let package: ProjectPackage
    let issues: [PreflightIssue]
    let selectedFrameID: String?
    /// Read so SwiftUI updates the view when a text session starts or ends (e.g. by Undo).
    let isEditingText: Bool
    let model: EditorModel

    func makeNSView(context: Context) -> SpreadCanvasNSView {
        let view = SpreadCanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: SpreadCanvasNSView, context: Context) {
        view.model = model
        view.update(content: content, album: album, revision: revision, geometry: geometry, package: package,
                    issues: issues, selectedFrameID: selectedFrameID)
    }
}

/// Thumbnails of the photos on the canvas, per photo id. Loaded with `SpreadRenderer.loadImages`
/// and a `PackageImageProvider` on a detached task (never on the main thread). `imageDPI` is 1, so
/// the size hint (drawn width in inches) stays far below the 1024 px limit and the provider
/// always returns the stored thumbnail, even for a photo zoomed 4x over the whole spread. The
/// provider snapshots the album, which is fine for thumbnails: they do not depend on the
/// originals, so no rebuild is needed when originals are downloaded.
///
/// A photo without a thumbnail yet (analysis has not reached it) is retried at the next album
/// revision (analysis results bump it).
///
/// Bounded to `maxEntries` images: above that the least recently shown photos are evicted, never
/// one of the page shown last (so the current page does not flicker grey).
@MainActor
final class CanvasImageCache {
    static let maxEntries = 120
    nonisolated static let loadOptions = RenderOptions(showGuides: false, includeBleed: true, pixelsPerMM: 1,
                                                       imageDPI: 1)

    var onLoad: (() -> Void)?
    private var images: [PhotoID: CGImage] = [:]
    private var inFlight: Set<PhotoID> = []
    private var missingAt: [PhotoID: Int] = [:]
    /// When each photo was last asked for (`useTick` of that request).
    private var lastUsed: [PhotoID: Int] = [:]
    private var useTick = 0

    func images(for page: Spread, area: PrintArea, album: Album, revision: Int, geometry: PageGeometry,
                package: ProjectPackage) -> [PhotoID: CGImage] {
        let ids = Set(page.frames.compactMap(\.photoID))
        useTick += 1
        for id in ids { lastUsed[id] = useTick }
        let missing = ids.filter { images[$0] == nil && !inFlight.contains($0) && missingAt[$0] != revision }
        if !missing.isEmpty {
            load(missing, page: page, area: area, album: album, revision: revision, geometry: geometry,
                 package: package)
        }
        return images.filter { ids.contains($0.key) }
    }

    private func load(_ ids: Set<PhotoID>, page: Spread, area: PrintArea, album: Album, revision: Int,
                      geometry: PageGeometry, package: ProjectPackage) {
        inFlight.formUnion(ids)
        var request = page
        request.frames = page.frames.filter { $0.photoID.map(ids.contains) ?? false }
        let renderer = SpreadRenderer(album: album, geometry: geometry,
                                      images: PackageImageProvider(package: package, album: album))
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                await renderer.loadImages(for: request, options: CanvasImageCache.loadOptions, area: area)
            }.value
            self?.finish(ids, loaded, revision)
        }
    }

    private func finish(_ ids: Set<PhotoID>, _ loaded: [PhotoID: CGImage], _ revision: Int) {
        inFlight.subtract(ids)
        for id in ids {
            if let image = loaded[id] {
                images[id] = image
                missingAt[id] = nil
            } else {
                missingAt[id] = revision
            }
        }
        for id in Self.evictionVictims(cached: Set(images.keys), lastUsed: lastUsed, currentTick: useTick,
                                       maxEntries: Self.maxEntries) {
            images[id] = nil
            lastUsed[id] = nil
        }
        if !loaded.isEmpty { onLoad?() }
    }

    /// The least recently used photos to drop so at most `maxEntries` stay, oldest first; photos of
    /// the latest request (`currentTick`) are never dropped (the cache may then stay above the
    /// bound until the page changes). Ties by id, so the choice is deterministic.
    nonisolated static func evictionVictims(cached: Set<PhotoID>, lastUsed: [PhotoID: Int], currentTick: Int,
                                            maxEntries: Int) -> [PhotoID] {
        let excess = cached.count - maxEntries
        guard excess > 0 else { return [] }
        return cached.filter { lastUsed[$0] != currentTick }
            .sorted { (lastUsed[$0] ?? Int.min, $0) < (lastUsed[$1] ?? Int.min, $1) }
            .prefix(excess)
            .map { $0 }
    }
}

final class SpreadCanvasNSView: NSView, NSTextViewDelegate, NSDraggingSource, NSViewToolTipOwner {
    weak var model: EditorModel?

    private var content: CanvasContent?
    private var album: Album?
    private var revision = 0
    private var geometry: PageGeometry?
    private var package: ProjectPackage?
    private var issues: [PreflightIssue] = []
    private var selectedFrameID: String?
    private let imageCache = CanvasImageCache()

    /// Badges in view coordinates (rebuilt on update and layout), for drawing and tooltips.
    private var badges: [(rect: CGRect, severity: PreflightSeverity, tooltip: String)] = []
    private var dropTargetFrame: String?

    private struct DragState {
        var frameID: String
        var start: CGPoint
        var startOffset: Point
        var zoom: Double
        var frameRect: Rect
        var photoSize: Size
        var began = false
    }

    private var drag: DragState?
    private var scrollFrame: String?
    private var scrollIdleEnd: Task<Void, Never>?
    private var magnifyFrame: String?
    private var arrowSession = false

    private var overlay: CanvasTextView?
    /// The scroll view around `overlay` (a text longer than its box scrolls instead of vanishing).
    private var overlayScroll: NSScrollView?
    private var overlayTextID: String?
    private var observers: [NSObjectProtocol] = []

    static let padding: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([PhotoPasteboard.type, .string])
        imageCache.onLoad = { [weak self] in self?.needsDisplay = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dvoustrana")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var isEditable: Bool { content.map { !$0.isCover } ?? false }
    private var area: PrintArea { content?.isCover == true ? .cover : .spread }

    // MARK: Update from SwiftUI

    func update(content: CanvasContent?, album: Album, revision: Int, geometry: PageGeometry, package: ProjectPackage,
                issues: [PreflightIssue], selectedFrameID: String?) {
        let pageChanged = content?.page.id != self.content?.page.id || content?.isCover != self.content?.isCover
        if pageChanged {
            endGestures()
            finishTextEditing()
        }
        self.content = content
        self.album = album
        self.revision = revision
        self.geometry = geometry
        self.package = package
        self.issues = issues
        self.selectedFrameID = selectedFrameID
        syncOverlay()
        rebuildBadges()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionOverlay()
        rebuildBadges()
    }

    /// The page as drawn: the model's live spread (session preview), else the last update's.
    private var page: Spread? {
        guard let content else { return nil }
        if !content.isCover, let live = model?.displayedSpread(content.page.id) { return live }
        return content.page
    }

    private var layoutForBounds: CanvasLayout? {
        guard let geometry, let content else { return nil }
        let layout = CanvasLayout(visibleArea: CanvasLayout.visibleArea(geometry: geometry, isCover: content.isCover),
                                  viewSize: bounds.size, padding: Self.padding)
        return layout.scale > 0 ? layout : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let page, let album, let geometry, let package, let layout = layoutForBounds,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        var drawn = page
        if let id = overlayTextID, let i = drawn.texts.firstIndex(where: { $0.id == id }) {
            drawn.texts[i].text = ""  // the overlay shows it; drawn below it would double faintly
        }
        let images = imageCache.images(for: page, area: area, album: album, revision: revision, geometry: geometry,
                                       package: package)
        let renderer = SpreadRenderer(album: album, geometry: geometry, images: PlaceholderImageProvider())
        let options = RenderOptions(showGuides: true, includeBleed: true, pixelsPerMM: layout.scale)
        ctx.saveGState()
        ctx.concatenate(layout.rendererTransform)
        if content?.isCover == true {
            renderer.drawCover(drawn, images: images, into: ctx, options: options)
        } else {
            renderer.draw(drawn, images: images, into: ctx, options: options)
        }
        ctx.restoreGState()

        drawBleedTint(layout, geometry: geometry)
        drawTextBoxes(page, layout)
        if let id = selectedFrameID, let frame = page.frames.first(where: { $0.id == id }) {
            let path = NSBezierPath(rect: layout.viewRect(frame.rect).insetBy(dx: -1, dy: -1))
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let id = dropTargetFrame, let frame = page.frames.first(where: { $0.id == id }) {
            let r = layout.viewRect(geometry.bleedExtended(frame.rect, area: area))
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            r.fill(using: .sourceOver)
            let path = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        for badge in badges { drawBadge(badge.rect, severity: badge.severity) }
    }

    /// The bleed band (visible area minus trim) lightly tinted, so the cut is obvious.
    private func drawBleedTint(_ layout: CanvasLayout, geometry: PageGeometry) {
        let trim = content?.isCover == true ? geometry.pageRect(side: .left)
            : Rect(origin: Point(x: 0, y: 0), size: geometry.spreadSize)
        let path = NSBezierPath(rect: layout.contentRect)
        path.append(NSBezierPath(rect: layout.viewRect(trim)))
        path.windingRule = .evenOdd
        NSColor.systemRed.withAlphaComponent(0.08).setFill()
        path.fill()
    }

    /// Text boxes are invisible when empty in print; on screen they get a dashed outline and the
    /// template's placeholder, so they can be found and double-clicked.
    private func drawTextBoxes(_ page: Spread, _ layout: CanvasLayout) {
        for box in page.texts where box.id != overlayTextID {
            let r = layout.viewRect(box.rect)
            let path = NSBezierPath(rect: r)
            path.lineWidth = 1
            path.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            guard box.text.isEmpty, let placeholder = EditorText.placeholder(templateID: page.templateID, textID: box.id)
            else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: box.role, scale: layout.scale),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
            NSAttributedString(string: placeholder, attributes: attributes)
                .draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawBadge(_ rect: CGRect, severity: PreflightSeverity) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
        let name = severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let color: NSColor = severity == .error ? .systemRed : .systemOrange
        let config = NSImage.SymbolConfiguration(pointSize: rect.height - 4, weight: .bold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    private func font(for role: TextRole, scale: CGFloat) -> NSFont {
        let spec = SpreadRenderer.font(for: role)
        return CTFontCreateWithName(spec.name as CFString, max(spec.size * scale, 4), nil) as NSFont
    }

    // MARK: Badges and tooltips

    private func rebuildBadges() {
        badges = []
        removeAllToolTips()
        guard let page, let layout = layoutForBounds, let geometry else { return }
        let area = self.area
        badges = WarningBadge.placements(issues, spread: page, bounds: bounds,
                                         frameRect: { geometry.bleedExtended($0.rect, area: area) },
                                         viewRect: { layout.viewRect($0) })
            .map { ($0.rect, $0.severity, $0.tooltip) }
        for badge in badges { addToolTip(badge.rect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        badges.first { $0.rect.contains(point) }?.tooltip ?? ""
    }

    // MARK: Hit testing helpers

    private func mmPoint(_ event: NSEvent) -> Point? {
        layoutForBounds?.mmPoint(convert(event.locationInWindow, from: nil))
    }

    private func mmPoint(_ windowPoint: NSPoint) -> Point? {
        layoutForBounds?.mmPoint(convert(windowPoint, from: nil))
    }

    private func hit(_ p: Point) -> CanvasHit? {
        guard let page, let geometry else { return nil }
        return CanvasHitTest.hit(page, at: p, geometry: geometry, area: area)
    }

    private func frame(_ id: String) -> Frame? {
        page?.frames.first { $0.id == id }
    }

    private func photoSize(_ frame: Frame) -> Size? {
        guard let id = frame.photoID, let photo = album?.photos[id], photo.pixelWidth > 0, photo.pixelHeight > 0
        else { return nil }
        return Size(width: Double(photo.pixelWidth), height: Double(photo.pixelHeight))
    }

    private func printedRect(_ frame: Frame) -> Rect {
        geometry?.bleedExtended(frame.rect, area: area) ?? frame.rect
    }

    /// A photo frame at `p` (for drag, zoom and swap), nil on texts, empty frames and the background.
    private func photoFrame(at p: Point) -> Frame? {
        guard case .frame(let id) = hit(p), let frame = frame(id), frame.photoID != nil else { return nil }
        return frame
    }

    private func select(_ frameID: String?) {
        guard let model else { return }
        if model.selectedFrameID != frameID {
            model.commitSessions()
            model.selectedFrameID = frameID
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isEditable, let model, let p = mmPoint(event) else { return }
        let target = hit(p)
        if event.clickCount == 2 {
            switch target {
            case .text(let id): beginTextOverlay(id)
            case .frame(let id): model.resetCrop(frame: id, in: page?.id)
            case nil: break
            }
            return
        }
        switch target {
        case .frame(let id):
            select(id)
            guard let frame = frame(id), let photoID = frame.photoID, let size = photoSize(frame) else { return }
            if event.modifierFlags.contains(.option) {
                beginSwapDrag(photoID, frame: frame, event: event)
                return
            }
            drag = DragState(frameID: id, start: convert(event.locationInWindow, from: nil), startOffset: frame.offset,
                             zoom: frame.zoom, frameRect: printedRect(frame), photoSize: size)
        case .text:
            select(nil)
        case nil:
            select(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = drag, let model, let layout = layoutForBounds else { return }
        let current = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: current.x - state.start.x, height: current.y - state.start.y)
        if !state.began {
            guard hypot(delta.width, delta.height) >= 3 else { return }
            state.began = true
            drag = state
        }
        // Also after an outside commit mid-gesture (e.g. ⌘Z): a new session, never one step per event.
        ensureTransform(state.frameID)
        let offset = CropMath.offset(start: state.startOffset, drag: layout.mmDelta(delta), frame: state.frameRect,
                                     photo: state.photoSize, zoom: state.zoom)
        model.nudge(frame: state.frameID, offset: offset, zoom: state.zoom, in: page?.id)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if drag?.began == true { model?.endTransform() }
        drag = nil
    }

    // MARK: Zoom: scroll wheel and pinch

    override func scrollWheel(with event: NSEvent) {
        guard isEditable, let model else { return super.scrollWheel(with: event) }
        let frameID: String
        if let scrollFrame {
            frameID = scrollFrame
        } else if let p = mmPoint(event), let frame = photoFrame(at: p) {
            frameID = frame.id
        } else {
            return super.scrollWheel(with: event)
        }
        let step = ScrollZoom.step(phase: event.phase, momentumPhase: event.momentumPhase,
                                   inSession: scrollFrame != nil && model.isTransforming)
        if step.begin {
            select(frameID)
            model.beginTransform(frame: frameID, in: page?.id)
            scrollFrame = frameID
        }
        if step.update, let frame = frame(frameID) {
            ensureTransform(frameID)
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            model.nudge(frame: frameID, offset: frame.offset, zoom: CropMath.zoom(frame.zoom, scrollDelta: delta),
                        in: page?.id)
            needsDisplay = true
        }
        if step.end { endScrollSession() }
        if step.idleEnd {
            scrollIdleEnd?.cancel()
            scrollIdleEnd = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.endScrollSession()
            }
        }
    }

    /// Starts a crop session on the canvas page's frame unless one runs (an outside commit, e.g.
    /// ⌘Z or a toolbar action, may have ended it mid-gesture).
    private func ensureTransform(_ frameID: String) {
        guard let model, !model.isTransforming else { return }
        model.beginTransform(frame: frameID, in: page?.id)
    }

    private func endScrollSession() {
        scrollIdleEnd?.cancel()
        scrollIdleEnd = nil
        if scrollFrame != nil { model?.endTransform() }
        scrollFrame = nil
    }

    override func magnify(with event: NSEvent) {
        guard isEditable, let model else { return }
        let ending = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.began) || (magnifyFrame == nil && !ending) {
            guard let p = mmPoint(event), let frame = photoFrame(at: p) else { return }
            select(frame.id)
            model.beginTransform(frame: frame.id, in: page?.id)
            magnifyFrame = frame.id
        }
        guard let id = magnifyFrame else { return }
        if let frame = frame(id) {
            if !ending { ensureTransform(id) }
            model.nudge(frame: id, offset: frame.offset, zoom: CropMath.zoom(frame.zoom, magnification: event.magnification),
                        in: page?.id)
            needsDisplay = true
        }
        if ending {
            model.endTransform()
            magnifyFrame = nil
        }
    }

    // MARK: Keyboard

    private static func arrow(_ keyCode: UInt16) -> (dx: Int, dy: Int)? {
        switch keyCode {
        case 123: (-1, 0)
        case 124: (1, 0)
        case 125: (0, 1)
        case 126: (0, -1)
        default: nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let selected = isEditable ? model.selectedFrameID : nil
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            if let selected { model.clearFrame(selected, in: page?.id); return }
        case 53:  // escape
            endGestures()
            select(nil)
            return
        default:
            break
        }
        if let (dx, dy) = Self.arrow(event.keyCode) {
            if let selected, let frame = frame(selected), let size = photoSize(frame) {
                if !model.isTransforming || !arrowSession {
                    model.beginTransform(frame: selected, in: page?.id)
                    arrowSession = true
                }
                let stepMM = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
                let offset = CropMath.arrowOffset(frame.offset, dx: dx, dy: dy, stepMM: stepMM,
                                                  frame: printedRect(frame), photo: size, zoom: frame.zoom)
                model.nudge(frame: selected, offset: offset, zoom: frame.zoom, in: page?.id)
                needsDisplay = true
                return
            }
            if selected == nil, dy == 0, isEditable {
                if dx < 0 { model.previousSpread() } else { model.nextSpread() }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if arrowSession, Self.arrow(event.keyCode) != nil {
            arrowSession = false
            model?.endTransform()
            return
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        endGestures()
        return super.resignFirstResponder()
    }

    /// Ends crop gestures (drag, scroll, pinch, arrows): each stores its one step.
    private func endGestures() {
        if drag?.began == true { model?.endTransform() }
        drag = nil
        endScrollSession()
        if magnifyFrame != nil { model?.endTransform() }
        magnifyFrame = nil
        if arrowSession { model?.endTransform() }
        arrowSession = false
    }

    // MARK: Window and app lifecycle: never leave a session pending

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.willCloseNotification, window),
            (NSApplication.willResignActiveNotification, nil),
            (NSApplication.willTerminateNotification, nil),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitEverything() }
            })
        }
    }

    /// Ends every gesture and the text overlay, committing what they changed.
    func commitEverything() {
        endGestures()
        finishTextEditing()
        model?.commitSessions()
    }

    // MARK: Text overlay

    private func beginTextOverlay(_ textID: String) {
        guard let model, let page, let box = page.texts.first(where: { $0.id == textID }),
              let layout = layoutForBounds else { return }
        finishTextEditing()
        endGestures()
        select(nil)
        model.beginTextEditing(textID, in: page.id)

        let (scroll, view) = Self.makeTextOverlay(frame: layout.viewRect(box.rect))
        view.font = font(for: box.role, scale: layout.scale)
        view.isMultiline = EditorText.isMultiline(box.role)
        view.string = box.text
        view.delegate = self
        view.onFinish = { [weak self] in self?.finishTextEditing() }
        view.onResign = { [weak self] in self?.finishTextEditing(resigning: true) }
        addSubview(scroll)
        overlayScroll = scroll
        overlay = view
        overlayTextID = textID
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Ends the overlay: the model stores the text as one step "Upravit text". Idempotent.
    ///
    /// `resigning`: called from the text view's own `resignFirstResponder` (a click elsewhere,
    /// another window): the first responder is already changing, so no nested
    /// `makeFirstResponder`. The view is hidden at once and removed on the next run-loop turn,
    /// never while AppKit is still inside its resign.
    private func finishTextEditing(resigning: Bool = false) {
        guard let view = overlay else { return }
        let container: NSView = overlayScroll ?? view
        overlay = nil
        overlayScroll = nil
        overlayTextID = nil
        view.onFinish = nil
        view.onResign = nil
        view.delegate = nil
        model?.endTextEditing()
        if !resigning, window?.firstResponder === view { window?.makeFirstResponder(self) }
        container.isHidden = true
        DispatchQueue.main.async { container.removeFromSuperview() }
        needsDisplay = true
    }

    /// After an Undo/Redo the model has no session any more: the overlay shows the stored text,
    /// and the next keystroke begins a new session (`textDidChange`). A text that vanished (spread
    /// changed, template changed) closes the overlay.
    private func syncOverlay() {
        guard let view = overlay, let id = overlayTextID else { return }
        guard let box = page?.texts.first(where: { $0.id == id }) else { return finishTextEditing() }
        if model?.isEditingText != true, !view.hasMarkedText(), view.string != box.text {
            view.string = box.text
        }
        positionOverlay()
    }

    private func positionOverlay() {
        guard let view = overlay, let id = overlayTextID, let layout = layoutForBounds,
              let box = page?.texts.first(where: { $0.id == id }) else { return }
        let rect = layout.viewRect(box.rect)
        if let scroll = overlayScroll {
            scroll.frame = rect
            view.minSize = NSSize(width: scroll.contentSize.width, height: scroll.contentSize.height)
            view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        } else {
            view.frame = rect
        }
        view.font = font(for: box.role, scale: layout.scale)
    }

    /// The overlay editor for a text box at `frame` (view coordinates): a `CanvasTextView` in a
    /// scroll view the size of the box. The text wraps at the box width and grows downwards; when
    /// it is longer than the box a vertical scroller appears, so the overflowing end stays visible
    /// and editable (the print cuts it: Preflight warns "Text se nevejde do rámečku").
    static func makeTextOverlay(frame: CGRect) -> (scroll: NSScrollView, text: CanvasTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
        scroll.layer?.borderWidth = 1.5

        let size = scroll.contentSize
        let view = CanvasTextView(frame: NSRect(origin: .zero, size: size))
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false  // Undo goes through EditorModel (UndoRouter), never the field's own stack.
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.textColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        view.insertionPointColor = .controlAccentColor
        view.drawsBackground = true
        view.backgroundColor = NSColor.white.withAlphaComponent(0.92)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = size
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("Text dvoustrany")
        scroll.documentView = view
        return (scroll, view)
    }

    func textDidChange(_ notification: Notification) {
        guard let view = overlay, let id = overlayTextID, let model, let spreadID = page?.id else { return }
        if !model.isEditingText { model.beginTextEditing(id, in: spreadID) }
        model.updateText(view.string)
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        finishTextEditing(resigning: true)
    }

    // MARK: Dragging a photo to another frame (⌥-drag)

    private func beginSwapDrag(_ photoID: PhotoID, frame: Frame, event: NSEvent) {
        guard let layout = layoutForBounds else { return }
        let rect = layout.viewRect(frame.rect).intersection(bounds)
        let item = NSDraggingItem(pasteboardWriter: PhotoPasteboard.item(for: photoID))
        var image: NSImage?
        if let rep = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: rep)
            let snapshot = NSImage(size: rect.size)
            snapshot.addRepresentation(rep)
            image = snapshot
        }
        item.setDraggingFrame(rect, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    // MARK: Drop target (photo from the tray or another frame)

    private func dropFrame(_ sender: NSDraggingInfo) -> String? {
        guard isEditable, PhotoPasteboard.photoID(from: sender.draggingPasteboard) != nil,
              let p = mmPoint(sender.draggingLocation), case .frame(let id) = hit(p) else { return nil }
        return id
    }

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        return [.copy, .move, .generic].first { mask.contains($0) } ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = dropFrame(sender)
        if target != dropTargetFrame {
            dropTargetFrame = target
            needsDisplay = true
        }
        return target == nil ? [] : operation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetFrame = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dropTargetFrame = nil
            needsDisplay = true
        }
        guard let model, let frameID = dropFrame(sender),
              let photoID = PhotoPasteboard.photoID(from: sender.draggingPasteboard) else { return false }
        endGestures()
        select(frameID)
        let spreadID = page?.id
        switch model.dropPhoto(photoID, onFrame: frameID, in: spreadID) {
        case .placed:
            return true
        case .rejected:
            return false
        case let .needsDuplicateDecision(locations):
            // The decision arrives asynchronously, so the drop itself counts as accepted.
            guard let window else { return false }
            askAboutDuplicate(photoID, frameID: frameID, spreadID: spreadID, locations: locations,
                              model: model, window: window)
            return true
        }
    }

    /// "Tahle fotka už v knize je": a sheet on the window. The ids are captured; if the spread is
    /// gone when the user answers, `dropPhoto` rejects the drop.
    private func askAboutDuplicate(_ photoID: PhotoID, frameID: String, spreadID: String?, locations: [String],
                                   model: EditorModel, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Tahle fotka už v knize je"
        alert.informativeText = "Je na: \(locations.joined(separator: ", "))."
        alert.addButton(withTitle: "Dát i sem")
        alert.addButton(withTitle: "Přesunout sem")
        let cancel = alert.addButton(withTitle: "Zrušit")
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            let policy: DuplicatePolicy
            switch response {
            case .alertFirstButtonReturn: policy = .keepBoth
            case .alertSecondButtonReturn: policy = .move
            default: return
            }
            model.dropPhoto(photoID, onFrame: frameID, in: spreadID, duplicates: policy)
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTargetFrame = nil
        needsDisplay = true
    }
}

/// The overlay text editor: Escape ends editing (the model has no cancel: the session is
/// committed), Return ends single-line texts; the field has no undo of its own.
final class CanvasTextView: NSTextView {
    var onFinish: (() -> Void)?
    /// Called after the view resigned first responder: AppKit does not always post an end-editing
    /// notification when nothing was typed, and an unfocused overlay must not stay behind.
    var onResign: (() -> Void)?
    var isMultiline = true

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish?()
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !isMultiline, event.modifierFlags.intersection([.shift, .option]).isEmpty {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}
