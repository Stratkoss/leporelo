import AppKit
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

/// The `AlbumDocument` SwiftUI keeps inside its NSDocument subclass (found by reflection: test-only,
/// the app itself never needs it).
@MainActor
private func albumDocument(in document: NSDocument) -> AlbumDocument? {
    func search(_ value: Any, depth: Int) -> AlbumDocument? {
        if let found = value as? AlbumDocument { return found }
        guard depth > 0 else { return nil }
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {  // a class's own properties, then each superclass's
            for child in current.children {
                if let found = search(child.value, depth: depth - 1) { return found }
            }
            mirror = current.superclassMirror
        }
        return nil
    }
    return search(document, depth: 6)
}

private func inode(_ url: URL) throws -> NSNumber {
    try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber
}

private struct OpenedPackage {
    let url: URL
    let package: ProjectPackage
    let originalURL: URL
    let originalBytes: Data
}

/// A package with a 5 MB stored original ("p1") and an interrupted download ("p2").
private func makeOpenablePackage(_ name: String) throws -> OpenedPackage {
    let url = makeTempDir().appendingPathComponent("\(name).leporelo")
    var album = makeTestAlbum(title: name, photos: [makeTestPhoto("p1"), makeTestPhoto("p2", state: .downloading)])
    let package = try ProjectPackage.create(at: url, album: album)
    let bytes = Data((0..<(5 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let relative = try package.storeOriginal(data: bytes, ext: "jpg", for: "p1")
    album.photos["p1"]?.originalState = .stored(relativePath: relative)
    try package.save(album)
    return OpenedPackage(url: url, package: package, originalURL: url.appendingPathComponent(relative),
                         originalBytes: bytes)
}

@MainActor
private func open(_ url: URL) async throws -> NSDocument {
    try await withCheckedThrowingContinuation { continuation in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
            if let document { continuation.resume(returning: document) }
            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
        }
    }
}

@MainActor
private func autosave(_ document: NSDocument) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        document.autosave(withImplicitCancellability: false) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

/// These open real packages through the app's NSDocumentController (SwiftUI's document class) and
/// let AppKit autosave them in place, with a store bound the way the window binds it.
@MainActor
struct DocumentSystemSaveTests {
    /// A background (no-undo) change marks the document edited; AppKit's autosave then writes it
    /// through the bound-package path: the 5 MB original keeps its inode (hard-linked, never read
    /// or copied) and bytes, an original stored after opening survives, and interrupted downloads
    /// are persisted as `.missing`.
    @Test func backgroundChangeIsAutosavedAndOriginalsKept() async throws {
        let fixture = try makeOpenablePackage("Systém")
        let inodeBefore = try inode(fixture.originalURL)

        let nsDocument = try await open(fixture.url)
        defer { nsDocument.close() }
        #expect(type(of: nsDocument).autosavesInPlace)
        let document = try #require(albumDocument(in: nsDocument))
        let store = try document.bind(to: fixture.url)
        #expect(!nsDocument.isDocumentEdited)

        // What Task 18's downloader does: store the file, then record it without undo.
        let relative = try fixture.package.storeOriginal(data: Data([4, 5, 6]), ext: "heic", for: "p3")
        var album = store.album
        album.photos["p3"] = makeTestPhoto("p3", state: .stored(relativePath: relative))
        album.title = "Na pozadí"
        store.replaceWithoutUndo(album: album)
        #expect(nsDocument.isDocumentEdited)

        try await autosave(nsDocument)

        #expect(try inode(fixture.originalURL) == inodeBefore)
        #expect(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes)
        let (saved, savedAlbum) = try ProjectPackage.open(fixture.url)
        #expect(savedAlbum.title == "Na pozadí")
        #expect(savedAlbum.photos["p2"]?.originalState == .missing)
        #expect(saved.originalURL(for: "p3", album: savedAlbum) != nil)
        #expect(saved.originalURL(for: "p1", album: savedAlbum) != nil)
    }

    /// File > Revert To Saved makes SwiftUI create a new AlbumDocument. Rebinding to it (what the
    /// window's BindKey does) must make later edits mark the document and get autosaved.
    @Test func editsAfterRevertAreSaved() async throws {
        let fixture = try makeOpenablePackage("Návrat")
        let inodeBefore = try inode(fixture.originalURL)
        let nsDocument = try await open(fixture.url)
        defer { nsDocument.close() }
        let before = try #require(albumDocument(in: nsDocument))
        let oldStore = try before.bind(to: fixture.url)
        try oldStore.applyWithoutUndo(.setTitle("Zahodit"))

        let fileURL = try #require(nsDocument.fileURL)
        let fileType = try #require(nsDocument.fileType)
        try nsDocument.revert(toContentsOf: fileURL, ofType: fileType)
        let after = try #require(albumDocument(in: nsDocument))
        #expect(after !== before)
        #expect(AlbumWindow.BindKey(document: before, fileURL: fileURL)
                != AlbumWindow.BindKey(document: after, fileURL: fileURL))

        let store = try after.bind(to: fileURL)
        #expect(store.album.title == "Návrat")
        try store.applyWithoutUndo(.setTitle("Po návratu"))
        #expect(nsDocument.isDocumentEdited)
        try await autosave(nsDocument)

        #expect(try ProjectPackage.open(fixture.url).1.title == "Po návratu")
        #expect(try inode(fixture.originalURL) == inodeBefore)
        #expect(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes)
    }
}
