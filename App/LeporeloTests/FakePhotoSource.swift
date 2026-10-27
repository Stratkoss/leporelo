import CoreGraphics
import Foundation
import LeporeloCore

/// In-memory `PhotoSource` for the app tests (the app test target cannot import the package's test
/// fixtures, so this is a small copy of the idea of `LeporeloCoreTests/FakePhotoSource`).
///
/// - `photos(matching:)` returns `photos` and records the query (not interpreted).
/// - `thumbnail` serves a generated image (a noisy gradient, never upscaled beyond `maxPixel`).
/// - While `holdThumbnails` is on, `thumbnail` calls suspend until `releaseAll()` or until their
///   task is cancelled (then they throw `CancellationError`).
final class FakePhotoSource: PhotoSource, @unchecked Sendable {
    private struct State {
        var photos: [SourcePhoto] = []
        var albums: [SourceAlbum] = []
        var photosError: PhotoSourceError?
        var thumbnailError: PhotoSourceError?
        var holdThumbnails = false
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var thumbnailCalls = 0
        var queries: [SourceQuery] = []
        var originalErrors: [String: PhotoSourceError] = [:]
        var originalCalls: [String: Int] = [:]
        var holdOriginals = false
        var holdPhotos = false
        var heldOriginalIDs: Set<String> = []
    }

    private let lock = NSLock()
    private var state = State()

    init(photos: [SourcePhoto] = [], albums: [SourceAlbum] = []) {
        state.photos = photos
        state.albums = albums
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    func setPhotos(_ photos: [SourcePhoto]) { locked { $0.photos = photos } }
    func setPhotosError(_ error: PhotoSourceError?) { locked { $0.photosError = error } }
    func holdThumbnails(_ on: Bool = true) { locked { $0.holdThumbnails = on } }
    /// Every later `thumbnail` call throws `error` (nil: serve images again).
    func failThumbnails(with error: PhotoSourceError?) { locked { $0.thumbnailError = error } }
    var thumbnailCalls: Int { locked { $0.thumbnailCalls } }
    /// `original(for: identifier)` throws `error` (nil: serves bytes again).
    func failOriginal(_ identifier: String, with error: PhotoSourceError?) { locked { $0.originalErrors[identifier] = error } }
    func originalCalls(_ identifier: String) -> Int { locked { $0.originalCalls[identifier, default: 0] } }
    var totalOriginalCalls: Int { locked { $0.originalCalls.values.reduce(0, +) } }
    /// While on, `original` calls suspend like held thumbnails (until `releaseAll()` or cancel).
    func holdOriginals(_ on: Bool = true) { locked { $0.holdOriginals = on } }
    /// Holds only the `original` calls for `identifier` (until `releaseAll()`).
    func holdOriginal(_ identifier: String) { locked { _ = $0.heldOriginalIDs.insert(identifier) } }
    /// While on, `photos(matching:)` calls suspend like held thumbnails.
    func holdPhotos(_ on: Bool = true) { locked { $0.holdPhotos = on } }
    var queries: [SourceQuery] { locked { $0.queries } }
    /// Number of `thumbnail` calls currently suspended by `holdThumbnails`.
    var heldCalls: Int { locked { $0.waiters.count } }

    func releaseAll() {
        let waiting = locked { s -> [CheckedContinuation<Void, Error>] in
            s.holdThumbnails = false
            s.holdOriginals = false
            s.holdPhotos = false
            s.heldOriginalIDs.removeAll()
            let all = Array(s.waiters.values)
            s.waiters.removeAll()
            return all
        }
        waiting.forEach { $0.resume() }
    }

    func albums() async throws -> [SourceAlbum] { locked { $0.albums } }

    func photos(matching query: SourceQuery) async throws -> [SourcePhoto] {
        try await wait(while: \.holdPhotos)
        return try locked { s -> Result<[SourcePhoto], PhotoSourceError> in
            s.queries.append(query)
            if let error = s.photosError { return .failure(error) }
            return .success(s.photos)
        }.get()
    }

    /// Called at the start of every `thumbnail` call with the identifier (tests use it to simulate
    /// something happening to the package mid-analysis).
    var onThumbnail: (@Sendable (String) -> Void)?

    func thumbnail(for identifier: String, maxPixel: Int) async throws -> CGImage {
        locked { $0.thumbnailCalls += 1 }
        onThumbnail?(identifier)
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let outcome: Int = locked { s in
                    if Task.isCancelled { return 2 }
                    if !s.holdThumbnails { return 0 }
                    s.waiters[token] = c
                    return 1
                }
                if outcome == 0 { c.resume() }
                if outcome == 2 { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c = locked { $0.waiters.removeValue(forKey: token) }
            c?.resume(throwing: CancellationError())
        }
        if let error = locked({ $0.thumbnailError }) { throw error }
        return Self.image(size: min(160, maxPixel), seed: identifier.utf8.reduce(17) { $0 &* 31 &+ Int($1) })
    }

    /// Suspends while `flag` is on (until `releaseAll()`; throws `CancellationError` on cancel).
    private func wait(while flag: KeyPath<State, Bool>) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let outcome: Int = locked { s in
                    if Task.isCancelled { return 2 }
                    if !s[keyPath: flag] { return 0 }
                    s.waiters[token] = c
                    return 1
                }
                if outcome == 0 { c.resume() }
                if outcome == 2 { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c = locked { $0.waiters.removeValue(forKey: token) }
            c?.resume(throwing: CancellationError())
        }
    }

