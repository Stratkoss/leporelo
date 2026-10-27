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

    /// Images only. Videos (and audio and unknown media types) are not part of the product and are
    /// never fetched, neither for a date range nor for an album.
    static func mediaTypePredicate() -> NSPredicate {
        NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
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

    /// `.livePhoto` for images with the live subtype, `.photo` for other images; nil (skipped)
    /// for videos, audio and unknown (the product has no videos).
    static func kind(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype) -> PhotoKind? {
        switch mediaType {
        case .image: subtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video, .audio, .unknown: nil
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

    /// Lowercased extension of a resource. The uniform type identifier describes the actual bytes,
    /// so it wins: its preferred extension ("public.heic" -> "heic", "public.jpeg" -> "jpg"),
    /// unless the filename's extension is a spelling of that same type ("IMG_1.JPEG" with
    /// public.jpeg -> "jpeg"). A filename that disagrees ("FullSizeRender.heic" holding JPEG
    /// bytes) loses. Without a known UTI the filename extension ("IMG_0001.HEIC" -> "heic") is the
    /// fallback. Nil when neither yields a short alphanumeric extension.
    static func fileExtension(originalFilename: String?, uniformTypeIdentifier: String?) -> String? {
        let nameExt = originalFilename
            .map { ($0 as NSString).pathExtension.lowercased() }
            .flatMap { isValidExtension($0) ? $0 : nil }
        if let uti = uniformTypeIdentifier, let type = UTType(uti), !type.isDynamic {
            // The filename keeps its own spelling only when it names the same type.
            if let nameExt, let nameType = UTType(filenameExtension: nameExt), nameType.conforms(to: type) {
                return nameExt
            }
            if let preferred = type.preferredFilenameExtension?.lowercased(), isValidExtension(preferred) {
                return preferred == "jpeg" ? "jpg" : preferred
            }
        }
        return nameExt
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

    /// iCloud / network failures, mapped to `cloudUnavailable` (retried by `OriginalsDownloader`
    /// 3 times before "unavailable"): PhotoKit network errors (3164 networkAccessRequired,
    /// 3169 networkError), 3303 missingResource (in practice an iCloud copy that is not available
    /// yet), and any `NSURLErrorDomain` or `CloudPhotoLibraryErrorDomain` error.
    static func isCloudFailure(domain: String, code: Int) -> Bool {
        if domain == PHPhotosErrorDomain {
            return code == PHPhotosError.Code.networkAccessRequired.rawValue
                || code == PHPhotosError.Code.networkError.rawValue
                || code == PHPhotosError.Code.missingResource.rawValue
        }
        return domain == NSURLErrorDomain || domain == cloudPhotoLibraryErrorDomain
    }

    /// Error domain of iCloud Photos (not a public constant; compared as a string).
    static let cloudPhotoLibraryErrorDomain = "CloudPhotoLibraryErrorDomain"

    /// Network failures only (a subset of `isCloudFailure`).
    static func isNetworkFailure(domain: String, code: Int) -> Bool {
        if domain == PHPhotosErrorDomain {
            return code == PHPhotosError.Code.networkAccessRequired.rawValue
                || code == PHPhotosError.Code.networkError.rawValue
        }
        return domain == NSURLErrorDomain
    }

    /// The asset identifier no longer exists (3201 identifierNotFound): `notFound`.
    static func isMissing(domain: String, code: Int) -> Bool {
        domain == PHPhotosErrorDomain && code == PHPhotosError.Code.identifierNotFound.rawValue
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

    /// Classifies one `requestImage` callback. Only a degraded image WITHOUT an error may wait:
    /// with `.highQualityFormat` PhotoKit delivers a single result, so every other callback must
    /// be terminal, or the continuation could never resume.
    /// - cancelled flag or user-cancelled error => `.cancelled`
    /// - any error (`PHImageErrorKey`) => terminal: `.cloudUnavailable` for cloud errors or when
    ///   `PHImageResultIsInCloudKey` is set, `.missing` for 3201, else `.failed`
    /// - an image without error: `.wait` if degraded, else `.deliver`
    /// - neither image nor error (degraded or not) => `.cloudUnavailable` if in iCloud, else `.failed`
    static func imageCallbackOutcome(hasImage: Bool, isDegraded: Bool, isCancelled: Bool,
                                     isInCloud: Bool, errorDomain: String?, errorCode: Int?) -> ImageCallbackOutcome {
        if isCancelled { return .cancelled }
        if let domain = errorDomain {
            let code = errorCode ?? 0
            if isUserCancelled(domain: domain, code: code) { return .cancelled }
            if isInCloud || isCloudFailure(domain: domain, code: code) { return .cloudUnavailable }
            if isMissing(domain: domain, code: code) { return .missing }
            return .failed
        }
        if hasImage { return isDegraded ? .wait : .deliver }
        return isInCloud ? .cloudUnavailable : .failed
    }

    /// Downscales `image` so its longest side is <= `maxPixel` (no-op when it already fits).
    /// Works in PIXELS (`CGImage.width/height`), so an image delivered at points x backing scale
    /// comes back at exactly the requested pixel size. A safety net: `.exact` resize normally
    /// delivers the requested size already.
    static func clamp(_ image: CGImage, maxPixel: Int) -> CGImage {
        let limit = max(1, maxPixel)
        guard max(image.width, image.height) > limit else { return image }
        let size = thumbnailPixelSize(pixelWidth: image.width, pixelHeight: image.height, maxPixel: limit)
        // Always an RGBA context, whatever the source space (grayscale, CMYK and indexed spaces
        // cannot back premultipliedLast): Display P3 for P3 sources, sRGB otherwise.
        let space = image.colorSpace?.name == CGColorSpace.displayP3
            ? CGColorSpace(name: CGColorSpace.displayP3)!
            : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage() ?? image
    }
}
