import Foundation
import LeporeloCore
import Observation
import os

/// The outcome of `EditorModel.changeTemplate`.
enum TemplateChangeOutcome: Equatable {
    /// Applied (one undo step). The photos that got no frame stay selected but unplaced.
    case applied(unplacedPhotoIDs: [PhotoID])
    /// Not applied: these non-empty texts have no slot in the new template. Call again with
    /// `confirmTextLoss: true` once the user agreed.
    case needsTextLossConfirmation([TextBox])
    /// Unknown spread or template, or a template not offered for the spread.
    case unavailable
}

/// The editor's model (spec 6.3 "Návrh alba", 6.4 "Ladění"): the current spread, the selected
/// frame, the photo tray, and every layout edit, all undoable.
///
/// Edits go through the store: single `AlbumEdit`s and edit batches (`AlbumStore.apply`, exact
/// inverses, one undo step per user action) for frame, text and spread changes; whole-album
/// `AlbumStore.replace` for "Navrhnout album", "Navrhnout znovu" and "Změnit formát".
///
/// Coalescing: a text editing session (`beginTextEditing` / `updateText` / `endTextEditing`) and a
/// crop gesture (`beginTransform` / `nudge` / `endTransform`) keep a live preview in the model
/// (`displayedSpread`) and are ONE undo step each. Session text also reaches the store
/// `textCommitDelay` after the last keystroke (same step), because autosave reads the album off
/// the main thread and cannot ask the model to flush (see `AlbumSnapshotBox`). Any other edit,
/// choosing another spread, `undo()`/`redo()` and `AlbumStore.flushPendingEdits()` (window close,
/// rebind) commit a running session first, as its own undo step. 21b routes Edit > Undo/Redo
/// through `undo()`/`redo()`.
///
/// Derived data (tray, placed photos, preflight) is cached per `AlbumStore.revision`; reading any
/// of it observes the store, so views update on every change, undo included.
@MainActor
@Observable
final class EditorModel {
    let store: AlbumStore
    /// The window's undo manager (set by the view); nil means edits without undo.
    @ObservationIgnored var undoManager: UndoManager?

    /// `geometry` seeds the page geometry; the model's profile (e.g. a test's page-count rule) is
    /// kept while the album stays on that profile, also across format changes.
    init(store: AlbumStore, geometry: PageGeometry) {
        self.store = store
        self.geometryCache = geometry
        // The window calls `store.flushPendingEdits()` before it closes or rebinds.
        store.addPendingEditsFlusher { [weak self] in self?.commitSessions() }
    }

    /// How long after the last keystroke a text session's text is written to the store (and so
    /// reaches the autosave snapshot). The session stays one undo step.
    @ObservationIgnored var textCommitDelay: Duration = .milliseconds(500)

    // MARK: Undo

    /// Edit > Undo for the editor (21b routes the menu and ⌘Z here). A running session is
    /// committed first as its own step, then undone: Undo while typing undoes the typing, like a
    /// text editor, and never reverts the step before the session while the preview keeps the text.
    func undo() {
        commitSessions()
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
    }

    /// Edit > Redo for the editor. A session with changed text is committed first (a new change,
    /// so, as in any editor, there is nothing left to redo then).
    func redo() {
        commitSessions()
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
    }

    // MARK: Geometry

    @ObservationIgnored private var geometryCache: PageGeometry

