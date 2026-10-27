import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private func inode(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as! NSNumber).uint64Value
}

private func readAlbumJSON(_ packageURL: URL) throws -> Album {
    try ProjectPackage.open(packageURL).1
}

/// A package with one stored 5 MB "original" (random bytes; never decoded as an image).
private func makePackageWithLargeOriginal() throws -> (URL, ProjectPackage, Album, Data) {
    let url = makeTempDir().appendingPathComponent("Velký.leporelo")
    var album = makeTestAlbum(title: "Původní", photos: [makeTestPhoto("p1")])
    let package = try ProjectPackage.create(at: url, album: album)
    var bytes = Data(count: 5 * 1024 * 1024)
    bytes.withUnsafeMutableBytes { buffer in
        for i in stride(from: 0, to: buffer.count, by: 4096) { buffer[i] = UInt8(truncatingIfNeeded: i / 4096) }
    }
    let relative = try package.storeOriginal(data: bytes, ext: "jpg", for: "p1")
    album.photos["p1"]?.originalState = .stored(relativePath: relative)
    try package.save(album)
    return (url, package, album, bytes)
}

@MainActor
struct AlbumDocumentTests {
    @Test func openingResetsInterruptedDownloads() throws {
        let url = makeTempDir().appendingPathComponent("Stav.leporelo")
        let album = makeTestAlbum(photos: [
            makeTestPhoto("down", state: .downloading),
            makeTestPhoto("miss", state: .missing),
            makeTestPhoto("gone", state: .unavailable),
            makeTestPhoto("kept", state: .stored(relativePath: "originals/kept.jpg")),
        ])
        let package = try ProjectPackage.create(at: url, album: album)
        _ = try package.storeOriginal(data: Data([7]), ext: "jpg", for: "kept")

        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        let opened = document.currentAlbum
        #expect(opened.photos["down"]?.originalState == .missing)
        #expect(opened.photos["miss"]?.originalState == .missing)
        #expect(opened.photos["gone"]?.originalState == .unavailable)
        #expect(opened.photos["kept"]?.originalState == .stored(relativePath: "originals/kept.jpg"))
        var expected = album
        expected.photos["down"]?.originalState = .missing
        #expect(opened == expected)
    }

    /// `.stored` whose file is not in the package (deleted, or lost in a crash) becomes `.missing`,
    /// so preflight and the downloader see the truth.
    @Test func openingReconcilesStoredOriginalsWithoutAFile() throws {
        let url = makeTempDir().appendingPathComponent("Soubory.leporelo")
        let album = makeTestAlbum(photos: [
            makeTestPhoto("here", state: .stored(relativePath: "originals/here.jpg")),
            makeTestPhoto("lost", state: .stored(relativePath: "originals/lost.jpg")),
            makeTestPhoto("escape", state: .stored(relativePath: "../outside.jpg")),
            makeTestPhoto("dir", state: .stored(relativePath: "originals")),
        ])
        let package = try ProjectPackage.create(at: url, album: album)
        _ = try package.storeOriginal(data: Data([1]), ext: "jpg", for: "here")

        let opened = try AlbumDocument(file: FileWrapper(url: url, options: [])).currentAlbum
        #expect(opened.photos["here"]?.originalState == .stored(relativePath: "originals/here.jpg"))
        #expect(opened.photos["lost"]?.originalState == .missing)
        #expect(opened.photos["escape"]?.originalState == .missing)
        #expect(opened.photos["dir"]?.originalState == .missing)
    }

    @Test func openingANewerFormatFailsWithACzechMessage() throws {
        let url = makeTempDir().appendingPathComponent("Budoucí.leporelo")
        _ = try ProjectPackage.create(at: url, album: makeTestAlbum())
        let jsonURL = url.appendingPathComponent(ProjectPackage.albumFileName)
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
            .replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        try json.write(to: jsonURL, atomically: true, encoding: .utf8)

        do {
            _ = try AlbumDocument(file: FileWrapper(url: url, options: []))
            Issue.record("opening a newer format must fail")
        } catch {
            #expect(error as? ProjectError == .unsupportedVersion(99))
            #expect(error.localizedDescription.contains("novější verz"))
        }
        let corrupt: Error = ProjectError.corrupt("bad")
        #expect(corrupt.localizedDescription.contains("poškozen"))
    }

