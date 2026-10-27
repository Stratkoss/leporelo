import LeporeloCore
import SwiftUI

/// The app's photo sources for background work: PhotoKit for albums created by the app (they
/// have a source query), and only with full access. Never prompts (the start window asks).
enum AppPhotoSources {
    @MainActor
    static func source(for album: Album) -> (any PhotoSource)? {
        guard album.source != nil,
              PhotoKitAuthorization.allowsReading(PhotoKitAuthorization.currentStatus()) else { return nil }
        return PhotoKitSource()
    }
}

extension EnvironmentValues {
    /// Where an album window's background work gets its photos (tests and previews can replace it).
    @Entry var photoSourceProvider: PhotoSourceProvider = { album in AppPhotoSources.source(for: album) }
}
