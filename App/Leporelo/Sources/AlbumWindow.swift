import LeporeloCore
import SwiftUI

/// The document window: the background-work banner on top of the triage view (Task 20) once the
/// album is bound and has photos, else placeholder content (the album title).
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
    @Environment(\.photoSourceProvider) private var photoSourceProvider

    private var store: AlbumStore? { session.store }

    var body: some View {
        VStack(spacing: 0) {
            // The banner observes the work's counters itself; this body only reads `session.work`.
            if let work = session.work { ProgressBanner(work: work) }
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
        .onDisappear { session.close() }
    }

    @ViewBuilder private var content: some View {
        if let bindError = session.bindError {
            ContentUnavailableView("Album nejde otevřít", systemImage: "exclamationmark.triangle",
                                   description: Text(bindError))
        } else if let store, !store.album.photos.isEmpty {
            // A new store (rebind after revert, reload or move) gets a new model.
            TriageContainer(store: store).id(ObjectIdentifier(store))
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
