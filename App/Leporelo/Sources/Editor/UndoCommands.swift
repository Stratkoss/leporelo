import AppKit
import SwiftUI

/// The album window's answer to Edit > Undo/Redo (published with `focusedSceneValue`), routed by
/// `UndoRouter`: the editor's model in editor mode (commits a running session first), the window's
/// undo manager in triage, the responder chain while a sheet of the window or a text field other
/// than the canvas overlay has the keyboard. The items are never disabled (`UndoMenuItem`); their
/// titles name the step ⌘Z really undoes (a session only once it has changes).
@MainActor
@Observable
final class AlbumUndoTarget {
    var mode: WindowMode = .triage
    @ObservationIgnored weak var editor: EditorModel?
    @ObservationIgnored weak var store: AlbumStore?
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Reads the key window's focus (tests inject one).
    @ObservationIgnored var focus: @MainActor () -> UndoFocus? = { UndoFocus.current() }

    /// Evaluated afresh for every title and every action, so the item's title and what ⌘Z does
    /// follow the same route (a sheet or a foreign text field: the responder chain).
    var route: UndoRoute {
        UndoRouter.route(mode: mode, hasEditor: editor != nil, hasUndoManager: undoManager != nil,
                         focus: focus())
    }

    /// The editor session's pending action (only with changes). Reading it and the store's
    /// revision lets the menu re-evaluate after every change, session previews included.
    private var pendingAction: String? {
        _ = store?.revision
        return route == .editor ? editor?.pendingSessionActionName : nil
    }

    var undoItem: UndoMenuItem {
        UndoRouter.undoItem(route: route, pendingAction: pendingAction,
                            undoActionName: undoManager?.undoActionName ?? "")
    }

    var redoItem: UndoMenuItem {
        UndoRouter.redoItem(route: route, pendingAction: pendingAction,
                            redoActionName: undoManager?.redoActionName ?? "")
    }

    func undo() {
        switch route {
        case .editor: editor?.undo()
        case .window: if undoManager?.canUndo == true { undoManager?.undo() }
        case .responderChain: Self.sendToResponderChain("undo:")
        }
    }

    func redo() {
        switch route {
        case .editor: editor?.redo()
        case .window: if undoManager?.canRedo == true { undoManager?.redo() }
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
            let undo = target?.undoItem
                ?? UndoRouter.undoItem(route: .responderChain, pendingAction: nil, undoActionName: "")
            Button(undo.title) {
                if let target { target.undo() } else { AlbumUndoTarget.sendToResponderChain("undo:") }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!undo.isEnabled)

            let redo = target?.redoItem
                ?? UndoRouter.redoItem(route: .responderChain, pendingAction: nil, redoActionName: "")
            Button(redo.title) {
                if let target { target.redo() } else { AlbumUndoTarget.sendToResponderChain("redo:") }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!redo.isEnabled)
        }
    }
}
