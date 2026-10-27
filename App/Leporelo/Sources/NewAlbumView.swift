import SwiftUI

/// Placeholder for the "Nové album" flow (Task 19 creates the package with `ProjectPackage.create`
/// and opens it with `NSDocumentController.shared.openDocument(withContentsOf:display:)`).
struct NewAlbumView: View {
    static let windowID = "new-album"

    var onClose: (() -> Void)?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nové album")
                .font(.title2.bold())
            Text("Založení alba z fotek přijde v další verzi.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Zavřít") {
                    if let onClose { onClose() } else { dismissWindow(id: Self.windowID) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
