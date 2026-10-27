import AppKit
import LeporeloCore
import SwiftUI

/// "Nové album": checks Photos access, then the form (title, format, source: a date range or an
/// album from Photos). "Založit album" asks where to save the `.leporelo` package, creates it
/// (`NewAlbumModel.createAlbum`: fetch, days, first save) and opens it as a document; the window
/// then starts the background analysis. Shown as its own window (File > Nové album…) and as a
/// sheet from an album window.
struct NewAlbumSheet: View {
    static let windowID = "new-album"

    var onClose: (() -> Void)?
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var access = PhotoAccess(PhotoKitAuthorization.currentStatus())
    @State private var model: NewAlbumModel?
    @State private var setupError: String?
    @State private var isCreating = false
    @State private var alertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nové album")
                .font(.title2.bold())
            if let setupError {
                Text(setupError).foregroundStyle(.red)
            } else if access.allowsForm, let model {
                // Locked while creating: the flow runs to its end (success or alert), never
                // half-cancelled with its error swallowed.
                NewAlbumForm(model: model)
                    .disabled(isCreating)
            } else if !access.allowsForm {
                accessView
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Zakládám album…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Zrušit", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                if access.allowsForm, let model {
                    Button("Založit album") { Task { await create(model) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canCreate || isCreating)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(isCreating)
        .onAppear(perform: refreshAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()  // the user may come back from System Settings
        }
        .alert("Album se nepodařilo založit", isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var accessView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(access.explanation)
                .fixedSize(horizontal: false, vertical: true)
            if let title = access.actionTitle {
                Button(title) {
                    switch access {
                    case .notDetermined:
                        Task {
                            access = PhotoAccess(await PhotoKitAuthorization.request())
                            refreshAccess()
                        }
                    case .denied, .limited:
                        NSWorkspace.shared.open(PhotoAccess.settingsURL)
                    case .restricted, .authorized:
                        break
                    }
                }
            }
        }
    }

    /// Re-reads the status (never prompts) and creates the model once full access is granted.
    private func refreshAccess() {
        access = PhotoAccess(PhotoKitAuthorization.currentStatus())
        guard access.allowsForm, model == nil, setupError == nil else { return }
        do {
            model = NewAlbumModel(source: PhotoKitSource(), profiles: try ProfileCatalog.all())
        } catch {
            setupError = "Nepodařilo se načíst formáty knih."
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismissWindow(id: Self.windowID) }
    }

    /// Main actor throughout: the save panel and the document controller are UI.
    @MainActor
    private func create(_ model: NewAlbumModel) async {
        guard let url = choosePackageURL(title: model.title) else { return }
        isCreating = true
        defer { isCreating = false }
        var created: URL?
        do {
            let (package, _) = try await model.createAlbum(packageURL: url)
            created = package.url
            try await openDocument(at: package.url)
            close()
        } catch {
            // createAlbum already removed a package it could not finish; a package that was
            // created but would not open is removed here. An existing package is never touched
            // (createAlbum refuses to create over it).
            if let created { try? FileManager.default.removeItem(at: created) }
            alertMessage = NewAlbumModel.errorMessage(for: error)
        }
    }

    @MainActor
    private func choosePackageURL(title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Uložit nové album"
        panel.prompt = "Založit"
        panel.allowedContentTypes = [.leporeloAlbum]
        panel.nameFieldStringValue = NewAlbumModel.packageFileName(for: title)
        panel.canCreateDirectories = true
        let guardian = NewPackageLocationGuard()
        panel.delegate = guardian
        let response = withExtendedLifetime(guardian) { panel.runModal() }
        guard response == .OK else { return nil }
        return panel.url
    }

    @MainActor
    private func openDocument(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if document != nil { continuation.resume() }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

/// Keeps the save panel from accepting an existing location, before AppKit would ask "Replace?"
/// (the flow never replaces or deletes an existing package, so "Replace" could only end in an
/// error). `NewAlbumModel.createAlbum` still refuses one (`alreadyExists`) as the last line.
@MainActor
private final class NewPackageLocationGuard: NSObject, NSOpenSavePanelDelegate {
    /// Called when the user confirms a name, before the replace confirmation; nil rejects it.
    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, let panel = sender as? NSSavePanel, let directory = panel.directoryURL else { return filename }
        if let problem = NewAlbumModel.saveLocationProblem(directory.appendingPathComponent(filename)) {
            panel.message = problem
            NSSound.beep()
            return nil
        }
        return filename
    }

    /// Second check on the final URL (e.g. a name AppKit completed with the extension).
    func panel(_ sender: Any, validate url: URL) throws {
        if let problem = NewAlbumModel.saveLocationProblem(url) {
            (sender as? NSSavePanel)?.message = problem
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: problem])
        }
    }
}

/// The form once Photos access is granted.
private struct NewAlbumForm: View {
    @Bindable var model: NewAlbumModel

    var body: some View {
        Form {
            TextField("Název", text: $model.title)
            if model.profiles.count > 1 {
                Picker("Dodavatel", selection: $model.profileID) {
                    ForEach(model.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Picker("Formát", selection: $model.formatID) {
                ForEach(model.formats, id: \.id) { Text($0.name).tag($0.id) }
            }
            if let note = model.unverifiedFormatNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            Picker("Zdroj fotek", selection: $model.queryMode) {
                Text("Rozmezí dat").tag(QueryMode.dateRange)
                Text("Album z Fotek").tag(QueryMode.album)
            }
            .pickerStyle(.segmented)
            switch model.queryMode {
            case .dateRange:
                DatePicker("Od", selection: $model.start, displayedComponents: .date)
                DatePicker("Do", selection: $model.end, displayedComponents: .date)
            case .album:
                Picker("Album", selection: selectedAlbumID) {
                    Text("Vyberte album").tag(String?.none)
                    ForEach(model.albums, id: \.identifier) { album in
                        Text("\(album.name) (\(BannerText.czech(album.count)))").tag(String?.some(album.identifier))
                    }
                }
            }
            status
        }
        .formStyle(.grouped)
        .task { await model.loadAlbums() }
        .task(id: model.query) { await model.refreshPreview() }
    }

    @ViewBuilder private var status: some View {
        if let error = model.sourceError {
            Text(error).foregroundStyle(.red)
        } else if let empty = model.emptySourceMessage {
            Text(empty).foregroundStyle(.red)
        } else if let count = model.photoCountText {
            Text(count).foregroundStyle(.secondary)
        }
        if let shared = model.sharedAlbumWarning {
            Label(shared, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if let warning = model.warning, model.sharedAlbumWarning == nil {
            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private var selectedAlbumID: Binding<String?> {
        Binding(get: { model.selectedAlbum?.identifier },
                set: { id in model.selectedAlbum = model.albums.first { $0.identifier == id } })
    }
}
