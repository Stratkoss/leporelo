import Foundation
import Testing
@testable import LeporeloCore

private func makeAlbum() -> Album {
    func photo(_ id: String, day: Int?) -> Photo {
        Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
              timeZoneSeconds: nil, location: nil, pixelWidth: 4000, pixelHeight: 3000, kind: .photo,
              analysis: nil, isSelected: false, dayKey: day.map { DayKey(year: 2026, month: 7, day: $0) },
              placeName: nil, seriesID: nil, originalState: .missing, deletedInSource: false)
    }
    func spread(_ id: String) -> Spread {
        Spread(id: id, kind: .gallery, templateID: "t1", dayKey: nil,
               frames: [
                Frame(id: "f1", rect: Rect(x: 0, y: 0, width: 10, height: 10), photoID: "p1",
                      offset: Point(x: 0.1, y: -0.2), zoom: 1.5),
                Frame(id: "f2", rect: Rect(x: 10, y: 0, width: 10, height: 10), photoID: "p2",
                      offset: Point(x: 0, y: 0), zoom: 1),
               ],
               texts: [TextBox(id: "t1", rect: Rect(x: 0, y: 10, width: 10, height: 5), role: .caption, text: "old")],
               manuallyEdited: false)
    }
    return Album(formatVersion: 1, id: "a", title: "Title", supplierProfileID: "s", formatID: "f",
                 world: "journal-gallery", cover: nil, spreads: [spread("s1"), spread("s2"), spread("s3")],
                 photos: ["p1": photo("p1", day: 1), "p2": photo("p2", day: 2), "p3": photo("p3", day: 3)],
                 source: nil, createdAt: Date(timeIntervalSince1970: 0))
}

@Test func everyEditIsReversible() throws {
    var original = makeAlbum()
    original.spreads[2].manuallyEdited = true
    original.photos["p3"]?.dayKey = nil
    var replacement = original.spreads[1]
    replacement.templateID = "t2"
    replacement.frames.removeLast()
    let extra = Spread(id: "s9", kind: .blank, templateID: "t0", dayKey: nil, frames: [], texts: [], manuallyEdited: false)

    let edits: [AlbumEdit] = [
        .setSelected("p1", true),
        .setSelected("p1", false),
        .restorePhotoSelection("p2", isSelected: true, decided: false),
        .restorePhotoSelection("p2", isSelected: false, decided: true),
        .setFramePhoto(spreadID: "s1", frameID: "f1", photoID: "p3"),
        .setFramePhoto(spreadID: "s1", frameID: "f1", photoID: nil),
        .swapFramePhotos(spreadID: "s1", frameA: "f1", frameB: "f2"),
        .setFrameTransform(spreadID: "s1", frameID: "f1", offset: Point(x: 0.5, y: 0.5), zoom: 2),
        .setFrameTransform(spreadID: "s1", frameID: "f1", offset: Point(x: 5, y: -5), zoom: 0.2),
        .setText(spreadID: "s1", textID: "t1", text: "new"),
        .moveSpread(from: 0, to: 2),
        .moveSpread(from: 2, to: 0),
        .insertSpread(extra, at: 1),
        .deleteSpread(id: "s2"),
        .replaceSpread(replacement),
        .restoreSpread(replacement),
        .setText(spreadID: "s3", textID: "t1", text: "new"),
        .swapFramePhotos(spreadID: "s3", frameA: "f1", frameB: "f2"),
        .setPhotoDay("p3", DayKey(year: 2026, month: 8, day: 9)),
        .setPhotoDay("p1", nil),
        .setPhotoDay("p1", DayKey(year: 2026, month: 8, day: 9)),
        .setTitle("Other"),
    ]
    for edit in edits {
        let (edited, inverse) = try original.applying(edit)
        #expect(edited != original, "\(edit) should change the album")
        let (restored, redo) = try edited.applying(inverse)
        #expect(restored == original, "\(edit) inverse should restore the album")
        let (again, _) = try restored.applying(redo)
        #expect(again == edited, "\(edit) redo should reproduce the edit")
    }
}

@Test func editMarksSpreadManuallyEdited() throws {
    let album = makeAlbum()
    let (edited, _) = try album.applying(.setText(spreadID: "s1", textID: "t1", text: "x"))
    #expect(edited.spreads[0].manuallyEdited)
    #expect(!edited.spreads[1].manuallyEdited)
    let (moved, _) = try album.applying(.moveSpread(from: 0, to: 1))
    #expect(moved.spreads.allSatisfy { !$0.manuallyEdited })
}

