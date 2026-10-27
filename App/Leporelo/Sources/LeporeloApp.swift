import LeporeloCore
import SwiftUI

@main
struct LeporeloApp: App {
    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { AlbumDocument() }) { file in
            AlbumWindow(document: file.document, fileURL: file.fileURL)
        }
        .commands {
            FileCommands()
            ExportCommands()
            SourceCommands()
            UndoCommands()
        }

        // "Nové album…" from the File menu (also when no album is open).
        Window("Nové album", id: NewAlbumSheet.windowID) {
            NewAlbumSheet()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Albums are created as packages by the "Nové album" flow (Task 19), never as untitled documents,
/// so File > New is replaced; Open and Open Recent are a separate group and stay.
/// Do not touch `NSDocumentController.shared` while building commands: that runs before SwiftUI
/// installs its own document controller, and an early `shared` crashes the app at launch.
struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nové album…") { openWindow(id: NewAlbumSheet.windowID) }
                .keyboardShortcut("n")
        }
    }
}

/// File > "Exportovat…" (⇧⌘E): the front album window's export action, enabled when that album
/// has spreads.
struct ExportCommands: Commands {
    @FocusedValue(\.albumExport) private var export

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Exportovat…") { export?.run() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(export == nil)
        }
    }
}

/// File > "Stáhnout znovu" (originals that could not be downloaded).
struct SourceCommands: Commands {
    @FocusedValue(\.albumRetryDownloads) private var retryDownloads

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button(BannerText.retry) { retryDownloads?.run() }
                .disabled(retryDownloads == nil)
        }
    }
}
