import CoreGraphics
import Foundation
import LeporeloCore
import Photos
import UniformTypeIdentifiers

/// Pure mapping logic of `PhotoKitSource`, on plain values only (enums, numbers, strings), so it
/// is unit-testable without touching `PHPhotoLibrary`.
enum PhotoKitMapping {

    // MARK: Queries

    /// Half-open capture range, same convention as `FolderPhotoSource`: `start <= date < end`.
    static func dateRangePredicate(start: Date, end: Date) -> NSPredicate {
        NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
    }

    /// Images and videos. Videos are returned (as `.video`) so triage can show them greyed out;
    /// audio and unknown media types are not.
    static func mediaTypePredicate() -> NSPredicate {
        NSPredicate(format: "mediaType == %d OR mediaType == %d",
                    PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
    }

    /// Full predicate for a query: the media types, plus the date range for `.dateRange`.
    /// `.album` queries scope by collection instead (`PHAsset.fetchAssets(in:options:)`).
    static func predicate(for query: SourceQuery) -> NSPredicate {
        switch query {
        case .dateRange(let start, let end):
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                dateRangePredicate(start: start, end: end), mediaTypePredicate(),
            ])
        case .album:
            mediaTypePredicate()
        }
    }

    /// PhotoKit sorts by creation date; the final, deterministic order (capturedAt, identifier)
    /// is applied in Swift by `sorted(_:)` because `localIdentifier` is not a documented
    /// PhotoKit sort key and `capturedAt` may come from a fallback date.
    static func fetchSortDescriptors() -> [NSSortDescriptor] {
        [NSSortDescriptor(key: "creationDate", ascending: true)]
    }

    static func sorted(_ photos: [SourcePhoto]) -> [SourcePhoto] {
        photos.sorted { ($0.capturedAt, $0.identifier) < ($1.capturedAt, $1.identifier) }
    }

    /// By name (Finder-like comparison), ties by identifier so the order is stable.
    static func sorted(_ albums: [SourceAlbum]) -> [SourceAlbum] {
        albums.sorted { a, b in
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.identifier < b.identifier
            }
        }
    }

    // MARK: Asset metadata

    /// `.livePhoto` for images with the live subtype, `.photo` for other images, `.video` for
    /// videos, nil (skipped) for audio/unknown.
    static func kind(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype) -> PhotoKind? {
        switch mediaType {
        case .image: subtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video: .video
        case .audio, .unknown: nil
        @unknown default: nil
        }
    }

    /// `creationDate`, else `modificationDate`, else the Unix epoch (never `.distantPast`, which
    /// would break day grouping arithmetic). Assets without a creation date are rare (broken
    /// imports); they sort first and the user can deselect them.
    static func capturedAt(creationDate: Date?, modificationDate: Date?) -> Date {
        creationDate ?? modificationDate ?? Date(timeIntervalSince1970: 0)
    }

    /// A `CLLocation` is usable when its coordinate is valid and its horizontal accuracy is not
    /// negative (CoreLocation's "invalid" marker). Exactly (0, 0) is treated as "no location",
    /// as in `FolderPhotoSource`.
    static func location(latitude: Double, longitude: Double, horizontalAccuracy: Double) -> GeoPoint? {
        guard horizontalAccuracy >= 0, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// Assembles a `SourcePhoto` from plain asset values.
    ///
    /// - `pixelWidth/Height` are `PHAsset.pixelWidth/pixelHeight`: the size of the asset's
    ///   current (edited, if edited) image in display orientation, i.e. upright. For assets of
    ///   iCloud shared albums these are the downsized dimensions (about 2048 px on the long
    ///   side), which is what the low-resolution warning in the UI relies on; no special case here.
    /// - `timeZoneSeconds` is always nil: PhotoKit exposes no capture time zone.
    /// - `isCloudOnly` is always false here: PhotoKit has no public, cheap per-asset "is the
    ///   original local" flag (`locallyAvailable` is private). See
    ///   `PhotoKitSource.isLocallyAvailable(identifier:)` for the lazy, per-photo check.
    static func sourcePhoto(identifier: String, creationDate: Date?, modificationDate: Date?,
                            coordinate: (latitude: Double, longitude: Double, accuracy: Double)?,
                            pixelWidth: Int, pixelHeight: Int,
                            mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype) -> SourcePhoto? {
        guard let kind = kind(mediaType: mediaType, subtypes: subtypes) else { return nil }
        let geo = coordinate.flatMap {
            location(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: $0.accuracy)
        }
        return SourcePhoto(identifier: identifier,
                           capturedAt: capturedAt(creationDate: creationDate, modificationDate: modificationDate),
                           timeZoneSeconds: nil, location: geo,
                           pixelWidth: max(0, pixelWidth), pixelHeight: max(0, pixelHeight),
                           kind: kind, isCloudOnly: false)
    }

    // MARK: Originals

    /// File extensions PhotoKit delivers as rendered still images Leporelo can place directly.
    static let renderedStillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"]

    /// Lowercased extension from the resource's original filename ("IMG_0001.HEIC" -> "heic"),
    /// else the preferred extension of its uniform type identifier ("public.heic" -> "heic").
    /// Nil when neither yields a short alphanumeric extension.
    static func fileExtension(originalFilename: String?, uniformTypeIdentifier: String?) -> String? {
        if let name = originalFilename {
            let ext = (name as NSString).pathExtension.lowercased()
            if isValidExtension(ext) { return ext }
        }
        if let uti = uniformTypeIdentifier, let type = UTType(uti),
           let ext = type.preferredFilenameExtension?.lowercased(), isValidExtension(ext) {
            return ext
        }
        return nil
    }

    /// Same rule as `ProjectPackage.storeOriginal`: 1-8 ASCII alphanumerics.
    static func isValidExtension(_ ext: String) -> Bool {
        (1...8).contains(ext.count)
            && ext.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Index of the still-image resource to download, or nil if the asset has none.
    ///
    /// Order: `.fullSizePhoto` (the rendered edit, what the user sees and what `PHAsset`'s
    /// dimensions describe), then `.photo` (the unedited original), then `.alternatePhoto`
    /// (the second half of a RAW+JPEG pair). The first candidate in that order with a rendered
    /// still extension (HEIC/JPEG/PNG/TIFF) wins, so a RAW primary with a JPEG alternate yields
    /// the JPEG; otherwise the first candidate present. Paired videos of live photos, videos,
    /// audio and adjustment data are never chosen.
    static func stillResourceIndex(_ resources: [(type: PHAssetResourceType, ext: String?)]) -> Int? {
        let order: [PHAssetResourceType] = [.fullSizePhoto, .photo, .alternatePhoto]
        let candidates = order.flatMap { type in
            resources.indices.filter { resources[$0].type == type }
        }
        if let rendered = candidates.first(where: {
            resources[$0].ext.map(renderedStillExtensions.contains) ?? false
        }) {
            return rendered
        }
        return candidates.first
    }

    // MARK: Errors

    /// iCloud / network failures, retried by `OriginalsDownloader` as `cloudUnavailable`.
    static func isNetworkFailure(domain: String, code: Int) -> Bool {
        if domain == PHPhotosErrorDomain {
            return code == PHPhotosError.Code.networkAccessRequired.rawValue
                || code == PHPhotosError.Code.networkError.rawValue
        }
        return domain == NSURLErrorDomain
    }

    /// The asset or its resource no longer exists.
    static func isMissing(domain: String, code: Int) -> Bool {
        domain == PHPhotosErrorDomain
            && (code == PHPhotosError.Code.identifierNotFound.rawValue
                || code == PHPhotosError.Code.missingResource.rawValue)
    }

    static func isUserCancelled(domain: String, code: Int) -> Bool {
        (domain == PHPhotosErrorDomain && code == PHPhotosError.Code.userCancelled.rawValue)
            || (domain == NSCocoaErrorDomain && code == NSUserCancelledError)
    }

    // MARK: Thumbnails

    /// Pixel size to request: the asset size scaled to fit `maxPixel` on the longest side,
    /// never upscaled, at least 1x1. Unknown asset size (0) => a `maxPixel` square box.
    static func thumbnailPixelSize(pixelWidth: Int, pixelHeight: Int, maxPixel: Int) -> (width: Int, height: Int) {
        let limit = max(1, maxPixel)
        guard pixelWidth > 0, pixelHeight > 0 else { return (limit, limit) }
        let longest = max(pixelWidth, pixelHeight)
        guard longest > limit else { return (pixelWidth, pixelHeight) }
        let scale = Double(limit) / Double(longest)
        return (min(limit, max(1, Int((Double(pixelWidth) * scale).rounded()))),
                min(limit, max(1, Int((Double(pixelHeight) * scale).rounded()))))
    }

    /// What to do with one `requestImage` callback.
    enum ImageCallbackOutcome: Equatable {
        /// A degraded interim image: ignore it and wait for the final callback.
        case wait
        case deliver
        case cancelled
        case cloudUnavailable
        case missing
        case failed
    }

    static func imageCallbackOutcome(hasImage: Bool, isDegraded: Bool, isCancelled: Bool,
                                     isInCloud: Bool, errorDomain: String?, errorCode: Int?) -> ImageCallbackOutcome {
        if isCancelled { return .cancelled }
        if let domain = errorDomain, let code = errorCode {
            if isUserCancelled(domain: domain, code: code) { return .cancelled }
            if isNetworkFailure(domain: domain, code: code) { return .cloudUnavailable }
            if isMissing(domain: domain, code: code) { return .missing }
            if !hasImage { return isInCloud ? .cloudUnavailable : .failed }
        }
        if hasImage { return isDegraded ? .wait : .deliver }
        if isDegraded { return .wait }
        return isInCloud ? .cloudUnavailable : .missing
    }

    /// Downscales `image` so its longest side is <= `maxPixel` (no-op when it already fits).
    /// A safety net: `.exact` resize normally delivers the requested size already.
    static func clamp(_ image: CGImage, maxPixel: Int) -> CGImage {
        let limit = max(1, maxPixel)
        guard max(image.width, image.height) > limit else { return image }
        let size = thumbnailPixelSize(pixelWidth: image.width, pixelHeight: image.height, maxPixel: limit)
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage() ?? image
    }
}
