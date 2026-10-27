import Foundation
import LeporeloCore
import Observation
import os

/// The UI model of one open album: the album in memory plus the package it lives in.
///
/// Every change goes through one of four methods, and every one of them gets autosaved:
/// - `apply(_:undoManager:)` / `replace(album:actionName:undoManager:)` for user actions: they
///   register their undo with the window's `UndoManager`, and that registration is what marks the
///   SwiftUI document as changed.
/// - `applyWithoutUndo(_:)` / `replaceWithoutUndo(album:)` for background results (analysis,
///   downloaded originals, source refresh): no undo; they call `markChanged`, which the document
///   sets at bind time to mark its NSDocument edited. Passing a `nil` undo manager to `apply` or
///   `replace` takes this same path, so there is no change that silently skips autosave.
///
/// Undoing a `replace` restores the previous album's user content but keeps the background-owned
/// photo fields as they are at undo time (see `replace`). Keep background writes on the no-undo
/// path.
@MainActor
@Observable
final class AlbumStore {
    private(set) var album: Album
    /// The package on disk. A `var` only so the store can follow the document when the user
    /// renames or moves it (`packageMoved(to:)`); the album and the undo history stay.
    private(set) var package: ProjectPackage
    /// Incremented by every change of `album` (and of `package`). Views and models that derive
    /// data from the album key their caches on it instead of comparing whole albums.
    private(set) var revision = 0
    /// Receives every change, so the document can snapshot from any thread.
    @ObservationIgnored private let snapshotBox: AlbumSnapshotBox
    /// Marks the document changed for edits that register no undo (set by `AlbumDocument.bind`).
    @ObservationIgnored var markChanged: (@MainActor () -> Void)?

    init(album: Album, package: ProjectPackage, snapshotBox: AlbumSnapshotBox? = nil) {
        self.album = album
        self.package = package
        let snapshot = AlbumSnapshot(album: album, packageURL: package.url)
        if let snapshotBox {
            snapshotBox.publish(snapshot)
            self.snapshotBox = snapshotBox
        } else {
            self.snapshotBox = AlbumSnapshotBox(snapshot)
        }
    }

    /// Applies `edit` and registers its exact inverse; undoing registers the inverse of the
    /// inverse, so redo works. Throws (and registers nothing) when the edit does not apply.
    /// With a `nil` undo manager this is `applyWithoutUndo`.
    func apply(_ edit: AlbumEdit, undoManager: UndoManager?) throws {
        try apply(edit, actionName: Self.actionName(for: edit), undoManager: undoManager)
    }

