import AppKit
import Foundation
import LeporeloCore
import SwiftUI
import Synchronization
import os
import UniformTypeIdentifiers

extension UTType {
    /// A `.leporelo` package (declared in Info.plist `UTExportedTypeDeclarations`).
    static let leporeloAlbum = UTType(exportedAs: "com.stratkoss.leporelo.album", conformingTo: .package)
}

/// What autosave writes: the album at the moment of the snapshot plus where its package lives.
struct AlbumSnapshot: Sendable {
    let album: Album
    /// The package on disk, or nil for a document that has never been saved.
    let packageURL: URL?
}

/// The latest `AlbumSnapshot`, readable from any thread. SwiftUI calls `snapshot(contentType:)` on
/// a background queue during autosave while the main thread may be waiting for that save, so the
/// snapshot must never hop to the main actor: the store publishes every change here instead.
final class AlbumSnapshotBox: Sendable {
    private let state: Mutex<AlbumSnapshot>

    init(_ snapshot: AlbumSnapshot) { state = Mutex(snapshot) }

    var snapshot: AlbumSnapshot { state.withLock { $0 } }

    func publish(_ snapshot: AlbumSnapshot) { state.withLock { $0 = snapshot } }
}

/// A `.leporelo` package as a SwiftUI document.
///
/// Reading: SwiftUI hands over a `FileWrapper` (no URL), so `init` decodes only `album.json` from
/// it (the originals are never touched). The window then binds an `AlbumStore` to the package URL
/// with `store(for:)` once SwiftUI tells it the file URL.
///
/// Writing (autosave, Save, Versions): `fileWrapper(snapshot:configuration:)` re-reads the
/// package directory from disk as a lazy `FileWrapper` (`options: []`: children are enumerated,
/// file contents are not loaded) and swaps in a new `album.json`. NSDocument writes it with
/// `originalContentsURL` = the package, which hard-links every unchanged file, so a save never
/// reads or copies the originals. Re-reading from disk (instead of returning the `existingFile`
/// from open time) keeps originals and thumbnails that background work stored in the package
/// after it was opened; a stale wrapper would drop them in NSDocument's safe-save swap.
///
/// Isolation: the class is `@MainActor` (so it is `Sendable`); the protocol requirements are
/// `nonisolated` because SwiftUI may read on a background thread and calls both `snapshot` and
/// `fileWrapper` off the main thread during autosave (observed: `snapshot` on a global queue
/// while the main thread waits, so hopping to the main actor there deadlocks). `snapshot` reads
/// the lock-protected `AlbumSnapshotBox` that the store keeps current.
@MainActor
final class AlbumDocument: ReferenceFileDocument {
    typealias Snapshot = AlbumSnapshot

    nonisolated static var readableContentTypes: [UTType] { [.leporeloAlbum] }

    /// The album as read from disk (downloads interrupted by a crash reset to `.missing`), or a new
    /// empty album. Only used until the store exists.
    private let openedAlbum: Album
    private var boundStore: AlbumStore?
    /// What autosave writes; starts as the opened album without a package URL.
    private nonisolated let latest: AlbumSnapshotBox

    private nonisolated init(album: Album) {
        openedAlbum = album
        latest = AlbumSnapshotBox(AlbumSnapshot(album: album, packageURL: nil))
    }

    /// A new, never saved album. The app creates albums through `ProjectPackage.create` and opens
    /// them (Task 19); this exists because `DocumentGroup(newDocument:)` requires it.
    nonisolated convenience init() {
        let profile = try? ProfileCatalog.profile(id: "canva-photobook")
        let format = profile.flatMap(Workflow.defaultFormat(of:))
        self.init(album: Album(formatVersion: Album.currentFormatVersion, id: UUID().uuidString,
                               title: "Nové album", supplierProfileID: "canva-photobook",
                               formatID: format?.id ?? "", world: Workflow.world, cover: nil, spreads: [],
                               photos: [:], source: nil, createdAt: Workflow.now()))
    }

    nonisolated convenience init(configuration: ReadConfiguration) throws {
        try self.init(file: configuration.file)
    }

    nonisolated convenience init(file: FileWrapper) throws {
        guard file.isDirectory, let children = file.fileWrappers else { throw ProjectError.notAPackage }
        guard let albumFile = children[ProjectPackage.albumFileName] else {
            throw ProjectError.missingAlbumFile
        }
        guard let data = albumFile.regularFileContents else {
            throw ProjectError.corrupt("\(ProjectPackage.albumFileName) is not a regular file")
        }
        self.init(album: Self.reconcilingOriginals(try ProjectPackage.decodeAlbum(data), in: file))
    }

    /// Fixes original states a crash or an outside change left wrong, in memory only (the next
    /// save persists them): a download that was running is not running any more, and a `.stored`
    /// original whose file is not a regular file inside the package is `.missing`.
    nonisolated static func reconcilingOriginals(_ album: Album, in package: FileWrapper) -> Album {
        var album = album
        for (id, photo) in album.photos {
            switch photo.originalState {
            case .downloading:
                album.photos[id]?.originalState = .missing
            case .stored(let relative) where !containsRegularFile(package, at: relative):
                album.photos[id]?.originalState = .missing
            default:
                break
            }
        }
        return album
    }

