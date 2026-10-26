import CoreGraphics
import Foundation

public struct PipelineProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Background image analysis (spec section 8): for every photo without `analysis` that is not a
/// video, fetch a 1024 px thumbnail from the source, store it in the package, analyze it and
/// report the result.
///
/// - Concurrency: one `withTaskGroup` with at most `concurrency` photo tasks in flight; the next
///   photo starts when one finishes. Each thumbnail `CGImage` lives only inside its child task.
/// - Callbacks are invoked only from the single consumer loop of `run` (actor context), never from
///   child tasks, so they are serialized: `onProgress` starts with `(0, total)`, `done` grows by one
///   per finished photo, and ends with `done == total` unless the run was cancelled.
///   `total` is the number of photos needing analysis when `run` starts.
/// - Failures (thumbnail fetch, thumbnail store, analysis) skip that photo and count as done; they
///   never stop the other photos. The thumbnail is stored before analysis, so it survives a failed
///   analysis. A photo whose thumbnail could not be stored is not analyzed (the next run retries it).
/// - `run` never mutates the album; the caller applies `onPhotoAnalyzed` results.
/// - `cancel()` (or cancelling the caller's task) stops launching photos, cancels the in-flight
///   ones cooperatively and makes `run` return promptly. Photos that still completed while
///   draining are reported. No callback is invoked after `run` returns. `run` can be called again
///   after a cancel; each run starts from a clean state.
/// - Only one run at a time is meaningful; a `run` call while another is active returns
///   immediately without callbacks.
public actor AnalysisPipeline {
    public static let thumbnailMaxPixel = ProjectPackage.thumbnailMaxPixelSize

    private let source: any PhotoSource
    private let package: ProjectPackage
    private let analyzer: ImageAnalyzer
    private let concurrency: Int

    private var isRunning = false
    private var cancelRequested = false
    private var cancelSignal: AsyncStream<Void>.Continuation?

    public init(source: any PhotoSource, package: ProjectPackage, analyzer: ImageAnalyzer,
                concurrency: Int = 4) {
        self.source = source
        self.package = package
        self.analyzer = analyzer
        self.concurrency = max(1, concurrency)
    }

    /// Stops the current run (no-op when none is running; does not affect a later run).
    public func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        cancelSignal?.finish()
        cancelSignal = nil
    }

    private enum Outcome: Sendable {
        case analyzed(PhotoID, PhotoAnalysis)
        case failed(PhotoID)
        /// A photo task that stopped because the group was cancelled.
        case cancelled(PhotoID)
        /// The cancel watcher ended: `cancel()` was called or the group was cancelled.
        case stopRequested
    }

    public func run(album: Album,
                    onPhotoAnalyzed: @Sendable (PhotoID, PhotoAnalysis) async -> Void,
                    onProgress: @Sendable (PipelineProgress) async -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        defer { isRunning = false }

        let pending = album.photos.values
            .filter { $0.analysis == nil && $0.kind != .video }
            .sorted(by: Photo.chronological)
            .map { (id: $0.id, sourceIdentifier: $0.sourceIdentifier) }
        let total = pending.count
        await onProgress(PipelineProgress(done: 0, total: total))
        guard total > 0, !Task.isCancelled, !cancelRequested else { return }

        let (signal, signalContinuation) = AsyncStream<Void>.makeStream()
        cancelSignal = signalContinuation
        defer {
            signalContinuation.finish()
            cancelSignal = nil
        }

        let source = self.source
        let package = self.package
        let analyzer = self.analyzer
        let concurrency = self.concurrency

        await withTaskGroup(of: Outcome.self) { group in
            // Cancel watcher: its stream ends when `cancel()` finishes it or the task is cancelled.
            group.addTask {
                for await _ in signal {}
                return .stopRequested
            }
            var next = pending.makeIterator()
            var inFlight = 0
            var stopped = false
            var done = 0

            func launch() {
                guard !stopped, let item = next.next() else { return }
                inFlight += 1
                group.addTask {
                    await Self.process(id: item.id, sourceIdentifier: item.sourceIdentifier,
                                       source: source, package: package, analyzer: analyzer)
                }
            }

            func stop() {
                stopped = true
                group.cancelAll()
            }

            for _ in 0..<concurrency { launch() }

            while inFlight > 0, let outcome = await group.next() {
                switch outcome {
                case .stopRequested:
                    stop()
                case .cancelled:
                    inFlight -= 1
                    stop()
                case .failed:
                    inFlight -= 1
                    done += 1
                    await onProgress(PipelineProgress(done: done, total: total))
                case .analyzed(let id, let analysis):
                    inFlight -= 1
                    done += 1
                    await onPhotoAnalyzed(id, analysis)
                    await onProgress(PipelineProgress(done: done, total: total))
                }
                if !stopped && (Task.isCancelled || cancelRequested) { stop() }
                launch()
            }
            // All photo tasks are finished; end the watcher so the group can complete.
            group.cancelAll()
        }
    }

    private static func process(id: PhotoID, sourceIdentifier: String, source: any PhotoSource,
                                package: ProjectPackage, analyzer: ImageAnalyzer) async -> Outcome {
        if Task.isCancelled { return .cancelled(id) }
        let image: CGImage
        do {
            image = try await source.thumbnail(for: sourceIdentifier, maxPixel: thumbnailMaxPixel)
        } catch {
            return Task.isCancelled ? .cancelled(id) : .failed(id)
        }
        do { try package.storeThumbnail(image, for: id) } catch { return .failed(id) }
        if Task.isCancelled { return .cancelled(id) }
        do {
            return .analyzed(id, try await analyzer.analyze(image))
        } catch {
            return Task.isCancelled ? .cancelled(id) : .failed(id)
        }
    }
}
