import AppKit
import LeporeloCore
import SwiftUI

/// The document window: the background-work banner on top of the album content (triage or the
/// editor, `AlbumContent`) once the album is bound and has photos, else placeholder content (the
/// album title).
struct AlbumWindow: View {
    let document: AlbumDocument
    let fileURL: URL?

    /// What the store binding depends on. Revert, Versions "Restore" and external-change reloads
    /// hand this window a NEW document for the same URL, so the document's identity is part of
    /// the key: otherwise the window would keep editing the old document's store, and the new
    /// document would autosave the reverted album forever.
    struct BindKey: Hashable {
        let document: ObjectIdentifier
        let fileURL: URL?

        init(document: AlbumDocument, fileURL: URL?) {
            self.document = ObjectIdentifier(document)
            self.fileURL = fileURL
        }
    }

    @State private var session = AlbumSession()
    @State private var showsNewAlbum = false
    /// Triage or editor as the user chose; nil = by the album (editor when it has spreads). Kept
    /// across rebinds (revert, reload, move) of the same window.
    @State private var requestedMode: WindowMode?
    /// Photos access, re-read when the app becomes active (the user may come back from Settings).
    @State private var access = PhotoAccess(PhotoKitAuthorization.currentStatus())
    @State private var refreshAlert: RefreshText.Alert?
    @Environment(\.photoSourceProvider) private var photoSourceProvider
    /// The document's undo manager (one per window); capped once here for every view of it.
    @Environment(\.undoManager) private var undoManager

    private var store: AlbumStore? { session.store }

    var body: some View {
        VStack(spacing: 0) {
            // The banner observes the work's counters itself; this body only reads `session.work`.
            if session.work != nil || session.originals != nil {
                ProgressBanner(work: session.work, originals: session.originals)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(store?.album.title ?? document.currentAlbum.title)
        .toolbar {
            ToolbarItem {
                Button("Nové album…", systemImage: "plus") { showsNewAlbum = true }
            }
        }
        .sheet(isPresented: $showsNewAlbum) {
            NewAlbumSheet(onClose: { showsNewAlbum = false })
        }
        .task(id: BindKey(document: document, fileURL: fileURL)) {
            // Binds the store once SwiftUI knows the file URL, again after a move, and to the new
            // document after a reload; the old store's background work is cancelled first.
            session.bind(document: document, fileURL: fileURL, sourceProvider: photoSourceProvider)
        }
        .focusedSceneValue(\.albumRetryDownloads, retryDownloadsAction)
        .focusedSceneValue(\.albumRefresh, refreshAction)
        .alert(item: $refreshAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateAccess()
        }
        .onAppear { AlbumStore.configure(undoManager) }
        .onChange(of: undoManager) { _, manager in AlbumStore.configure(manager) }
        .onDisappear { session.close() }
    }

    /// File > "Stáhnout znovu": while some originals could not be downloaded.
    private var retryDownloadsAction: RetryDownloadsAction? {
        guard let originals = session.originals, originals.failedCount > 0 else { return nil }
        return RetryDownloadsAction { originals.retryFailed() }
    }

    /// File > "Načíst nové fotky ze zdroje": with a source query and a source, not while running.
    private var refreshAction: RefreshSourceAction? {
        guard session.canRefresh else { return nil }
        return RefreshSourceAction { refresh() }
    }

    private func refresh() {
        Task {
            switch await session.refreshFromSource() {
            case .success(let report): refreshAlert = RefreshText.success(report)
            case .failure(let alert): refreshAlert = alert
            }
        }
    }

    /// Re-reads the Photos status (never prompts); when access was just granted, the background
    /// work restarts so analysis and downloads continue (Task 19b minor).
    private func updateAccess() {
        let now = PhotoAccess(PhotoKitAuthorization.currentStatus())
        guard now != access else { return }
        let granted = now.allowsForm && !access.allowsForm
        access = now
        if granted { session.restartWork() }
    }

    @ViewBuilder private var content: some View {
        if let bindError = session.bindError {
            ContentUnavailableView("Album nejde otevřít", systemImage: "exclamationmark.triangle",
                                   description: Text(bindError))
        } else if let store {
            switch AlbumScreenLogic.screen(album: store.album, access: access) {
            case .content:
                // A new store (rebind after revert, reload or move) gets a new model.
                AlbumContent(store: store, requestedMode: $requestedMode).id(ObjectIdentifier(store))
            case .noPermission(let blocked):
                PermissionStateView(access: blocked, onAccessChanged: updateAccess)
            case .empty:
                EmptyAlbumView(source: store.album.source, onRefresh: session.canRefresh ? { refresh() } : nil)
            }
        } else {
            ContentUnavailableView {
                Label(store?.album.title ?? document.currentAlbum.title, systemImage: "book.pages")
            } description: {
                if let fileURL {
                    Text(fileURL.deletingPathExtension().lastPathComponent)
                } else {
                    Text("Album zatím není uložené.")
                }
            }
        }
    }
}
