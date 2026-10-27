import LeporeloCore
import SwiftUI

/// The content of a bound album window: triage (Task 20) or the editor (Task 21), one window, two
/// modes (`WindowModeLogic`). Owns the `TriageModel` and the `EditorModel` of one store; both are
/// created once per store identity (on appear and when the store changes), never in `init`:
/// `State(initialValue:)` would evaluate throwaway models on every body evaluation of the window.
///
/// - The album opens in the editor when it already has spreads, else in triage.
/// - "Navrhnout album" (triage) drafts when there are no spreads (`draftIfEmpty`) and opens the
///   editor once spreads exist; with spreads it just opens the editor.
/// - "Třídění | Dvoustrany" in the toolbar switches; "Dvoustrany" without spreads is "Navrhnout
///   album". Leaving the editor commits its running sessions.
/// - Edit > Undo/Redo is published as `AlbumUndoTarget` for `UndoCommands`.
struct AlbumContent: View {
    let store: AlbumStore
    @Binding var requestedMode: WindowMode?

    @State private var triage: TriageModel?
    @State private var editor: EditorModel?
    @State private var editorError: String?
    @State private var exportModel: ExportModel?
    @State private var undoTarget = AlbumUndoTarget()
    @Environment(\.undoManager) private var undoManager

    private var mode: WindowMode {
        WindowModeLogic.resolve(requested: requestedMode, hasSpreads: !store.album.spreads.isEmpty)
    }

    var body: some View {
        Group {
            if let triage, triage.store === store {
                switch mode {
                case .triage:
                    TriageView(model: triage)
                        .environment(\.proposeAlbum, editor == nil ? nil : ProposeAlbumAction { propose() })
                case .editor:
                    if let editor, editor.store === store {
                        EditorView(model: editor, onBackToTriage: { switchTo(.triage) })
                            .environment(\.exportAlbum, exportAction)
                    } else {
                        ContentUnavailableView("Editor nejde otevřít", systemImage: "exclamationmark.triangle",
                                               description: Text(editorError ?? ""))
                    }
                }
            } else {
                Color.clear
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Pohled", selection: Binding(get: { mode }, set: { switchTo($0) })) {
                    Text(EditorText.triage).tag(WindowMode.triage)
                    Text(EditorText.spreads).tag(WindowMode.editor)
                }
                .pickerStyle(.segmented)
                .help("Třídění fotek nebo ladění dvoustran")
            }
        }
        .focusedSceneValue(\.albumUndo, undoTarget)
        .focusedSceneValue(\.albumExport, exportAction)
        .sheet(item: $exportModel, onDismiss: { exportModel = nil }) { model in
            ExportSheet(model: model, onClose: { closeExport() })
        }
        .onAppear(perform: makeModels)
        .onChange(of: ObjectIdentifier(store)) { makeModels() }
        .onChange(of: undoManager) { _, manager in bindUndo(manager) }
        .onChange(of: mode) { _, mode in undoTarget.mode = mode }
    }

    /// "Exportovat…" (editor toolbar, File menu): available once the album has spreads.
    private var exportAction: ExportAlbumAction? {
        guard editor?.store === store, !store.album.spreads.isEmpty else { return nil }
        return ExportAlbumAction { openExport() }
    }

    /// Opens the export sheet (in the editor: its problems jump to spreads there).
    private func openExport() {
        guard exportModel == nil, let editor, editor.store === store, !store.album.spreads.isEmpty else { return }
        editor.commitSessions()
        if mode != .editor { requestedMode = .editor }
        exportModel = ExportModel(store: store, geometry: { [weak editor] in editor?.geometry },
                                  onJump: { [weak editor] spreadID, frameID in
                                      editor?.currentSpreadID = spreadID
                                      if let frameID { editor?.selectedFrameID = frameID }
                                      closeExport()
                                  })
    }

    /// Closes the export sheet, never while an export runs (it has to be cancelled first).
    private func closeExport() {
        guard exportModel?.isExporting != true else { return }
        exportModel?.close()
        exportModel = nil
    }

    private func makeModels() {
        if triage?.store !== store { triage = TriageModel(store: store) }
        if editor?.store !== store {
            do {
                let (profile, format) = try ProfileCatalog.format(profileID: store.album.supplierProfileID,
                                                                  formatID: store.album.formatID)
                editor = EditorModel(store: store, geometry: PageGeometry(format: format, profile: profile))
                editorError = nil
            } catch {
                editor = nil
                editorError = "Formát alba není známý (\(store.album.supplierProfileID), \(store.album.formatID))."
            }
        }
        undoTarget.mode = mode
        bindUndo(undoManager)
    }

    private func bindUndo(_ manager: UndoManager?) {
        editor?.undoManager = manager
        undoTarget.editor = editor
        undoTarget.store = store
        undoTarget.undoManager = manager
    }

    private func propose() {
        guard let editor else { return }
        editor.undoManager = undoManager
        editor.draftIfEmpty()
        if let next = WindowModeLogic.afterPropose(hasSpreads: !store.album.spreads.isEmpty) {
            requestedMode = next
        }
    }

    private func switchTo(_ next: WindowMode) {
        if next == .editor && store.album.spreads.isEmpty {
            propose()
            return
        }
        if next == .triage { editor?.commitSessions() }
        requestedMode = next
    }
}
