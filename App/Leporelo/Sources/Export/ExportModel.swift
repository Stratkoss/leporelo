import AppKit
import Foundation
import LeporeloCore
import Observation
import os

/// Everything one export needs, as values taken on the main actor at export start.
struct ExportJob: Sendable {
    var album: Album
    var profile: SupplierProfile
    var format: BookFormat
    var package: ProjectPackage
    var directory: URL
}

/// The seam between `ExportModel` and Core's `PDFExporter`. Runs off the main actor; reports
/// `(done, total)` like `PDFExporter.export(to:progress:)`; must honour task cancellation.
struct ExportRunner: Sendable {
    var run: @Sendable (ExportJob, @escaping @Sendable (Int, Int) -> Void) async throws -> ExportResult

    /// The real export: `PDFExporter` over originals from the package (`PackageImageProvider`
    /// built from the same album snapshot).
    static let pdf = ExportRunner.pdf(images: { job in PackageImageProvider(package: job.package, album: job.album) })

    /// `PDFExporter` with another image provider (tests).
    static func pdf(images: @escaping @Sendable (ExportJob) -> any ImageProvider) -> ExportRunner {
        ExportRunner { job, progress in
            let exporter = PDFExporter(album: job.album, profile: job.profile, format: job.format,
                                       images: images(job))
            return try await exporter.export(to: job.directory, progress: progress)
        }
    }
}

enum ExportPhase: Equatable {
    case idle
    /// `total` is 0 until the exporter reports the first page.
    case exporting(done: Int, total: Int)
    case finished(ExportSummary)
    case failed(ExportFailure)
}

/// The export sheet's model (spec 6.5): preflight, the gate, the export and its result.
///
/// - Preflight runs in a detached task on a VALUE snapshot of the album and is published on the
///   main actor; while the sheet observes (`startObserving`) every `store.revision` change re-runs
///   it after `preflightDebounce`. Results of an older snapshot never overwrite a newer one.
/// - Gate (`canExport`): a preflight exists, it has no errors (missing originals are errors; the
///   button then says "Čekám na originály (N)"), its warnings are accepted (`acceptedWarnings`,
///   reset whenever the warning set changes), and no export is running.
/// - `export(to:)` commits the editor's running sessions (`store.flushPendingEdits()`), snapshots
///   the album after that, re-runs preflight when the album changed since the shown result, and
///   refuses when the fresh result has errors or new warnings. Then `ExportRunner` runs off the
///   main actor; progress is throttled. Cancelling the task (`cancelExport`) returns to `.idle`
///   with `notice` "Export byl zrušen" (Core removes its temp folder).
@MainActor
@Observable
final class ExportModel: Identifiable {
    let store: AlbumStore
    @ObservationIgnored private let geometry: @MainActor () -> PageGeometry?
    @ObservationIgnored private let runner: ExportRunner
    @ObservationIgnored private let onJump: (@MainActor (String, String?) -> Void)?
    /// Delay between an album change and the preflight re-run while observing.
    @ObservationIgnored var preflightDebounce: Duration = .milliseconds(300)
    /// Minimum time between two progress updates of the UI.
    @ObservationIgnored var progressInterval: Duration = .milliseconds(100)

    private(set) var issues: [PreflightIssue] = []
    /// Placed photos whose original is still coming (`.missing`, `.downloading`).
    private(set) var waitingForOriginals = 0
    /// The store revision `issues` were computed for; nil before the first preflight.
    private(set) var issuesRevision: Int?
    /// "Rozumím varováním". Reset to false whenever the set of warnings changes.
    var acceptedWarnings = false
    private(set) var phase: ExportPhase = .idle
    /// A one-line note under the buttons ("Export byl zrušen", a refused export).
    var notice: String?

    @ObservationIgnored private(set) var exportTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var preflightGeneration = 0
    @ObservationIgnored private var exportGeneration = 0
    @ObservationIgnored private var warningKeys: Set<String>?
    @ObservationIgnored private var observing = false

