import LeporeloCore
import SwiftUI

@main
struct LeporeloApp: App {
    @NSApplicationDelegateAdaptor(LeporeloAppDelegate.self) private var appDelegate

    init() {
        FontRegistry.registerBundledFonts()
        // At launch the start window replaces the system Open panel (spec section 2). Registered,
        // not set, so a value the user set with `defaults write` still wins.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
    }

    var body: some Scene {
        DocumentGroup(newDocument: { AlbumDocument() }) { file in
            AlbumWindow(document: file.document, fileURL: file.fileURL)
        }
        .commands {
            FileCommands()
            StartCommands()
            ExportCommands()
            SourceCommands()
            UndoCommands()
        }

        // The start window: at launch, File > "Nové album…" and Window > "Úvod". Its automatic
        // Window menu item is removed in favour of "Úvod" (`StartCommands`).
        Window("Leporelo", id: StartView.windowID) {
            StartView()
        }
        .defaultSize(width: 1000, height: 680)
        .defaultLaunchBehavior(.presented)
        .commandsRemoved()
    }
}

/// Albums are only created from the start window, never as untitled documents. With the Open
/// panel switched off (`NSShowAppCentricOpenPanelInsteadOfUntitledFile`), AppKit would open an
/// empty untitled document at launch (and on a Dock click without windows) instead; this stops it.
final class LeporeloAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

/// Window > "Úvod": opens (or brings to front) the start window.
struct StartCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Úvod") { openWindow(id: StartView.windowID) }
        }
    }
}

/// Albums are created as packages from the start window, never as untitled documents, so
/// File > New is replaced by "Nové album…", which opens the start window; Open and Open Recent
/// are a separate group and stay.
/// Do not touch `NSDocumentController.shared` while building commands: that runs before SwiftUI
/// installs its own document controller, and an early `shared` crashes the app at launch.
struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nové album…") { openWindow(id: StartView.windowID) }
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

/// File > "Načíst nové fotky ze zdroje" and "Stáhnout znovu" (originals that could not be
/// downloaded), for the front album window.
struct SourceCommands: Commands {
    @FocusedValue(\.albumRefresh) private var refresh
    @FocusedValue(\.albumRetryDownloads) private var retryDownloads

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button(RefreshText.command) { refresh?.run() }
                .disabled(refresh == nil)
            Button(BannerText.retry) { retryDownloads?.run() }
                .disabled(retryDownloads == nil)
        }
    }
}