    /// Walks the (lazy) wrapper tree; `..`, `.` and absolute paths never match.
    private nonisolated static func containsRegularFile(_ root: FileWrapper, at relative: String) -> Bool {
        guard !relative.hasPrefix("/") else { return false }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        var node = root
        for name in components {
            guard let child = node.fileWrappers?[name] else { return false }
            node = child
        }
        return node.isRegularFile
    }

    // MARK: Store

    /// The album the document would save now.
    var currentAlbum: Album { boundStore?.album ?? openedAlbum }

    /// What the window calls: `store(for:)` plus the hook that marks this document's NSDocument
    /// edited for changes without undo (`AlbumStore.applyWithoutUndo` / `replaceWithoutUndo`).
    /// The NSDocument is looked up lazily, never while menus are built (an early
    /// `NSDocumentController.shared` crashes the launch), and found again after a move.
    ///
    /// It also makes the store's package coordinate its original and thumbnail writes with this
    /// NSDocument's saves (`DocumentPackageWrites`, Task 17 contract). The NSDocument is looked up
    /// now and again (on the main actor) whenever a write found none, e.g. after a move.
    func bind(to url: URL) throws -> AlbumStore {
        let store = try store(for: url)
        weak var cached: NSDocument?
        let documents = DocumentBox()
        let lookUp: @MainActor () -> Void = { [weak store] in
            guard let url = store?.package.url else { return }
            documents.set(Self.platformDocument(for: url))
        }
        lookUp()
        store.coordinateWrites(with: DocumentPackageWrites(documents: documents, onMissingDocument: {
            Task { @MainActor in lookUp() }
        }))
        store.markChanged = { [weak store] in
            if cached == nil, let url = store?.package.url { cached = Self.platformDocument(for: url) }
            cached?.updateChangeCount(.changeDone)
        }
        // Task 17 ruling (b): an explicit save after background changes. `autosave(
        // withImplicitCancellability:)` would write nothing when a user Undo has brought the change
        // count back to "saved", so this saves in place unconditionally (the same operation
        // AppKit's autosave uses); `AlbumStore.requestAutosave` debounces it.
        store.autosaveHandler = { [weak store] in
            guard let url = store?.package.url, let document = Self.platformDocument(for: url),
                  let fileURL = document.fileURL, let fileType = document.fileType else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                document.save(to: fileURL, ofType: fileType, for: .autosaveInPlaceOperation) { error in
                    if let error {
                        Logger.document.error("Background autosave failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.resume()
                }
            }
        }
        return store
    }

    /// The open NSDocument whose file is `url` (compared with symlinks resolved: temp and
    /// `/var` paths reach AppKit as `/private/var`).
    private static func platformDocument(for url: URL) -> NSDocument? {
        let controller = NSDocumentController.shared
        if let document = controller.document(for: url) { return document }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return controller.documents.first {
            $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath().path == target
        }
    }

    /// The store for this document, bound to its package at `url`. Created on first call; later
    /// calls with a new URL (rename, move) re-point the same store, keeping album and undo history.
    func store(for url: URL) throws -> AlbumStore {
        if let store = boundStore {
            try store.packageMoved(to: url)
            return store
        }
        let package = try ProjectPackage.open(url).0
        let store = AlbumStore(album: openedAlbum, package: package, snapshotBox: latest)
        boundStore = store
        return store
    }

    // MARK: Writing

    nonisolated func snapshot(contentType: UTType) throws -> AlbumSnapshot {
        latest.snapshot
    }

    nonisolated func fileWrapper(snapshot: AlbumSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.fileWrapper(for: snapshot, existingFile: configuration.existingFile)
    }

    /// The package to write: the current package directory (lazy, nothing loaded) with the
    /// snapshot's `album.json`. Only a document with no package URL (never bound) falls back to
    /// `existingFile`, then to a new package. A bound package that is gone (moved before the
    /// window rebinds) throws, so NSDocument retries later instead of writing the open-time tree,
    /// which would drop originals stored after opening.
    nonisolated static func fileWrapper(for snapshot: AlbumSnapshot, existingFile: FileWrapper?) throws -> FileWrapper {
        let json = try AlbumCoding.encoder().encode(snapshot.album)
        let root: FileWrapper
        if let url = snapshot.packageURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            root = try FileWrapper(url: url, options: [])
        } else if let existingFile, existingFile.isDirectory {
            root = existingFile
        } else {
            root = FileWrapper(directoryWithFileWrappers: [:])
        }

        if let old = root.fileWrappers?[ProjectPackage.albumFileName] { root.removeFileWrapper(old) }
        let albumFile = FileWrapper(regularFileWithContents: json)
        albumFile.preferredFilename = ProjectPackage.albumFileName
        root.addFileWrapper(albumFile)

        for name in ["originals", "thumbs"] {
            if let directory = root.fileWrappers?[name] {
                removeTemporaryFiles(from: directory)
            } else {
                let directory = FileWrapper(directoryWithFileWrappers: [:])
                directory.preferredFilename = name
                root.addFileWrapper(directory)
            }
        }
        return root
    }

    /// `ProjectPackage` writes through `.<uuid>.tmp` files that it renames a moment later; a
    /// snapshot must not try to copy one that is gone by the time NSDocument writes.
    private nonisolated static func removeTemporaryFiles(from directory: FileWrapper) {
        for (name, child) in directory.fileWrappers ?? [:] where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            directory.removeFileWrapper(child)
        }
    }
}
