import LeporeloCore
import SwiftUI

/// The document window. Placeholder content until Task 19+: the album title and an empty state.
struct AlbumWindow: View {
    let document: AlbumDocument
    let fileURL: URL?

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
            .task(id: fileURL) { bind() }
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

    /// Binds the store to the package once SwiftUI knows the file URL (and again after a move).
    private func bind() {
        guard let fileURL else { return }
        do {
            store = try document.store(for: fileURL)
            bindError = nil
        } catch {
            bindError = String(describing: error)
        }
    }
}
