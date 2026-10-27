import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

func makeTestAlbum(title: String = "A", photos: [Photo] = []) -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "album-1", title: title,
          supplierProfileID: "canva-photobook", formatID: "landscape", world: Workflow.world,
          cover: nil, spreads: [], photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
          source: nil, createdAt: Date(timeIntervalSince1970: 1_000))
}

func makeTestPhoto(_ id: String, state: OriginalState = .missing) -> Photo {
    Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: 2_000),
          timeZoneSeconds: 0, location: nil, pixelWidth: 40, pixelHeight: 30, kind: .photo,
          analysis: nil, isSelected: false, dayKey: nil, placeName: nil, seriesID: nil,
          originalState: state, deletedInSource: false)
}

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("leporelo-app-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// An undo manager that does not depend on the run loop: every registration is its own group.
@MainActor
private func makeUndoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
}

@MainActor
private func makeStore(title: String = "A", photos: [Photo] = []) throws -> AlbumStore {
    let url = makeTempDir().appendingPathComponent("Test.leporelo")
    let album = makeTestAlbum(title: title, photos: photos)
    let package = try ProjectPackage.create(at: url, album: album)
    return AlbumStore(album: album, package: package)
}

@MainActor
struct AlbumStoreTests {
    @Test func applyRegistersUndo() throws {
        let store = try makeStore(title: "A")
        let undo = makeUndoManager()

        undo.beginUndoGrouping()
        try store.apply(.setTitle("B"), undoManager: undo)
        undo.endUndoGrouping()
        #expect(store.album.title == "B")
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Změnit název")

        undo.undo()
        #expect(store.album.title == "A")
        #expect(undo.canRedo)
        #expect(undo.redoActionName == "Změnit název")

        undo.redo()
        #expect(store.album.title == "B")

        undo.undo()
        #expect(store.album.title == "A")
    }