    init(store: AlbumStore,
         geometry: @escaping @MainActor () -> PageGeometry?,
         runner: ExportRunner = .pdf,
         onJump: (@MainActor (String, String?) -> Void)? = nil) {
        self.store = store
        self.runner = runner
        self.onJump = onJump
        self.geometry = geometry
    }

    /// `init(store:)` of the plan: profile and format from the catalog by the album's ids.
    convenience init(store: AlbumStore) {
        self.init(store: store, geometry: { [weak store] in
            guard let album = store?.album,
                  let (profile, format) = try? ProfileCatalog.format(profileID: album.supplierProfileID,
                                                                    formatID: album.formatID) else { return nil }
            return PageGeometry(format: format, profile: profile)
        })
    }

    // MARK: State

    var hasPreflight: Bool { issuesRevision != nil }
    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    var hasErrors: Bool { Preflight.hasErrors(issues) }
    var hasWarnings: Bool { issues.contains { $0.severity == .warning } }

    var canExport: Bool { preflightAllowsExport && !isExporting }

    private var preflightAllowsExport: Bool {
        hasPreflight && geometry() != nil && !hasErrors && (!hasWarnings || acceptedWarnings)
    }

    var title: String { ExportLogic.title(geometry()?.profile) }

    var exportButtonTitle: String {
        waitingForOriginals > 0 ? ExportLogic.waitingTitle(waitingForOriginals) : title
    }

    var rows: [ExportIssueRow] { ExportLogic.rows(issues: issues, album: store.album) }

    // MARK: Preflight

    /// Checks the album as it is now, off the main actor; the returned task ends once the result
    /// is published (or superseded by a newer run).
    @discardableResult
    func runPreflight() -> Task<Void, Never> {
        guard let g = geometry() else { return Task {} }
        let album = store.album, revision = store.revision
        preflightGeneration += 1
        let generation = preflightGeneration
        return Task { [weak self] in
            let result = await Self.evaluate(album: album, geometry: g)
            guard let self, generation == self.preflightGeneration else { return }
            self.publish(result, revision: revision)
        }
    }

    /// Runs preflight now and again (debounced) after every album change, until `close()`.
    func startObserving() {
        guard !observing else { return }
        observing = true
        runPreflight()
        observeRevision()
    }

    /// Stops observing and cancels a running export (the sheet went away).
    func close() {
        observing = false
        debounceTask?.cancel()
        exportTask?.cancel()
    }

