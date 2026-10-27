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
/// Caveat for Tasks 19-21: undoing a `replace` restores the WHOLE previous album, including
/// background-owned fields (`analysis`, `originalState`, photos added by a refresh) that changed
/// after it. Use `replace` with undo only for user steps whose undo should restore everything
/// (recommendations, redraft, format change), and keep background writes on the no-undo path.
/// Background results that arrive between a user `replace` and its undo can be lost by that undo;
/// re-run or merge them if that matters.
@MainActor
@Observable
final class AlbumStore {
    private(set) var album: Album
    /// The package on disk. A `var` only so the store can follow the document when the user
    /// renames or moves it (`packageMoved(to:)`); the album and the undo history stay.
    private(set) var package: ProjectPackage
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

    /// Replaces the whole album (selection recommendations, redraft, format change) as one undoable
    /// step named `actionName` (see the caveat above). With a `nil` undo manager this is
    /// `replaceWithoutUndo`.
    func replace(album newAlbum: Album, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return replaceWithoutUndo(album: newAlbum) }
        let previous = album
        album = newAlbum
        publish()
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            store.replace(album: previous, actionName: actionName, undoManager: undoManager)
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
        case .setFrameTransform: "Upravit ořez"
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