    /// Applies `edits` in order as ONE undoable step named `actionName` (e.g. a drop that selects
    /// the photo and changes two spreads). Atomic: when any edit does not apply, nothing changes
    /// and nothing is registered. Undo applies the inverses in reverse order. An empty list does
    /// nothing. With a `nil` undo manager this is the no-undo path (`markChanged`).
    func apply(_ edits: [AlbumEdit], actionName: String, undoManager: UndoManager?) throws {
        guard !edits.isEmpty else { return }
        var updated = album
        var inverses: [AlbumEdit] = []
        for edit in edits {
            let result = try updated.applying(edit)
            updated = result.album
            inverses.append(result.inverse)
        }
        album = updated
        publish()
        guard let undoManager else {
            markChanged?()
            return
        }
        let undoEdits = Array(inverses.reversed())
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            do {
                try store.apply(undoEdits, actionName: actionName, undoManager: undoManager)
            } catch {
                Logger.store.fault("Undo of \(actionName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        undoManager.setActionName(actionName)
    }

    /// How many steps the window's undo manager keeps. Every `replace` step holds a whole album,
    /// so unlimited undo would grow without bound during a long editing session.
    static let undoLevels = 200

    /// Caps `undoManager` at `undoLevels` (views call it when they get the window's manager).
    static func configure(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager.levelsOfUndo != undoLevels else { return }
        undoManager.levelsOfUndo = undoLevels
    }

    /// Replaces the whole album (selection recommendations, redraft, format change, a selection
    /// change once spreads exist) as one undoable step named `actionName`. With a `nil` undo
    /// manager this is `replaceWithoutUndo`.
    ///
    /// Undo and redo restore the stored snapshot merged with the album as it is at that moment
    /// (`Album.keepingBackgroundFields(of:)`): the user's content comes back, but analysis, place
    /// names, series, original states and deleted flags written by background work in the meantime
    /// are kept, and photos added meanwhile stay.
    func replace(album newAlbum: Album, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return replaceWithoutUndo(album: newAlbum) }
        let previous = album
        album = newAlbum
        publish()
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            store.replace(album: previous.keepingBackgroundFields(of: store.album),
                          actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    /// Applies a background edit: no undo, snapshot published at once, document marked changed.
    func applyWithoutUndo(_ edit: AlbumEdit) throws {
        album = try album.applying(edit).album
        publish()
        markChanged?()
    }

    /// Replaces the album with a background result: no undo, snapshot published at once, document
    /// marked changed.
    func replaceWithoutUndo(album newAlbum: Album) {
        album = newAlbum
        publish()
        markChanged?()
    }

    // MARK: Background results (no undo; `BackgroundWork` calls these on the CURRENT album)

    /// Sets the analysis of a batch of photos as ONE no-undo mutation (one snapshot, one
    /// `markChanged`). Photos no longer in the album are ignored; an empty batch changes nothing.
    func setAnalyses(_ results: [PhotoID: PhotoAnalysis]) {
        var updated = album
        var changed = false
        for (id, analysis) in results where updated.photos[id] != nil {
            updated.photos[id]?.analysis = analysis
            changed = true
        }
        if changed { replaceWithoutUndo(album: updated) }
    }

    /// Applies resolved places to the album as it is NOW (`GroupingService.applyRefinement`), in
    /// one synchronous step, so day moves the user made while geocoding ran are kept. No undo.
    @discardableResult
    func applyPlaceRefinement(_ places: [PhotoID: Place], completed: Bool) -> PlaceRefinement {
        var updated = album
        let result = GroupingService.applyRefinement(places, completed: completed, to: &updated)
        if result.namedPhotos > 0 || result.changedDays > 0 { replaceWithoutUndo(album: updated) }
        return result
    }

    /// Recommends photos per day (`Workflow.applyRecommendations`: series, `Recommender`) on the
    /// current album and selects them, as one no-undo mutation. Only photos the user has not
    /// decided change, so a photo the user deselected is never reselected, however often this runs.
    func applyRecommendations() {
        let updated = Workflow.applyRecommendations(to: album)
        if updated != album { replaceWithoutUndo(album: updated) }
    }

    /// Points the store at the package's new location after a rename or move.
    func packageMoved(to url: URL) throws {
        guard url != package.url else { return }
        package = try ProjectPackage.open(url).0
        publish()
    }

    private func apply(_ edit: AlbumEdit, actionName: String, undoManager: UndoManager?) throws {
        guard let undoManager else { return try applyWithoutUndo(edit) }
        let (updated, inverse) = try album.applying(edit)
        album = updated
        publish()
        // Weak: the undo manager owns this closure.
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            do {
                try store.apply(inverse, actionName: actionName, undoManager: undoManager)
            } catch {
                // Inverses are built from the state they undo, so this means a bug in AlbumEdit.
                Logger.store.fault("Undo of \(actionName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        undoManager.setActionName(actionName)
    }

    private func publish() {
        revision &+= 1
        snapshotBox.publish(AlbumSnapshot(album: album, packageURL: package.url))
    }

    /// The Czech name shown in Edit > Undo/Redo.
    static func actionName(for edit: AlbumEdit) -> String {
        switch edit {
        case .setSelected(_, true): "Vybrat fotku"
        case .setSelected(_, false): "Vyřadit fotku"
        case .restorePhotoSelection(_, true, _): "Vybrat fotku"
        case .restorePhotoSelection(_, false, _): "Vyřadit fotku"
        case .setFramePhoto(_, _, .some): "Vložit fotku"
        case .setFramePhoto(_, _, .none): "Odebrat fotku"
        case .swapFramePhotos: "Prohodit fotky"
        case .setFrameTransform: "Posunout fotku"
        case .setText: "Upravit text"
        case .moveSpread: "Přesunout dvoustranu"
        case .insertSpread: "Přidat dvoustranu"
        case .deleteSpread: "Smazat dvoustranu"
        case .replaceSpread: "Změnit šablonu"
        case .restoreSpread: "Obnovit dvoustranu"
        case .setPhotoDay: "Přesunout fotku do dne"
        case .setTitle: "Změnit název"
        }
    }
}

extension Logger {
    static let store = Logger(subsystem: "com.stratkoss.leporelo", category: "AlbumStore")
    static let document = Logger(subsystem: "com.stratkoss.leporelo", category: "AlbumDocument")
}