    private func observeRevision() {
        guard observing else { return }
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor in self?.revisionChanged() }
        }
    }

    private func revisionChanged() {
        guard observing else { return }
        observeRevision()
        debounceTask?.cancel()
        let delay = preflightDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.observing else { return }
            self.runPreflight()
        }
    }

    private nonisolated static func evaluate(album: Album, geometry: PageGeometry) async
        -> (issues: [PreflightIssue], waiting: Int) {
        await Task.detached(priority: .userInitiated) {
            ExportLogic.evaluate(album: album, profile: geometry.profile, format: geometry.format)
        }.value
    }

    private func publish(_ result: (issues: [PreflightIssue], waiting: Int), revision: Int) {
        if let current = issuesRevision, current > revision { return }
        let keys = ExportLogic.warningKeys(result.issues)
        if keys != warningKeys {
            warningKeys = keys
            acceptedWarnings = false
        }
        issues = result.issues
        waitingForOriginals = result.waiting
        issuesRevision = revision
    }

    // MARK: Jump

    /// Shows the issue's spread (and frame) in the editor; issues without a spread do nothing.
    func jump(to row: ExportIssueRow) {
        guard let spreadID = row.jumpSpreadID, !isExporting else { return }
        onJump?(spreadID, row.issue.frameID)
    }

    // MARK: Export

    /// What the chosen folder means (inside the package, earlier export files there).
    func check(destination: URL) -> ExportDestinationCheck {
        ExportLogic.check(destination: destination, packageURL: store.package.url)
    }

    /// Starts `export(to:)` as a cancellable task (the sheet's "Exportovat").
    func startExport(to directory: URL) {
        guard !isExporting else { return }
        let generation = beginExport()
        exportTask = Task { [weak self] in
            _ = try? await self?.runExport(to: directory, generation: generation)
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func export(to directory: URL) async throws -> ExportResult {
        guard !isExporting else { throw ExportFailure(message: "Export už běží.") }
        return try await runExport(to: directory, generation: beginExport())
    }

    /// Marks the export running at once (the button disables before the task starts).
    private func beginExport() -> Int {
        notice = nil
        exportGeneration += 1
        phase = .exporting(done: 0, total: 0)
        return exportGeneration
    }

    private func runExport(to directory: URL, generation: Int) async throws -> ExportResult {
        // What the user sees: commit running text and crop sessions, then snapshot.
        store.flushPendingEdits()
        guard let g = geometry() else {
            throw fail(ExportFailure(message: "Formát alba není známý, export nejde spustit."))
        }
        let album = store.album, revision = store.revision

        if issuesRevision != revision {
            // A changed warning set resets `acceptedWarnings` (publish).
            publish(await Self.evaluate(album: album, geometry: g), revision: revision)
        }
        guard preflightAllowsExport else {
            phase = .idle
            let message = hasErrors ? "Album se od kontroly změnilo a má chyby. Opravte je a zkuste to znovu."
                                    : "Přibyla varování. Projděte je a potvrďte, že jim rozumíte."
            notice = message
            throw ExportFailure(message: message, issues: issues)
        }

        let job = ExportJob(album: album, profile: g.profile, format: g.format, package: store.package,
                            directory: directory)
        let throttle = ProgressThrottle(interval: progressInterval)
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard throttle.shouldEmit(done: done, total: total) else { return }
            Task { @MainActor in self?.progressed(done: done, total: total, generation: generation) }
        }
        do {
            let result = try await runner.run(job, progress)
            try Task.checkCancellation()
            let readme = result.readmeURL
            let text = await Task.detached { try? String(contentsOf: readme, encoding: .utf8) }.value
            let summary = ExportSummary(result: result, headline: ExportLogic.headline(result),
                                        folderPath: directory.path,
                                        steps: ExportLogic.uploadSteps(fromReadme: text ?? ""))
            phase = .finished(summary)
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                phase = .idle
                notice = ExportLogic.cancelledNotice
                throw CancellationError()
            }
            let failure = ExportLogic.failure(for: error)
            if let refused = failure.issues {
                publish((refused, ExportLogic.waitingForOriginals(album)), revision: revision)
            }
            Logger.export.error("Export failed: \(String(describing: error), privacy: .public)")
            throw fail(failure)
        }
    }

    private func fail(_ failure: ExportFailure) -> ExportFailure {
        phase = .failed(failure)
        return failure
    }

    private func progressed(done: Int, total: Int, generation: Int) {
        guard generation == exportGeneration, case let .exporting(current, _) = phase, done > current else { return }
        phase = .exporting(done: done, total: total)
    }

    // MARK: Finder

    /// Selects the exported files in Finder.
    func reveal(_ result: ExportResult) {
        NSWorkspace.shared.activateFileViewerSelecting([result.pagesURL, result.coverURL, result.readmeURL]
            .compactMap { $0 })
    }

    func openFolder(_ result: ExportResult) {
        NSWorkspace.shared.open(result.pagesURL.deletingLastPathComponent())
    }
}

/// Lets through the first update, the last one and at most one per `interval` in between
/// (called from the exporter's thread).
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration) { self.interval = interval }

    func shouldEmit(done: Int, total: Int) -> Bool {
        let now = ContinuousClock.now
        return lock.withLock {
            if done >= total || last.map({ now - $0 >= interval }) ?? true {
                last = now
                return true
            }
            return false
        }
    }
}

extension Logger {
    static let export = Logger(subsystem: "com.stratkoss.leporelo", category: "Export")
}
