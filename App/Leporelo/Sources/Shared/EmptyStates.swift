import AppKit
import LeporeloCore
import SwiftUI

/// What the album window shows instead of (or as) its content.
enum AlbumScreen: Equatable {
    case content
    /// Background work needs Photos, access blocks it and there is nothing to browse yet.
    case noPermission(PhotoAccess)
    /// The album has no photos (CLI, or a refresh of an empty range).
    case empty
}

enum AlbumScreenLogic {
    /// Whether background work would read the source: the album has a source query and a
    /// non-video photo has no analysis (no thumbnail) or a selected or placed photo has no stored
    /// original.
    static func needsSource(_ album: Album) -> Bool {
        guard album.source != nil else { return false }
        if album.photos.values.contains(where: { $0.kind != .video && $0.analysis == nil }) { return true }
        return !OriginalsWork.wanted(in: album).isEmpty
    }

    /// The permission screen only when work actually needs the source, `access` blocks it and
    /// there is nothing to browse (no photo analysed, so no thumbnail). An album that is
    /// browsable or fully downloaded opens without Photos access: triage, editing and export work
    /// from the package (the banner says what cannot be fetched).
    static func screen(album: Album, access: PhotoAccess) -> AlbumScreen {
        if album.photos.isEmpty { return .empty }
        if access.allowsForm || !needsSource(album) { return .content }
        let browsable = album.photos.values.contains { $0.analysis != nil }
        return browsable ? .content : .noPermission(access)
    }
}

enum EmptyStateText {
    static func title(for source: SourceQuery?) -> String {
        switch source {
        case .dateRange: "V tomto rozmezí nejsou žádné fotky"
        case .album(_, let name): "V albu \(name) nejsou žádné fotky"
        case nil: "V albu nejsou žádné fotky"
        }
    }

    static let permissionTitle = "Leporelo nemá přístup k Fotkám"
}

/// Full-window text when Photos access blocks an album that has nothing to show yet.
struct PermissionStateView: View {
    let access: PhotoAccess
    /// Called after the user granted access from here (the window restarts its work).
    let onAccessChanged: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(EmptyStateText.permissionTitle, systemImage: "photo.badge.exclamationmark")
        } description: {
            Text(access.explanation)
        } actions: {
            if let title = access.actionTitle {
                Button(title) {
                    switch access {
                    case .notDetermined:
                        Task {
                            _ = await PhotoKitAuthorization.request()
                            onAccessChanged()
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
}

/// An album without photos, with "Načíst nové fotky ze zdroje" when it can be refreshed.
struct EmptyAlbumView: View {
    let source: SourceQuery?
    let onRefresh: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(EmptyStateText.title(for: source), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(source == nil
                 ? "Album nemá uložený zdroj fotek."
                 : "Až do zdroje přibudou fotky, načtěte je znovu.")
        } actions: {
            if let onRefresh {
                Button(RefreshText.command, action: onRefresh)
            }
        }
    }
}
