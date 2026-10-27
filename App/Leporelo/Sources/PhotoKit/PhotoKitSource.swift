import AppKit
import CoreGraphics
import CoreLocation
import Foundation
import LeporeloCore
import Photos

/// Failure of a PhotoKit request that is neither a network/iCloud failure nor a missing asset.
/// Plain values only, so it is Sendable. `OriginalsDownloader` maps it to `.missing`.
struct PhotoKitRequestError: Error, Equatable, CustomStringConvertible {
    var identifier: String
    var domain: String
    var code: Int
    var message: String

    var description: String { "PhotoKit request for \(identifier) failed: \(domain) \(code) \(message)" }
}

/// Photo source over the user's Apple Photos library (the system library).
///
/// Conventions (same as `FolderPhotoSource` where they overlap):
/// - Every method first checks full (`.readWrite`) authorization and throws
///   `PhotoSourceError.notAuthorized` otherwise, including `.limited`. It never prompts; the UI
///   calls `PhotoKitAuthorization.request()` first.
/// - `identifier` is `PHAsset.localIdentifier`.
/// - `.dateRange(start, end)` is half-open on `creationDate` (`start <= date < end`) over the
///   library (PhotoKit's default source for a plain asset fetch: the user library, which includes
///   the iCloud Shared Photo Library; iCloud *shared albums* are reached through `.album` queries).
///   Images and videos only; hidden assets and Recently Deleted are excluded; of a burst only the
///   representative photo is returned (PhotoKit defaults).
/// - `.album(identifier:)` fetches the collection by local identifier; unknown => `notFound`.
/// - Results are sorted by (capturedAt, identifier).
/// - `timeZoneSeconds` is nil (PhotoKit gives none), `isCloudOnly` is false (see
///   `PhotoKitMapping.sourcePhoto` and `isLocallyAvailable(identifier:)`).
/// - Cost of `photos(matching:)`: one fetch plus a read of in-memory properties per asset
///   (no image data, no per-asset resource queries), so ~3000 assets take well under a second.
///
/// The struct holds no PhotoKit objects: every `PHAsset`/`PHAssetCollection` lives inside a single
/// method call, and only Sendable values (`String`, `CGImage`, `Data`) leave it.
struct PhotoKitSource: PhotoSource {

    init() {}

    // MARK: PhotoSource