    @Test func failedEditRegistersNothing() throws {
        let store = try makeStore()
        let undo = makeUndoManager()
        // No group is opened: registering outside a group (groupsByEvent off) would raise, so this
        // also proves nothing is registered.
        #expect(throws: AlbumEditError.unknownPhoto) {
            try store.apply(.setSelected("nope", true), undoManager: undo)
        }
        #expect(store.album == makeTestAlbum())
        #expect(!undo.canUndo)
    }

    @Test func applyWithoutUndoManagerStillApplies() throws {
        let store = try makeStore(photos: [makeTestPhoto("p1")])
        try store.apply(.setSelected("p1", true), undoManager: nil)
        #expect(store.album.photos["p1"]?.isSelected == true)
    }

    @Test func multipleEditsUndoInReverseOrder() throws {
        let store = try makeStore(title: "A", photos: [makeTestPhoto("p1")])
        let undo = makeUndoManager()
        for edit in [AlbumEdit.setTitle("B"), .setSelected("p1", true), .setTitle("C")] {
            undo.beginUndoGrouping()
            try store.apply(edit, undoManager: undo)
            undo.endUndoGrouping()
        }
        undo.undo()
        #expect(store.album.title == "B")
        undo.undo()
        #expect(store.album.photos["p1"]?.isSelected == false)
        undo.undo()
        #expect(store.album.title == "A")
        undo.redo(); undo.redo(); undo.redo()
        #expect(store.album.title == "C")
        #expect(store.album.photos["p1"]?.isSelected == true)
    }

    @Test func replaceRegistersUndoAndRedo() throws {
        let store = try makeStore(title: "A")
        let undo = makeUndoManager()
        var replacement = store.album
        replacement.title = "Navrženo"
        replacement.formatID = "square"

        undo.beginUndoGrouping()
        store.replace(album: replacement, actionName: "Navrhnout album", undoManager: undo)
        undo.endUndoGrouping()
        #expect(store.album == replacement)
        #expect(undo.undoActionName == "Navrhnout album")

        undo.undo()
        #expect(store.album == makeTestAlbum(title: "A"))
        #expect(undo.redoActionName == "Navrhnout album")

        undo.redo()
        #expect(store.album == replacement)
    }

    /// Task 20 ruling: undo and redo of a `replace` restore the user's content but keep the
    /// background-owned photo fields (analysis, original state, series, place, deleted flag) as they
    /// are NOW.
    @Test func replaceUndoKeepsBackgroundFields() throws {
        let store = try makeStore(photos: [makeTestPhoto("p1"), makeTestPhoto("p2")])
        let undo = makeUndoManager()
        var selected = store.album
        selected.photos["p1"]?.isSelected = true
        selected.photos["p1"]?.selectionDecidedByUser = true

        undo.beginUndoGrouping()
        store.replace(album: selected, actionName: "Vybrat fotku", undoManager: undo)
        undo.endUndoGrouping()

        let analysis = PhotoAnalysis(aesthetic: 0.8, sharpness: 400, isUtility: false, faceRects: [],
                                     closedEyes: false, featurePrint: nil)
        store.setAnalyses(["p1": analysis, "p2": analysis])
        var downloaded = store.album
        downloaded.photos["p1"]?.originalState = .stored(relativePath: "originals/p1.jpg")
        downloaded.photos["p2"]?.placeName = "Positano"
        store.replaceWithoutUndo(album: downloaded)

        undo.undo()
        #expect(store.album.photos["p1"]?.isSelected == false)
        #expect(store.album.photos["p1"]?.selectionDecidedByUser == false)
        #expect(store.album.photos["p1"]?.analysis == analysis)
        #expect(store.album.photos["p2"]?.analysis == analysis)
        #expect(store.album.photos["p1"]?.originalState == .stored(relativePath: "originals/p1.jpg"))
        #expect(store.album.photos["p2"]?.placeName == "Positano")

        // A background change between undo and redo survives the redo too.
        var later = store.album
        later.photos["p2"]?.seriesID = "series-p2"
        store.replaceWithoutUndo(album: later)

        undo.redo()
        #expect(store.album.photos["p1"]?.isSelected == true)
        #expect(store.album.photos["p1"]?.analysis == analysis)
        #expect(store.album.photos["p1"]?.originalState == .stored(relativePath: "originals/p1.jpg"))
        #expect(store.album.photos["p2"]?.seriesID == "series-p2")
        #expect(store.album.photos["p2"]?.placeName == "Positano")
    }

    @Test func revisionCountsEveryChange() throws {
        let store = try makeStore(photos: [makeTestPhoto("p1")])
        let start = store.revision
        try store.apply(.setSelected("p1", true), undoManager: nil)
        store.replaceWithoutUndo(album: store.album)
        #expect(store.revision == start + 2)
    }

    /// Background work (analysis, downloads) changes the album without undo; every such change
    /// must reach the document's "changed" hook so autosave runs.
    @Test func changesWithoutUndoCallMarkChanged() throws {
        let store = try makeStore(title: "A", photos: [makeTestPhoto("p1")])
        var marks = 0
        store.markChanged = { marks += 1 }

        try store.applyWithoutUndo(.setSelected("p1", true))
        #expect(store.album.photos["p1"]?.isSelected == true)
        #expect(marks == 1)

        var replacement = store.album
        replacement.title = "Analyzováno"
        store.replaceWithoutUndo(album: replacement)
        #expect(store.album.title == "Analyzováno")
        #expect(marks == 2)

        // The nil-undo-manager forms are the same no-undo path, never a silent unsaved change.
        try store.apply(.setTitle("C"), undoManager: nil)
        store.replace(album: replacement, actionName: "X", undoManager: nil)
        #expect(marks == 4)

        // With an undo manager, the registered undo marks the document; the hook stays quiet.
        let undo = makeUndoManager()
        undo.beginUndoGrouping()
        try store.apply(.setTitle("D"), undoManager: undo)
        undo.endUndoGrouping()
        #expect(marks == 4)

        #expect(throws: AlbumEditError.unknownPhoto) { try store.applyWithoutUndo(.setSelected("nope", true)) }
        #expect(marks == 4)
    }
}
