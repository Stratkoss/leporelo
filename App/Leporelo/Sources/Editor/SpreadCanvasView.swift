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
/// click = select a frame or text (`selectedItem`; 8 handles), click on the background =
/// deselect; drag inside an item = move it, drag a handle = resize it (`LayoutDrag`, snapped by
/// `SnapEngine` unless ⌘ is held, ⇧ on a corner keeps the ratio; `beginLayoutChange`/
/// `updateLayout`/`endLayoutChange` on mouse up; guides drawn while snapped); double-click a photo
/// = crop mode (`cropFrameID`: dashed accent border, a drag moves the crop with
/// `beginTransform`/`nudge`/`endTransform`, Escape, Return or a click elsewhere leave it); scroll
/// wheel or pinch over a photo = zoom (one session per gesture, also outside crop mode); ⌥-drag =
/// carry the photo to another frame (swap); drop a photo from the tray = `dropPhoto`;
/// double-click a text = overlay editor (`beginTextEditing`/`updateText`/`endTextEditing`; drawn
/// in the text's printed style, `EditorModel.overlayTextID` while open, the text stays selected
/// after it);
/// Delete = "Odebrat fotku" on a photo, "Smazat" on an empty frame or a text; arrows = move the
/// selected item by 1 mm (⇧ 5 mm), in crop mode the crop, one step per key press-and-hold;
/// without a selection they switch spreads; Escape = deselect; right click = context menu.
/// Every click on a spread also makes its page the current page (`EditorModel.currentPageSide`,
/// spec 5), drawn with a 2 pt accent outline inset 1 pt; not on the cover.
/// `showGrid` draws a 5 mm grid on each page. The cover is read-only. Sessions end on mouse up,
/// selection change, focus loss, window resign key, window close and app termination.
struct SpreadCanvasView: NSViewRepresentable {
    let content: CanvasContent?
    let album: Album
    let revision: Int
    let geometry: PageGeometry
    let package: ProjectPackage
    let issues: [PreflightIssue]
    let selectedItem: LayoutItem?
    /// The page outlined as current; nil on the cover.
    let currentPageSide: PageSide?
    let snapSettings: SnapSettings
    let showGrid: Bool
    /// Read so SwiftUI updates the view when a text session starts or ends (e.g. by Undo).
    let isEditingText: Bool
    let model: EditorModel
    /// "Doporučené rozložení…" from the context menu, for the spread with this id.
    let onChangeLayout: (String) -> Void

