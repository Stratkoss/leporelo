import CoreGraphics
import Foundation
import LeporeloCore
import Photos
import Testing
@testable import Leporelo

/// Pure PhotoKit mapping logic. None of these tests touch `PHPhotoLibrary` (no permission prompt,
/// no library access): they only use PhotoKit's plain enum/option values.
struct PhotoKitMappingTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let end = Date(timeIntervalSince1970: 2_000_000)

    // MARK: Queries

    @Test func dateRangePredicateUsesStartAndEndHalfOpen() {
        let predicate = PhotoKitMapping.dateRangePredicate(start: start, end: end)
        func matches(_ date: Date) -> Bool { predicate.evaluate(with: ["creationDate": date] as NSDictionary) }
        #expect(matches(start))
        #expect(matches(start.addingTimeInterval(1)))
        #expect(matches(end.addingTimeInterval(-0.001)))
        #expect(!matches(end))
        #expect(!matches(start.addingTimeInterval(-1)))
        let comparison = predicate as? NSCompoundPredicate
        let parts = comparison?.subpredicates.compactMap { $0 as? NSComparisonPredicate } ?? []
        #expect(parts.count == 2)
        #expect(parts.first?.predicateOperatorType == .greaterThanOrEqualTo)
        #expect(parts.first?.rightExpression.constantValue as? Date == start)
        #expect(parts.last?.predicateOperatorType == .lessThan)
        #expect(parts.last?.rightExpression.constantValue as? Date == end)
    }

    @Test func queryPredicateKeepsImagesAndVideosOnly() {
        let predicate = PhotoKitMapping.predicate(for: .dateRange(start: start, end: end))
        func matches(_ type: PHAssetMediaType, _ date: Date) -> Bool {
            predicate.evaluate(with: ["creationDate": date, "mediaType": type.rawValue] as NSDictionary)
        }
        let inside = start.addingTimeInterval(10)
        #expect(matches(.image, inside))
        #expect(matches(.video, inside))
        #expect(!matches(.audio, inside))
        #expect(!matches(.image, end))

        let album = PhotoKitMapping.predicate(for: .album(identifier: "x", name: "X"))
        #expect(album.evaluate(with: ["mediaType": PHAssetMediaType.image.rawValue] as NSDictionary))
        #expect(!album.evaluate(with: ["mediaType": PHAssetMediaType.audio.rawValue] as NSDictionary))
        #expect(PhotoKitMapping.fetchSortDescriptors().first?.key == "creationDate")
        #expect(PhotoKitMapping.fetchSortDescriptors().first?.ascending == true)
    }

    @Test func photosSortByDateThenIdentifier() {
        func photo(_ id: String, _ t: TimeInterval) -> SourcePhoto {
            SourcePhoto(identifier: id, capturedAt: Date(timeIntervalSince1970: t), timeZoneSeconds: nil,
                        location: nil, pixelWidth: 1, pixelHeight: 1, kind: .photo, isCloudOnly: false)
        }
        let sorted = PhotoKitMapping.sorted([photo("b", 5), photo("a", 5), photo("c", 1)])
        #expect(sorted.map(\.identifier) == ["c", "a", "b"])
    }

    @Test func albumsSortByName() {
        let albums = [SourceAlbum(identifier: "2", name: "Řecko 10", count: 1, isShared: true),
                      SourceAlbum(identifier: "1", name: "Řecko 9", count: 1, isShared: false),
                      SourceAlbum(identifier: "3", name: "Alpy", count: 1, isShared: false)]
        #expect(PhotoKitMapping.sorted(albums).map(\.identifier) == ["3", "1", "2"])
    }

    // MARK: Metadata

    @Test func kindMapping() {
        #expect(PhotoKitMapping.kind(mediaType: .image, subtypes: []) == .photo)
        #expect(PhotoKitMapping.kind(mediaType: .image, subtypes: [.photoHDR]) == .photo)
        #expect(PhotoKitMapping.kind(mediaType: .image, subtypes: [.photoLive, .photoHDR]) == .livePhoto)
        #expect(PhotoKitMapping.kind(mediaType: .video, subtypes: []) == .video)
        #expect(PhotoKitMapping.kind(mediaType: .video, subtypes: [.videoHighFrameRate]) == .video)
        #expect(PhotoKitMapping.kind(mediaType: .audio, subtypes: []) == nil)
        #expect(PhotoKitMapping.kind(mediaType: .unknown, subtypes: []) == nil)
    }

    @Test func capturedAtFallbacks() {
        let created = Date(timeIntervalSince1970: 100)
        let modified = Date(timeIntervalSince1970: 200)
        #expect(PhotoKitMapping.capturedAt(creationDate: created, modificationDate: modified) == created)
        #expect(PhotoKitMapping.capturedAt(creationDate: nil, modificationDate: modified) == modified)
        #expect(PhotoKitMapping.capturedAt(creationDate: nil, modificationDate: nil) == Date(timeIntervalSince1970: 0))
    }

    @Test func locationValidity() {
        #expect(PhotoKitMapping.location(latitude: 50.08, longitude: 14.42, horizontalAccuracy: 5)
                == GeoPoint(latitude: 50.08, longitude: 14.42))
        #expect(PhotoKitMapping.location(latitude: 50.08, longitude: 14.42, horizontalAccuracy: -1) == nil)
        #expect(PhotoKitMapping.location(latitude: 0, longitude: 0, horizontalAccuracy: 5) == nil)
        #expect(PhotoKitMapping.location(latitude: 91, longitude: 0, horizontalAccuracy: 5) == nil)
    }

    @Test func sourcePhotoAssembly() throws {
        let created = Date(timeIntervalSince1970: 1234)
        let photo = try #require(PhotoKitMapping.sourcePhoto(
            identifier: "ABC/L0/001", creationDate: created, modificationDate: nil,
            coordinate: (latitude: 36.4, longitude: 25.4, accuracy: 10),
            pixelWidth: 3024, pixelHeight: 4032, mediaType: .image, subtypes: [.photoLive]))
        #expect(photo == SourcePhoto(identifier: "ABC/L0/001", capturedAt: created, timeZoneSeconds: nil,
                                     location: GeoPoint(latitude: 36.4, longitude: 25.4),
                                     pixelWidth: 3024, pixelHeight: 4032, kind: .livePhoto,
                                     isCloudOnly: false))
        #expect(PhotoKitMapping.sourcePhoto(identifier: "a", creationDate: created, modificationDate: nil,
                                            coordinate: nil, pixelWidth: 1, pixelHeight: 1,
                                            mediaType: .audio, subtypes: []) == nil)
        let video = PhotoKitMapping.sourcePhoto(identifier: "v", creationDate: created, modificationDate: nil,
                                                coordinate: nil, pixelWidth: 1920, pixelHeight: 1080,
                                                mediaType: .video, subtypes: [])
        #expect(video?.kind == .video)
        #expect(video?.location == nil)
    }

    // MARK: Originals

    @Test func extensionChoice() {
        #expect(PhotoKitMapping.fileExtension(originalFilename: "IMG_0001.HEIC", uniformTypeIdentifier: nil) == "heic")
        #expect(PhotoKitMapping.fileExtension(originalFilename: "photo.JPG", uniformTypeIdentifier: nil) == "jpg")
        #expect(PhotoKitMapping.fileExtension(originalFilename: "noext", uniformTypeIdentifier: "public.heic") == "heic")
        #expect(PhotoKitMapping.fileExtension(originalFilename: nil, uniformTypeIdentifier: "public.jpeg") == "jpg")
        // The UTI describes the actual bytes: it wins over a disagreeing filename extension.
        #expect(PhotoKitMapping.fileExtension(originalFilename: "FullSizeRender.heic",
                                              uniformTypeIdentifier: "public.jpeg") == "jpg")
        // Agreeing filename keeps its own spelling.
        #expect(PhotoKitMapping.fileExtension(originalFilename: "IMG_1.JPEG", uniformTypeIdentifier: "public.jpeg") == "jpeg")
        #expect(PhotoKitMapping.fileExtension(originalFilename: "IMG_1.HEIC", uniformTypeIdentifier: "public.heic") == "heic")
        // Unknown UTI: the filename is the fallback.
        #expect(PhotoKitMapping.fileExtension(originalFilename: "IMG_1.HEIC", uniformTypeIdentifier: "not.a.type") == "heic")
        #expect(PhotoKitMapping.fileExtension(originalFilename: "", uniformTypeIdentifier: "not.a.type") == nil)
    }

    @Test func stillResourceChoice() {
        // Edited photo: the rendered full-size edit wins over the unedited original.
        #expect(PhotoKitMapping.stillResourceIndex([(.photo, "heic"), (.adjustmentData, "plist"),
                                                    (.fullSizePhoto, "heic")]) == 2)
        // Live photo: the still, never the paired video.
        #expect(PhotoKitMapping.stillResourceIndex([(.pairedVideo, "mov"), (.photo, "heic")]) == 1)
        // RAW primary with JPEG alternate: the rendered JPEG.
        #expect(PhotoKitMapping.stillResourceIndex([(.photo, "dng"), (.alternatePhoto, "jpg")]) == 1)
        // RAW only: still the RAW (better than nothing).
        #expect(PhotoKitMapping.stillResourceIndex([(.photo, "dng")]) == 0)
        // Video assets have no still resource.
        #expect(PhotoKitMapping.stillResourceIndex([(.video, "mov")]) == nil)
        #expect(PhotoKitMapping.stillResourceIndex([]) == nil)
    }

    // MARK: Errors

    @Test func errorClassification() {
        let domain = PHPhotosErrorDomain
        #expect(PhotoKitMapping.isNetworkFailure(domain: domain, code: PHPhotosError.Code.networkAccessRequired.rawValue))
        #expect(PhotoKitMapping.isNetworkFailure(domain: domain, code: PHPhotosError.Code.networkError.rawValue))
        #expect(PhotoKitMapping.isNetworkFailure(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(!PhotoKitMapping.isNetworkFailure(domain: domain, code: PHPhotosError.Code.missingResource.rawValue))
        #expect(PhotoKitMapping.isMissing(domain: domain, code: PHPhotosError.Code.identifierNotFound.rawValue))
        #expect(!PhotoKitMapping.isMissing(domain: domain, code: PHPhotosError.Code.missingResource.rawValue))
        // A missing resource is usually an iCloud copy not (yet) available: retried as cloud.
        #expect(PhotoKitMapping.isCloudFailure(domain: domain, code: PHPhotosError.Code.missingResource.rawValue))
        #expect(PhotoKitMapping.isCloudFailure(domain: "CloudPhotoLibraryErrorDomain", code: 1))
        #expect(PhotoKitMapping.isCloudFailure(domain: domain, code: PHPhotosError.Code.networkError.rawValue))
        #expect(!PhotoKitMapping.isCloudFailure(domain: domain, code: PHPhotosError.Code.identifierNotFound.rawValue))
        #expect(!PhotoKitMapping.isCloudFailure(domain: NSCocoaErrorDomain, code: 4))
        #expect(PhotoKitMapping.isUserCancelled(domain: domain, code: PHPhotosError.Code.userCancelled.rawValue))
        #expect(!PhotoKitMapping.isUserCancelled(domain: domain, code: PHPhotosError.Code.networkError.rawValue))
    }

    @Test func imageCallbackOutcomes() {
        typealias M = PhotoKitMapping
        let net = PHPhotosError.Code.networkError.rawValue
        #expect(M.imageCallbackOutcome(hasImage: true, isDegraded: false, isCancelled: false, isInCloud: false,
                                       errorDomain: nil, errorCode: nil) == .deliver)
        #expect(M.imageCallbackOutcome(hasImage: true, isDegraded: true, isCancelled: false, isInCloud: false,
                                       errorDomain: nil, errorCode: nil) == .wait)
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: true, isInCloud: false,
                                       errorDomain: nil, errorCode: nil) == .cancelled)
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: true,
                                       errorDomain: nil, errorCode: nil) == .cloudUnavailable)
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: false,
                                       errorDomain: PHPhotosErrorDomain, errorCode: net) == .cloudUnavailable)
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: false,
                                       errorDomain: NSCocoaErrorDomain, errorCode: 4) == .failed)
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: false,
                                       errorDomain: PHPhotosErrorDomain,
                                       errorCode: PHPhotosError.Code.identifierNotFound.rawValue) == .missing)
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: false,
                                       errorDomain: PHPhotosErrorDomain,
                                       errorCode: PHPhotosError.Code.missingResource.rawValue) == .cloudUnavailable)
        // Any error on an in-cloud result is a cloud failure.
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: true,
                                       errorDomain: NSCocoaErrorDomain, errorCode: 4) == .cloudUnavailable)
    }

    /// With `.highQualityFormat` PhotoKit delivers ONE result, so only a degraded image without an
    /// error may wait; everything else is terminal, otherwise the continuation could never resume.
    @Test func imageCallbackTerminatesUnlessDegradedImageWithoutError() {
        typealias M = PhotoKitMapping
        // Error + degraded image: terminal.
        #expect(M.imageCallbackOutcome(hasImage: true, isDegraded: true, isCancelled: false, isInCloud: false,
                                       errorDomain: NSCocoaErrorDomain, errorCode: 4) == .failed)
        #expect(M.imageCallbackOutcome(hasImage: true, isDegraded: true, isCancelled: false, isInCloud: true,
                                       errorDomain: NSCocoaErrorDomain, errorCode: 4) == .cloudUnavailable)
        // Degraded, no image, no error: terminal failure.
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: true, isCancelled: false, isInCloud: false,
                                       errorDomain: nil, errorCode: nil) == .failed)
        // Neither image nor error, not degraded: terminal failure.
        #expect(M.imageCallbackOutcome(hasImage: false, isDegraded: false, isCancelled: false, isInCloud: false,
                                       errorDomain: nil, errorCode: nil) == .failed)
        // Degraded image, no error: wait for the final one.
        #expect(M.imageCallbackOutcome(hasImage: true, isDegraded: true, isCancelled: false, isInCloud: false,
                                       errorDomain: nil, errorCode: nil) == .wait)
    }

    // MARK: Authorization

    @Test func onlyFullAccessAllowsReading() {
        #expect(PhotoKitAuthorization.allowsReading(.authorized))
        for status in [PHAuthorizationStatus.limited, .denied, .restricted, .notDetermined] {
            #expect(!PhotoKitAuthorization.allowsReading(status))
            #expect(throws: PhotoSourceError.notAuthorized) {
                try PhotoKitAuthorization.ensureAuthorized(status: status)
            }
        }
        #expect(throws: Never.self) { try PhotoKitAuthorization.ensureAuthorized(status: .authorized) }
        #expect(PhotoKitAuthorization.accessLevel == .readWrite)
    }

    // MARK: Thumbnails

    @Test func thumbnailSizeFitsAndNeverUpscales() {
        #expect(PhotoKitMapping.thumbnailPixelSize(pixelWidth: 4032, pixelHeight: 3024, maxPixel: 512) == (512, 384))
        #expect(PhotoKitMapping.thumbnailPixelSize(pixelWidth: 3024, pixelHeight: 4032, maxPixel: 512) == (384, 512))
        #expect(PhotoKitMapping.thumbnailPixelSize(pixelWidth: 300, pixelHeight: 200, maxPixel: 512) == (300, 200))
        #expect(PhotoKitMapping.thumbnailPixelSize(pixelWidth: 0, pixelHeight: 0, maxPixel: 256) == (256, 256))
        #expect(PhotoKitMapping.thumbnailPixelSize(pixelWidth: 10000, pixelHeight: 1, maxPixel: 100) == (100, 1))
    }

    @Test func clampDownscalesOnlyOversizedImages() throws {
        func image(_ w: Int, _ h: Int) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try #require(ctx.makeImage())
        }
        let big = PhotoKitMapping.clamp(try image(400, 200), maxPixel: 100)
        #expect(big.width == 100 && big.height == 50)
        let small = PhotoKitMapping.clamp(try image(50, 20), maxPixel: 100)
        #expect(small.width == 50 && small.height == 20)
    }

    @Test func clampHandlesGrayscaleSources() throws {
        let ctx = try #require(CGContext(data: nil, width: 300, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let gray = try #require(ctx.makeImage())
        let clamped = PhotoKitMapping.clamp(gray, maxPixel: 120)
        #expect(clamped.width == 60 && clamped.height == 120)
        #expect(clamped.colorSpace?.model == .rgb)
    }

    /// The result is in PIXELS: an image delivered at 2x the requested size (points x backing
    /// scale) is brought back to exactly the requested pixel size.
    @Test func clampResultEqualsRequestedPixelSize() throws {
        let requested = PhotoKitMapping.thumbnailPixelSize(pixelWidth: 4032, pixelHeight: 3024, maxPixel: 512)
        let delivered2x = PhotoKitMapping.thumbnailPixelSize(pixelWidth: requested.width * 2,
                                                             pixelHeight: requested.height * 2, maxPixel: 512)
        #expect(delivered2x == requested)
        let ctx = try #require(CGContext(data: nil, width: requested.width * 2, height: requested.height * 2,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let clamped = PhotoKitMapping.clamp(try #require(ctx.makeImage()), maxPixel: 512)
        #expect(clamped.width == requested.width && clamped.height == requested.height)
    }

    // MARK: Gate

    @Test func gateResumesExactlyOnce() async throws {
        let gate = RequestGate<Int>()
        let value = try await withCheckedThrowingContinuation { continuation in
            #expect(gate.install(continuation))
            gate.finish(.success(1))
            gate.finish(.success(2))
            gate.cancel()
        }
        #expect(value == 1)
    }

    @Test func gateCancelledBeforeInstallDoesNotStart() async {
        let gate = RequestGate<Int>()
        gate.cancel()
        var started = false
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { continuation in
                started = gate.install(continuation)
            }
        }
        #expect(!started)
    }

    @Test func gateCancelRunsCancelActionAndResumes() async {
        let gate = RequestGate<Int>()
        let flag = DataBuffer()
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { continuation in
                _ = gate.install(continuation)
                gate.setCancelAction { flag.append(Data([1])) }
                gate.cancel()
                gate.finish(.success(5))
            }
        }
        #expect(flag.take() == Data([1]))
    }
}
