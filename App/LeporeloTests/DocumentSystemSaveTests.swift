import AppKit
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

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
        let inodeBefore = try inodeNumber(fixture.originalURL)

        let nsDocument = try await openDocument(fixture.url)
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

        #expect(try inodeNumber(fixture.originalURL) == inodeBefore)
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
        let inodeBefore = try inodeNumber(fixture.originalURL)
        let nsDocument = try await openDocument(fixture.url)
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
        #expect(try inodeNumber(fixture.originalURL) == inodeBefore)
        #expect(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes)
    }
}