    func makeNSView(context: Context) -> SpreadCanvasNSView {
        let view = SpreadCanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: SpreadCanvasNSView, context: Context) {
        view.model = model
        view.onChangeLayout = onChangeLayout
        view.update(content: content, album: album, revision: revision, geometry: geometry, package: package,
                    issues: issues, selectedItem: selectedItem, currentPageSide: currentPageSide,
                    snapSettings: snapSettings, showGrid: showGrid)
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
    var onChangeLayout: ((String) -> Void)?

    private var content: CanvasContent?
    private var album: Album?
    private var revision = 0
    private var geometry: PageGeometry?
    private var package: ProjectPackage?
    private var issues: [PreflightIssue] = []
    private var selectedItem: LayoutItem?
    private var currentPageSide: PageSide?
    private var snapSettings = SnapSettings(grid: false, objects: true)
    private var showGrid = false
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

    /// A mouse drag that moves (`edges == .all`) or resizes a frame or text.
    private struct LayoutDragState {
        var item: LayoutItem
        var edges: RectEdges
        var start: CGPoint
        var startRect: Rect
        var began = false
    }

    private var layoutDrag: LayoutDragState?
    /// The guides of the last snap during a layout drag (cleared on mouse up).
    private var snapGuides: [SnapGuide] = []
    /// The distances around the dragged or nudged item and its equal sizes, drawn with the guides.
    private var measurements: (gaps: [Gap], sizes: [SizeMatch]) = ([], [])
    /// Clears the distances shortly after the last arrow key is released.
    private var measurementsClear: Task<Void, Never>?
    /// The photo frame in crop mode (double-click): a drag moves its crop, not the frame.
    private var cropFrameID: String?
    private var layoutArrowSession = false
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
    /// Side of a resize handle in points.
    static let handleSize: CGFloat = 7
    /// Snapping reaches this far, in points (converted to mm with the layout's scale).
    static let snapThreshold: CGFloat = 8
    /// The distances of an arrow nudge stay this long after the last key is released.
    static let nudgeMeasurementsDelay: Duration = .milliseconds(600)

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
                issues: [PreflightIssue], selectedItem: LayoutItem?, currentPageSide: PageSide?,
                snapSettings: SnapSettings, showGrid: Bool) {
        let pageChanged = content?.page.id != self.content?.page.id || content?.isCover != self.content?.isCover
        if pageChanged {
            endGestures()
            finishTextEditing(reselect: false)
            cropFrameID = nil
        }
        self.content = content
        self.album = album
        self.revision = revision
        self.geometry = geometry
        self.package = package
        self.issues = issues
        self.selectedItem = selectedItem
        self.currentPageSide = currentPageSide
        self.snapSettings = snapSettings
        self.showGrid = showGrid
        // Crop mode ends when its frame is no longer the selection or has no photo (undo, Delete).
        if let crop = cropFrameID, !isEditable || selectedItem != .frame(crop) || frame(crop)?.photoID == nil {
            cropFrameID = nil
        }
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
        if showGrid, isEditable { drawGrid(layout, geometry: geometry) }
        drawCurrentPage(layout, geometry: geometry)
        drawSelection(page, layout)
        if let id = dropTargetFrame, let frame = page.frames.first(where: { $0.id == id }) {
            let r = layout.viewRect(geometry.bleedExtended(frame.rect, area: area))
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            r.fill(using: .sourceOver)
            let path = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        drawGuides(layout, geometry: geometry)
        drawMeasurements(layout)
        for badge in badges { drawBadge(badge.rect, severity: badge.severity) }
    }

    /// Lines every `snapSettings.gridMM` (5 mm) inside the trim of each page, the same lines the
    /// grid snaps to. The pages are paper, so the colour resolves in the light appearance.
    private func drawGrid(_ layout: CanvasLayout, geometry: PageGeometry) {
        let step = snapSettings.gridMM
        guard step > 0, step * layout.scale >= 3 else { return }
        let path = NSBezierPath()
        for side in [PageSide.left, .right] {
            let r = geometry.pageRect(side: side)
            var k = 1
            while r.minX + Double(k) * step < r.maxX - 1e-6 {
                let x = r.minX + Double(k) * step
                path.move(to: layout.viewPoint(Point(x: x, y: r.minY)))
                path.line(to: layout.viewPoint(Point(x: x, y: r.maxY)))
                k += 1
            }
            k = 1
            while r.minY + Double(k) * step < r.maxY - 1e-6 {
                let y = r.minY + Double(k) * step
                path.move(to: layout.viewPoint(Point(x: r.minX, y: y)))
                path.line(to: layout.viewPoint(Point(x: r.maxX, y: y)))
                k += 1
            }
        }
        path.lineWidth = 0.5
        (NSAppearance(named: .aqua) ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
            path.stroke()
        }
    }

    /// The current page ("Zkusit jinak", the picker): a 2 pt accent outline inset 1 pt into the
    /// page's trim. Never on the cover.
    private func drawCurrentPage(_ layout: CanvasLayout, geometry: PageGeometry) {
        guard isEditable, let side = currentPageSide else { return }
        let path = NSBezierPath(rect: layout.viewRect(geometry.pageRect(side: side)).insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// The page under `p` (spread mm): left of the spine is the left page.
    private func pageSide(at p: Point) -> PageSide? {
        guard let geometry else { return nil }
        return p.x < geometry.format.pageWidthMM ? .left : .right
    }

    /// The selected frame (ring) or text (outline) with its 8 handles; in crop mode the frame gets
    /// a dashed accent border instead, without handles.
    private func drawSelection(_ page: Spread, _ layout: CanvasLayout) {
        guard isEditable else { return }
        if let id = cropFrameID, let frame = page.frames.first(where: { $0.id == id }) {
            let path = NSBezierPath(rect: layout.viewRect(printedRect(frame)).insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            return
        }
        guard let item = selectedItem, let rect = itemRect(item) else { return }
        if case .text(let id) = item, id == overlayTextID { return }
        let r = layout.viewRect(rect)
        let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
        if case .frame = item { path.lineWidth = 3 } else { path.lineWidth = 1.5 }
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        let s = Self.handleSize
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let handle = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            NSColor.white.setFill()
            handle.insetBy(dx: -1, dy: -1).fill()
            NSColor.controlAccentColor.setFill()
            handle.fill()
        }
    }

    /// The snap guides of the running drag, 1 point, across the whole spread.
    private func drawGuides(_ layout: CanvasLayout, geometry: PageGeometry) {
        guard !snapGuides.isEmpty else { return }
        let size = geometry.spreadSize
        let path = NSBezierPath()
        for guide in snapGuides {
            switch guide.axis {
            case .x:
                path.move(to: layout.viewPoint(Point(x: guide.position, y: 0)))
                path.line(to: layout.viewPoint(Point(x: guide.position, y: size.height)))
            case .y:
                path.move(to: layout.viewPoint(Point(x: 0, y: guide.position)))
                path.line(to: layout.viewPoint(Point(x: size.width, y: guide.position)))
            }
        }
        path.lineWidth = 1
        SnapStyle.purple.setStroke()
        path.stroke()
    }

    /// The distances of the running drag or nudge: per gap a 1 point line with 4 point ticks at
    /// its ends and its length in the middle; an equal size gets its length on the middle of the
    /// rect's bottom (width) or right (height) edge.
    private func drawMeasurements(_ layout: CanvasLayout) {
        guard !measurements.gaps.isEmpty || !measurements.sizes.isEmpty else { return }
        let tick: CGFloat = 2
        let path = NSBezierPath()
        for gap in measurements.gaps {
            let start: CGPoint, end: CGPoint
            switch gap.axis {
            case .x:
                start = layout.viewPoint(Point(x: gap.from, y: gap.at))
                end = layout.viewPoint(Point(x: gap.to, y: gap.at))
                for p in [start, end] {
                    path.move(to: CGPoint(x: p.x, y: p.y - tick))
                    path.line(to: CGPoint(x: p.x, y: p.y + tick))
                }
            case .y:
                start = layout.viewPoint(Point(x: gap.at, y: gap.from))
                end = layout.viewPoint(Point(x: gap.at, y: gap.to))
                for p in [start, end] {
                    path.move(to: CGPoint(x: p.x - tick, y: p.y))
                    path.line(to: CGPoint(x: p.x + tick, y: p.y))
                }
            }
            path.move(to: start)
            path.line(to: end)
        }
        path.lineWidth = 1
        SnapStyle.purple.setStroke()
        path.stroke()
        for gap in measurements.gaps {
            let mid = gap.from + (gap.to - gap.from) / 2
            let centre = gap.axis == .x ? Point(x: mid, y: gap.at) : Point(x: gap.at, y: mid)
            drawMeasurementLabel(EditorText.millimetres(gap.to - gap.from), at: layout.viewPoint(centre))
        }
        for size in measurements.sizes {
            let r = size.rect
            let centre = size.axis == .x ? Point(x: r.minX + r.size.width / 2, y: r.maxY)
                : Point(x: r.maxX, y: r.minY + r.size.height / 2)
            drawMeasurementLabel(EditorText.millimetres(size.length), at: layout.viewPoint(centre))
        }
    }

    /// White 10 point digits on a purple rounded rect, centred on `centre`.
    private func drawMeasurementLabel(_ text: String, at centre: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let size = label.size()
        let box = CGRect(x: centre.x - size.width / 2 - 3, y: centre.y - size.height / 2 - 1.5,
                         width: size.width + 6, height: size.height + 3)
        SnapStyle.purple.setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: box.minX + 3, y: box.minY + 1.5))
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
            let style = resolvedStyle(box)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = Self.alignment(style.alignment)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font(style, scale: layout.scale),
                .foregroundColor: NSColor.placeholderTextColor,
                .paragraphStyle: paragraph,
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

    /// The look `box` is printed with (`SpreadRenderer.resolvedStyle`; the spine decides a page
    /// number's default alignment, none on the cover).
    private func resolvedStyle(_ box: TextBox) -> ResolvedTextStyle {
        let pageWidth = content?.isCover == false ? geometry?.format.pageWidthMM : nil
        return SpreadRenderer.resolvedStyle(for: box, pageWidth: pageWidth)
    }

    /// The printed font of `style` at the canvas scale (`ctFont` sizes in mm, so points = mm size
    /// × points per mm), at least 4 pt.
    static func font(_ style: ResolvedTextStyle, scale: CGFloat) -> NSFont {
        var scaled = style
        scaled.sizePt = max(style.sizePt * Double(scale), 4 * 72 / 25.4)
        return SpreadRenderer.ctFont(for: scaled) as NSFont
    }

    static func alignment(_ alignment: LeporeloCore.TextAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
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

    /// The rectangle (spread mm, as stored, without bleed) of a frame or text of the page shown.
    private func itemRect(_ item: LayoutItem) -> Rect? {
        switch item {
        case .frame(let id): frame(id)?.rect
        case .text(let id): page?.texts.first { $0.id == id }?.rect
        }
    }

    /// Selects a frame or text (nil: nothing), committing running sessions when it changes; crop
    /// mode ends unless its frame stays selected.
    private func select(_ item: LayoutItem?) {
        guard let model else { return }
        if model.selectedItem != item {
            model.commitSessions()
            model.selectedItem = item
        }
        selectedItem = model.selectedItem
        if let crop = cropFrameID, item != .frame(crop) { endCropMode() }
        needsDisplay = true
    }

    // MARK: Crop mode

    /// Double-click on a photo (or "Upravit výřez"): a drag in the frame now moves the crop.
    private func beginCropMode(_ frameID: String) {
        guard isEditable, frame(frameID)?.photoID != nil else { return }
        endGestures()
        select(.frame(frameID))
        cropFrameID = frameID
        needsDisplay = true
    }

    private func endCropMode() {
        guard cropFrameID != nil else { return }
        if drag?.began == true { model?.endTransform() }
        drag = nil
        if arrowSession { model?.endTransform() }
        arrowSession = false
        cropFrameID = nil
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isEditable, let model, let p = mmPoint(event) else { return }
        // Any click chooses its page; a selected item's centre still wins (`currentPageSide`).
        model.currentPageSide = pageSide(at: p)
        let target = hit(p)
        if event.clickCount == 2 {
            switch target {
            case .text(let id): beginTextOverlay(id)
            case .frame(let id): beginCropMode(id)
            case nil: break
            }
            return
        }
        if let crop = cropFrameID {
            if target == .frame(crop) {
                beginCropDrag(crop, event: event)
                return
            }
            endCropMode()  // a click elsewhere leaves crop mode and acts as usual
        }
        if let item = selectedItem, let rect = itemRect(item), let edges = handleEdges(at: p, rect: rect) {
            beginLayoutDrag(item, edges: edges, rect: rect, event: event)
            return
        }
        switch target {
        case .frame(let id):
            select(.frame(id))
            guard let frame = frame(id) else { return }
            if event.modifierFlags.contains(.option), let photoID = frame.photoID {
                beginSwapDrag(photoID, frame: frame, event: event)
                return
            }
            beginLayoutDrag(.frame(id), edges: .all, rect: frame.rect, event: event)
        case .text(let id):
            select(.text(id))
            if let rect = itemRect(.text(id)) { beginLayoutDrag(.text(id), edges: .all, rect: rect, event: event) }
        case nil:
            select(nil)
        }
    }

    /// The handle of the selected item's `rect` under `p`: within half a handle plus 2 points.
    private func handleEdges(at p: Point, rect: Rect) -> RectEdges? {
        guard let layout = layoutForBounds else { return nil }
        return LayoutHandles.hit(p, rect: rect, tolerance: Double((Self.handleSize / 2 + 2) / layout.scale))
    }

    private func beginLayoutDrag(_ item: LayoutItem, edges: RectEdges, rect: Rect, event: NSEvent) {
        layoutDrag = LayoutDragState(item: item, edges: edges, start: convert(event.locationInWindow, from: nil),
                                     startRect: rect)
    }

    private func beginCropDrag(_ frameID: String, event: NSEvent) {
        guard let frame = frame(frameID), let photoID = frame.photoID, let size = photoSize(frame) else { return }
        if event.modifierFlags.contains(.option) {
            beginSwapDrag(photoID, frame: frame, event: event)
            return
        }
        drag = DragState(frameID: frameID, start: convert(event.locationInWindow, from: nil), startOffset: frame.offset,
                         zoom: frame.zoom, frameRect: printedRect(frame), photoSize: size)
    }

    /// `rect` snapped by `SnapEngine` (targets: the page edges, margins and centres, the other
    /// frames and texts of the spread with their equal gaps (`SpacingGuides.spacingLines`) and,
    /// for a resize, equal sizes (`sizeLines`), the grid; per `snapSettings`, without the lines
    /// inside a margin band: `MarginRule.allowedTargets`), threshold 8 points. Sets the guides of
    /// the axes that snapped to an alignment line (`mouseDragged` then keeps only those the
    /// conformed result touches) and returns the
    /// reasons of the snap, nil when snapping is off: while ⌘ is held, for a ⇧ corner resize (the
    /// snapped edges would break the kept ratio) or with both "Přichytávat" and "Mřížka" off.
    private func snapped(_ rect: Rect, edges: RectEdges, item: LayoutItem, keepAspect: Bool, flags: NSEvent.ModifierFlags,
                         scale: CGFloat) -> (rect: Rect, reasons: [SnapAxis: SnapReason]?) {
        snapGuides = []
        guard !flags.contains(.command), !keepAspect, snapSettings.grid || snapSettings.objects,
              let geometry, let model, let pageRect = pageRect(containing: rect), scale > 0 else { return (rect, nil) }
        let others = otherRects(item)
        var targets = SnapEngine.targets(geometry: geometry, marginMM: model.marginMM, area: .spread, others: others,
                                         settings: snapSettings)
        if snapSettings.objects {
            let spacing = SpacingGuides.spacingLines(for: rect, moving: edges, others: others, page: pageRect)
            let sizes = SpacingGuides.sizeLines(for: rect, moving: edges, others: others)
            targets = SnapTargets(x: targets.x + spacing.x + sizes.x, y: targets.y + spacing.y + sizes.y)
        }
        targets = MarginRule(geometry: geometry, marginMM: model.marginMM).allowedTargets(targets, area: .spread)
        let result = SnapEngine.snap(rect, moving: edges, to: targets, threshold: Double(Self.snapThreshold / scale))
        // Only alignment draws a line across the spread; equal gaps and sizes show their distances.
        snapGuides = result.guides.filter { result.reasons[$0.axis] == .alignment }
        return (result.rect, result.reasons)
    }

    /// The stored rects of the spread's frames and texts other than `item`.
    private func otherRects(_ item: LayoutItem) -> [Rect] {
        guard let page else { return [] }
        return page.frames.filter { item != .frame($0.id) }.map(\.rect)
            + page.texts.filter { item != .text($0.id) }.map(\.rect)
    }

    /// The trim of the page `rect`'s centre is on.
    private func pageRect(containing rect: Rect) -> Rect? {
        guard let geometry,
              let side = pageSide(at: Point(x: rect.minX + rect.size.width / 2, y: rect.minY + rect.size.height / 2))
        else { return nil }
        return geometry.pageRect(side: side)
    }

    /// Shows the distances around `item` as it now lies (after the margin rule) and, per axis in
    /// `equalSizes`, the items of the same width or height; cancels a pending clear.
    private func showMeasurements(_ item: LayoutItem, equalSizes: Set<SnapAxis> = []) {
        measurementsClear?.cancel()
        measurementsClear = nil
        guard let rect = itemRect(item), let pageRect = pageRect(containing: rect) else {
            measurements = ([], [])
            return
        }
        let others = otherRects(item)
        let sizes = equalSizes.isEmpty ? []
            : SpacingGuides.sizeMatches(for: rect, others: others).filter { equalSizes.contains($0.axis) }
        measurements = (SpacingGuides.gaps(for: rect, others: others, page: pageRect), sizes)
    }

    /// Removes the guides and distances (mouse up, end of gestures, ⌘ pressed).
    private func clearSnapMarks() {
        measurementsClear?.cancel()
        measurementsClear = nil
        guard !snapGuides.isEmpty || !measurements.gaps.isEmpty || !measurements.sizes.isEmpty else { return }
        snapGuides = []
        measurements = ([], [])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if var state = layoutDrag, let model, let layout = layoutForBounds {
            let current = convert(event.locationInWindow, from: nil)
            let delta = CGSize(width: current.x - state.start.x, height: current.y - state.start.y)
            if !state.began {
                guard hypot(delta.width, delta.height) >= 3 else { return }
                state.began = true
                layoutDrag = state
                model.beginLayoutChange(state.item, in: page?.id)
            }
            let isCorner = state.edges != .all
                && !state.edges.isDisjoint(with: [.minX, .maxX]) && !state.edges.isDisjoint(with: [.minY, .maxY])
            let keepAspect = isCorner && event.modifierFlags.contains(.shift)
            let raw = LayoutDrag.rect(from: state.startRect, edges: state.edges, delta: layout.mmDelta(delta),
                                      keepAspect: keepAspect, minSize: MarginRule.minItemMM)
            let snap = snapped(raw, edges: state.edges, item: state.item, keepAspect: keepAspect,
                               flags: event.modifierFlags, scale: layout.scale)
            // After an outside commit mid-gesture (e.g. ⌘Z) `updateLayout` starts a new session itself.
            model.updateLayout(state.item, rect: snap.rect, mode: state.edges == .all ? .move : .resize)
            // The margin rule may have moved the item off a snap line: draw only the guides it is on.
            if let shown = itemRect(state.item) { snapGuides = SnapEngine.guides(snapGuides, touching: shown) }
            if let reasons = snap.reasons {
                showMeasurements(state.item, equalSizes: Set(reasons.filter { $0.value == .equalSize }.keys))
            } else {
                clearSnapMarks()
            }
            needsDisplay = true
            return
        }
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
        if layoutDrag?.began == true { model?.endLayoutChange() }
        layoutDrag = nil
        clearSnapMarks()
        if drag?.began == true { model?.endTransform() }
        drag = nil
    }

    /// ⌘ pressed mid-drag turns snapping off: its marks go at once, not on the next move.
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { clearSnapMarks() }
        super.flagsChanged(with: event)
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
            select(.frame(frameID))
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
            select(.frame(frame.id))
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
        let selected = isEditable ? model.selectedItem : nil
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            // One press, one action: a held key must not delete the frame its first press emptied.
            if event.isARepeat { return }
            if let selected { deleteOrClear(selected); return }
        case 53:  // escape: leaves crop mode, else deselects
            endGestures()
            if cropFrameID != nil { endCropMode() } else { select(nil) }
            return
        case 36, 76:  // return, enter: leave crop mode
            if cropFrameID != nil {
                endGestures()
                endCropMode()
                return
            }
        default:
            break
        }
        if let (dx, dy) = Self.arrow(event.keyCode) {
            let stepMM = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
            if isEditable, let crop = cropFrameID, let frame = frame(crop), let size = photoSize(frame) {
                if !model.isTransforming || !arrowSession {
                    model.beginTransform(frame: crop, in: page?.id)
                    arrowSession = true
                }
                let offset = CropMath.arrowOffset(frame.offset, dx: dx, dy: dy, stepMM: stepMM,
                                                  frame: printedRect(frame), photo: size, zoom: frame.zoom)
                model.nudge(frame: crop, offset: offset, zoom: frame.zoom, in: page?.id)
                needsDisplay = true
                return
            }
            if let selected, let rect = itemRect(selected) {
                // One layout session per key press-and-hold (repeats included), stored on keyUp. A
                // run that was committed from outside (⌘Z) restarts inside `updateLayout`.
                if !layoutArrowSession {
                    model.beginLayoutChange(selected, in: page?.id)
                    layoutArrowSession = true
                }
                let nudge = Point(x: Double(dx) * stepMM, y: Double(dy) * stepMM)
                let moved = Rect(x: rect.minX + nudge.x, y: rect.minY + nudge.y,
                                 width: rect.size.width, height: rect.size.height)
                // With the nudge a frame steps between the bleed and the margin line instead of
                // being pulled back to where it started.
                model.updateLayout(selected, rect: moved, mode: .move, nudge: nudge)
                if !event.modifierFlags.contains(.command), snapSettings.grid || snapSettings.objects {
                    showMeasurements(selected)
                }
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
        if layoutArrowSession, Self.arrow(event.keyCode) != nil {
            layoutArrowSession = false
            model?.endLayoutChange()
            measurementsClear?.cancel()
            measurementsClear = Task { [weak self] in
                try? await Task.sleep(for: Self.nudgeMeasurementsDelay)
                guard !Task.isCancelled else { return }
                self?.clearSnapMarks()
            }
            return
        }
        super.keyUp(with: event)
    }

    /// Delete: a frame with a photo is emptied ("Odebrat fotku"), an empty frame or a text is
    /// removed ("Smazat").
    private func deleteOrClear(_ item: LayoutItem) {
        guard let model else { return }
        endGestures()
        if case .frame(let id) = item, frame(id)?.photoID != nil {
            endCropMode()
            model.clearFrame(id, in: page?.id)
        } else {
            model.deleteItem(item, in: page?.id)
        }
        needsDisplay = true
    }

    // MARK: Context menu

    /// "Přidat rámeček", "Přidat text" (on the page under the pointer) and, for the item under the
    /// pointer (which becomes the selection), "Upravit výřez", "Obnovit výřez" (a moved or zoomed
    /// crop), "Odebrat fotku" and "Smazat". None on the cover.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditable, let model, let page, let geometry, let p = mmPoint(event) else { return nil }
        window?.makeFirstResponder(self)
        endGestures()
        let spreadID = page.id
        let side: PageSide = p.x < geometry.format.pageWidthMM ? .left : .right
        model.currentPageSide = side
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(EditorText.addFrame) { model.addFrame(on: side, in: spreadID) })
        menu.addItem(ActionMenuItem(EditorText.addText) { model.addText(on: side, in: spreadID) })
        if model.offersLayoutChoice(for: spreadID) {
            menu.addItem(ActionMenuItem(EditorText.changeTemplate) { [weak self] in self?.onChangeLayout?(spreadID) })
        }
        switch hit(p) {
        case .frame(let id):
            select(.frame(id))
            guard let frame = frame(id) else { break }
            menu.addItem(.separator())
            if frame.photoID != nil {
                if cropFrameID != id {
                    menu.addItem(ActionMenuItem(EditorText.editCrop) { [weak self] in self?.beginCropMode(id) })
                }
                if frame.offset != Point(x: 0, y: 0) || frame.zoom != 1 {
                    menu.addItem(ActionMenuItem(EditorText.resetCrop) { model.resetCrop(frame: id, in: spreadID) })
                }
                menu.addItem(ActionMenuItem(EditorText.removePhoto) { [weak self] in
                    self?.endCropMode()
                    model.clearFrame(id, in: spreadID)
                })
            }
            menu.addItem(ActionMenuItem(EditorText.deleteItem) { [weak self] in
                self?.endCropMode()
                model.deleteItem(.frame(id), in: spreadID)
            })
        case .text(let id):
            select(.text(id))
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(EditorText.deleteItem) { model.deleteItem(.text(id), in: spreadID) })
        case nil:
            break
        }
        return menu
    }