    func albums() async throws -> [SourceAlbum] {
        try PhotoKitAuthorization.ensureAuthorized()
        // Count-only fetch: the media-type predicate, no sort descriptor.
        let countOptions = PHFetchOptions()
        countOptions.predicate = PhotoKitMapping.mediaTypePredicate()
        countOptions.includeHiddenAssets = false
        countOptions.wantsIncrementalChangeDetails = false
        var result: [SourceAlbum] = []
        // User albums (including those inside folders) and iCloud shared albums.
        let kinds: [(PHAssetCollectionSubtype, Bool)] = [(.albumRegular, false), (.albumCloudShared, true)]
        for (subtype, isShared) in kinds {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: subtype, options: nil)
            collections.enumerateObjects { collection, _, _ in
                // Exact count of images + videos, because `estimatedAssetCount` is often
                // NSNotFound for shared albums. A count-only fetch is cheap (no objects are
                // materialised), so this stays fast for dozens of albums.
                let count = PHAsset.fetchAssets(in: collection, options: countOptions).count
                result.append(SourceAlbum(identifier: collection.localIdentifier,
                                          name: collection.localizedTitle ?? "",
                                          count: count, isShared: isShared))
            }
        }
        return PhotoKitMapping.sorted(result)
    }

    func photos(matching query: SourceQuery) async throws -> [SourcePhoto] {
        try PhotoKitAuthorization.ensureAuthorized()
        let options = Self.assetOptions(for: query)
        let assets: PHFetchResult<PHAsset>
        switch query {
        case .dateRange:
            assets = PHAsset.fetchAssets(with: options)
        case .album(let identifier, _):
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
            guard let collection = collections.firstObject else {
                throw PhotoSourceError.notFound(identifier)
            }
            assets = PHAsset.fetchAssets(in: collection, options: options)
        }
        var photos: [SourcePhoto] = []
        photos.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            if let photo = Self.sourcePhoto(from: asset) { photos.append(photo) }
        }
        return PhotoKitMapping.sorted(photos)
    }

    /// Upright image (PhotoKit applies the orientation and the user's edits), longest side
    /// <= maxPixel, never upscaled. Downloads from iCloud when needed.
    func thumbnail(for identifier: String, maxPixel: Int) async throws -> CGImage {
        try PhotoKitAuthorization.ensureAuthorized()
        let asset = try Self.asset(identifier)
        let size = PhotoKitMapping.thumbnailPixelSize(pixelWidth: asset.pixelWidth,
                                                      pixelHeight: asset.pixelHeight, maxPixel: maxPixel)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let gate = RequestGate<CGImage>()
        let manager = PHImageManager.default()
        let limit = maxPixel
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset, targetSize: CGSize(width: size.width, height: size.height),
                    contentMode: .aspectFit, options: options
                ) { image, info in
                    let error = info?[PHImageErrorKey] as? NSError
                    let outcome = PhotoKitMapping.imageCallbackOutcome(
                        hasImage: image != nil,
                        isDegraded: (info?[PHImageResultIsDegradedKey] as? Bool) ?? false,
                        isCancelled: (info?[PHImageCancelledKey] as? Bool) ?? false,
                        isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) ?? false,
                        errorDomain: error?.domain, errorCode: error?.code)
                    switch outcome {
                    case .wait:
                        return
                    case .deliver:
                        if let image, let cg = Self.cgImage(from: image) {
                            gate.finish(.success(PhotoKitMapping.clamp(cg, maxPixel: limit)))
                        } else {
                            gate.finish(.failure(Self.requestError(identifier, error,
                                                                   message: "image conversion failed")))
                        }
                    case .cancelled:
                        gate.finish(.failure(CancellationError()))
                    case .cloudUnavailable:
                        gate.finish(.failure(PhotoSourceError.cloudUnavailable(identifier)))
                    case .missing:
                        gate.finish(.failure(PhotoSourceError.notFound(identifier)))
                    case .failed:
                        gate.finish(.failure(Self.requestError(identifier, error)))
                    }
                }
                gate.setCancelAction { manager.cancelImageRequest(requestID) }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// Original bytes of the still image, as stored by Photos (HEIC stays HEIC, EXIF orientation
    /// kept; `ProjectPackage`'s provider applies it). For an edited photo this is the rendered
    /// full-size edit, which matches `PHAsset`'s dimensions. Live photos yield their still.
    /// Videos throw `notFound`: they are never placed in the album.
    func original(for identifier: String) async throws -> (data: Data, ext: String) {
        try PhotoKitAuthorization.ensureAuthorized()
        let asset = try Self.asset(identifier)
        guard asset.mediaType == .image else { throw PhotoSourceError.notFound(identifier) }
        let resources = PHAssetResource.assetResources(for: asset)
        let described = resources.map { resource in
            (type: resource.type,
             ext: PhotoKitMapping.fileExtension(originalFilename: resource.originalFilename,
                                                uniformTypeIdentifier: resource.uniformTypeIdentifier))
        }
        guard let index = PhotoKitMapping.stillResourceIndex(described),
              let ext = described[index].ext else {
            throw PhotoSourceError.notFound(identifier)
        }
        let resource = resources[index]
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let gate = RequestGate<Data>()
        let buffer = DataBuffer()
        let manager = PHAssetResourceManager.default()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let requestID = manager.requestData(for: resource, options: options) { chunk in
                    buffer.append(chunk)
                } completionHandler: { error in
                    guard let error = error as NSError? else {
                        gate.finish(.success(buffer.take()))
                        return
                    }
                    if PhotoKitMapping.isUserCancelled(domain: error.domain, code: error.code) {
                        gate.finish(.failure(CancellationError()))
                    } else if PhotoKitMapping.isCloudFailure(domain: error.domain, code: error.code) {
                        gate.finish(.failure(PhotoSourceError.cloudUnavailable(identifier)))
                    } else if PhotoKitMapping.isMissing(domain: error.domain, code: error.code) {
                        gate.finish(.failure(PhotoSourceError.notFound(identifier)))
                    } else {
                        gate.finish(.failure(Self.requestError(identifier, error)))
                    }
                }
                gate.setCancelAction { manager.cancelDataRequest(requestID) }
            }
        } onCancel: {
            gate.cancel()
        }
        return (data, ext)
    }

    // MARK: Lazy availability

    /// Whether the current version of the photo is on this Mac (no download needed).
    ///
    /// PhotoKit has no public per-asset "locally available" flag, so this asks
    /// `requestImageDataAndOrientation` with network access disallowed: it returns data when the
    /// file is local and nil with `PHImageResultIsInCloudKey` when it is not. When local it reads
    /// the WHOLE current file into memory (a few MB for HEIC/JPEG, up to tens of MB for RAW), so
    /// it is meant for a single photo on demand, NOT for a whole fetch; that is why
    /// `photos(matching:)` reports `isCloudOnly = false`. False when unauthorized or unknown.
    func isLocallyAvailable(identifier: String) async -> Bool {
        guard PhotoKitAuthorization.allowsReading(PhotoKitAuthorization.currentStatus()),
              let asset = try? Self.asset(identifier), asset.mediaType == .image else { return false }
        let options = PHImageRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let gate = RequestGate<Bool>()
        let manager = PHImageManager.default()
        let available = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let requestID = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    gate.finish(.success(data != nil))
                }
                gate.setCancelAction { manager.cancelImageRequest(requestID) }
            }
        } onCancel: {
            gate.cancel()
        }
        return available ?? false
    }

    // MARK: Helpers

    private static func assetOptions(for query: SourceQuery) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = PhotoKitMapping.predicate(for: query)
        options.sortDescriptors = PhotoKitMapping.fetchSortDescriptors()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.wantsIncrementalChangeDetails = false
        return options
    }

    private static func asset(_ identifier: String) throws -> PHAsset {
        // Lookup by identifier also finds hidden assets; that is fine for an asset the album
        // already references.
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoSourceError.notFound(identifier)
        }
        return asset
    }

    private static func sourcePhoto(from asset: PHAsset) -> SourcePhoto? {
        let coordinate = asset.location.map {
            (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
             accuracy: $0.horizontalAccuracy)
        }
        return PhotoKitMapping.sourcePhoto(
            identifier: asset.localIdentifier, creationDate: asset.creationDate,
            modificationDate: asset.modificationDate, coordinate: coordinate,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            mediaType: asset.mediaType, subtypes: asset.mediaSubtypes)
    }

    /// The bitmap behind PhotoKit's NSImage, at its pixel size (not its point size).
    private static func cgImage(from image: NSImage) -> CGImage? {
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep, let cg = bitmap.cgImage { return cg }
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func requestError(_ identifier: String, _ error: NSError?,
                                     message: String = "no result") -> Error {
        PhotoKitRequestError(identifier: identifier, domain: error?.domain ?? "PhotoKit",
                             code: error?.code ?? 0,
                             message: error?.localizedDescription ?? message)
    }
}

// MARK: - Callback plumbing

/// Bridges a PhotoKit callback request to a checked continuation that is resumed EXACTLY ONCE,
/// whichever comes first: a final result, an error, or Task cancellation (after which PhotoKit
/// may not call the handler at all, so the gate resumes with `CancellationError` itself).
final class RequestGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false
    private var cancelled = false
    private var cancelAction: (@Sendable () -> Void)?

    /// Stores the continuation. Returns false (and resumes with `CancellationError`) when the
    /// task was already cancelled; the caller must then not start the request.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancelled || finished {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Registers how to cancel the running request; runs it at once if cancellation came first.
    func setCancelAction(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            action()
            return
        }
        cancelAction = action
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            finished = true
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        cancelAction = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = finished ? nil : cancelAction
        cancelAction = nil
        lock.unlock()
        action?()
        finish(.failure(CancellationError()))
    }
}

/// Accumulates the chunks of a resource data request (handlers run on one serial queue; the
/// lock makes the hand-over to the completion explicit).
final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { data = Data(); lock.unlock() }
        return data
    }
}
