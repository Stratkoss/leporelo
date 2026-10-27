import AppKit
import Foundation
import LeporeloCore
import os

/// The open NSDocument of a package, readable from any thread: NSDocumentController may only be
/// asked on the main thread, so the main actor fills this box and the writers only read it. Holds
/// the document weakly.
final class DocumentBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: NSDocument?

    var document: NSDocument? { lock.withLock { stored } }

    func set(_ document: NSDocument?) { lock.withLock { stored = document } }
}

/// Task 17/19b contract: originals and thumbnails stored into a package that a document has open
/// are serialized with that document's saves.
///
/// Why: NSDocument's save lists the package directory (our lazy `FileWrapper`), writes a new
/// package next to it and swaps it in. A file renamed into `originals/` after the listing is
/// deleted by the swap. Measured with `CoordinatedWritesTests`' stress run (300 originals written
/// on a background thread during repeated autosaves): direct writes lost 134 to 211 of 300.
///
/// How, for each write (the bytes are already staged outside the package, the body is a rename):
/// 1. `NSDocument.performSynchronousFileAccess` (callable from any thread): waits until the file
///    access of a running save is over (it spans the listing and the swap) and keeps a new save
///    from starting until the rename is done. This is what NSDocument itself does when another
///    process writes into its file (`relinquishPresentedItem(toWriter:)`).
/// 2. Inside it, `NSFileCoordinator(filePresenter: document)`, `coordinate(writingItemAt:
///    destination, options: .forReplacing)`: coordinates with other processes, and with the
///    document as presenter the document is not told about our own write.
///
/// Findings that shaped this (same stress run):
/// - a coordinated write with the document as presenter but WITHOUT step 1 is not serialized with
///   the save: files were lost as with direct writes;
/// - a coordinated write WITHOUT a presenter is serialized (NSDocument relinquishes to it, 0 lost)
///   but the document is then told its package changed and reloads itself (a new `AlbumDocument`,
///   so the window would rebind and restart its background work after every download), so it is
///   only the fallback when no open document is known for the package.
///
/// Option `.forReplacing`: we replace whatever is at the destination with a staged file by a
/// rename; unlike `.forDeleting` or `.forMoving` it asks nobody to give up or delete anything.
/// Errors from the coordination or the move are rethrown.
///
/// Call it off the main thread (the downloader actor, the analysis pipeline's tasks): it may wait
/// for a running save. On the main thread it would still not deadlock (a save that needs the main
/// thread interrupts `performSynchronousFileAccess`), but it would block the UI meanwhile.
struct DocumentPackageWrites: PackageWriteCoordinator {
    let documents: DocumentBox
    /// Called when no document is known, so the main actor can look it up for the next write.
    let onMissingDocument: @Sendable () -> Void

    func coordinateWriting(at url: URL, _ write: @escaping @Sendable (URL) throws -> Void) throws {
        guard let document = documents.document else {
            onMissingDocument()
            return try Self.coordinate(at: url, presenter: nil, write)
        }
        let outcome = Outcome()
        Self.performSynchronousFileAccess(of: document) {
            outcome.result = Result { try Self.coordinate(at: url, presenter: document, write) }
        }
        try outcome.result.get()
    }

    /// `NSDocument.performSynchronousFileAccess(_:)` with an escaping block. The Swift overlay
    /// declares the block non-escaping and checks that on return, but AppKit keeps a copy of it
    /// (measured: the runtime trapped with "non-escaping closure has escaped"), so the method is
    /// called through its Objective-C implementation with a real, escaping block. The block still
    /// runs synchronously, on this thread, before the call returns.
    private static func performSynchronousFileAccess(of document: NSDocument,
                                                     _ block: @escaping @convention(block) () -> Void) {
        typealias Implementation = @convention(c) (AnyObject, Selector, @convention(block) () -> Void) -> Void
        let selector = #selector(NSDocument.performSynchronousFileAccess(_:))
        let implementation = unsafeBitCast(document.method(for: selector), to: Implementation.self)
        implementation(document, selector, block)
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<Void, any Error> = .success(())
    }

    private static func coordinate(at url: URL, presenter: (any NSFilePresenter)?,
                                   _ write: @escaping (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        let outcome = Outcome()
        var wrote = false
        let accessor: (URL) -> Void = { target in
            wrote = true
            outcome.result = Result { try write(target) }
        }
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError,
                               byAccessor: accessor)
        if !wrote, let coordinationError { throw coordinationError }
        try outcome.result.get()
    }
}