    /// Revert, Versions "Restore" and external-change reloads give the window a NEW document. The
    /// window must rebind (its key changes) and edits must land in the new document's snapshot.
    @Test func reloadedDocumentGetsItsOwnStore() throws {
        let (url, _, _, _) = try makePackageWithLargeOriginal()
        let first = try AlbumDocument(file: FileWrapper(url: url, options: []))
        let firstStore = try first.bind(to: url)
        try firstStore.applyWithoutUndo(.setTitle("Před návratem"))

        let reloaded = try AlbumDocument(file: FileWrapper(url: url, options: []))
        #expect(AlbumWindow.BindKey(document: first, fileURL: url)
                != AlbumWindow.BindKey(document: reloaded, fileURL: url))
        let store = try reloaded.bind(to: url)
        #expect(store !== firstStore)
        #expect(store.album.title == "Původní")

        try store.applyWithoutUndo(.setTitle("Po návratu"))
        let snapshot = try reloaded.snapshot(contentType: .leporeloAlbum)
        #expect(snapshot.album.title == "Po návratu")
        #expect(snapshot.packageURL == url)
    }

    /// A bound package that vanished (moved in Finder before the window rebinds) must fail the
    /// save, so NSDocument retries later, instead of writing the stale open-time tree, which
    /// would delete originals stored after opening.
    @Test func savingFailsWhenTheBoundPackageIsGone() throws {
        let (url, _, album, _) = try makePackageWithLargeOriginal()
        let openTime = try FileWrapper(url: url, options: [])
        let gone = url.deletingLastPathComponent().appendingPathComponent("Přesunuto.leporelo")
        try FileManager.default.moveItem(at: url, to: gone)

        #expect(throws: CocoaError.self) {
            _ = try AlbumDocument.fileWrapper(for: AlbumSnapshot(album: album, packageURL: url),
                                              existingFile: openTime)
        }
        // No package URL at all (never saved): the existing file is still the fallback.
        let fallback = try AlbumDocument.fileWrapper(for: AlbumSnapshot(album: album, packageURL: nil),
                                                     existingFile: openTime)
        #expect(fallback === openTime)
    }

    @Test func openingRejectsDirectoryWithoutAlbum() throws {
        let dir = makeTempDir().appendingPathComponent("Prázdný.leporelo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: ProjectError.missingAlbumFile) {
            _ = try AlbumDocument(file: FileWrapper(url: dir, options: []))
        }
    }

    @Test func storeIsBoundToThePackageURL() throws {
        let (url, _, album, _) = try makePackageWithLargeOriginal()
        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        let store = try document.store(for: url)
        #expect(store.package.url == url)
        #expect(store.album == album)
        #expect(try document.store(for: url) === store)
    }

    /// Autosave of a package with a 5 MB original: the written package hard-links the original
    /// (same inode, so its bytes were never read into memory or copied) and the original file in
    /// the package stays byte-for-byte intact. The write mirrors what NSDocument does on a safe
    /// save: `FileWrapper.write(to: temp, originalContentsURL: package)`.
    @Test func autosaveDoesNotCopyOriginals() throws {
        let (url, _, _, bytes) = try makePackageWithLargeOriginal()
        let originalURL = url.appendingPathComponent("originals/p1.jpg")
        let originalInode = try inode(originalURL)

        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        let store = try document.store(for: url)
        try store.apply(.setTitle("Nový název"), undoManager: nil)

        let snapshot = try document.snapshot(contentType: .leporeloAlbum)
        let wrapper = try AlbumDocument.fileWrapper(for: snapshot, existingFile: nil)

        let saved = makeTempDir().appendingPathComponent("Uloženo.leporelo")
        try wrapper.write(to: saved, options: [], originalContentsURL: url)

        let savedOriginal = saved.appendingPathComponent("originals/p1.jpg")
        #expect(try inode(savedOriginal) == originalInode)
        #expect(try readAlbumJSON(saved).title == "Nový název")
        #expect(try Data(contentsOf: originalURL) == bytes)
        #expect(try readAlbumJSON(url).title == "Původní")  // the live package is untouched until the swap
    }

    /// Originals stored by the background downloader after the document was opened must survive
    /// an autosave (a stale `existingFile` from open time would drop them on the safe-save swap).
    @Test func autosaveKeepsOriginalsAddedAfterOpening() throws {
        let (url, package, _, _) = try makePackageWithLargeOriginal()
        let staleWrapper = try FileWrapper(url: url, options: [])
        let document = try AlbumDocument(file: staleWrapper)
        let store = try document.store(for: url)

        let relative = try package.storeOriginal(data: Data([1, 2, 3]), ext: "heic", for: "p2")
        var album = store.album
        album.photos["p2"] = makeTestPhoto("p2", state: .stored(relativePath: relative))
        store.replace(album: album, actionName: "Stáhnout originály", undoManager: nil)

        let snapshot = try document.snapshot(contentType: .leporeloAlbum)
        let wrapper = try AlbumDocument.fileWrapper(for: snapshot, existingFile: staleWrapper)
        let saved = makeTempDir().appendingPathComponent("Uloženo.leporelo")
        try wrapper.write(to: saved, options: [], originalContentsURL: url)

        #expect(try Data(contentsOf: saved.appendingPathComponent("originals/p2.heic")) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("originals/p1.jpg").path))
        let (reopened, reopenedAlbum) = try ProjectPackage.open(saved)
        #expect(reopened.originalURL(for: "p2", album: reopenedAlbum) != nil)
    }

    /// SwiftUI takes the snapshot on a background queue while the main thread may be blocked
    /// waiting for the save; a snapshot that hops to the main thread would deadlock here.
    @Test func snapshotWorksWhileMainThreadIsBlocked() throws {
        let (url, _, _, _) = try makePackageWithLargeOriginal()
        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        let store = try document.store(for: url)
        try store.apply(.setTitle("Z pozadí"), undoManager: nil)

        let snapshot = try DispatchQueue.global().sync {  // blocks the main thread
            try document.snapshot(contentType: .leporeloAlbum)
        }
        #expect(snapshot.album.title == "Z pozadí")
        #expect(snapshot.packageURL == url)
    }

    /// A document without a package on disk yet (untitled) writes a complete, openable package.
    @Test func untitledDocumentWritesAValidPackage() throws {
        let document = AlbumDocument()
        let snapshot = try document.snapshot(contentType: .leporeloAlbum)
        #expect(snapshot.packageURL == nil)
        let wrapper = try AlbumDocument.fileWrapper(for: snapshot, existingFile: nil)
        let saved = makeTempDir().appendingPathComponent("Bez názvu.leporelo")
        try wrapper.write(to: saved, options: [], originalContentsURL: nil)

        let (_, album) = try ProjectPackage.open(saved)
        #expect(album == document.currentAlbum)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("originals").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("thumbs").path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// The JSON written by the document is exactly what `ProjectPackage.save` (AlbumCoding) writes.
    @Test func albumJSONUsesAlbumCoding() throws {
        let (url, package, album, _) = try makePackageWithLargeOriginal()
        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        _ = try document.store(for: url)
        let wrapper = try AlbumDocument.fileWrapper(for: document.snapshot(contentType: .leporeloAlbum),
                                                    existingFile: nil)
        let written = wrapper.fileWrappers?[ProjectPackage.albumFileName]?.regularFileContents
        try package.save(album)
        #expect(written == (try Data(contentsOf: url.appendingPathComponent(ProjectPackage.albumFileName))))
        #expect(written == (try AlbumCoding.encoder().encode(album)))
    }
}
