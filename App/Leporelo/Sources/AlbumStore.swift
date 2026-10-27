import Foundation
import LeporeloCore
import Observation
import os

/// The UI model of one open album: the album in memory plus the package it lives in.
///
/// Every change goes through `apply` (an `AlbumEdit`) or `replace` (a whole new album from a
/// workflow step), and both register their undo with the window's `UndoManager`. Registering an
/// undo is also what marks the SwiftUI document as changed, which schedules autosave: a change
/// made with a `nil` undo manager is applied in memory but does not trigger autosave on its own.
@MainActor
@Observable
final class AlbumStore {
    private(set) var album: Album
    /// The package on disk. A `var` only so the store can follow the document when the user
    /// renames or moves it (`packageMoved(to:)`); the album and the undo history stay.
    private(set) var package: ProjectPackage
    /// Receives every change, so the document can snapshot from any thread.
    @ObservationIgnored private let snapshotBox: AlbumSnapshotBox

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
    func apply(_ edit: AlbumEdit, undoManager: UndoManager?) throws {
        try apply(edit, actionName: Self.actionName(for: edit), undoManager: undoManager)
    }

    /// Replaces the whole album (selection recommendations, redraft, format change) as one undoable
    /// step named `actionName`.
    func replace(album newAlbum: Album, actionName: String, undoManager: UndoManager?) {
        let previous = album
        album = newAlbum
        publish()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            store.replace(album: previous, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    /// Points the store at the package's new location after a rename or move.
    func packageMoved(to url: URL) throws {
        guard url != package.url else { return }
        package = try ProjectPackage.open(url).0
        publish()
    }

    private func apply(_ edit: AlbumEdit, actionName: String, undoManager: UndoManager?) throws {
        let (updated, inverse) = try album.applying(edit)
        album = updated
        publish()
        guard let undoManager else { return }
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
