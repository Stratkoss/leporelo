import AppKit
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Writes `count` originals into `package` from a background thread while the document is
/// autosaved over and over (each save lists the package, writes a new one and swaps it in), and
/// returns the ids whose file is gone afterwards.
@MainActor
func originalsLostWhileAutosaving(package: ProjectPackage, document: NSDocument,
                                          count: Int, minimumSaves: Int) async throws -> (lost: [String], saves: Int) {
    let bytes = Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let finished = Flag()
    let writer = Task.detached {
        defer { finished.set() }
        var paths: [String: String] = [:]
        for i in 0..<count {
            let id = "s\(i)"
            paths[id] = try package.storeOriginal(data: bytes, ext: "jpg", for: id)
        }
        return paths
    }
    var saves = 0
    while !finished.isSet || saves < minimumSaves {
        document.updateChangeCount(.changeDone)
        try await autosave(document)
        saves += 1
        // Real autosaves are seconds apart; back-to-back saves would starve the writer.
        try await Task.sleep(for: .milliseconds(3))
    }
    let paths = try await writer.value
    let lost = paths.filter { !FileManager.default.fileExists(atPath: package.url.appendingPathComponent($0.value).path) }
    return (lost.keys.sorted(), saves)
}

private func modificationDate(_ url: URL) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
}

/// Task 17/19b contract: while a document is open, originals and thumbnails are written through
/// `DocumentPackageWrites` (the document's file access, then NSFileCoordinator).
@MainActor
struct CoordinatedWritesTests {
    /// Binding gives the store a coordinated package; a move keeps the coordinator.
    @Test func bindCoordinatesTheStoresPackage() async throws {
        let fixture = try makeOpenablePackage("Vazba")
        let nsDocument = try await openDocument(fixture.url)
        defer { nsDocument.close() }
        let document = try #require(albumDocument(in: nsDocument))
        let store = try document.bind(to: fixture.url)
        let writes = try #require(store.package.writeCoordinator as? DocumentPackageWrites)
        #expect(writes.documents.document === nsDocument)

        let moved = makeTempDir().appendingPathComponent("Přesunuto.leporelo")
        try FileManager.default.copyItem(at: fixture.url, to: moved)
        try store.packageMoved(to: moved)
        #expect(store.package.url == moved)
        #expect(store.package.writeCoordinator is DocumentPackageWrites)
    }

    /// A coordinated original write waits while someone else holds a coordinated write on the
    /// package itself (what NSDocument's save does around its listing and swap), deterministically.
    @Test func originalWriteWaitsForAWriteOnThePackage() async throws {
        let fixture = try makeOpenablePackage("Čekání")
        let nsDocument = try await openDocument(fixture.url)
        defer { nsDocument.close() }
        let store = try #require(albumDocument(in: nsDocument)).bind(to: fixture.url)
        let package = store.package
        let packageURL = fixture.url
        let holding = Flag()
        let released = Flag()

        let saver = Task.detached {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: packageURL, options: .forReplacing, error: &error) { _ in
                holding.set()
                Thread.sleep(forTimeInterval: 0.4)
                released.set()
            }
        }
        while !holding.isSet { try await Task.sleep(for: .milliseconds(5)) }
        let writer = Task.detached { () -> Bool in
            _ = try package.storeOriginal(data: Data([1, 2]), ext: "jpg", for: "w1")
            return released.isSet
        }
        let finishedAfterRelease = try await writer.value
        await saver.value
        #expect(finishedAfterRelease)
        #expect(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("originals/w1.jpg").path))
    }

    /// SAFETY NET for `DocumentPackageWrites` (the Objective-C `performSynchronousFileAccess` call
    /// and the presenter choice rest on measured AppKit behaviour): it MUST stay in the default
    /// `make test-app` run, so an AppKit change that breaks the serialization fails here.
    ///
    /// The Task 17 race: originals written while the document autosaves repeatedly all survive,
    /// and the document does not see its package as changed by another application (its
    /// recorded modification date matches the package on disk).
    @Test func coordinatedOriginalsSurviveRepeatedAutosaves() async throws {
        let fixture = try makeOpenablePackage("Souběh")
        let nsDocument = try await openDocument(fixture.url)
        defer { nsDocument.close() }
        let document = try #require(albumDocument(in: nsDocument))
        let store = try document.bind(to: fixture.url)
        #expect(store.package.writeCoordinator is DocumentPackageWrites)

        let (lost, saves) = try await originalsLostWhileAutosaving(package: store.package, document: nsDocument,
                                                                   count: 200, minimumSaves: 10)
        #expect(saves >= 10)
        #expect(lost.isEmpty, "lost \(lost.count) of 200 originals over \(saves) saves")
        #expect(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes)

        // The document is not told about our own writes: it neither reloads nor considers its
        // package changed by another application: same AlbumDocument, matching modification date,
        // and the next save goes through.
        try await Task.sleep(for: .milliseconds(300))
        #expect(albumDocument(in: nsDocument) === document)
        let onDisk = try #require(try modificationDate(fixture.url))
        let recorded = try #require(nsDocument.fileModificationDate)
        #expect(abs(onDisk.timeIntervalSince(recorded)) < 0.001)
        try store.applyWithoutUndo(.setTitle("Po souběhu"))
        try await autosave(nsDocument)
        #expect(try ProjectPackage.open(fixture.url).1.title == "Po souběhu")
        #expect(albumDocument(in: nsDocument) === document)
    }
}
