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
            LayoutCommands()
            UndoCommands()
        }

        // The start window: at launch, File > "Nové album…", Window > "Úvod" and a Dock click
        // with no window open. Its automatic Window menu item is removed in favour of "Úvod"
        // (`StartCommands`). As the host of the app tests it stays empty: the tests must not
        // read the real Photos library.
        Window("Leporelo", id: StartView.windowID) {
            if AppRuntime.isHostingTests {
                Color.clear
            } else {
                StartView()
            }
        }
        .defaultSize(width: 1000, height: 680)
        .defaultLaunchBehavior(.presented)
        .commandsRemoved()

        // Leporelo > "Oblíbená rozložení…" (`LayoutCommands`): the layouts the draft favours.
        Window("Oblíbená rozložení", id: FavoriteLayoutsWindow.windowID) {
            if AppRuntime.isHostingTests {
                Color.clear
            } else {
                FavoriteLayoutsWindow()
            }
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

enum AppRuntime {
    /// True when the app runs as the host of its XCTest bundle (`make test-app`).
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// Albums are only created from the start window, never as untitled documents. With the Open
/// panel switched off (`NSShowAppCentricOpenPanelInsteadOfUntitledFile`), AppKit would open an
/// empty untitled document at launch (and on a Dock click without windows) instead; this stops it.
/// A Dock click with no visible window opens the start window instead.
final class LeporeloAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // Handled when the start window opens; else AppKit's default (which opens nothing).
        return !StartWindowOpener.shared.open()
    }
}

/// SwiftUI's `OpenWindowAction` for the start window, for AppKit callbacks that have no SwiftUI
/// environment (the app delegate's Dock reopen). `StartCommands` registers it when the menus
/// are built, which happens at launch.
@MainActor
final class StartWindowOpener {
    static let shared = StartWindowOpener()
    private var action: OpenWindowAction?

    func register(_ action: OpenWindowAction) {
        self.action = action
    }

    /// Opens (or brings to front) the start window; false before an action was registered.
    @discardableResult
    func open() -> Bool {
        guard let action else { return false }
        action(id: StartView.windowID)
        return true
    }
}

/// Window > "Úvod": opens (or brings to front) the start window. Also hands the window opener
/// to `StartWindowOpener` for the Dock reopen.
struct StartCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = StartWindowOpener.shared.register(openWindow)
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

/// Leporelo > "Oblíbená rozložení…": opens the choice of favourite layouts (spec 6).
struct LayoutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Oblíbená rozložení…") { openWindow(id: FavoriteLayoutsWindow.windowID) }
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
