import LeporeloCore
import SwiftUI

/// "Udělat z toho knihu": the book form for the album or date range picked in the start window.
/// "Založit" asks where to save, creates and opens the book (`AlbumCreation`), then closes the
/// start window.
struct CreateBookSheet: View {
    let model: NewAlbumModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isCreating = false
    @State private var alertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Udělat z toho knihu")
                .font(.title2.bold())
            // Locked while creating: the flow runs to its end (success or alert), never
            // half-cancelled with its error swallowed.
            NewAlbumForm(model: model)
                .disabled(isCreating)
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Zakládám album…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Zrušit", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Založit") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate || isCreating)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(isCreating)
        .alert("Album se nepodařilo založit", isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    /// Main actor throughout: the save panel and the document controller are UI.
    private func create() async {
        guard let url = AlbumCreation.choosePackageURL(title: model.title) else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            try await AlbumCreation.create(model, at: url)
            dismiss()
            dismissWindow(id: StartView.windowID)
        } catch {
            alertMessage = NewAlbumModel.errorMessage(for: error)
        }
    }
}
