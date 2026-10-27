import AppKit
import Foundation
import LeporeloCore
@testable import Leporelo

// Helpers for tests that open real packages through the app's NSDocumentController.

/// The `AlbumDocument` SwiftUI keeps inside its NSDocument subclass (found by reflection: test-only,
/// the app itself never needs it).
@MainActor
func albumDocument(in document: NSDocument) -> AlbumDocument? {
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

func inodeNumber(_ url: URL) throws -> NSNumber {
    try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber
}

struct OpenedPackage {
    let url: URL
    let package: ProjectPackage
    let originalURL: URL
    let originalBytes: Data
}

/// A package with a 5 MB stored original ("p1") and an interrupted download ("p2").
func makeOpenablePackage(_ name: String) throws -> OpenedPackage {
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
func openDocument(_ url: URL) async throws -> NSDocument {
    try await withCheckedThrowingContinuation { continuation in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
            if let document { continuation.resume(returning: document) }
            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
        }
    }
}

@MainActor
func autosave(_ document: NSDocument) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        document.autosave(withImplicitCancellability: false) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