    override func resignFirstResponder() -> Bool {
        endGestures()
        return super.resignFirstResponder()
    }

    /// Ends crop and layout gestures (drag, scroll, pinch, arrows): each stores its one step.
    private func endGestures() {
        if layoutDrag?.began == true { model?.endLayoutChange() }
        layoutDrag = nil
        if layoutArrowSession { model?.endLayoutChange() }
        layoutArrowSession = false
        clearSnapMarks()
        if drag?.began == true { model?.endTransform() }
        drag = nil
        endScrollSession()
        if magnifyFrame != nil { model?.endTransform() }
        magnifyFrame = nil
        if arrowSession { model?.endTransform() }
        arrowSession = false
    }

    // MARK: Window and app lifecycle: never leave a session pending

    /// Leaving the window (back to triage) closes the overlay, so `EditorModel.overlayTextID`
    /// does not outlive it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishTextEditing(resigning: true, reselect: false) }
        super.viewWillMove(toWindow: newWindow)
    }

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
        view.isMultiline = EditorText.isMultiline(box.role)
        view.string = box.text
        view.delegate = self
        view.onFinish = { [weak self] in self?.finishTextEditing() }
        view.onResign = { [weak self] in self?.finishTextEditing(resigning: true) }
        addSubview(scroll)
        overlayScroll = scroll
        overlay = view
        overlayTextID = textID
        model.overlayTextID = textID
        applyStyle(of: box, to: view, scale: layout.scale)
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Ends the overlay: the model stores the text as one step "Upravit text". Idempotent.
    /// `reselect`: the edited text becomes the selection, so the text bar stays (a click into its
    /// size field or font popover takes the focus from the overlay); not when the page changed.
    ///
    /// `resigning`: called from the text view's own `resignFirstResponder` (a click elsewhere,
    /// another window): the first responder is already changing, so no nested
    /// `makeFirstResponder`. The view is hidden at once and removed on the next run-loop turn,
    /// never while AppKit is still inside its resign.
    private func finishTextEditing(resigning: Bool = false, reselect: Bool = true) {
        guard let view = overlay else { return }
        let container: NSView = overlayScroll ?? view
        let textID = overlayTextID
        overlay = nil
        overlayScroll = nil
        overlayTextID = nil
        view.onFinish = nil
        view.onResign = nil
        view.delegate = nil
        model?.endTextEditing()
        model?.overlayTextID = nil
        if reselect, let textID, page?.texts.contains(where: { $0.id == textID }) == true { select(.text(textID)) }
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
        guard let box = page?.texts.first(where: { $0.id == id }) else { return finishTextEditing(reselect: false) }
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
        applyStyle(of: box, to: view, scale: layout.scale)
    }

    /// The overlay shows the text as printed: its font, alignment and colour (a light colour on a
    /// dark backing). Set only when changed, so typing (and marked text) is not disturbed.
    private func applyStyle(of box: TextBox, to view: CanvasTextView, scale: CGFloat) {
        let style = resolvedStyle(box)
        let font = Self.font(style, scale: scale)
        if view.font != font { view.font = font }
        let alignment = Self.alignment(style.alignment)
        if view.alignment != alignment { view.alignment = alignment }
        let color = NSColor(cgColor: SpreadRenderer.color(hex: style.colorHex)) ?? .black
        if view.textColor != color { view.textColor = color }
        let backing = TextColour.isLight(style.colorHex) ? NSColor.black.withAlphaComponent(0.6)
            : NSColor.white.withAlphaComponent(0.92)
        if view.backgroundColor != backing { view.backgroundColor = backing }
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
        select(.frame(frameID))
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

/// A context-menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
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