@Test func swapFramePhotosExchangesIDs() throws {
    let (edited, _) = try makeAlbum().applying(.swapFramePhotos(spreadID: "s1", frameA: "f1", frameB: "f2"))
    #expect(edited.spreads[0].frames[0].photoID == "p2")
    #expect(edited.spreads[0].frames[1].photoID == "p1")
}

private let sampleStyle = TextStyle(fontFamily: "Georgia", sizePt: 14, bold: true, alignment: .right,
                                    colorHex: "#336699")

@Test func setTextStyleAndUndo() throws {
    var original = makeAlbum()
    original.spreads[0].manuallyEdited = false
    let (edited, inverse) = try original.applying(.setTextStyle(spreadID: "s1", textID: "t1", style: sampleStyle))
    #expect(edited.spreads[0].texts[0].style == sampleStyle)
    #expect(edited.spreads[0].texts[0].text == "old")
    #expect(edited.spreads[0].manuallyEdited)
    let (restored, redo) = try edited.applying(inverse)
    #expect(restored == original)
    #expect(restored.spreads[0].texts[0].style == nil && !restored.spreads[0].manuallyEdited)
    #expect(try restored.applying(redo).album == edited)
    // Clearing a style is undoable too.
    let (cleared, clearInverse) = try edited.applying(.setTextStyle(spreadID: "s1", textID: "t1", style: nil))
    #expect(cleared.spreads[0].texts[0].style == nil)
    #expect(try cleared.applying(clearInverse).album == edited)
}

@Test func setTextStyleClampsSize() throws {
    func stored(_ size: Double) throws -> Double? {
        let (edited, _) = try makeAlbum().applying(
            .setTextStyle(spreadID: "s1", textID: "t1", style: TextStyle(sizePt: size, bold: true)))
        return edited.spreads[0].texts[0].style?.sizePt
    }
    #expect(try stored(300) == 200)
    #expect(try stored(2) == 6)
    #expect(try stored(12) == 12)
    #expect(try stored(.nan) == nil)
    #expect(try stored(.infinity) == nil)
}

@Test func emptyStyleStoredAsNil() throws {
    var album = makeAlbum()
    album.spreads[0].texts[0].style = sampleStyle
    let (edited, _) = try album.applying(.setTextStyle(spreadID: "s1", textID: "t1", style: TextStyle()))
    #expect(edited.spreads[0].texts[0].style == nil)
    // A style that is empty only after the NaN size is dropped counts as empty too.
    let (nan, _) = try album.applying(.setTextStyle(spreadID: "s1", textID: "t1", style: TextStyle(sizePt: .nan)))
    #expect(nan.spreads[0].texts[0].style == nil)
}

@Test func setTextStyleUnknownIDsThrow() {
    let album = makeAlbum()
    #expect(throws: AlbumEditError.unknownText) {
        try album.applying(.setTextStyle(spreadID: "s1", textID: "nope", style: sampleStyle))
    }
    #expect(throws: AlbumEditError.unknownSpread) {
        try album.applying(.setTextStyle(spreadID: "nope", textID: "t1", style: sampleStyle))
    }
}

@Test func setFrameTransformClamps() throws {
    let (edited, _) = try makeAlbum().applying(
        .setFrameTransform(spreadID: "s1", frameID: "f1", offset: Point(x: 3, y: -3), zoom: 0.5))
    let frame = edited.spreads[0].frames[0]
    #expect(frame.zoom == 1)
    #expect(frame.offset == Point(x: 1, y: -1))
}

@Test func setFrameTransformSanitisesNonFiniteValues() throws {
    func frame(_ offset: Point, _ zoom: Double) throws -> Frame {
        try makeAlbum().applying(.setFrameTransform(spreadID: "s1", frameID: "f1", offset: offset, zoom: zoom))
            .album.spreads[0].frames[0]
    }
    #expect(try frame(Point(x: .nan, y: .infinity), .nan) == Frame(id: "f1", rect: Rect(x: 0, y: 0, width: 10, height: 10),
                                                                  photoID: "p1", offset: Point(x: 0, y: 0), zoom: 1))
    #expect(try frame(Point(x: -.infinity, y: 0.5), .infinity).zoom == 1)
    #expect(try frame(Point(x: -.infinity, y: 0.5), .infinity).offset == Point(x: 0, y: 0.5))
    #expect(try frame(Point(x: 0, y: 0), -.infinity).zoom == 1)
    #expect(try frame(Point(x: 0, y: 0), 1e9).zoom == 100)
    #expect(try frame(Point(x: 0, y: 0), 3).zoom == 3)
    // The result always encodes (JSONEncoder throws on NaN/infinity).
    let (edited, _) = try makeAlbum().applying(
        .setFrameTransform(spreadID: "s1", frameID: "f1", offset: Point(x: .nan, y: .nan), zoom: .infinity))
    #expect(throws: Never.self) { _ = try AlbumCoding.encoder().encode(edited) }
}

