import AppKit
import LeporeloCore
import SwiftUI

/// The start window (spec section 2), shown at launch and by File > "Nové album…" and
/// Window > "Úvod": recent books, the albums from Photos and "Podle data…" in the sidebar; the
/// selected album's (or date range's) photos with "Udělat z toho knihu" on the right.
struct StartView: View {
    static let windowID = "start"

    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var model = StartModel(source: PhotoKitSource(), recentBooks: StartView.recentBooks)
    @State private var access = PhotoAccess(PhotoKitAuthorization.currentStatus())
    @State private var draft: NewAlbumModel?
    @State private var alert: (title: String, message: String)?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        // Reloads when access changes (e.g. granted from the detail's prompt or in Settings).
        .task(id: access) { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()  // the user may come back from System Settings
        }
        .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
            if let draft { CreateBookSheet(model: draft) }
        }
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    /// The document controller's recent `.leporelo` packages that still exist. Only called from
    /// `StartModel.load()`, i.e. from this view's `.task`: never while scenes or commands are
    /// built (see `FileCommands`).
    @MainActor
    private static func recentBooks() -> [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter {
            $0.pathExtension == "leporelo" && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Moje knihy") {
                if model.books.isEmpty {
                    Text("Zatím žádná kniha").foregroundStyle(.secondary)
                }
                // Selecting a book (arrow keys) only shows it; a click, a double-click or Return
                // opens it (`primaryAction` below).
                ForEach(model.books, id: \.self) { url in
                    Label(Self.bookName(url), systemImage: "book.closed")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { open(url) }
                        .help(url.path)
                        .tag(StartItem.book(url))
                }
            }
            Section("Alba v iCloudu") {
                ForEach(model.albums, id: \.identifier) { album in
                    albumRow(album).tag(StartItem.album(album.identifier))
                }
            }
            Section("Jinak") {
                Label("Podle data…", systemImage: "calendar")
                    .tag(StartItem.dateRange)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: StartItem.self) { items in
            if case .book(let url)? = items.first, items.count == 1 {
                Button("Otevřít") { open(url) }
            }
        } primaryAction: { items in
            // Return or a double-click; only a single book opens.
            guard items.count == 1, case .book(let url)? = items.first else { return }
            open(url)
        }
    }

    private static func bookName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    @ViewBuilder private func albumRow(_ album: SourceAlbum) -> some View {
        let name = Self.displayName(album)
        if album.isShared {
            Label(name, systemImage: "person.2")
                .badge(CzechPlural.grouped(album.count))
                .help(NewAlbumModel.sharedAlbumMessage)
        } else {
            Label(name, systemImage: "rectangle.stack")
                .badge(CzechPlural.grouped(album.count))
        }
    }

    // MARK: Detail

    /// What the photo fetch depends on: the query, and access (granted later: fetch again).
    private struct PhotosKey: Equatable {
        let query: SourceQuery?
        let access: PhotoAccess
    }

    /// The fetch is attached here, not to the grid, so it also runs while an error is shown
    /// (picking another album after a failed one fetches again and clears the error).
    private var detail: some View {
        detailContent
            .task(id: PhotosKey(query: model.query, access: access)) {
                guard access.allowsForm else { return }
                await model.loadPhotos()
            }
    }

    @ViewBuilder private var detailContent: some View {
        if !access.allowsForm {
            PermissionStateView(access: access, onAccessChanged: refreshAccess)
        } else if let problem = model.accessProblem {
            ContentUnavailableView("Fotky nejde načíst", systemImage: "exclamationmark.triangle",
                                   description: Text(problem))
        } else {
            switch model.selection {
            case .album, .dateRange:
                VStack(spacing: 0) {
                    header
                    Divider()
                    photos
                }
            case .book(let url):
                ContentUnavailableView {
                    Label(Self.bookName(url), systemImage: "book.closed")
                } description: {
                    Text(url.deletingLastPathComponent().path)
                } actions: {
                    // No default-button shortcut: Return in the sidebar already opens the
                    // book (the list's `primaryAction`), and must not open it twice.
                    Button("Otevřít") { open(url) }
                }
            case nil:
                ContentUnavailableView("Vyberte album", systemImage: "photo.on.rectangle",
                                       description: Text("Vlevo vyberte album z Fotek nebo rozmezí dat."))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(model.photoCount.map(CzechPlural.photos) ?? " ")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.selection == .dateRange {
                DatePicker("Od", selection: $model.start, displayedComponents: .date)
                    .fixedSize()
                DatePicker("Do", selection: $model.end, displayedComponents: .date)
                    .fixedSize()
            }
            Spacer()
            Button("Udělat z toho knihu", action: makeBook)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isLoadingPhotos || model.photos.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: String {
        model.selectedAlbum.map(Self.displayName) ?? "Podle data"
    }

    private static func displayName(_ album: SourceAlbum) -> String {
        album.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bez názvu" : album.name
    }

    @ViewBuilder private var photos: some View {
        if model.query == nil {
            ContentUnavailableView("Neplatné rozmezí", systemImage: "calendar.badge.exclamationmark",
                                   description: Text(NewAlbumError.invalidRange.errorDescription ?? ""))
        } else if model.isLoadingPhotos && model.photos.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.photos.isEmpty {
            ContentUnavailableView("Žádné fotky", systemImage: "photo.on.rectangle",
                                   description: Text(model.selection == .dateRange
                                                     ? NewAlbumError.noPhotosInRange.errorDescription ?? ""
                                                     : NewAlbumError.noPhotosInAlbum.errorDescription ?? ""))
        } else {
            StartPhotoGrid(photos: model.photos, source: PhotoKitSource())
        }
    }

    // MARK: Actions

    private func refreshAccess() {
        access = PhotoAccess(PhotoKitAuthorization.currentStatus())
    }

    private func makeBook() {
        do {
            draft = model.makeNewAlbumModel(profiles: try ProfileCatalog.all())
        } catch {
            alert = ("Knihu nejde založit", "Nepodařilo se načíst formáty knih.")
        }
    }

    /// Opens a recent book through SwiftUI's document opening, then closes this window.
    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: Self.windowID)
            } catch {
                alert = ("Knihu nejde otevřít", error.localizedDescription)
            }
        }
    }
}