    func original(for identifier: String) async throws -> (data: Data, ext: String) {
        locked { $0.originalCalls[identifier, default: 0] += 1 }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let outcome: Int = locked { s in
                    if Task.isCancelled { return 2 }
                    if !s.holdOriginals && !s.heldOriginalIDs.contains(identifier) { return 0 }
                    s.waiters[token] = c
                    return 1
                }
                if outcome == 0 { c.resume() }
                if outcome == 2 { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c = locked { $0.waiters.removeValue(forKey: token) }
            c?.resume(throwing: CancellationError())
        }
        if let error = locked({ $0.originalErrors[identifier] }) { throw error }
        return (Data("original:\(identifier)".utf8), "jpg")
    }

    /// A photo-like test image: a colour gradient with pseudo-random speckles (sharp, not a
    /// document), so the analyzer treats it as an ordinary photo.
    static func image(size: Int, seed: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SplitMix(seed: UInt64(bitPattern: Int64(seed)))
        for y in stride(from: 0, to: size, by: 4) {
            for x in stride(from: 0, to: size, by: 4) {
                let noise = Double(generator.next() % 100) / 400
                ctx.setFillColor(CGColor(red: Double(x) / Double(size) * 0.7 + noise,
                                         green: Double(y) / Double(size) * 0.6 + noise,
                                         blue: 0.4 + noise, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return ctx.makeImage()!
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SourcePhoto {
    /// A photo captured `minutes` after 2026-07-01 00:00 +02:00 (zone +2 h).
    static func fake(_ id: String, minutes: Int = 0, kind: PhotoKind = .photo,
                     width: Int = 4000, height: Int = 3000, location: GeoPoint? = nil) -> SourcePhoto {
        SourcePhoto(identifier: id,
                    capturedAt: Date(timeIntervalSince1970: 1_782_856_800 + Double(minutes) * 60),
                    timeZoneSeconds: 7200, location: location, pixelWidth: width, pixelHeight: height,
                    kind: kind, isCloudOnly: false)
    }
}

/// A `PlaceResolver` that answers from a table and can hold every lookup until `release()`.
actor HeldPlaceResolver: PlaceResolver {
    private let place: Place?
    private var held: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    init(place: Place?, held: Bool = false) {
        self.place = place
        self.held = held
    }

    func place(for point: GeoPoint) async -> Place? {
        calls += 1
        if held { await withCheckedContinuation { waiters.append($0) } }
        return place
    }

    func release() {
        held = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
