import AppKit
import LeporeloCore
import SwiftUI

/// Creating a book from a filled `NewAlbumModel`: asks where to save the `.leporelo` package,
/// creates it (`NewAlbumModel.createAlbum`: fetch, days, first save) and opens it as a document;
/// the album window then starts the background analysis. Used by the start window's
/// "Udělat z toho knihu" sheet (`CreateBookSheet`).
@MainActor
enum AlbumCreation {
    /// The save panel; nil when the user cancelled it.
    static func choosePackageURL(title: String) -> URL? {
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

    /// Creates the package at `url` and opens it. On failure nothing is left behind:
    /// `createAlbum` already removed a package it could not finish, and a package that was
    /// created but would not open is removed here. An existing package is never touched
    /// (`createAlbum` refuses to create over it).
    static func create(_ model: NewAlbumModel, at url: URL) async throws {
        var created: URL?
        do {
            let (package, _) = try await model.createAlbum(packageURL: url)
            created = package.url
            try await openDocument(at: package.url)
        } catch {
            if let created { try? FileManager.default.removeItem(at: created) }
            throw error
        }
    }

    private static func openDocument(at url: URL) async throws {
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

/// The book form: title, supplier (only with more than one profile), format and the checks
/// before creating (photo count, empty source, reduced or shared photos, unverified format).
/// The photo source is given by the start window, so the form has no source picker.
struct NewAlbumForm: View {
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
            status
        }
        .formStyle(.grouped)
        .task(id: model.query) { await model.refreshPreview() }
    }

    @ViewBuilder private var status: some View {
        if let error = model.sourceError {
            Text(error).foregroundStyle(.red)
        } else if let empty = model.emptySourceMessage {
            Text(empty).foregroundStyle(.red)
        } else if let count = model.photoCountText {
            Text(count).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Počítám fotky…").foregroundStyle(.secondary)
            }
        }
        if let shared = model.sharedAlbumWarning {
            Label(shared, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if let warning = model.warning, model.sharedAlbumWarning == nil {
            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
