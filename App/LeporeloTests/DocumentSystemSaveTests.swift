import AppKit
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

/// Opens a real package through the app's NSDocumentController (SwiftUI's document class) and lets
/// AppKit autosave it in place: the 5 MB original must keep its inode (hard-linked, never read or
/// copied) and its bytes, and `album.json` must be rewritten with interrupted downloads reset.
@MainActor
struct DocumentSystemSaveTests {
    @Test func appKitAutosaveInPlaceKeepsOriginals() async throws {
        let url = makeTempDir().appendingPathComponent("Systém.leporelo")
        var album = makeTestAlbum(title: "Systém", photos: [makeTestPhoto("p1"), makeTestPhoto("p2", state: .downloading)])
        let package = try ProjectPackage.create(at: url, album: album)
        let bytes = Data((0..<(5 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let relative = try package.storeOriginal(data: bytes, ext: "jpg", for: "p1")
        album.photos["p1"]?.originalState = .stored(relativePath: relative)
        try package.save(album)
        let originalURL = url.appendingPathComponent(relative)
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: originalURL.path)[.systemFileNumber] as! NSNumber

        let document: NSDocument = try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                if let document { continuation.resume(returning: document) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        defer { document.close() }
        #expect(type(of: document).autosavesInPlace)

        document.updateChangeCount(.changeDone)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.autosave(withImplicitCancellability: false) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }

        let inodeAfter = try FileManager.default.attributesOfItem(atPath: originalURL.path)[.systemFileNumber] as! NSNumber
        #expect(inodeAfter == inodeBefore)
        #expect(try Data(contentsOf: originalURL) == bytes)
        let (_, saved) = try ProjectPackage.open(url)
        #expect(saved.photos["p2"]?.originalState == .missing)
        #expect(saved.photos["p1"]?.originalState == .stored(relativePath: relative))
        #expect(saved.title == "Systém")
    }
}
