import AppKit
import LeporeloCore

/// Grid thumbnails: decoded OFF the main thread from the package's stored thumbnail, downsampled
/// at decode time to the cell's pixel size (ImageIO, `ProjectPackage.thumbnail(for:maxPixelSize:)`),
/// and kept in a cost-limited `NSCache` keyed by photo id.
///
/// A missing thumbnail (analysis has not reached the photo yet) is not cached, so the next
/// configure of the cell (its item changes when its analysis lands) tries again.
@MainActor
final class ThumbnailLoader {
    /// Long side in pixels: 160 pt cells on a 2x display.
    nonisolated static let pixelSize = 320

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

    /// The thumbnail of `id` from the cache or decoded off the main actor; nil when the package
    /// has none (yet) or the task was cancelled (cell reused).
    func load(_ id: PhotoID, from package: ProjectPackage) async -> CGImage? {
        if let image = cached(id) { return image }
        guard let image = await Self.decode(id, package) else { return nil }
        cache.setObject(Entry(image), forKey: id as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Warms the cache for rows about to scroll in (`NSCollectionViewPrefetching`).
    func prefetch(_ ids: [PhotoID], from package: ProjectPackage) {
        for id in ids where prefetches[id] == nil && cached(id) == nil {
            prefetches[id] = Task { [weak self] in
                _ = await self?.load(id, from: package)
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
    nonisolated private static func decode(_ id: PhotoID, _ package: ProjectPackage) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let image = package.thumbnail(for: id, maxPixelSize: pixelSize)
        return Task.isCancelled ? nil : image
    }
}
