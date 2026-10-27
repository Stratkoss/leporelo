import Foundation

/// Copies full-resolution originals from the source into the project (spec section 8), so export
/// never depends on iCloud and the album survives photos deleted from the library.
///
/// - Queue: `enqueue` is safe at any time, also while `run` is active. Ids already queued or in
///   progress are ignored. Photos whose original is already `.stored` and ids unknown to the album
///   are skipped when they are processed (the album is read via the `album` closure, which must
///   return the CURRENT album, at the moment each id is taken from the queue).
/// - Single runner: `run` drains the queue, including ids enqueued while it runs, and returns when
///   the queue is empty and nothing is in flight. A `run` call while another is active returns
///   immediately; the active one picks up anything enqueued. Callers that enqueue after `run`
///   returned call `run` again.
/// - At most `concurrency` downloads are in flight (one `withTaskGroup`).
/// - States per id, reported through `onStateChange` from the run loop only (serialized, in order):
///   `.downloading`, then one of
///   - `.stored(relativePath:)` on success,
///   - `.unavailable` only on `PhotoSourceError.notFound` (the photo is gone; retrying will not
///     help),
///   - `.missing` after `maxAttempts` `PhotoSourceError.cloudUnavailable` failures in a row
///     (`retryDelay` apart): iCloud or the network may be back later, so it stays transient and the
///     app's bounded automatic retry and the "Stáhnout znovu" command enqueue it again,
///   - `.missing` on any other error (not authorized, disk write failure, cancellation): treated as
///     transient, so the user can retry by enqueueing the id again.
/// - Photos with `deletedInSource == true` get a single attempt.
/// - Cancelling the caller's task stops launching downloads; in-flight ones end as `.missing`
///   (when the source honours cancellation) and the rest of the queue stays queued.
public actor OriginalsDownloader {
    public static let maxAttempts = 3

    private let source: any PhotoSource
    private let package: ProjectPackage
    private let concurrency: Int
    private let retryDelay: Duration

    private var queue: [PhotoID] = []
    private var queued: Set<PhotoID> = []
    private var inProgress: Set<PhotoID> = []
    private var isRunning = false

    public init(source: any PhotoSource, package: ProjectPackage, concurrency: Int = 3,
                retryDelay: Duration = .seconds(2)) {
        self.source = source
        self.package = package
        self.concurrency = max(1, concurrency)
        self.retryDelay = retryDelay
    }

    public func enqueue(_ ids: [PhotoID]) {
        for id in ids where !queued.contains(id) && !inProgress.contains(id) {
            queue.append(id)
            queued.insert(id)
        }
    }

    /// Ids waiting in the queue (not counting downloads in flight).
    public var queuedCount: Int { queue.count }

    public func run(album: @Sendable () async -> Album,
                    onStateChange: @Sendable (PhotoID, OriginalState) async -> Void) async {
        guard !isRunning else { return }
        isRunning = true

        let source = self.source
        let package = self.package
        let retryDelay = self.retryDelay
        let concurrency = self.concurrency

        await withTaskGroup(of: (PhotoID, OriginalState).self) { group in
            var inFlight = 0
            while true {
                while inFlight < concurrency, !Task.isCancelled, !queue.isEmpty {
                    let id = queue.removeFirst()
                    queued.remove(id)
                    inProgress.insert(id)
                    let current = await album()
                    guard let photo = current.photos[id] else {
                        inProgress.remove(id)
                        continue
                    }
                    if case .stored = photo.originalState {
                        inProgress.remove(id)
                        continue
                    }
                    await onStateChange(id, .downloading)
                    let attempts = photo.deletedInSource ? 1 : Self.maxAttempts
                    let sourceIdentifier = photo.sourceIdentifier
                    inFlight += 1
                    group.addTask {
                        let state = await Self.download(
                            id: id, sourceIdentifier: sourceIdentifier, attempts: attempts,
                            source: source, package: package, retryDelay: retryDelay)
                        return (id, state)
                    }
                }
                if inFlight == 0 {
                    // Queue drained (or cancelled). Release the runner flag here, with no
                    // suspension point after the last queue check, so a later `run` is never
                    // turned away while this one is finishing.
                    isRunning = false
                    break
                }
                guard let (id, state) = await group.next() else { break }
                inFlight -= 1
                await onStateChange(id, state)
                // Removed only after the callback, so the caller has applied the final state
                // before the same id can be enqueued again.
                inProgress.remove(id)
            }
        }
        isRunning = false
    }

    private static func download(id: PhotoID, sourceIdentifier: String, attempts: Int,
                                 source: any PhotoSource, package: ProjectPackage,
                                 retryDelay: Duration) async -> OriginalState {
        var attempt = 1
        while true {
            if Task.isCancelled { return .missing }
            do {
                let original = try await source.original(for: sourceIdentifier)
                let path = try package.storeOriginal(data: original.data, ext: original.ext, for: id)
                return .stored(relativePath: path)
            } catch let error as PhotoSourceError {
                switch error {
                case .cloudUnavailable:
                    if attempt >= attempts { return .missing }  // transient: retried later
                    attempt += 1
                    do { try await Task.sleep(for: retryDelay) } catch { return .missing }
                case .notFound:
                    return .unavailable
                case .notAuthorized:
                    return .missing
                }
            } catch {
                return .missing
            }
        }
    }
}
