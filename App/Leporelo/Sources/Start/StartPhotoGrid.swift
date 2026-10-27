import AppKit
import LeporeloCore
import SwiftUI

/// The start window's photo grid: square cells of about 110 pt, view only (picking photos is
/// done later in triage). Each cell loads its thumbnail in `.task(id:)`, so the load starts when
/// the lazy grid creates the cell and is cancelled when the cell disappears.
struct StartPhotoGrid: View {
    let photos: [SourcePhoto]
    let source: any PhotoSource

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 4)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(photos, id: \.identifier) { photo in
                    StartPhotoCell(identifier: photo.identifier, source: source)
                }
            }
            .padding(16)
        }
    }
}

private struct StartPhotoCell: View {
    let identifier: String
    let source: any PhotoSource

    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .task(id: identifier) {
                image = StartThumbnails.cached(identifier)
                guard image == nil else { return }
                guard let loaded = try? await source.thumbnail(for: identifier, maxPixel: StartThumbnails.maxPixel),
                      !Task.isCancelled else { return }
                StartThumbnails.store(loaded, for: identifier)
                image = loaded
            }
    }
}

/// A small, bounded cache so scrolling back does not ask PhotoKit again for the last few
/// hundred thumbnails.
@MainActor
private enum StartThumbnails {
    static let maxPixel = 256

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 64 * 1024 * 1024  // a few hundred 256 px thumbnails
        return cache
    }()

    static func cached(_ identifier: String) -> CGImage? {
        cache.object(forKey: identifier as NSString)?.image
    }

    static func store(_ image: CGImage, for identifier: String) {
        cache.setObject(Entry(image), forKey: identifier as NSString, cost: image.bytesPerRow * image.height)
    }
}
