import AppKit
import LeporeloCore

/// Grid thumbnails: decoded OFF the main thread from the package's stored thumbnail, downsampled
/// at decode time (ImageIO, `ProjectPackage.thumbnail(for:maxPixelSize:)`) so the SHORT side still
/// fills a 160 pt cell on Retina (`maxPixel(width:height:)`), and kept in a cost-limited `NSCache`
/// keyed by photo id (one decode size per photo, so the id is the whole key).
///
/// A missing thumbnail (analysis has not reached the photo yet) is not cached, so the next
/// configure of the cell (its item changes when its analysis lands) tries again.
@MainActor
final class ThumbnailLoader {
    /// Short side in pixels: 160 pt cells on a 2x display.
    nonisolated static let shortSidePixels = 320

    /// The long-side limit to decode a photo of this size at, so its short side is at least
    /// `shortSidePixels` (aspect fill crops the long side; e.g. 480 for 3:2), capped at the stored
    /// thumbnail size. Unknown sizes decode at `shortSidePixels`.
    nonisolated static func maxPixel(width: Int, height: Int) -> Int {
        let long = max(width, height), short = min(width, height)
        guard short > 0 else { return shortSidePixels }
        let needed = (Double(shortSidePixels) * Double(long) / Double(short)).rounded(.up)
        return min(Int(needed), ProjectPackage.thumbnailMaxPixelSize)
    }

    nonisolated static func maxPixel(for photo: Photo) -> Int {
        maxPixel(width: photo.pixelWidth, height: photo.pixelHeight)
    }

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Entry>()
    private var prefetches: [PhotoID: Task<Void, Never>] = [:]

    init(costLimitBytes: Int = 192 * 1024 * 1024) {
        cache.totalCostLimit = costLimitBytes
    }

    func cached(_ id: PhotoID) -> CGImage? {
        cache.object(forKey: id as NSString)?.image
    }

    /// The thumbnail of `id` from the cache or decoded off the main actor with its long side at
    /// most `maxPixel`; nil when the package has none (yet) or the task was cancelled (cell reused).
    func load(_ id: PhotoID, maxPixel: Int, from package: ProjectPackage) async -> CGImage? {
        if let image = cached(id) { return image }
        guard let image = await Self.decode(id, maxPixel, package) else { return nil }
        cache.setObject(Entry(image), forKey: id as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Warms the cache for rows about to scroll in (`NSCollectionViewPrefetching`).
    func prefetch(_ requests: [(id: PhotoID, maxPixel: Int)], from package: ProjectPackage) {
        for (id, maxPixel) in requests where prefetches[id] == nil && cached(id) == nil {
            prefetches[id] = Task { [weak self] in
                _ = await self?.load(id, maxPixel: maxPixel, from: package)
                self?.prefetches[id] = nil
            }
        }
    }

    func cancelPrefetch(_ ids: [PhotoID]) {
        for id in ids { prefetches.removeValue(forKey: id)?.cancel() }
    }

    func cancelAll() {
        prefetches.values.forEach { $0.cancel() }
        prefetches = [:]
    }

    /// Runs on the global executor (nonisolated async), never on the main actor.
    nonisolated private static func decode(_ id: PhotoID, _ maxPixel: Int,
                                           _ package: ProjectPackage) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let image = package.thumbnail(for: id, maxPixelSize: maxPixel)
        return Task.isCancelled ? nil : image
    }
}