@Test func deleteSpreadInverseRestoresAtSameIndex() throws {
    let album = makeAlbum()
    let (edited, inverse) = try album.applying(.deleteSpread(id: "s2"))
    #expect(edited.spreads.map(\.id) == ["s1", "s3"])
    #expect(inverse == .insertSpread(album.spreads[1], at: 1))
    #expect(try edited.applying(inverse).album.spreads.map(\.id) == ["s1", "s2", "s3"])
}

@Test func unknownSpreadThrows() {
    let album = makeAlbum()
    #expect(throws: AlbumEditError.unknownSpread) {
        try album.applying(.setText(spreadID: "nope", textID: "t1", text: "x"))
    }
    #expect(throws: AlbumEditError.unknownFrame) {
        try album.applying(.setFramePhoto(spreadID: "s1", frameID: "nope", photoID: nil))
    }
    #expect(throws: AlbumEditError.unknownPhoto) {
        try album.applying(.setSelected("nope", true))
    }
    #expect(throws: AlbumEditError.badIndex) {
        try album.applying(.moveSpread(from: 0, to: 9))
    }
}

@Test func replaceSpreadMarksManuallyEdited() throws {
    let album = makeAlbum()
    var replacement = album.spreads[0]
    replacement.templateID = "t2"
    let (edited, inverse) = try album.applying(.replaceSpread(replacement))
    #expect(edited.spreads[0].manuallyEdited)
    #expect(try edited.applying(inverse).album == album)
}

@Test func duplicateInsertThrows() {
    let album = makeAlbum()
    #expect(throws: AlbumEditError.duplicateSpread) {
        try album.applying(.insertSpread(album.spreads[0], at: 0))
    }
}

@Test func setPhotoDayHandlesNilDay() throws {
    var album = makeAlbum()
    album.photos["p1"]?.dayKey = nil
    let day = DayKey(year: 2026, month: 9, day: 1)
    let (edited, inverse) = try album.applying(.setPhotoDay("p1", day))
    #expect(edited.photos["p1"]?.dayKey == day)
    #expect(inverse == .setPhotoDay("p1", nil))
    #expect(try edited.applying(inverse).album == album)
}

@Test func failedEditLeavesAlbumUnchanged() {
    let album = makeAlbum()
    let snapshot = album
    _ = try? album.applying(.setText(spreadID: "s1", textID: "nope", text: "x"))
    _ = try? album.applying(.setFramePhoto(spreadID: "s1", frameID: "f1", photoID: "nope"))
    _ = try? album.applying(.insertSpread(album.spreads[0], at: 0))
    #expect(album == snapshot)
}

@Test func unknownIDsThrow() {
    let album = makeAlbum()
    let ghost = Spread(id: "ghost", kind: .blank, templateID: "t", dayKey: nil, frames: [], texts: [], manuallyEdited: false)
    #expect(throws: AlbumEditError.unknownSpread) { try album.applying(.deleteSpread(id: "ghost")) }
    #expect(throws: AlbumEditError.unknownSpread) { try album.applying(.replaceSpread(ghost)) }
    #expect(throws: AlbumEditError.unknownSpread) { try album.applying(.restoreSpread(ghost)) }
    #expect(throws: AlbumEditError.unknownText) {
        try album.applying(.setText(spreadID: "s1", textID: "nope", text: "x"))
    }
}

@Test func setSelectedRecordsUserDecisionAndInverseRestoresBoth() throws {
    var original = makeAlbum()
    original.photos["p2"]?.isSelected = true
    original.photos["p2"]?.selectionDecidedByUser = true
    // p1 starts undecided and unselected, p2 decided and selected.
    for (id, value) in [("p1", true), ("p1", false), ("p2", false), ("p2", true)] {
        let before = original.photos[id]!
        let (edited, inverse) = try original.applying(.setSelected(id, value))
        #expect(edited.photos[id]?.isSelected == value)
        #expect(edited.photos[id]?.selectionDecidedByUser == true)
        #expect(inverse == .restorePhotoSelection(id, isSelected: before.isSelected,
                                                  decided: before.selectionDecidedByUser))
        let (restored, redo) = try edited.applying(inverse)
        #expect(restored == original)
        #expect(try restored.applying(redo).album == edited)
    }
    #expect(throws: AlbumEditError.unknownPhoto) {
        try original.applying(.restorePhotoSelection("nope", isSelected: true, decided: true))
    }
}
