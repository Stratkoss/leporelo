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
    let original = makeAlbum()
    var replacement = original.spreads[1]
    replacement.templateID = "t2"
    replacement.frames.removeLast()
    let extra = Spread(id: "s9", kind: .blank, templateID: "t0", dayKey: nil, frames: [], texts: [], manuallyEdited: false)

    let edits: [AlbumEdit] = [
        .setSelected("p1", true),
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

@Test func setFrameTransformClamps() throws {
    let (edited, _) = try makeAlbum().applying(
        .setFrameTransform(spreadID: "s1", frameID: "f1", offset: Point(x: 3, y: -3), zoom: 0.5))
    let frame = edited.spreads[0].frames[0]
    #expect(frame.zoom == 1)
    #expect(frame.offset == Point(x: 1, y: -1))
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
