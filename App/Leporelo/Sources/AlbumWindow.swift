import LeporeloCore
import SwiftUI

/// The document window. Placeholder content until Task 19+: the album title and an empty state.
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

    @State private var store: AlbumStore?
    @State private var bindError: String?
    @State private var showsNewAlbum = false

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(store?.album.title ?? document.currentAlbum.title)
            .toolbar {
                ToolbarItem {
                    Button("Nové album…", systemImage: "plus") { showsNewAlbum = true }
                }
            }
            .sheet(isPresented: $showsNewAlbum) {
                NewAlbumView(onClose: { showsNewAlbum = false })
            }
            .task(id: BindKey(document: document, fileURL: fileURL)) { bind() }
    }

    @ViewBuilder private var content: some View {
        if let bindError {
            ContentUnavailableView("Album nejde otevřít", systemImage: "exclamationmark.triangle",
                                   description: Text(bindError))
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

    /// Binds the store to the package once SwiftUI knows the file URL, again after a move, and
    /// to the new document after a reload. The old store is dropped first.
    private func bind() {
        store = nil
        guard let fileURL else { return }
        do {
            store = try document.bind(to: fileURL)
            bindError = nil
        } catch {
            bindError = error.localizedDescription
        }
    }
}
