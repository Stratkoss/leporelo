import AppKit
import SwiftUI

/// The album window's answer to Edit > Undo/Redo (published with `focusedSceneValue`), routed by
/// `UndoRouter`: the editor's model in editor mode (commits a running session first), the window's
/// undo manager in triage.
@MainActor
@Observable
final class AlbumUndoTarget {
    var mode: WindowMode = .triage
    @ObservationIgnored weak var editor: EditorModel?
    @ObservationIgnored weak var store: AlbumStore?
    @ObservationIgnored weak var undoManager: UndoManager?

    var route: UndoRoute {
        UndoRouter.route(mode: mode, hasEditor: editor != nil, hasUndoManager: undoManager != nil)
    }

    /// Reading the store's revision makes the menu re-evaluate after every change (each undo
    /// registration and each undo/redo changes the album).
    private func observeChanges() {
        _ = store?.revision
        _ = editor?.hasPendingSession
    }

    var canUndo: Bool {
        observeChanges()
        switch route {
        case .editor: return (editor?.hasPendingSession ?? false) || (undoManager?.canUndo ?? false)
        case .window: return undoManager?.canUndo ?? false
        case .responderChain: return true
        }
    }

    var canRedo: Bool {
        observeChanges()
        switch route {
        case .editor, .window: return undoManager?.canRedo ?? false
        case .responderChain: return true
        }
    }

    var undoTitle: String {
        observeChanges()
        if route == .editor, let editor {
            if editor.isEditingText { return UndoRouter.undoTitle("Upravit text") }
            if editor.isTransforming { return UndoRouter.undoTitle("Posunout fotku") }
        }
        return UndoRouter.undoTitle(undoManager?.undoActionName ?? "")
    }

    var redoTitle: String {
        observeChanges()
        return UndoRouter.redoTitle(undoManager?.redoActionName ?? "")
    }

    func undo() {
        switch route {
        case .editor: editor?.undo()
        case .window: undoManager?.undo()
        case .responderChain: Self.sendToResponderChain("undo:")
        }
    }

    func redo() {
        switch route {
        case .editor: editor?.redo()
        case .window: undoManager?.redo()
        case .responderChain: Self.sendToResponderChain("redo:")
        }
    }

    static func sendToResponderChain(_ action: String) {
        NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }
}

extension FocusedValues {
    @Entry var albumUndo: AlbumUndoTarget? = nil
}

/// Replaces the system Undo/Redo items so ⌘Z and ⇧⌘Z always reach `EditorModel.undo()/redo()` in
/// the editor (also while the text overlay has focus; it has no undo of its own). Without an album
/// window in front, the action goes down the responder chain (text fields of other windows).
struct UndoCommands: Commands {
    @FocusedValue(\.albumUndo) private var target

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(target?.undoTitle ?? UndoRouter.undoTitle("")) {
                if let target { target.undo() } else { AlbumUndoTarget.sendToResponderChain("undo:") }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(target.map { !$0.canUndo } ?? false)

            Button(target?.redoTitle ?? UndoRouter.redoTitle("")) {
                if let target { target.redo() } else { AlbumUndoTarget.sendToResponderChain("redo:") }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(target.map { !$0.canRedo } ?? false)
        }
    }
}