    /// The page geometry of the album's CURRENT profile and format (follows "Změnit formát" and its
    /// undo). Resolved from the model's profile when its id matches the album's, else from
    /// `ProfileCatalog`; an unknown format keeps the last geometry (logged).
    var geometry: PageGeometry {
        let album = store.album
        let cached = geometryCache
        if cached.profile.id == album.supplierProfileID && cached.format.id == album.formatID { return cached }
        if cached.profile.id == album.supplierProfileID,
           let format = cached.profile.formats.first(where: { $0.id == album.formatID }) {
            geometryCache = PageGeometry(format: format, profile: cached.profile)
            return geometryCache
        }
        do {
            let (profile, format) = try ProfileCatalog.format(profileID: album.supplierProfileID,
                                                              formatID: album.formatID)
            geometryCache = PageGeometry(format: format, profile: profile)
        } catch {
            Logger.editor.error("Unknown format \(album.supplierProfileID, privacy: .public)/\(album.formatID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return geometryCache
    }

    // MARK: Derived data (per store revision)

    private struct Derived {
        var days: [DayKey] = []
        var photosByDay: [DayKey: [Photo]] = [:]
        var placed: Set<PhotoID> = []
        var unplacedSelected: [Photo] = []
        var selected: [Photo] = []
    }

    @ObservationIgnored private var derivedRevision = -1
    @ObservationIgnored private var derivedCache = Derived()
    @ObservationIgnored private var issuesKey: (revision: Int, profile: String, format: String)?
    @ObservationIgnored private var issuesCache: [PreflightIssue] = []

    private var derived: Derived {
        let revision = store.revision  // observed: every store change invalidates
        if revision != derivedRevision {
            let album = store.album
            var d = Derived()
            d.photosByDay = album.photosByDay()
            d.days = d.photosByDay.keys.sorted()
            d.placed = album.placedPhotoIDs
            d.unplacedSelected = album.unplacedSelectedPhotos
            d.selected = album.selectedPhotos.filter { $0.kind != .video }
            derivedCache = d
            derivedRevision = revision
        }
        return derivedCache
    }

    /// Photos in any frame of the spreads or the cover (the tray marks them).
    var placedPhotoIDs: Set<PhotoID> { derived.placed }

    /// Selected photos in no frame (after a delete, a smaller template or a replacing drop),
    /// chronological. The tray can mark them; Preflight warns about them.
    var unplacedSelectedPhotos: [Photo] { derived.unplacedSelected }

    // MARK: Navigation

    /// The spread the user chose; may no longer exist (deleted, undone draft).
    private var requestedSpreadID: String?
    /// Index of the current spread when last resolved: the fallback position after it vanished.
    @ObservationIgnored private var lastSpreadIndex = 0
    /// The frame the user chose, with the spread it belongs to.
    private var requestedFrame: FrameRef?

    private struct FrameRef: Equatable {
        var spreadID: String
        var frameID: String
    }
    /// The tray day the user chose for the current spread; nil follows the spread.
    private var chosenTrayDay: DayKey?

    /// The shown spread: the one the user chose while it exists, else the spread now at its last
    /// position (the nearest remaining one), else the first spread; nil without spreads. Choosing a
    /// spread ends a running text or crop session (committed) and resets the tray day.
    var currentSpreadID: String? {
        get {
            let spreads = store.album.spreads
            guard !spreads.isEmpty else { return nil }
            if let id = requestedSpreadID {
                if let index = spreads.firstIndex(where: { $0.id == id }) {
                    lastSpreadIndex = index
                    return id
                }
                return spreads[min(lastSpreadIndex, spreads.count - 1)].id
            }
            return spreads[0].id
        }
        set {
            commitSessions()
            requestedSpreadID = newValue
            if let newValue, let index = spreadIndex(of: newValue) { lastSpreadIndex = index }
            chosenTrayDay = nil
        }
    }

    /// The current spread as shown (with a running session's preview).
    var currentSpread: Spread? { currentSpreadID.flatMap(displayedSpread) }

    /// The selected frame of the current spread; nil when that frame (or spread) no longer exists
    /// or another spread is shown.
    var selectedFrameID: String? {
        get {
            guard let requestedFrame, requestedFrame.spreadID == currentSpreadID,
                  let spread = store.album.spreads.first(where: { $0.id == requestedFrame.spreadID }),
                  spread.frames.contains(where: { $0.id == requestedFrame.frameID }) else { return nil }
            return requestedFrame.frameID
        }
        set {
            requestedFrame = newValue.flatMap { frame in currentSpreadID.map { FrameRef(spreadID: $0, frameID: frame) } }
        }
    }

    func spreadIndex(of id: String) -> Int? {
        store.album.spreads.firstIndex { $0.id == id }
    }

    func nextSpread() { step(by: 1) }
    func previousSpread() { step(by: -1) }

    private func step(by delta: Int) {
        let spreads = store.album.spreads
        guard let current = currentSpreadID, let index = spreadIndex(of: current) else { return }
        let next = min(max(index + delta, 0), spreads.count - 1)
        if next != index { currentSpreadID = spreads[next].id }
    }

    // MARK: Tray

    /// "Celý výběr": the tray shows every selected photo of the album instead of the days.
    var trayShowsAll = false

    /// The day the tray is built around: the user's choice for this spread, else the current
    /// spread's day, else (intro, closing, blank) the album's first day.
    var trayDay: DayKey? {
        get { chosenTrayDay ?? currentSpread?.dayKey ?? derived.days.first }
        set { chosenTrayDay = newValue }
    }

    /// The tray (spec 6.4): photos of `trayDay` and its neighbouring days in the album (the
    /// previous and next day that HAS photos, not the calendar's ±1), selected and unselected,
    /// selected first, then chronological; never videos. With `trayShowsAll`: every selected photo
    /// of the album, chronological. `placedPhotoIDs` tells which are already in the album.
    var trayPhotos: [Photo] {
        let d = derived
        if trayShowsAll { return d.selected }
        guard let day = trayDay, let index = d.days.firstIndex(of: day) else { return [] }
        let range = max(index - 1, 0)...min(index + 1, d.days.count - 1)
        let photos = d.days[range].flatMap { d.photosByDay[$0] ?? [] }.filter { $0.kind != .video }
        return photos.filter(\.isSelected) + photos.filter { !$0.isSelected }
    }

    // MARK: Draft, redraft, format

    /// "Navrhnout album": drafts the selection as it is (`Workflow.draft`) when the album has no
    /// spreads and some photo is selected. One step "Navrhnout album". Returns whether it drafted.
    @discardableResult
    func draftIfEmpty() -> Bool {
        commitSessions()
        let album = store.album
        guard album.spreads.isEmpty, !album.selectedPhotos.isEmpty else { return false }
        let g = geometry
        let draft = Workflow.draft(album: album, profile: g.profile, format: g.format)
        guard !draft.spreads.isEmpty else { return false }
        startStepAfterSessionCommit()
        store.replace(album: draft, actionName: "Navrhnout album", undoManager: undoManager)
        requestedSpreadID = nil
        return true
    }

    /// How many manually edited spreads "Navrhnout znovu" would keep (for the confirmation
    /// "Zachovám N ručně upravených dvoustran"). Changes nothing.
    func redraftPreview() -> Int {
        store.album.spreads.filter(\.manuallyEdited).count
    }

    /// "Navrhnout znovu" (`AlbumUpdater.redraft`): regenerates the spreads that are not manually
    /// edited. One step; returns the number of kept manual spreads.
    @discardableResult
    func redraft() -> Int {
        commitSessions()
        let album = store.album
        let g = geometry
        let result = AlbumUpdater.redraft(album: album, days: Workflow.days(of: album),
                                          profile: g.profile, format: g.format)
        if result.album != album {
            startStepAfterSessionCommit()
            store.replace(album: result.album, actionName: "Navrhnout znovu", undoManager: undoManager)
        }
        return result.keptManual
    }

    /// "Změnit formát" (`AlbumUpdater.changeFormat`) to a format of the current profile: the layout
    /// is recomputed, content stays; `geometry` follows. False for an unknown or the current format.
    @discardableResult
    func changeFormat(to formatID: String) -> Bool {
        commitSessions()
        let g = geometry
        guard formatID != store.album.formatID,
              let format = g.profile.formats.first(where: { $0.id == formatID }) else { return false }
        let updated = AlbumUpdater.changeFormat(album: store.album, to: format, profile: g.profile)
        startStepAfterSessionCommit()
        store.replace(album: updated, actionName: "Změnit formát", undoManager: undoManager)
        return true
    }

    // MARK: Photos in frames

    /// Puts photo `id` into frame `frameID` of the spread (default: the current one) as one step
    /// "Vložit fotku". The frame's crop resets (except for a swap, below). Returns false (nothing changes) for videos,
    /// unknown photos/frames, or a photo already in that frame.
    ///
    /// A photo is never duplicated in print:
    /// - already in ANOTHER frame of the same spread: the two frames swap photos, each photo
    ///   keeping its crop (as `swap`);
    /// - target is a journal/gallery spread and the photo sits in another journal/gallery spread:
    ///   it MOVES (that frame is emptied, marked by the preflight, and that spread becomes
    ///   manually edited too). Intro, closing and cover frames are left alone: they repeat a day
    ///   photo by design (the drafter's title photo);
    /// - the target frame's previous photo stays selected but unplaced (tray and preflight show it).
    /// An unselected photo (from the tray) is selected in the same step, as a user decision.
    @discardableResult
    func dropPhoto(_ id: PhotoID, onFrame frameID: String, in spreadID: String? = nil) -> Bool {
        commitSessions()
        let album = store.album
        guard let targetID = spreadID ?? currentSpreadID,
              var target = album.spreads.first(where: { $0.id == targetID }),
              let f = target.frames.firstIndex(where: { $0.id == frameID }),
              let photo = album.photos[id], photo.kind != .video,
              target.frames[f].photoID != id else { return false }

        var edits: [AlbumEdit] = []
        if !photo.isSelected { edits.append(.setSelected(id, true)) }
        if let g = target.frames.indices.first(where: { $0 != f && target.frames[$0].photoID == id }) {
            Self.swapFrames(&target, f, g)  // exactly like swap(): each crop stays with its photo
        } else {
            target.frames[f].photoID = id
            Self.resetCrop(&target.frames[f])
        }
        edits.append(.replaceSpread(target))

        if Self.isDaySpread(target) {
            for var source in album.spreads where source.id != target.id && Self.isDaySpread(source) {
                var changed = false
                for i in source.frames.indices where source.frames[i].photoID == id {
                    source.frames[i].photoID = nil
                    Self.resetCrop(&source.frames[i])
                    changed = true
                }
                if changed { edits.append(.replaceSpread(source)) }
            }
        }
        return perform(edits, "Vložit fotku")
    }

    /// Swaps the photos of two frames of the spread (default: current), each photo keeping its crop.
    /// One step "Prohodit fotky".
    func swap(frameA: String, frameB: String, in spreadID: String? = nil) {
        commitSessions()
        guard frameA != frameB, let id = spreadID ?? currentSpreadID,
              var spread = store.album.spreads.first(where: { $0.id == id }),
              let a = spread.frames.firstIndex(where: { $0.id == frameA }),
              let b = spread.frames.firstIndex(where: { $0.id == frameB }) else { return }
        Self.swapFrames(&spread, a, b)
        perform([.replaceSpread(spread)], "Prohodit fotky")
    }

    /// Exchanges photo, offset and zoom of two frames (shared by `swap` and `dropPhoto`).
    private static func swapFrames(_ spread: inout Spread, _ a: Int, _ b: Int) {
        let first = spread.frames[a]
        spread.frames[a].photoID = spread.frames[b].photoID
        spread.frames[a].offset = spread.frames[b].offset
        spread.frames[a].zoom = spread.frames[b].zoom
        spread.frames[b].photoID = first.photoID
        spread.frames[b].offset = first.offset
        spread.frames[b].zoom = first.zoom
    }

    // MARK: Crop (offset and zoom)

    private struct TransformSession {
        var spreadID: String
        var frameID: String
        var offset: Point
        var zoom: Double
    }

    private var transformSession: TransformSession?

    /// Starts a crop gesture (drag or pinch) on a frame of the spread (default: current): `nudge`
    /// then only updates the preview, `endTransform` stores one step "Posunout fotku".
    func beginTransform(frame frameID: String, in spreadID: String? = nil) {
        commitSessions()
        guard let id = spreadID ?? currentSpreadID,
              let frame = store.album.spreads.first(where: { $0.id == id })?.frames.first(where: { $0.id == frameID })
        else { return }
        transformSession = TransformSession(spreadID: id, frameID: frameID, offset: frame.offset, zoom: frame.zoom)
    }

    /// Sets a frame's crop: offset -1...1 per axis (relative to the slack, `FrameFit`), zoom >= 1
    /// (both clamped). During a gesture on that frame it updates the preview; otherwise it is one
    /// step "Posunout fotku" of its own (e.g. arrow keys).
    func nudge(frame frameID: String, offset: Point, zoom: Double, in spreadID: String? = nil) {
        let clampedOffset = FrameFit.clampedOffset(offset, imageSize: Size(width: 1, height: 1),
                                                   frame: Rect(x: 0, y: 0, width: 1, height: 1), zoom: zoom)
        let clampedZoom = zoom.isFinite ? max(1, zoom) : 1
        if var session = transformSession, session.frameID == frameID,
           spreadID == nil || spreadID == session.spreadID {
            session.offset = clampedOffset
            session.zoom = clampedZoom
            transformSession = session
            return
        }
        commitSessions()
        guard let id = spreadID ?? currentSpreadID else { return }
        perform([.setFrameTransform(spreadID: id, frameID: frameID, offset: clampedOffset, zoom: clampedZoom)],
                "Posunout fotku")
    }

    /// Ends the crop gesture: stores its final crop as one step (nothing if unchanged).
    func endTransform() {
        guard let session = transformSession else { return }
        transformSession = nil
        guard let frame = store.album.spreads.first(where: { $0.id == session.spreadID })?
            .frames.first(where: { $0.id == session.frameID }),
              frame.offset != session.offset || frame.zoom != session.zoom else { return }
        asOwnStep {
            perform([.setFrameTransform(spreadID: session.spreadID, frameID: session.frameID,
                                        offset: session.offset, zoom: session.zoom)], "Posunout fotku")
        }
    }

    // MARK: Texts

    private struct TextSession {
        var spreadID: String
        var textID: String
        var text: String
        /// The session's undo step exists (its first store write registered it).
        var registered = false
        /// The store revision right after the session's last write; a different revision means
        /// something else changed the album since (e.g. an Undo from outside the editor).
        var storedRevision: Int?
    }

    private var textSession: TextSession?
    @ObservationIgnored private var textCommitTask: Task<Void, Never>?

    /// Whether a text editing session is running.
    var isEditingText: Bool { textSession != nil }

    /// Starts editing a text box of the spread (default: current). The whole session is ONE undo
    /// step "Upravit text": `updateText` updates the preview at once and, `textCommitDelay` after
    /// the last keystroke, writes the text to the store (the first write registers the step, later
    /// writes amend it without a new step: the step's inverse restores the spread from before the
    /// session, so it undoes all of it). `endTextEditing` writes the final text.
    func beginTextEditing(_ textID: String, in spreadID: String? = nil) {
        commitSessions()
        guard let id = spreadID ?? currentSpreadID,
              let box = store.album.spreads.first(where: { $0.id == id })?.texts.first(where: { $0.id == textID })
        else { return }
        textSession = TextSession(spreadID: id, textID: textID, text: box.text)
    }

    /// The live text of the running session: the preview at once, the store after the delay.
    func updateText(_ text: String) {
        guard textSession != nil else { return }
        textSession?.text = text
        textCommitTask?.cancel()
        let delay = textCommitDelay
        textCommitTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.storeSessionText()
        }
    }

    /// Ends the session: stores the final text (nothing if it equals the stored one).
    func endTextEditing() {
        textCommitTask?.cancel()
        textCommitTask = nil
        storeSessionText()
        textSession = nil
    }

    /// Writes the session text to the store; see `beginTextEditing` for the one-step rule.
    private func storeSessionText() {
        guard var session = textSession,
              let box = store.album.spreads.first(where: { $0.id == session.spreadID })?
                .texts.first(where: { $0.id == session.textID }), box.text != session.text else { return }
        let edit = AlbumEdit.setText(spreadID: session.spreadID, textID: session.textID, text: session.text)
        if session.registered, session.storedRevision == store.revision {
            do {
                try store.applyWithoutUndo(edit)
            } catch {
                Logger.editor.error("Text update failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            var stored = false
            asOwnStep { stored = perform([edit], "Upravit text") }
            session.registered = stored
        }
        session.storedRevision = store.revision
        textSession = session
    }

    /// Sets a text at once as one step "Upravit text" (no session).
    func setText(_ textID: String, _ text: String, in spreadID: String? = nil) {
        commitSessions()
        guard let id = spreadID ?? currentSpreadID else { return }
        perform([.setText(spreadID: id, textID: textID, text: text)], "Upravit text")
    }

    /// The spread as the canvas shows it: the stored spread with a running text or crop session
    /// applied.
    func displayedSpread(_ id: String) -> Spread? {
        guard var spread = store.album.spreads.first(where: { $0.id == id }) else { return nil }
        if let t = textSession, t.spreadID == id, let i = spread.texts.firstIndex(where: { $0.id == t.textID }) {
            spread.texts[i].text = t.text
        }
        if let s = transformSession, s.spreadID == id, let i = spread.frames.firstIndex(where: { $0.id == s.frameID }) {
            spread.frames[i].offset = s.offset
            spread.frames[i].zoom = s.zoom
        }
        return spread
    }

    /// Ends running sessions, storing what they changed, each as its OWN undo step (see
    /// `asOwnStep`). Every other edit, choosing another spread, `undo`/`redo` and
    /// `AlbumStore.flushPendingEdits` (window close, rebind) call it first.
    func commitSessions() {
        endTextEditing()
        endTransform()
    }

    /// A session commit registered a step in the current event; the next action must start a
    /// step of its own (`startStepAfterSessionCommit`).
    @ObservationIgnored private var sessionCommittedInEvent = false

    /// Runs a session commit (`body` registers one undo step) as an undo step of its own.
    ///
    /// The window's undo manager groups by event: it opens a group lazily at the first
    /// registration of an event (level 1) and closes it when the run loop finishes the event, and
    /// that end requires level 1 (an extra `endUndoGrouping` throws; an empty group left behind
    /// becomes an empty undo step). So, verified against NSUndoManager:
    /// - level 1 (something earlier in this event registered): close that group and open a fresh
    ///   one for the commit (`end` + `begin` in the same event gives level 1 again); the run loop
    ///   closes it, or the next action splits it again;
    /// - level 0: a plain registration opens the event's group;
    /// - a manager that does not group by event (tests) at level 0 gets an explicit group; deeper
    ///   levels are a caller's explicit group and nest.
    /// Afterwards `sessionCommittedInEvent` makes the following action split once more, so
    /// "commit + action" are TWO steps with their own names and one Undo reverts only the action.
    private func asOwnStep(_ body: () -> Void) {
        guard let undoManager else { return body() }
        if undoManager.groupsByEvent {
            splitEventGroup()
            body()
            sessionCommittedInEvent = true
        } else if undoManager.groupingLevel == 0 {
            undoManager.beginUndoGrouping()
            body()
            undoManager.endUndoGrouping()
        } else {
            body()
        }
    }

    /// Called right before an action registers: if a session commit registered in this event,
    /// the action gets its own group (see `asOwnStep`).
    private func startStepAfterSessionCommit() {
        guard sessionCommittedInEvent else { return }
        sessionCommittedInEvent = false
        splitEventGroup()
    }

    /// Closes the event's open undo group (level 1 of a manager grouping by event) and opens a
    /// new one, so what follows is a separate step. Only call it right before a registration.
    private func splitEventGroup() {
        guard let undoManager, undoManager.groupsByEvent, undoManager.groupingLevel == 1 else { return }
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
    }

    // MARK: Templates

    /// Templates the picker offers for the spread: journal and gallery spreads switch freely
    /// between all journal and gallery templates (spec: "jiné rozložení stejného typu, nebo změna
    /// typu A na B a zpět"); intro, closing and blank spreads get the templates of their kind.
    /// `photoCount` is each template's number of frames.
    func availableTemplates(for spreadID: String) -> [SpreadTemplate] {
        guard let spread = store.album.spreads.first(where: { $0.id == spreadID }) else { return [] }
        switch spread.kind {
        case .journal, .gallery: return TemplateCatalog.all.filter { $0.kind == .journal || $0.kind == .gallery }
        case .intro, .closing, .blank: return TemplateCatalog.templates(kind: spread.kind)
        }
    }

    /// What `changeTemplate` would do, without changing anything (the view's confirmation text).
    func previewTemplateChange(to templateID: String, in spreadID: String? = nil) -> RetemplateResult? {
        guard let id = spreadID ?? currentSpreadID,
              let spread = store.album.spreads.first(where: { $0.id == id }),
              let template = availableTemplates(for: id).first(where: { $0.id == templateID }) else { return nil }
        return TemplateLayout.retemplate(spread, to: template, geometry: geometry, photos: store.album.photos)
    }

    /// "Změnit šablonu" (`TemplateLayout.retemplate`, edit `replaceSpread`, one step). Texts that
    /// would be lost block the change until `confirmTextLoss`; photos without a frame stay
    /// selected but unplaced; extra frames stay empty (preflight).
    @discardableResult
    func changeTemplate(to templateID: String, in spreadID: String? = nil,
                        confirmTextLoss: Bool = false) -> TemplateChangeOutcome {
        commitSessions()
        guard let id = spreadID ?? currentSpreadID,
              let spread = store.album.spreads.first(where: { $0.id == id }) else { return .unavailable }
        // The spread's own template: nothing to do, no undo step, the spread stays unedited.
        if spread.templateID == templateID { return .applied(unplacedPhotoIDs: []) }
        guard let result = previewTemplateChange(to: templateID, in: id) else { return .unavailable }
        if !result.droppedTexts.isEmpty && !confirmTextLoss { return .needsTextLossConfirmation(result.droppedTexts) }
        return perform([.replaceSpread(result.spread)], "Změnit šablonu")
            ? .applied(unplacedPhotoIDs: result.unplacedPhotoIDs) : .unavailable
    }

    // MARK: Spreads

    /// The template a new spread of `kind` starts from.
    static func defaultTemplateID(for kind: SpreadKind) -> String {
        switch kind {
        case .blank: "blank"
        case .gallery: "gallery-1"
        case .journal: "journal-3"
        case .intro: "intro-1"
        case .closing: "closing-1"
        }
    }

    /// "Přidat dvoustranu": an EMPTY spread of `kind` (`defaultTemplateID`) with id `manual-N`
    /// (smallest free N; the drafter never uses that prefix), `manuallyEdited = true` so
    /// "Navrhnout znovu" keeps it. Inserted after spread `after`; nil = at the end, before the
    /// closing spread if the album ends with one (also for `after` = that closing spread). A gallery/journal takes the day of the spread it
    /// follows, else of the spread after it, else the tray day. Its empty frames are flagged by the
    /// preflight until filled. Becomes the current spread. Returns its id (nil: unknown `after`).
    @discardableResult
    func insertSpread(kind: SpreadKind, after: String?) -> String? {
        commitSessions()
        let spreads = store.album.spreads
        let index: Int
        if let after {
            guard let i = spreadIndex(of: after) else { return nil }
            // Nothing goes after the closing spread: "after the closing" means before it.
            index = spreads[i].kind == .closing && i == spreads.count - 1 ? i : i + 1
        } else {
            index = spreads.last?.kind == .closing ? spreads.count - 1 : spreads.count
        }
        guard let template = TemplateCatalog.template(id: Self.defaultTemplateID(for: kind)) else { return nil }
        let taken = Set(spreads.map(\.id))
        var n = 1
        while taken.contains("manual-\(n)") { n += 1 }
        let id = "manual-\(n)"
        var day: DayKey?
        if kind == .gallery || kind == .journal {
            day = (index > 0 ? spreads[index - 1].dayKey : nil)
                ?? (index < spreads.count ? spreads[index].dayKey : nil)
                ?? trayDay
        }
        var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: day, id: id)
        spread.manuallyEdited = true
        guard perform([.insertSpread(spread, at: index)], "Přidat dvoustranu") else { return nil }
        currentSpreadID = id
        return id
    }

    /// "Smazat dvoustranu". Its photos stay selected but unplaced (tray, preflight warning).
    func deleteSpread(_ id: String) {
        commitSessions()
        perform([.deleteSpread(id: id)], "Smazat dvoustranu")
    }

    /// "Přesunout dvoustranu" to `index`. A leading intro stays first and a trailing closing
    /// stays last: they cannot be moved, and other spreads are clamped between them.
    func moveSpread(_ id: String, to index: Int) {
        commitSessions()
        let spreads = store.album.spreads
        guard let from = spreadIndex(of: id) else { return }
        let first = spreads.first?.kind == .intro ? 1 : 0
        let last = spreads.count - 1 - (spreads.count > 1 && spreads.last?.kind == .closing ? 1 : 0)
        guard from >= first, from <= last else { return }  // the intro or the closing itself
        let to = min(max(index, first), last)
        guard from != to else { return }
        perform([.moveSpread(from: from, to: to)], "Přesunout dvoustranu")
    }

    // MARK: Preflight

    /// `Preflight.check` of the album with the current geometry, cached per store revision.
    var allIssues: [PreflightIssue] {
        let revision = store.revision
        let g = geometry
        if let key = issuesKey, key.revision == revision, key.profile == g.profile.id, key.format == g.format.id {
            return issuesCache
        }
        issuesCache = Preflight.check(album: store.album, profile: g.profile, format: g.format)
        issuesKey = (revision, g.profile.id, g.format.id)
        return issuesCache
    }

    /// The issues of one spread (warnings shown on the canvas).
    func issues(for spreadID: String) -> [PreflightIssue] {
        allIssues.filter { $0.spreadID == spreadID }
    }

    // MARK: Helpers

    private static func isDaySpread(_ spread: Spread) -> Bool {
        spread.kind == .journal || spread.kind == .gallery
    }

    private static func resetCrop(_ frame: inout Frame) {
        frame.offset = Point(x: 0, y: 0)
        frame.zoom = 1
    }

    /// Applies `edits` as one undo step; false (logged) when they do not apply.
    @discardableResult
    private func perform(_ edits: [AlbumEdit], _ actionName: String) -> Bool {
        do {
            // Validate first: a split undo group that then registers nothing is an empty step.
            var check = store.album
            for edit in edits { check = try check.applying(edit).album }
            startStepAfterSessionCommit()
            try store.apply(edits, actionName: actionName, undoManager: undoManager)
            return true
        } catch {
            Logger.editor.error("\(actionName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

extension Logger {
    static let editor = Logger(subsystem: "com.stratkoss.leporelo", category: "Editor")
}
