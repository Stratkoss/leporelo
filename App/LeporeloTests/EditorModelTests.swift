import AppKit
import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private let day1 = DayKey(year: 2026, month: 6, day: 18)
private let day2 = DayKey(year: 2026, month: 6, day: 19)
private let day3 = DayKey(year: 2026, month: 6, day: 20)
/// Far from day3 in the calendar but its neighbour in the album.
private let day4 = DayKey(year: 2026, month: 6, day: 27)
private let lax = PageCountRule(min: 2, max: nil, multipleOf: 2)

private func photo(_ id: String, day: DayKey?, minute: Int, selected: Bool = true, landscape: Bool = true,
                   aesthetic: Double = 0.5, kind: PhotoKind = .photo, square: Bool = false) -> Photo {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let key = day ?? day1
    let date = calendar.date(from: DateComponents(year: key.year, month: key.month, day: key.day,
                                                  hour: 9, minute: minute))!
    return Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: date, timeZoneSeconds: 0, location: nil,
                 pixelWidth: square ? 3000 : landscape ? 4000 : 3000,
                 pixelHeight: square ? 3000 : landscape ? 3000 : 4000, kind: kind,
                 analysis: PhotoAnalysis(aesthetic: aesthetic, sharpness: 500, isUtility: false, faceRects: [],
                                         closedEyes: false, featurePrint: nil),
                 isSelected: selected, dayKey: day, placeName: nil, seriesID: nil,
                 originalState: .stored(relativePath: "originals/\(id).jpg"), deletedInSource: false)
}

/// `count` landscape photos of `day`, ids "<prefix>0"...; aesthetic varies so ranks are distinct.
private func dayPhotos(_ prefix: String, _ day: DayKey, count: Int, selected: Bool = true) -> [Photo] {
    (0..<count).map { photo("\(prefix)\($0)", day: day, minute: $0, selected: selected,
                            aesthetic: 0.3 + Double($0 % 5) * 0.1) }
}

private func makeAlbum(_ photos: [Photo]) -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "album-1", title: "Amalfi",
          supplierProfileID: "canva-photobook", formatID: "landscape-a4", world: Workflow.world,
          cover: nil, spreads: [], photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
          source: nil, createdAt: Date(timeIntervalSince1970: 1_000))
}

/// Canva A4 landscape with a lax page-count rule, so drafts are not padded.
private func laxGeometry() throws -> PageGeometry {
    var (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
    profile.pageCount = lax
    return PageGeometry(format: format, profile: profile)
}

private func drafted(_ album: Album) throws -> Album {
    let g = try laxGeometry()
    return Workflow.draft(album: album, profile: g.profile, format: g.format)
}

@MainActor
private func makeModel(_ album: Album) throws -> (EditorModel, AlbumStore, UndoManager) {
    let url = makeTempDir().appendingPathComponent("Editor.leporelo")
    let package = try ProjectPackage.create(at: url, album: album)
    let store = AlbumStore(album: album, package: package)
    let undo = UndoManager()
    undo.groupsByEvent = false
    let model = EditorModel(store: store, geometry: try laxGeometry())
    model.undoManager = undo
    return (model, store, undo)
}

/// One user action = one undo group (the manager does not group by event in tests).
@MainActor
private func step<T>(_ undo: UndoManager, _ body: () throws -> T) rethrows -> T {
    undo.beginUndoGrouping()
    defer { undo.endUndoGrouping() }
    return try body()
}

private func spread(_ album: Album, _ id: String) -> Spread? { album.spreads.first { $0.id == id } }

private func frameMap(_ s: Spread) -> [String: PhotoID] {
    Dictionary(uniqueKeysWithValues: s.frames.compactMap { f in f.photoID.map { (f.id, $0) } })
}

/// Two days as the drafter built them before page layouts (an old book of `TemplateCatalog`
/// spreads): day1 with 8 photos (journal-5, gallery-2, gallery-1), day2 with 4 (journal-4).
private func standardAlbum() throws -> Album {
    let g = try laxGeometry()
    var album = makeAlbum(dayPhotos("a", day1, count: 8) + dayPhotos("b", day2, count: 4))
    func make(_ templateID: String, _ id: String, _ day: DayKey?, _ photos: [PhotoID],
              _ texts: [TextRole: String]) throws -> Spread {
        let template = try #require(TemplateCatalog.template(id: templateID))
        var spread = TemplateLayout.instantiate(template, geometry: g, dayKey: day, id: id, marginMM: album.marginMM)
        let assignment = TemplateLayout.assign(template.frames, photos: photos.compactMap { album.photos[$0] })
        for i in spread.frames.indices { spread.frames[i].photoID = assignment[spread.frames[i].id] }
        for i in spread.texts.indices { spread.texts[i].text = texts[spread.texts[i].role] ?? "" }
        return spread
    }
    // The journal takes the day's best photos, the galleries the rest chronologically, 2 per spread.
    func journal(_ day: DayKey) -> [TextRole: String] {
        [.date: AlbumDrafter.czechDate(day), .title: AlbumDrafter.noPlaceTitle, .body: ""]
    }
    album.spreads = [
        try make("intro-1", "intro", nil, ["a4"], [.title: "Amalfi", .body: "18. 6. – 19. 6. 2026"]),
        try make("journal-5", "2026-06-18-journal", day1, ["a4", "a3", "a2", "a7", "a1"], journal(day1)),
        try make("gallery-2", "2026-06-18-gallery-1", day1, ["a0", "a5"], [:]),
        try make("gallery-1", "2026-06-18-gallery-2", day1, ["a6"], [:]),
        try make("journal-4", "2026-06-19-journal", day2, ["b0", "b1", "b2", "b3"], journal(day2)),
        try make("closing-1", "closing", nil, ["b3"], [:]),
    ]
    album.cover = AlbumDrafter.cover(title: album.title, photoID: "a4", format: g.format, profile: g.profile,
                                     marginMM: album.marginMM)
    return album
}

/// A book of page spreads: the legacy intro, then the gallery `pagesGalleryID` of day1 whose left
/// page is `left` holding the square photo "sq" and whose right page is `grid-4` with r0...r3.
private let pagesGalleryID = "2026-06-18-gallery-1"

private func pagesAlbum(left: String = "full") throws -> Album {
    let g = try laxGeometry()
    var album = makeAlbum([photo("sq", day: day1, minute: 50, square: true)] + dayPhotos("r", day1, count: 4))
    let intro = try #require(TemplateCatalog.template(id: "intro-1"))
    var introSpread = TemplateLayout.instantiate(intro, geometry: g, dayKey: nil, id: "intro", marginMM: album.marginMM)
    introSpread.frames[0].photoID = "r0"
    var gallery = PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: left)),
                                     right: try #require(PageLayoutCatalog.layout(id: "grid-4")),
                                     kind: .gallery, dayKey: day1, id: pagesGalleryID, geometry: g,
                                     marginMM: album.marginMM)
    let photos: [String: PhotoID] = ["L.photo1": "sq", "R.photo1": "r0", "R.photo2": "r1", "R.photo3": "r2",
                                     "R.photo4": "r3"]
    for i in gallery.frames.indices { gallery.frames[i].photoID = photos[gallery.frames[i].id] }
    album.spreads = [introSpread, gallery]
    return album
}

private func pageIDs(_ s: Spread?, _ side: PageSide, _ g: PageGeometry) -> [PhotoID] {
    s.map { PageEditing.photoIDs(on: side, of: $0, geometry: g) } ?? []
}

@MainActor
struct EditorModelTests {
    // MARK: Draft and redraft

    @Test func draftIfEmptyCreatesSpreads() throws {
        let album = makeAlbum(dayPhotos("a", day1, count: 8) + [photo("u", day: day1, minute: 30, selected: false)])
        let (model, store, undo) = try makeModel(album)
        #expect(model.currentSpreadID == nil)

        let didDraft = step(undo) { model.draftIfEmpty() }
        #expect(didDraft)
        #expect(!store.album.spreads.isEmpty)
        #expect(store.album == (try drafted(album)))
        #expect(store.album.photos == album.photos)  // the selection is drafted as it is
        #expect(undo.undoActionName == "Navrhnout album")
        #expect(model.currentSpreadID == store.album.spreads.first?.id)

        // Not empty any more: nothing happens.
        let before = store.album
        #expect(!model.draftIfEmpty())
        #expect(store.album == before)

        undo.undo()
        #expect(store.album.spreads.isEmpty)
        #expect(model.currentSpreadID == nil)
    }

    @Test func draftIfEmptyNeedsASelection() throws {
        let (model, store, undo) = try makeModel(makeAlbum(dayPhotos("a", day1, count: 3, selected: false)))
        #expect(!model.draftIfEmpty())
        #expect(store.album.spreads.isEmpty)
        #expect(!undo.canUndo)
    }

    @Test func redraftKeepsManualCountMatches() throws {
        var album = try standardAlbum()
        album.photos["extra"] = photo("extra", day: day1, minute: 40)
        let (model, store, undo) = try makeModel(album)
        #expect(model.redraftPreview() == 0)

        let gallery = try #require(store.album.spreads.first { $0.kind == .gallery })
        _ = step(undo) { model.dropPhoto("extra", onFrame: gallery.frames[0].id, in: gallery.id) }
        let manual = try #require(spread(store.album, gallery.id))
        #expect(manual.manuallyEdited)
        #expect(model.redraftPreview() == 1)
        let beforeRedraft = store.album

        let kept = step(undo) { model.redraft() }
        #expect(kept == 1)
        #expect(model.redraftPreview() == 1)  // the preview changes nothing; still one manual spread
        #expect(spread(store.album, gallery.id) == manual)
        #expect(undo.undoActionName == "Navrhnout znovu")
        let expected = AlbumUpdater.redraft(album: beforeRedraft, days: Workflow.days(of: beforeRedraft),
                                            profile: model.geometry.profile, format: model.geometry.format)
        #expect(store.album == expected.album)

        undo.undo()
        #expect(store.album == beforeRedraft)
    }

    @Test func changeFormatGeometryFollows() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        #expect(model.geometry.format.id == "landscape-a4")
        let before = store.album

        #expect(step(undo) { model.changeFormat(to: "square-21") })
        #expect(store.album.formatID == "square-21")
        #expect(model.geometry.format.id == "square-21")
        #expect(model.geometry.profile.pageCount == lax)  // the model's profile is kept
        #expect(undo.undoActionName == "Změnit formát")
        let size = model.geometry.spreadSize
        #expect(store.album.spreads.allSatisfy { s in s.frames.allSatisfy { $0.rect.maxX <= size.width + 1e-9 } })

        #expect(!model.changeFormat(to: "no-such-format"))
        #expect(!model.changeFormat(to: "square-21"))  // already

        undo.undo()
        #expect(store.album == before)
        #expect(model.geometry.format.id == "landscape-a4")
    }

    // MARK: Dropping photos

    @Test func dropPhotoReplacesAndMarksManual() throws {
        var album = try standardAlbum()
        album.photos["extra"] = photo("extra", day: day1, minute: 40)
        let (model, store, undo) = try makeModel(album)
        #expect(model.unplacedSelectedPhotos.map(\.id) == ["extra"])
        let gallery = try #require(store.album.spreads.first { $0.kind == .gallery && $0.dayKey == day1 })
        #expect(!gallery.manuallyEdited)
        let frameID = gallery.frames[0].id
        let old = try #require(gallery.frames[0].photoID)
        let before = store.album

        model.currentSpreadID = gallery.id
        #expect(step(undo) { model.dropPhoto("extra", onFrame: frameID) } == .placed)

        let after = try #require(spread(store.album, gallery.id))
        #expect(after.frames[0].photoID == "extra")
        #expect(after.frames[0].offset == Point(x: 0, y: 0) && after.frames[0].zoom == 1)
        #expect(after.manuallyEdited)
        #expect(undo.undoActionName == "Vložit fotku")
        // The replaced photo stays selected but is no longer in the album: tray and preflight show it.
        #expect(store.album.photos[old]?.isSelected == true)
        #expect(model.unplacedSelectedPhotos.map(\.id) == [old])
        #expect(model.placedPhotoIDs.contains("extra") && !model.placedPhotoIDs.contains(old))
        #expect(model.allIssues.contains { $0.id == "unplacedSelected" && $0.severity == .warning })

        undo.undo()
        #expect(store.album == before)
    }

    @Test func droppingAnUnselectedPhotoSelectsItInTheSameStep() throws {
        var album = try standardAlbum()
        album.photos["u"] = photo("u", day: day2, minute: 50, selected: false)
        let (model, store, undo) = try makeModel(album)
        let journal = try #require(store.album.spreads.first { $0.kind == .journal && $0.dayKey == day2 })
        let before = store.album

        #expect(step(undo) { model.dropPhoto("u", onFrame: journal.frames[1].id, in: journal.id) } == .placed)
        #expect(store.album.photos["u"]?.isSelected == true)
        #expect(store.album.photos["u"]?.selectionDecidedByUser == true)
        #expect(spread(store.album, journal.id)?.frames[1].photoID == "u")

        undo.undo()  // one step undoes the selection too
        #expect(store.album == before)
        #expect(!undo.canUndo)
    }

    @Test func dropWithinASpreadSwaps() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal && $0.dayKey == day1 })
        let a = try #require(journal.frames[0].photoID), b = try #require(journal.frames[2].photoID)
        let count = store.album.placedPhotoIDs.count
        step(undo) { model.nudge(frame: journal.frames[0].id, offset: Point(x: 0.4, y: 0), zoom: 1.5, in: journal.id) }

        #expect(step(undo) { model.dropPhoto(a, onFrame: journal.frames[2].id, in: journal.id) } == .placed)
        let after = try #require(spread(store.album, journal.id))
        #expect(after.frames[2].photoID == a)
        #expect(after.frames[0].photoID == b)
        // Like swap(): each crop stays with its photo.
        #expect(after.frames[2].zoom == 1.5 && after.frames[2].offset == Point(x: 0.4, y: 0))
        #expect(after.frames[0].zoom == 1 && after.frames[0].offset == Point(x: 0, y: 0))
        #expect(store.album.placedPhotoIDs.count == count)  // no duplicate, nothing lost
        #expect(undo.undoActionName == "Vložit fotku")
    }

    @Test func dropFromAnotherSpreadMovesThePhoto() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let source = try #require(store.album.spreads.first { $0.kind == .gallery && $0.dayKey == day1 })
        let target = try #require(store.album.spreads.first { $0.kind == .journal && $0.dayKey == day2 })
        let moved = try #require(source.frames[0].photoID)
        // A target frame whose photo is in no other spread (the closing repeats the last photo).
        let others = Set(store.album.spreads.filter { $0.id != target.id }.flatMap(\.frames).compactMap(\.photoID))
            .union(store.album.cover?.front.frames.compactMap(\.photoID) ?? [])
        let slot = try #require(target.frames.firstIndex { $0.photoID.map { !others.contains($0) } ?? false })
        let replaced = try #require(target.frames[slot].photoID)
        let before = store.album

        #expect(step(undo) {
            model.dropPhoto(moved, onFrame: target.frames[slot].id, in: target.id, duplicates: .move)
        } == .placed)
        #expect(undo.undoActionName == "Přesunout fotku")
        let s = try #require(spread(store.album, source.id)), t = try #require(spread(store.album, target.id))
        #expect(t.frames[slot].photoID == moved)
        #expect(s.frames[0].photoID == nil)  // emptied: preflight flags it
        #expect(s.manuallyEdited && t.manuallyEdited)
        #expect(store.album.spreads.flatMap(\.frames).filter { $0.photoID == moved }.count == 1)
        #expect(model.unplacedSelectedPhotos.map(\.id) == [replaced])
        #expect(model.issues(for: source.id).contains { $0.frameID == source.frames[0].id && $0.severity == .error })

        undo.undo()
        #expect(store.album == before)
    }

    @Test func dropRejectsVideosAndUnknownTargets() throws {
        var album = try standardAlbum()
        album.photos["v"] = photo("v", day: day1, minute: 55, kind: .video)
        let (model, store, undo) = try makeModel(album)
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        #expect(model.dropPhoto("v", onFrame: journal.frames[0].id, in: journal.id) == .rejected)
        #expect(model.dropPhoto("a0", onFrame: "nope", in: journal.id) == .rejected)
        #expect(model.dropPhoto("ghost", onFrame: journal.frames[0].id, in: journal.id) == .rejected)
        #expect(model.dropPhoto("a0", onFrame: journal.frames[0].id, in: "nope") == .rejected)
        #expect(!undo.canUndo)
    }

    /// Where `id` sits in the album: (spread id or cover side, frame id).
    private func occurrences(_ album: Album, _ id: PhotoID) -> [String] {
        let all = album.spreads + [album.cover?.front, album.cover?.back].compactMap { $0 }
        return all.flatMap { s in s.frames.filter { $0.photoID == id }.map { "\(s.id)/\($0.id)" } }
    }

    /// A photo placed exactly once in the whole album, in a spread of `kind` (and `day` if given).
    private func soloPhoto(_ album: Album, kind: SpreadKind, day: DayKey? = nil) throws -> (Spread, Int, PhotoID) {
        for s in album.spreads where s.kind == kind && (day == nil || s.dayKey == day) {
            for (i, f) in s.frames.enumerated() {
                if let id = f.photoID, occurrences(album, id).count == 1 { return (s, i, id) }
            }
        }
        throw TestFailure("no solo photo in a \(kind) spread")
    }

    private struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    /// A frame of a journal spread of `day2` whose own photo sits nowhere else.
    private func freeTargetFrame(_ album: Album) throws -> (Spread, Int) {
        let target = try #require(album.spreads.first { $0.kind == .journal && $0.dayKey == day2 })
        let slot = try #require(target.frames.indices.first { occurrences(album, target.frames[$0].photoID ?? "").count == 1 })
        return (target, slot)
    }

    @Test func dropOfPhotoPlacedElsewhereAsksAndChangesNothing() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let (source, _, moved) = try soloPhoto(store.album, kind: .gallery, day: day1)
        let (target, slot) = try freeTargetFrame(store.album)
        let index = try #require(store.album.spreads.firstIndex { $0.id == source.id })
        let before = store.album, revision = store.revision

        let outcome = model.dropPhoto(moved, onFrame: target.frames[slot].id, in: target.id)
        #expect(outcome == .needsDuplicateDecision(locations: ["dvoustrana \(index + 1)"]))
        #expect(store.revision == revision)
        #expect(store.album == before)
        #expect(!undo.canUndo)
    }

    @Test func dropKeepBothLeavesOtherFrame() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let (source, srcFrame, moved) = try soloPhoto(store.album, kind: .gallery, day: day1)
        let (target, slot) = try freeTargetFrame(store.album)
        let before = store.album

        let outcome = step(undo) {
            model.dropPhoto(moved, onFrame: target.frames[slot].id, in: target.id, duplicates: .keepBoth)
        }
        #expect(outcome == .placed)
        #expect(undo.undoActionName == "Vložit fotku")
        #expect(spread(store.album, target.id)?.frames[slot].photoID == moved)
        #expect(spread(store.album, source.id)?.frames[srcFrame].photoID == moved)
        #expect(spread(store.album, source.id) == source)  // untouched, not even marked manual
        #expect(occurrences(store.album, moved).count == 2)

        undo.undo()
        #expect(store.album == before)
    }

    @Test func dropMoveClearsOtherFramesAsOneUndoStep() throws {
        var album = try standardAlbum()
        let (_, _, moved) = try soloPhoto(album, kind: .gallery, day: day1)
        // Put the same photo on the cover as well: both places are emptied.
        var cover = try #require(album.cover)
        cover.front.frames[0].photoID = moved
        cover.front.frames[0].zoom = 1.7
        album.cover = cover
        let (model, store, undo) = try makeModel(album)
        let (target, slot) = try freeTargetFrame(store.album)
        let before = store.album
        try #require(occurrences(before, moved).count == 2)

        let outcome = step(undo) {
            model.dropPhoto(moved, onFrame: target.frames[slot].id, in: target.id, duplicates: .move)
        }
        #expect(outcome == .placed)
        #expect(undo.undoActionName == "Přesunout fotku")
        #expect(occurrences(store.album, moved) == ["\(target.id)/\(target.frames[slot].id)"])
        #expect(store.album.cover?.front.frames[0].photoID == nil)
        #expect(store.album.cover?.front.frames[0].zoom == 1)
        #expect(store.album.spreads.filter { $0.id != target.id }.allSatisfy { s in
            s.frames.allSatisfy { $0.photoID != moved }
        })

        undo.undo()  // one undo brings back both the spread and the cover
        #expect(store.album == before)
        #expect(!undo.canUndo)
    }

    @Test func dropFromIntroOntoDaySpreadAsks() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let intro = try #require(store.album.spreads.first { $0.kind == .intro })
        let id = try #require(intro.frames.compactMap(\.photoID).first)
        // A day-spread frame that does not hold this photo.
        let target = try #require(store.album.spreads.first { $0.kind == .journal && !$0.frames.contains { $0.photoID == id } })
        let before = store.album

        let outcome = model.dropPhoto(id, onFrame: target.frames[0].id, in: target.id)
        guard case let .needsDuplicateDecision(locations) = outcome else {
            Issue.record("expected a decision, got \(outcome)"); return
        }
        let introNumber = try #require(store.album.spreads.firstIndex { $0.id == intro.id }) + 1
        #expect(locations.contains("dvoustrana \(introNumber)"))
        #expect(store.album == before)
    }

    @Test func dropOfCoverPhotoListsObalka() throws {
        var album = try standardAlbum()
        let (_, _, solo) = try soloPhoto(album, kind: .journal, day: day1)
        var cover = try #require(album.cover)
        cover.back.frames = cover.front.frames  // both sides hold a photo
        cover.front.frames[0].photoID = solo
        cover.back.frames[0].photoID = solo
        album.cover = cover
        let (model, store, _) = try makeModel(album)
        let (target, slot) = try freeTargetFrame(store.album)
        let spreadNumber = try #require(store.album.spreads.firstIndex { $0.frames.contains { $0.photoID == solo } }) + 1

        let outcome = model.dropPhoto(solo, onFrame: target.frames[slot].id, in: target.id)
        // The cover is listed once, after the spreads, although both its sides hold the photo.
        #expect(outcome == .needsDuplicateDecision(locations: ["dvoustrana \(spreadNumber)", "obálka"]))
        #expect(model.placementLabels(of: solo, excludingSpread: target.id) == ["dvoustrana \(spreadNumber)", "obálka"])
        #expect(model.placementLabels(of: "ghost", excludingSpread: target.id).isEmpty)
    }

    @Test func dropWithinSameSpreadStillSwaps() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal && $0.dayKey == day1 })
        let a = try #require(journal.frames[0].photoID)
        let b = try #require(journal.frames[1].photoID)
        let before = store.album, revision = store.revision

        // Even with .ask no question: the photo is only moving inside its spread.
        #expect(step(undo) { model.dropPhoto(a, onFrame: journal.frames[1].id, in: journal.id) } == .placed)
        #expect(store.revision != revision)
        let after = try #require(spread(store.album, journal.id))
        #expect(after.frames[1].photoID == a && after.frames[0].photoID == b)
        undo.undo()
        #expect(store.album == before)
    }

    @Test func dropOnTheSameFrameIsRejectedAndMoveWithoutDuplicatesIsAPlainInsert() throws {
        var album = try standardAlbum()
        album.photos["extra"] = photo("extra", day: day1, minute: 41)
        let (model, store, undo) = try makeModel(album)
        let gallery = try #require(store.album.spreads.first { $0.kind == .gallery && $0.dayKey == day1 })
        let own = try #require(gallery.frames[0].photoID)
        #expect(model.dropPhoto(own, onFrame: gallery.frames[0].id, in: gallery.id, duplicates: .move) == .rejected)
        #expect(!undo.canUndo)

        #expect(step(undo) { model.dropPhoto("extra", onFrame: gallery.frames[0].id, in: gallery.id, duplicates: .move) } == .placed)
        #expect(undo.undoActionName == "Vložit fotku")
    }

    @Test func swapExchangesPhotosWithTheirCrop() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal && $0.dayKey == day1 })
        model.currentSpreadID = journal.id
        step(undo) { model.nudge(frame: journal.frames[0].id, offset: Point(x: 0.4, y: 0), zoom: 1.5) }
        step(undo) { model.swap(frameA: journal.frames[0].id, frameB: journal.frames[1].id) }
        let after = try #require(spread(store.album, journal.id))
        #expect(after.frames[0].photoID == journal.frames[1].photoID)
        #expect(after.frames[1].photoID == journal.frames[0].photoID)
        #expect(after.frames[1].zoom == 1.5)  // the crop follows the photo
        #expect(after.frames[0].zoom == 1)
        #expect(undo.undoActionName == "Prohodit fotky")
    }

    // MARK: Tray

    @Test func trayContainsAdjacentDays() throws {
        var photos = dayPhotos("a", day1, count: 3) + dayPhotos("b", day2, count: 3)
        photos += dayPhotos("c", day3, count: 3) + dayPhotos("d", day4, count: 3)
        photos += [photo("b-off", day: day2, minute: 1, selected: false),
                   photo("c-off", day: day3, minute: 0, selected: false),
                   photo("c-video", day: day3, minute: 2, selected: false, kind: .video),
                   photo("a-off", day: day1, minute: 5, selected: false)]
        let (model, store, _) = try makeModel(try drafted(makeAlbum(photos)))

        model.trayDay = day3
        let ids = model.trayPhotos.map(\.id)
        // day2, day3 and day4 (the neighbour in the album, a week later in the calendar), not day1.
        #expect(Set(ids) == ["b0", "b1", "b2", "b-off", "c0", "c1", "c2", "c-off", "d0", "d1", "d2"])
        // Selected first, then chronological.
        #expect(ids == ["b0", "b1", "b2", "c0", "c1", "c2", "d0", "d1", "d2", "b-off", "c-off"])

        model.trayDay = day1
        #expect(Set(model.trayPhotos.map(\.id)) == ["a0", "a1", "a2", "a-off", "b0", "b1", "b2", "b-off"])

        model.trayShowsAll = true
        #expect(model.trayPhotos.map(\.id) == store.album.selectedPhotos.map(\.id))
        #expect(!model.trayPhotos.contains { !$0.isSelected })
        #expect(model.placedPhotoIDs == store.album.placedPhotoIDs)
    }

    @Test func trayExcludesVideosEvenWhenSelected() throws {
        var photos = dayPhotos("a", day1, count: 3) + dayPhotos("b", day2, count: 3)
        photos += [photo("a-vid", day: day1, minute: 9, selected: true, kind: .video),
                   photo("b-vid", day: day2, minute: 9, selected: false, kind: .video)]
        let (model, _, _) = try makeModel(try drafted(makeAlbum(photos)))
        model.trayDay = day1
        #expect(!model.trayPhotos.contains { $0.kind == .video })
        #expect(Set(model.trayPhotos.map(\.id)) == ["a0", "a1", "a2", "b0", "b1", "b2"])
        model.trayShowsAll = true
        #expect(!model.trayPhotos.contains { $0.kind == .video })
    }

    @Test func trayDayFollowsTheCurrentSpread() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let june19 = try #require(store.album.spreads.first { $0.dayKey == day2 })
        model.currentSpreadID = june19.id
        #expect(model.trayDay == day2)
        model.trayDay = day1
        #expect(model.trayDay == day1)
        // Choosing another spread resets the tray to that spread's day.
        model.currentSpreadID = june19.id
        #expect(model.trayDay == day2)
        // Intro has no day: the first day.
        model.currentSpreadID = store.album.spreads.first { $0.kind == .intro }?.id
        #expect(model.trayDay == day1)
    }

    // MARK: Templates

    @Test func changeTemplateKeepsPhotosInOrder() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        let before = store.album
        let photos = gallery.frames.compactMap(\.photoID).compactMap { store.album.photos[$0] }
        let target = try #require(TemplateCatalog.template(id: "gallery-3"))
        #expect(model.availableTemplates(for: gallery.id).map(\.id).contains("gallery-3"))

        let outcome = step(undo) { model.changeTemplate(to: "gallery-3") }
        #expect(outcome == .applied(unplacedPhotoIDs: []))
        let after = try #require(spread(store.album, gallery.id))
        #expect(after.templateID == "gallery-3")
        #expect(after.dayKey == gallery.dayKey)
        #expect(after.manuallyEdited)
        #expect(frameMap(after) == TemplateLayout.assign(target.frames, photos: photos))
        #expect(after.frames.filter { $0.photoID == nil }.count == 1)
        #expect(after.texts.first { $0.role == .caption }?.text == gallery.texts.first { $0.role == .caption }?.text)
        #expect(undo.undoActionName == "Použít doporučené rozložení")

        undo.undo()
        #expect(store.album == before)
    }

    @Test func changeTemplateAsksBeforeLosingTextAndReportsUnplaced() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })
        let before = store.album

        let refused = model.changeTemplate(to: "gallery-2", in: journal.id)
        guard case .needsTextLossConfirmation(let texts) = refused else {
            Issue.record("expected a confirmation, got \(refused)")
            return
        }
        #expect(texts.map(\.role) == [.date, .title])  // the empty body is not content
        #expect(store.album == before)

        let applied = step(undo) { model.changeTemplate(to: "gallery-2", in: journal.id, confirmTextLoss: true) }
        guard case .applied(let unplaced) = applied else {
            Issue.record("expected applied, got \(applied)")
            return
        }
        #expect(unplaced.count == 3)
        #expect(spread(store.album, journal.id)?.kind == .gallery)
        #expect(Set(model.unplacedSelectedPhotos.map(\.id)) == Set(unplaced))
        #expect(unplaced.allSatisfy { store.album.photos[$0]?.isSelected == true })

        #expect(model.changeTemplate(to: "no-such-template", in: journal.id) == .unavailable)
        #expect(model.changeTemplate(to: "intro-1", in: journal.id) == .unavailable)  // not offered
    }

    @Test func availableTemplatesSwitchBetweenGalleryAndJournalOnly() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.kind == .gallery })
        let ids = model.availableTemplates(for: gallery.id).map(\.id)
        #expect(Set(ids) == Set(TemplateCatalog.all.filter { $0.kind == .gallery || $0.kind == .journal }.map(\.id)))
        let intro = try #require(store.album.spreads.first { $0.kind == .intro })
        #expect(model.availableTemplates(for: intro.id).map(\.id) == ["intro-1"])
        #expect(model.availableTemplates(for: "nope").isEmpty)
    }

    // MARK: Text and crop coalescing

    @Test func textEditsCoalesceIntoOneStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        let revision = store.revision

        step(undo) {
            model.beginTextEditing("body", in: journal.id)
            model.updateText("D")
            model.updateText("Dn")
            model.updateText("Dnes jsme byli v Ravellu")
            // Live preview, nothing stored yet.
            #expect(model.displayedSpread(journal.id)?.texts.first { $0.id == "body" }?.text == "Dnes jsme byli v Ravellu")
            #expect(store.revision == revision)
            model.endTextEditing()
        }
        #expect(store.revision == revision + 1)  // one change for the whole session
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "Dnes jsme byli v Ravellu")
        #expect(undo.undoActionName == "Upravit text")

        undo.undo()
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "")
        #expect(!undo.canUndo)

        // A session that ends with the original text stores nothing.
        model.beginTextEditing("body", in: journal.id)
        model.updateText("x")
        model.updateText("")
        model.endTextEditing()
        #expect(!undo.canUndo)

        // Direct setText is one step.
        step(undo) { model.setText("title", "Ravello", in: journal.id) }
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "title" }?.text == "Ravello")
    }

    @Test func switchingSpreadsCommitsAPendingTextEdit() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        step(undo) {
            model.beginTextEditing("body", in: journal.id)
            model.updateText("Pláž")
            model.nextSpread()
        }
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "Pláž")
        #expect(!model.isEditingText)
    }

    @Test func transformGestureCoalescesIntoOneStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        let frameID = journal.frames[0].id
        model.currentSpreadID = journal.id
        let revision = store.revision

        step(undo) {
            model.beginTransform(frame: frameID)
            model.nudge(frame: frameID, offset: Point(x: 0.1, y: 0), zoom: 1.1)
            model.nudge(frame: frameID, offset: Point(x: 0.5, y: -0.2), zoom: 1.6)
            model.nudge(frame: frameID, offset: Point(x: 3, y: -0.2), zoom: 0.5)  // clamped
            #expect(model.displayedSpread(journal.id)?.frames[0].offset == Point(x: 1, y: -0.2))
            #expect(model.displayedSpread(journal.id)?.frames[0].zoom == 1)
            #expect(store.revision == revision)
            model.nudge(frame: frameID, offset: Point(x: 0.3, y: -0.2), zoom: 1.4)
            model.endTransform()
        }
        #expect(store.revision == revision + 1)
        let after = try #require(spread(store.album, journal.id))
        #expect(after.frames[0].offset == Point(x: 0.3, y: -0.2))
        #expect(after.frames[0].zoom == 1.4)
        #expect(undo.undoActionName == "Posunout fotku")
        undo.undo()
        #expect(spread(store.album, journal.id) == journal)

        // Outside a gesture a nudge (e.g. arrow keys) is its own step.
        step(undo) { model.nudge(frame: frameID, offset: Point(x: -0.5, y: 0), zoom: 1) }
        #expect(spread(store.album, journal.id)?.frames[0].offset == Point(x: -0.5, y: 0))
        #expect(undo.undoActionName == "Posunout fotku")
    }

    // MARK: Spreads

    @Test func insertDeleteMoveSpreadAreUndoable() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let before = store.album
        let journal = try #require(store.album.spreads.first { $0.kind == .journal && $0.dayKey == day2 })
        let journalIndex = try #require(model.spreadIndex(of: journal.id))

        let id = try #require(step(undo) { model.insertSpread(kind: .gallery, after: journal.id) })
        #expect(id == "manual-1")
        #expect(model.spreadIndex(of: id) == journalIndex + 1)
        let inserted = try #require(spread(store.album, id))
        #expect(inserted.templateID == PageSpread.templateID && inserted.dayKey == day2)
        #expect(inserted.frames.allSatisfy { $0.photoID == nil })
        #expect(inserted.manuallyEdited)  // user work survives "Navrhnout znovu"
        #expect(model.currentSpreadID == id)
        #expect(undo.undoActionName == "Přidat dvoustranu")
        #expect(model.issues(for: id).contains { $0.id.hasPrefix("emptyFrame") })

        // nil = at the end, before the closing spread.
        let second = try #require(step(undo) { model.insertSpread(kind: .blank, after: nil) })
        #expect(second == "manual-2")
        #expect(store.album.spreads.last?.kind == .closing)
        #expect(store.album.spreads[store.album.spreads.count - 2].id == second)

        step(undo) { model.moveSpread(second, to: 1) }
        #expect(model.spreadIndex(of: second) == 1)
        #expect(undo.undoActionName == "Přesunout dvoustranu")

        step(undo) { model.deleteSpread(id) }
        #expect(spread(store.album, id) == nil)
        #expect(undo.undoActionName == "Smazat dvoustranu")

        undo.undo(); undo.undo(); undo.undo(); undo.undo()
        #expect(store.album == before)
    }

    @Test func deletingASpreadLeavesItsPhotosSelectedButUnplaced() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        let ids = gallery.frames.compactMap(\.photoID)
        step(undo) { model.deleteSpread(gallery.id) }
        #expect(Set(model.unplacedSelectedPhotos.map(\.id)) == Set(ids))
        #expect(ids.allSatisfy { store.album.photos[$0]?.isSelected == true })
    }

    // MARK: Navigation

    @Test func currentSpreadSurvivesDeleteAndUndo() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        #expect(model.currentSpreadID == store.album.spreads.first?.id)
        let index = 2
        let target = store.album.spreads[index].id
        let next = store.album.spreads[index + 1].id
        model.currentSpreadID = target
        model.selectedFrameID = store.album.spreads[index].frames.first?.id
        #expect(model.selectedFrameID != nil)

        step(undo) { model.deleteSpread(target) }
        #expect(model.currentSpreadID == next)  // the nearest remaining spread
        #expect(model.selectedFrameID == nil)
        undo.undo()
        #expect(model.currentSpreadID == target)

        // Deleting the last spread falls back to the new last one.
        let last = try #require(store.album.spreads.last?.id)
        let beforeLast = store.album.spreads[store.album.spreads.count - 2].id
        model.currentSpreadID = last
        step(undo) { model.deleteSpread(last) }
        #expect(model.currentSpreadID == beforeLast)
    }

    @Test func selectedFrameClearsWhenItsFrameDisappears() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        model.selectedFrameID = "photo2"
        #expect(model.selectedFrameID == "photo2")
        _ = step(undo) { model.changeTemplate(to: "gallery-1") }
        #expect(model.selectedFrameID == nil)
        model.selectedFrameID = "nope"
        #expect(model.selectedFrameID == nil)
    }

    /// Final fix wave A6: choosing a spread (the export's "Dvoustrana N" jump) leaves the cover.
    @Test func choosingASpreadLeavesTheCover() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let ids = store.album.spreads.map(\.id)
        model.coverSide = .front
        #expect(model.coverSide == .front)
        model.currentSpreadID = ids[2]
        #expect(model.coverSide == nil)
        #expect(model.currentSpreadID == ids[2])
        model.coverSide = .back
        model.currentSpreadID = ids[2]  // the same spread again
        #expect(model.coverSide == nil)
    }

    @Test func nextAndPreviousStopAtTheEnds() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let ids = store.album.spreads.map(\.id)
        model.previousSpread()
        #expect(model.currentSpreadID == ids[0])
        model.nextSpread()
        #expect(model.currentSpreadID == ids[1])
        #expect(model.spreadIndex(of: ids[1]) == 1)
        model.currentSpreadID = ids.last
        model.nextSpread()
        #expect(model.currentSpreadID == ids.last)
        model.previousSpread()
        #expect(model.currentSpreadID == ids[ids.count - 2])
        #expect(model.spreadIndex(of: "nope") == nil)
    }

    // MARK: Preflight

    @Test func issuesAreThePreflightOfTheSpread() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.kind == .gallery })
        step(undo) { _ = model.changeTemplate(to: "gallery-3", in: gallery.id) }
        let g = model.geometry
        let all = Preflight.check(album: store.album, profile: g.profile, format: g.format)
        #expect(model.allIssues == all)
        #expect(model.issues(for: gallery.id) == all.filter { $0.spreadID == gallery.id })
        #expect(model.issues(for: gallery.id).contains { $0.id.hasPrefix("emptyFrame") })
        undo.undo()
        #expect(!model.issues(for: gallery.id).contains { $0.id.hasPrefix("emptyFrame") })
    }

    // MARK: Fix round 1: templates and spread order

    @Test func changeTemplateToTheCurrentTemplateIsANoOp() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        let before = store.album
        let outcome = model.changeTemplate(to: "gallery-2", in: gallery.id)
        #expect(outcome == .applied(unplacedPhotoIDs: []))
        #expect(store.album == before)
        #expect(spread(store.album, gallery.id)?.manuallyEdited == false)
        #expect(!undo.canUndo)
    }

    @Test func introStaysFirstAndClosingStaysLast() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let ids = store.album.spreads.map(\.id)
        #expect(ids.first == "intro" && ids.last == "closing")
        let count = ids.count

        // Intro and closing do not move.
        model.moveSpread("intro", to: 3)
        model.moveSpread("closing", to: 0)
        #expect(store.album.spreads.map(\.id) == ids)
        #expect(!undo.canUndo)

        // Others are clamped between them.
        step(undo) { model.moveSpread(ids[2], to: 0) }
        #expect(model.spreadIndex(of: ids[2]) == 1)
        step(undo) { model.moveSpread(ids[2], to: 99) }
        #expect(model.spreadIndex(of: ids[2]) == count - 2)
        #expect(store.album.spreads.first?.id == "intro" && store.album.spreads.last?.id == "closing")

        // Inserting after the closing inserts before it.
        let id = try #require(step(undo) { model.insertSpread(kind: .blank, after: "closing") })
        #expect(store.album.spreads.last?.id == "closing")
        #expect(model.spreadIndex(of: id) == store.album.spreads.count - 2)
    }
}

/// Fix round 1: editing sessions must never lose text, never merge with another action's undo
/// step, and must reach the store (and so the autosave snapshot) without waiting for their end.
@MainActor
struct EditorSessionTests {
    private func body(_ store: AlbumStore, _ id: String) -> String? {
        spread(store.album, id)?.texts.first { $0.id == "body" }?.text
    }

    private func title(_ store: AlbumStore, _ id: String) -> String? {
        spread(store.album, id)?.texts.first { $0.id == "title" }?.text
    }

    /// Lets the run loop end the current event, which closes the undo manager's event group.
    private func endEvent() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func undoDuringATextSessionUndoesTheSession() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        step(undo) { model.setText("title", "Ravello", in: journal.id) }

        model.beginTextEditing("body", in: journal.id)
        model.updateText("Pláž")
        model.undo()
        #expect(!model.isEditingText)
        #expect(body(store, journal.id) == "")  // the session, not the edit before it
        #expect(title(store, journal.id) == "Ravello")
        #expect(model.displayedSpread(journal.id)?.texts.first { $0.id == "body" }?.text == "")
        #expect(undo.canRedo)

        model.redo()
        #expect(body(store, journal.id) == "Pláž")
        model.undo()
        model.undo()
        #expect(title(store, journal.id) == AlbumDrafter.noPlaceTitle)
        #expect(!undo.canUndo)
    }

    @Test func aSessionEndedByAnotherActionIsItsOwnStep() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let undo = UndoManager()  // groups by event, like the window's
        model.undoManager = undo
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })

        model.beginTextEditing("body", in: journal.id)
        model.updateText("Pláž")
        // A toolbar action while the text field still has focus, in the same event.
        _ = model.changeTemplate(to: "journal-4", in: journal.id)
        endEvent()
        #expect(spread(store.album, journal.id)?.templateID == "journal-4")
        #expect(undo.undoActionName == "Použít doporučené rozložení")

        model.undo()
        endEvent()
        #expect(spread(store.album, journal.id)?.templateID == "journal-5")
        #expect(body(store, journal.id) == "Pláž")  // one Undo reverts only the action
        #expect(undo.undoActionName == "Upravit text")

        model.undo()
        endEvent()
        #expect(body(store, journal.id) == "")
        #expect(!undo.canUndo)
    }

    @Test func anEditEarlierInTheSameEventStaysItsOwnStepToo() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let undo = UndoManager()
        model.undoManager = undo
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })

        model.setText("title", "Ravello", in: journal.id)  // opens the event's undo group
        model.beginTextEditing("body", in: journal.id)
        model.updateText("Pláž")
        _ = model.changeTemplate(to: "journal-4", in: journal.id)
        endEvent()

        model.undo(); endEvent()
        #expect(spread(store.album, journal.id)?.templateID == "journal-5")
        #expect(body(store, journal.id) == "Pláž" && title(store, journal.id) == "Ravello")
        model.undo(); endEvent()
        #expect(body(store, journal.id) == "" && title(store, journal.id) == "Ravello")
        model.undo(); endEvent()
        #expect(title(store, journal.id) == AlbumDrafter.noPlaceTitle)
        #expect(!undo.canUndo)
    }

    @Test func textReachesTheStoreWithinTheDebounceAsOneStep() async throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        model.textCommitDelay = .milliseconds(30)
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })

        model.beginTextEditing("body", in: journal.id)
        model.updateText("Pl")
        try await Task.sleep(for: .milliseconds(200))
        #expect(body(store, journal.id) == "Pl")  // visible to the autosave snapshot
        model.updateText("Pláž")
        try await Task.sleep(for: .milliseconds(200))
        #expect(body(store, journal.id) == "Pláž")
        #expect(model.isEditingText)
        model.endTextEditing()

        #expect(undo.undoActionName == "Upravit text")
        undo.undo()  // the whole session is one step
        #expect(body(store, journal.id) == "")
        #expect(!undo.canUndo)
        undo.redo()
        #expect(body(store, journal.id) == "Pláž")
    }

    @Test func storeFlushCommitsTheSession() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.beginTextEditing("body", in: journal.id)
        model.updateText("Pláž")
        store.flushPendingEdits()
        #expect(body(store, journal.id) == "Pláž")
        #expect(!model.isEditingText)
        #expect(undo.undoActionName == "Upravit text")

        // A crop gesture too.
        model.beginTransform(frame: journal.frames[0].id, in: journal.id)
        model.nudge(frame: journal.frames[0].id, offset: Point(x: 0.5, y: 0), zoom: 2)
        store.flushPendingEdits()
        #expect(spread(store.album, journal.id)?.frames[0].zoom == 2)
    }

    @Test func closingTheSessionFlushesTheEditor() throws {
        let album = try standardAlbum()
        let url = makeTempDir().appendingPathComponent("Close.leporelo")
        _ = try ProjectPackage.create(at: url, album: album)
        let session = AlbumSession(placeResolver: { InMemoryPlaceResolver([]) })
        let document = try AlbumDocument(file: FileWrapper(url: url, options: []))
        session.bind(document: document, fileURL: url, sourceProvider: { _ in FakePhotoSource() })
        let store = try #require(session.store)
        let model = EditorModel(store: store, geometry: try laxGeometry())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })

        model.beginTextEditing("body", in: journal.id)
        model.updateText("Pláž")
        session.close()  // window closes (also runs before every rebind)
        #expect(body(store, journal.id) == "Pláž")
        #expect(document.currentAlbum == store.album)
    }
}

/// Model pieces the editor views (21b) need.
@MainActor
struct EditorViewSupportTests {
    @Test func clearFrameEmptiesTheFrameAsOneUndoableStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        let frame = journal.frames[1]
        let photoID = try #require(frame.photoID)
        step(undo) { model.nudge(frame: frame.id, offset: Point(x: 0.4, y: 0), zoom: 2) }

        #expect(step(undo) { model.clearFrame(frame.id) })
        let after = try #require(spread(store.album, journal.id))
        #expect(after.frames[1].photoID == nil)
        #expect(after.frames[1].zoom == 1 && after.frames[1].offset == Point(x: 0, y: 0))
        #expect(after.manuallyEdited)
        #expect(store.album.photos[photoID]?.isSelected == true)  // selected but unplaced
        #expect(model.unplacedSelectedPhotos.map(\.id).contains(photoID))
        #expect(undo.undoActionName == "Odebrat fotku")

        // An empty frame: nothing to do, no step.
        let revision = store.revision
        #expect(!model.clearFrame(frame.id))
        #expect(store.revision == revision)

        undo.undo()
        #expect(spread(store.album, journal.id)?.frames[1].photoID == photoID)
        #expect(spread(store.album, journal.id)?.frames[1].zoom == 2)
    }

    @Test func resetCropIsOneStepAndANoOpWhenAlreadyReset() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        let frameID = journal.frames[0].id
        let revision = store.revision
        #expect(!model.resetCrop(frame: frameID))
        #expect(store.revision == revision)

        step(undo) { model.nudge(frame: frameID, offset: Point(x: -0.5, y: 0.2), zoom: 1.8) }
        #expect(step(undo) { model.resetCrop(frame: frameID) })
        #expect(spread(store.album, journal.id)?.frames[0].offset == Point(x: 0, y: 0))
        #expect(spread(store.album, journal.id)?.frames[0].zoom == 1)
        #expect(undo.undoActionName == "Obnovit výřez")
        undo.undo()
        #expect(spread(store.album, journal.id)?.frames[0].zoom == 1.8)
    }

    @Test func pendingSessionIsReported() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        #expect(!model.hasPendingSession)
        model.beginTransform(frame: journal.frames[0].id)
        #expect(model.hasPendingSession && model.isTransforming)
        model.endTransform()
        #expect(!model.hasPendingSession)
        model.beginTextEditing("body")
        #expect(model.hasPendingSession)
        model.commitSessions()
        #expect(!model.hasPendingSession)
    }

    @Test func updateTextOutsideASessionIsIgnoredUntilEditingBeginsAgain() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        model.beginTextEditing("body")
        model.updateText("Pláž")
        model.undo()  // commits the session, then undoes it
        model.updateText("Pláž a moře")  // the overlay must begin again first
        #expect(!model.isEditingText)
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "")
        model.beginTextEditing("body")
        model.updateText("Pláž a moře")
        model.endTextEditing()
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "Pláž a moře")
        #expect(undo.undoActionName == "Upravit text")
    }

    @Test func pendingSessionActionNameNeedsChanges() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        model.beginTextEditing("body")
        #expect(model.pendingSessionActionName == nil)  // open, unchanged
        model.updateText("Pláž")
        #expect(model.pendingSessionActionName == "Upravit text")
        model.updateText("")  // back to the stored text
        #expect(model.pendingSessionActionName == nil)
        model.endTextEditing()

        let frame = journal.frames[0]
        model.beginTransform(frame: frame.id)
        #expect(model.pendingSessionActionName == nil)
        model.nudge(frame: frame.id, offset: Point(x: 0.3, y: 0), zoom: 1.2)
        #expect(model.pendingSessionActionName == "Posunout fotku")
        model.endTransform()
        #expect(model.pendingSessionActionName == nil)
    }

    /// The canvas passes its page's spread id: edits land there even while the model's current
    /// spread is another one (frame ids repeat across spreads).
    @Test func canvasEditsTargetTheGivenSpread() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journals = store.album.spreads.filter { $0.kind == .journal }
        try #require(journals.count == 2)
        let page = journals[0], other = journals[1]
        model.currentSpreadID = other.id
        let frameID = "photo1"
        try #require(page.frames.contains { $0.id == frameID } && other.frames.contains { $0.id == frameID })

        step(undo) {
            model.beginTransform(frame: frameID, in: page.id)
            model.nudge(frame: frameID, offset: Point(x: 0.5, y: 0), zoom: 1.5, in: page.id)
            model.endTransform()
        }
        #expect(spread(store.album, page.id)?.frames.first { $0.id == frameID }?.zoom == 1.5)
        #expect(spread(store.album, other.id) == other)

        #expect(step(undo) { model.resetCrop(frame: frameID, in: page.id) })
        #expect(spread(store.album, page.id)?.frames.first { $0.id == frameID }?.zoom == 1)

        let incoming = try #require(other.frames.first { $0.id == "photo2" }?.photoID)
        #expect(step(undo) { model.dropPhoto(incoming, onFrame: frameID, in: page.id, duplicates: .move) } == .placed)
        #expect(spread(store.album, page.id)?.frames.first { $0.id == frameID }?.photoID == incoming)

        #expect(step(undo) { model.clearFrame(frameID, in: page.id) })
        #expect(spread(store.album, page.id)?.frames.first { $0.id == frameID }?.photoID == nil)
        #expect(spread(store.album, other.id)?.frames.first { $0.id == frameID }?.photoID
                == other.frames.first { $0.id == frameID }?.photoID)
        #expect(model.currentSpreadID == other.id)
    }

    /// Edit > Undo/Redo per route (`AlbumUndoTarget`, the window's published target).
    @Test func undoTargetTitlesAndRoutes() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        step(undo) { model.setText("title", "Ravello") }

        let target = AlbumUndoTarget()
        target.focus = { nil }
        target.editor = model
        target.store = store
        target.undoManager = undo
        target.mode = .editor
        #expect(target.route == .editor)
        #expect(target.undoItem == UndoMenuItem(title: "Odvolat: Upravit text", isEnabled: true))

        // An open but unchanged overlay: ⌘Z undoes the previous step, and the title says so.
        _ = step(undo) { model.insertSpread(kind: .blank, after: journal.id) }
        model.currentSpreadID = journal.id
        model.beginTextEditing("body")
        #expect(target.undoItem.title == "Odvolat: Přidat dvoustranu")
        model.updateText("Pláž")
        #expect(target.undoItem.title == "Odvolat: Upravit text")
        target.undo()  // commits the session, then undoes it
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "")
        #expect(target.redoItem.title == "Znovu: Upravit text")
        target.redo()
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "Pláž")

        // Triage: the window's manager, still enabled.
        target.mode = .triage
        #expect(target.route == .window)
        #expect(target.undoItem == UndoMenuItem(title: "Odvolat: Upravit text", isEnabled: true))
        target.undo()
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "body" }?.text == "")

        // A sheet of the window is key ("Nové album…", export): the responder chain, plain title,
        // and ⌘Z does not touch the album.
        target.mode = .editor
        target.focus = { UndoFocus(keyWindowIsSheet: true, text: .other) }
        #expect(target.route == .responderChain)
        #expect(target.undoItem == UndoMenuItem(title: "Odvolat", isEnabled: true))
        let before = store.album
        target.undo()
        #expect(store.album == before)
        target.focus = { UndoFocus(keyWindowIsSheet: false, text: .canvasOverlay) }
        #expect(target.route == .editor)

        // Without an undo manager or an editor: the responder chain.
        let bare = AlbumUndoTarget()
        #expect(bare.route == .responderChain)
        #expect(bare.undoItem == UndoMenuItem(title: "Odvolat", isEnabled: true))
    }

    /// Final fix wave A2: the text overlay scrolls when its text is longer than the box.
    @Test func textOverlayScrollsLongText() {
        let (scroll, text) = SpreadCanvasNSView.makeTextOverlay(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        #expect(scroll.documentView === text)
        #expect(scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(text.isVerticallyResizable && !text.isHorizontallyResizable)
        #expect(!text.allowsUndo)
        text.font = NSFont.systemFont(ofSize: 13)
        text.string = String(repeating: "Dlouhý text, který se do rámečku nevejde. ", count: 40)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.sizeToFit()
        #expect(text.frame.height > scroll.contentSize.height)
        #expect(text.frame.width <= scroll.contentSize.width + 0.5)
    }

    @Test func showInTrayJumpsToThePhotosDay() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        model.trayShowsAll = true
        model.currentSpreadID = store.album.spreads.first { $0.dayKey == day1 }?.id
        model.showInTray("b2")
        #expect(!model.trayShowsAll)
        #expect(model.trayDay == day2)
        #expect(model.trayPhotos.contains { $0.id == "b2" })
    }
}

/// Free layout editing (start-a-volne-rozlozeni Task 6): moving, resizing, adding and deleting
/// frames and texts, the page margin and the template picker's confirmation.
@MainActor
struct EditorLayoutTests {
    private func moved(_ r: Rect, dx: Double, dy: Double) -> Rect {
        Rect(x: r.minX + dx, y: r.minY + dy, width: r.size.width, height: r.size.height)
    }

    private func rule(_ model: EditorModel) -> MarginRule {
        MarginRule(geometry: model.geometry, marginMM: model.marginMM)
    }

    private func endEvent() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func layoutSessionIsOneUndoStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        let frame = gallery.frames[0]
        let before = store.album
        let revision = store.revision
        let target = rule(model).conformFrame(moved(frame.rect, dx: 20, dy: 10), area: .spread)

        step(undo) {
            model.beginLayoutChange(.frame(frame.id))
            #expect(model.hasPendingSession)
            #expect(model.pendingSessionActionName == nil)  // open, unchanged
            model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: 5, dy: 0))
            model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: 20, dy: 10))
            #expect(store.revision == revision)
            #expect(model.displayedSpread(gallery.id)?.frames[0].rect == target)
            #expect(model.currentSpread?.frames[0].rect == target)
            #expect(model.pendingSessionActionName == "Upravit rozložení")
            model.endLayoutChange()
        }
        #expect(!model.hasPendingSession)
        #expect(store.revision == revision + 1)
        #expect(spread(store.album, gallery.id)?.frames[0].rect == target)
        #expect(spread(store.album, gallery.id)?.frames[0].photoID == frame.photoID)
        #expect(undo.undoActionName == "Upravit rozložení")
        undo.undo()
        #expect(store.album == before)

        // A gesture that changes nothing stores nothing.
        let unchanged = store.revision
        model.beginLayoutChange(.frame(frame.id))
        model.updateLayout(.frame(frame.id), rect: frame.rect)
        model.endLayoutChange()
        #expect(store.revision == unchanged)

        // Without a running session (or for another item), updateLayout starts one itself.
        model.updateLayout(.text("caption"), rect: moved(try #require(gallery.texts.first { $0.id == "caption" }).rect,
                                                          dx: -30, dy: 0))
        #expect(model.hasPendingSession)
        #expect(model.pendingSessionActionName == "Upravit rozložení")
        model.commitSessions()
        #expect(undo.undoActionName == "Upravit rozložení")
        #expect(spread(store.album, gallery.id)?.texts.first { $0.id == "caption" }?.rect
                != gallery.texts.first { $0.id == "caption" }?.rect)
    }

    @Test func layoutChangeConformsToMargin() throws {
        var album = try standardAlbum()
        album.marginMM = 20
        let (model, store, undo) = try makeModel(album)
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })
        model.currentSpreadID = journal.id
        let frame = journal.frames[0]

        // A frame moved into the band (14 mm from the trim, margin 20) shifts onto the margin line
        // and keeps its size.
        step(undo) {
            model.beginLayoutChange(.frame(frame.id))
            model.updateLayout(.frame(frame.id), rect: Rect(x: 14, y: 14, width: 100, height: 80), mode: .move)
            model.endLayoutChange()
        }
        let stored = try #require(spread(store.album, journal.id)?.frames.first { $0.id == frame.id }?.rect)
        #expect(stored == Rect(x: 20, y: 20, width: 100, height: 80))

        // A resize snaps each edge on its own: the dragged edges land on the margin line, the
        // opposite ones stay.
        step(undo) {
            model.beginLayoutChange(.frame(frame.id))
            model.updateLayout(.frame(frame.id), rect: Rect(x: 14, y: 14, width: 106, height: 80), mode: .resize)
            model.endLayoutChange()
        }
        #expect(spread(store.album, journal.id)?.frames.first { $0.id == frame.id }?.rect
                == Rect(x: 20, y: 20, width: 100, height: 74))

        // A moved text stays inside the margin box of its page, keeping its size.
        let title = try #require(journal.texts.first { $0.id == "title" })
        step(undo) {
            model.beginLayoutChange(.text(title.id))
            model.updateLayout(.text(title.id), rect: Rect(x: 2, y: 3, width: 50, height: 10), mode: .move)
            model.endLayoutChange()
        }
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == title.id }?.rect
                == Rect(x: 20, y: 20, width: 50, height: 10))

        // A text resized into the band: only the dragged edge is clamped, the box does not shift.
        step(undo) {
            model.beginLayoutChange(.text(title.id))
            model.updateLayout(.text(title.id), rect: Rect(x: 20, y: 20, width: 50, height: 185), mode: .resize)
            model.endLayoutChange()
        }
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == title.id }?.rect
                == Rect(x: 20, y: 20, width: 50, height: 170))
        step(undo) {
            model.beginLayoutChange(.text(title.id))
            model.updateLayout(.text(title.id), rect: Rect(x: 5, y: 20, width: 65, height: 170), mode: .resize)
            model.endLayoutChange()
        }
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == title.id }?.rect
                == Rect(x: 20, y: 20, width: 50, height: 170))

        // Non-finite input is ignored.
        let resized = try #require(spread(store.album, journal.id)?.frames.first { $0.id == frame.id }?.rect)
        model.beginLayoutChange(.frame(frame.id))
        model.updateLayout(.frame(frame.id), rect: Rect(x: .nan, y: 0, width: 10, height: 10), mode: .move)
        #expect(model.displayedSpread(journal.id)?.frames.first { $0.id == frame.id }?.rect == resized)
        model.endLayoutChange()
    }

    /// Arrow keys (incremental `.move` updates with their nudge, in one session) step a frame
    /// between margin lines, never shrinking it and never onto a page edge (no bleed, margin 6):
    /// outward at the margin line by the trim it stays, toward the spine it jumps past it.
    @Test func arrowNudgeStepsBetweenMarginLines() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        #expect(model.marginMM == 6)
        let start = Rect(x: 6, y: 40, width: 120, height: 90)
        step(undo) {
            model.beginLayoutChange(.frame("photo1"))
            model.updateLayout(.frame("photo1"), rect: start, mode: .move)
            model.endLayoutChange()
        }
        #expect(spread(store.album, gallery.id)?.frames.first { $0.id == "photo1" }?.rect == start)

        func press(_ dx: Double, _ dy: Double = 0) throws -> Rect {
            let current = try #require(model.displayedSpread(gallery.id)?.frames.first { $0.id == "photo1" }?.rect)
            model.updateLayout(.frame("photo1"), rect: moved(current, dx: dx, dy: dy), mode: .move,
                               nudge: Point(x: dx, y: dy))
            return try #require(model.displayedSpread(gallery.id)?.frames.first { $0.id == "photo1" }?.rect)
        }
        try step(undo) {
            model.beginLayoutChange(.frame("photo1"))
            let out = try press(-1)    // the trim is no stop: stays on the margin line
            let beyond = try press(-5)
            let inward = try press(1)
            let further = try press(5)
            #expect(out == start)
            #expect(beyond == start)
            #expect(inward == Rect(x: 7, y: 40, width: 120, height: 90))
            #expect(further == Rect(x: 12, y: 40, width: 120, height: 90))
            model.endLayoutChange()
        }
        #expect(spread(store.album, gallery.id)?.frames.first { $0.id == "photo1" }?.rect
                == Rect(x: 12, y: 40, width: 120, height: 90))

        // ⇧→ from the right margin line before the spine jumps past the spine to the margin line
        // after it (never onto the spine); ⇧↓ from the bottom margin line stays.
        let right = Rect(x: 171, y: 114, width: 120, height: 90)  // maxX 291, maxY 204
        try step(undo) {
            model.beginLayoutChange(.frame("photo1"))
            model.updateLayout(.frame("photo1"), rect: right, mode: .move)
            let pastSpine = try press(5)
            let toBottom = try press(0, 5)
            #expect(pastSpine.maxX == 303 && pastSpine.size.width == 120)
            #expect(toBottom.maxY == 204)
            model.endLayoutChange()
        }
        // A mouse drag (no nudge) into the band goes to the margin line, even right by the trim.
        for x in [5.0, 1] {
            try step(undo) {
                model.beginLayoutChange(.frame("photo1"))
                model.updateLayout(.frame("photo1"), rect: Rect(x: x, y: 40, width: 120, height: 90), mode: .move)
                let dragged = try #require(model.displayedSpread(gallery.id)?.frames.first { $0.id == "photo1" }?.rect)
                #expect(dragged == start)
                model.endLayoutChange()
            }
        }
    }

    @Test func layoutChangeMarksSpreadCustomAndManual() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        #expect(!gallery.manuallyEdited && !gallery.customLayout)
        step(undo) {
            model.beginLayoutChange(.frame("photo1"), in: gallery.id)
            model.updateLayout(.frame("photo1"), rect: moved(gallery.frames[0].rect, dx: 0, dy: 15))
            model.endLayoutChange()
        }
        let after = try #require(spread(store.album, gallery.id))
        #expect(after.manuallyEdited && after.customLayout)
        undo.undo()
        #expect(spread(store.album, gallery.id) == gallery)
    }

    /// Review Focus 3: ⌘Z in the middle of a drag stores the drag as its own step and undoes
    /// only that step, never the one before it.
    @Test func undoDuringLayoutSessionCommitsThenUndoesOnlyIt() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        step(undo) { model.setText("title", "Ravello", in: journal.id) }
        let frame = journal.frames[0]
        let target = rule(model).conformFrame(moved(frame.rect, dx: 0, dy: 12), area: .spread)

        model.beginLayoutChange(.frame(frame.id), in: journal.id)
        model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: 0, dy: 12))
        model.undo()
        #expect(!model.hasPendingSession)
        #expect(spread(store.album, journal.id)?.frames[0].rect == frame.rect)
        #expect(model.displayedSpread(journal.id)?.frames[0].rect == frame.rect)
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "title" }?.text == "Ravello")
        #expect(undo.canRedo)

        model.redo()
        #expect(spread(store.album, journal.id)?.frames[0].rect == target)
        model.undo()
        model.undo()
        #expect(spread(store.album, journal.id) == journal)
        #expect(!undo.canUndo)
    }

    /// A layout gesture ended by another action in the same event is its own step (window manager).
    @Test func layoutSessionEndedByAnotherActionIsItsOwnStep() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let undo = UndoManager()  // groups by event, like the window's
        model.undoManager = undo
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })
        let frame = journal.frames[0]

        model.beginLayoutChange(.frame(frame.id), in: journal.id)
        model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: 0, dy: 12))
        model.setText("title", "Ravello", in: journal.id)
        endEvent()
        #expect(undo.undoActionName == "Upravit text")

        model.undo(); endEvent()
        #expect(spread(store.album, journal.id)?.texts.first { $0.id == "title" }?.text == AlbumDrafter.noPlaceTitle)
        #expect(spread(store.album, journal.id)?.frames[0].rect != frame.rect)
        #expect(undo.undoActionName == "Upravit rozložení")
        model.undo(); endEvent()
        #expect(spread(store.album, journal.id) == journal)
        #expect(!undo.canUndo)
    }

    @Test func addFrameIsCenteredConformedAndSelected() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        let before = store.album

        let id = step(undo) { model.addFrame(on: .right) }
        #expect(id == "frame-1")
        let page = model.geometry.pageRect(side: .right)
        let centred = Rect(x: page.minX + page.size.width / 4, y: page.size.height / 4,
                           width: page.size.width / 2, height: page.size.height / 2)
        let after = try #require(spread(store.album, gallery.id))
        let frame = try #require(after.frames.first { $0.id == "frame-1" })
        #expect(frame.rect == rule(model).conformFrame(centred, area: .spread))
        #expect(frame.rect == centred)
        #expect(frame.photoID == nil && frame.offset == Point(x: 0, y: 0) && frame.zoom == 1)
        #expect(after.frames.count == gallery.frames.count + 1)
        #expect(after.customLayout && after.manuallyEdited)
        #expect(model.selectedItem == .frame("frame-1"))
        #expect(model.selectedFrameID == "frame-1")
        #expect(undo.undoActionName == "Přidat rámeček")

        undo.undo()
        #expect(store.album == before)
        #expect(model.selectedItem == nil)
        #expect(model.addFrame(on: .left, in: "nope") == nil)
    }

    // MARK: Copy, cut, paste (⌘C ⌘X ⌘V)

    @Test func copyPastePhotoFrameOffsetsTheCopyAndSelectsIt() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" && !$0.frames.isEmpty })
        model.currentSpreadID = gallery.id
        let original = gallery.frames[0]
        let before = store.album

        let clip = try #require(model.clipboardItem(.frame(original.id)))
        let id = try #require(step(undo) { model.paste(clip) })
        #expect(id != original.id)
        let after = try #require(spread(store.album, gallery.id))
        let copy = try #require(after.frames.first { $0.id == id })
        #expect(copy.photoID == original.photoID && copy.zoom == original.zoom && copy.offset == original.offset)
        #expect(copy.rect.size == original.rect.size)
        #expect(copy.rect != original.rect)
        #expect(!rule(model).frameIntrudesMargin(copy.rect, area: .spread))
        #expect(model.selectedItem == .frame(id))
        #expect(undo.undoActionName == "Vložit")
        // A second paste does not land on the first copy.
        let second = try #require(step(undo) { model.paste(clip) })
        let rects = try #require(spread(store.album, gallery.id)).frames.map(\.rect)
        #expect(Set(rects.map { "\($0)" }).count == rects.count, "\(second)")

        undo.undo()
        undo.undo()
        #expect(store.album == before)
    }

    /// A frame against the bottom-right margin lines: the copy goes up-left instead of being
    /// pulled back onto the original.
    @Test func pasteNextToAFrameInTheCornerDoesNotStackOnIt() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" && !$0.frames.isEmpty })
        model.currentSpreadID = gallery.id
        var frame = gallery.frames[0]
        let page = model.geometry.pageRect(side: .right)
        frame.rect = Rect(x: page.maxX - 6 - 80, y: page.maxY - 6 - 60, width: 80, height: 60)
        let id = try #require(step(undo) { model.paste(.frame(frame)) })
        let second = try #require(step(undo) { model.paste(.frame(frame)) })
        let frames = try #require(spread(store.album, gallery.id)).frames
        let first = try #require(frames.first { $0.id == id }), copy = try #require(frames.first { $0.id == second })
        #expect(first.rect == frame.rect)
        #expect(copy.rect != first.rect && copy.rect.size == frame.rect.size)
        #expect(!rule(model).frameIntrudesMargin(copy.rect, area: .spread))
    }

    @Test func pasteOnAnotherSpreadKeepsThePosition() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let spreads = store.album.spreads.filter { !$0.frames.isEmpty }
        let from = try #require(spreads.first), to = try #require(spreads.dropFirst().first)
        model.currentSpreadID = from.id
        let clip = try #require(model.clipboardItem(.frame(from.frames[0].id)))
        model.currentSpreadID = to.id
        let id = try #require(step(undo) { model.paste(clip) })
        let copy = try #require(spread(store.album, to.id)?.frames.first { $0.id == id })
        let occupied = to.frames.contains { $0.rect == from.frames[0].rect }
        #expect(occupied || copy.rect == rule(model).conformMovedFrame(from.frames[0].rect, area: .spread))
    }

    @Test func pasteTextKeepsTextAndStyle() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        let textID = try #require(step(undo) { model.addText(on: .left) })
        step(undo) { model.setText(textID, "Soul") }
        model.selectedItem = .text(textID)
        step(undo) { model.changeTextStyle { $0.sizePt = 30; $0.bold = true } }
        let clip = try #require(model.clipboardItem(.text(textID)))
        let id = try #require(step(undo) { model.paste(clip) })
        let copy = try #require(spread(store.album, gallery.id)?.texts.first { $0.id == id })
        #expect(copy.text == "Soul" && copy.style?.sizePt == 30 && copy.style?.bold == true)
        #expect(model.selectedItem == .text(id))
    }

    @Test func pastedPhotoFromAnotherAlbumBecomesAnEmptyFrame() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" && !$0.frames.isEmpty })
        model.currentSpreadID = gallery.id
        var frame = gallery.frames[0]
        frame.photoID = "not-in-this-album"
        let id = try #require(step(undo) { model.paste(.frame(frame)) })
        #expect(spread(store.album, gallery.id)?.frames.first { $0.id == id }?.photoID == nil)
    }

    @Test func cutRemovesTheItemInOneStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" && !$0.frames.isEmpty })
        model.currentSpreadID = gallery.id
        let frameID = gallery.frames[0].id
        let clip = try #require(step(undo) { model.cut(.frame(frameID)) })
        #expect(clip == .frame(gallery.frames[0]))
        #expect(spread(store.album, gallery.id)?.frames.contains { $0.id == frameID } == false)
        #expect(undo.undoActionName == "Vyjmout")
    }

    @Test func clipboardRoundTripsThroughAPasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("leporelo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let text = TextBox(id: "t", rect: Rect(x: 1, y: 2, width: 30, height: 10), role: .caption, text: "Ahoj")
        #expect(LayoutClipboard.read(from: pasteboard) == nil)
        #expect(!LayoutClipboard.hasItem(in: pasteboard))
        LayoutClipboard.write(.text(text), to: pasteboard)
        #expect(LayoutClipboard.hasItem(in: pasteboard))
        #expect(LayoutClipboard.read(from: pasteboard) == .text(text))
        #expect(pasteboard.string(forType: .string) == "Ahoj")
    }

    @Test func addFrameIdsAreUnique() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id
        #expect(step(undo) { model.addFrame(on: .left) } == "frame-1")
        #expect(step(undo) { model.addFrame(on: .right) } == "frame-2")
        #expect(step(undo) { model.deleteItem(.frame("frame-1")) })
        #expect(step(undo) { model.addFrame(on: .left) } == "frame-1")
        let ids = try #require(spread(store.album, gallery.id)).frames.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func addTextSitsAboveTheBottomMargin() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id

        let id = step(undo) { model.addText(on: .left) }
        #expect(id == "text-1")
        let page = model.geometry.pageRect(side: .left)
        let box = try #require(spread(store.album, gallery.id)?.texts.first { $0.id == "text-1" })
        #expect(box.role == .caption && box.text == "")
        #expect(box.rect == Rect(x: page.minX + (page.size.width - 60) / 2, y: page.size.height - model.marginMM - 12,
                                 width: 60, height: 12))
        #expect(model.selectedItem == .text("text-1"))
        #expect(model.selectedFrameID == nil)
        #expect(spread(store.album, gallery.id)?.customLayout == true)
        #expect(undo.undoActionName == "Přidat text")
        #expect(step(undo) { model.addText(on: .right) } == "text-2")
    }

    @Test func deleteEmptyFrameRemovesIt() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let id = try #require(step(undo) { model.insertSpread(kind: .gallery, after: nil) })
        let inserted = try #require(spread(store.album, id))
        let frameID = try #require(inserted.frames.first?.id)
        model.selectedItem = .frame(frameID)
        let before = store.album

        #expect(step(undo) { model.deleteItem(.frame(frameID)) })
        let after = try #require(spread(store.album, id))
        #expect(!after.frames.contains { $0.id == frameID })
        #expect(after.frames.count == inserted.frames.count - 1)
        #expect(after.customLayout && after.manuallyEdited)
        #expect(model.selectedItem == nil)
        #expect(undo.undoActionName == "Smazat")

        undo.undo()
        #expect(store.album == before)
        let revision = store.revision
        #expect(!model.deleteItem(.frame("nope")))
        #expect(!model.deleteItem(.frame(frameID), in: "nope"))
        #expect(store.revision == revision)
    }

    @Test func deleteFrameWithPhotoLeavesPhotoUnplaced() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        let frame = gallery.frames[0]
        let photoID = try #require(frame.photoID)
        #expect(!model.unplacedSelectedPhotos.contains { $0.id == photoID })

        #expect(step(undo) { model.deleteItem(.frame(frame.id), in: gallery.id) })
        #expect(spread(store.album, gallery.id)?.frames.contains { $0.id == frame.id } == false)
        #expect(store.album.photos[photoID]?.isSelected == true)
        #expect(model.unplacedSelectedPhotos.contains { $0.id == photoID })
        undo.undo()
        #expect(spread(store.album, gallery.id) == gallery)
    }

    @Test func deleteTextRemovesIt() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })
        model.currentSpreadID = journal.id
        model.selectedItem = .text("title")
        #expect(model.selectedItem == .text("title"))

        #expect(step(undo) { model.deleteItem(.text("title")) })
        let after = try #require(spread(store.album, journal.id))
        #expect(!after.texts.contains { $0.id == "title" })
        #expect(after.customLayout)
        #expect(model.selectedItem == nil)
        #expect(undo.undoActionName == "Smazat")
        undo.undo()
        #expect(spread(store.album, journal.id) == journal)
    }

    @Test func setMarginIsOneUndoStepAndConforms() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let before = store.album
        let g = model.geometry
        #expect(model.marginMM == 6)

        step(undo) { model.setMargin(20) }
        #expect(model.marginMM == 20)
        #expect(store.album == AlbumUpdater.settingMargin(20, in: before, profile: g.profile, format: g.format))
        #expect(undo.undoActionName == "Změnit okraj")
        let w = g.format.pageWidthMM, h = g.format.pageHeightMM
        for frame in store.album.spreads.flatMap(\.frames) {
            for (v, edges) in [(frame.rect.minX, [0, w, 2 * w]), (frame.rect.maxX, [0, w, 2 * w]),
                               (frame.rect.minY, [0, h]), (frame.rect.maxY, [0, h])] {
                // No bleed: every edge at least the margin from every page edge.
                let d = edges.map { abs($0 - v) }.min() ?? 0
                #expect(d >= 20 - 1e-6)
            }
        }

        // The same value (also after clamping) changes nothing.
        let revision = store.revision
        model.setMargin(20)
        #expect(store.revision == revision)

        step(undo) { model.setMargin(100) }
        #expect(model.marginMM == MarginRule.maxMarginMM)
        model.setMargin(31)
        #expect(store.revision == revision + 1)
        step(undo) { model.setMargin(1) }
        #expect(model.marginMM == g.profile.safeMM)

        undo.undo(); undo.undo(); undo.undo()
        #expect(store.album == before)
    }

    /// An older book with a photo to the page edge: choosing the same margin again fixes it in one
    /// step "Změnit okraj".
    @Test func setMarginReconformsBleedFramesAtSameMargin() throws {
        var album = try standardAlbum()
        #expect(album.marginMM == 6)
        let s = try #require(album.spreads.firstIndex { !$0.frames.isEmpty })
        album.spreads[s].customLayout = true
        album.spreads[s].frames[0].rect = Rect(x: 0, y: 30, width: 100, height: 80)
        let (model, store, undo) = try makeModel(album)
        let before = store.album
        let revision = store.revision

        step(undo) { model.setMargin(6) }
        #expect(store.revision == revision + 1)
        #expect(undo.undoActionName == "Změnit okraj")
        #expect(store.album.spreads[s].frames[0].rect == Rect(x: 6, y: 30, width: 94, height: 80))
        #expect(store.album.spreads[s].frames[0].photoID == before.spreads[s].frames[0].photoID)
        // Now nothing intrudes: the same value again changes nothing.
        model.setMargin(6)
        #expect(store.revision == revision + 1)
        undo.undo()
        #expect(store.album == before)
    }

    /// A cover photo to the page edge (a book made before the rule) is fixed the same way.
    @Test func setMarginReconformsBleedCoverAtSameMargin() throws {
        var album = try standardAlbum()
        let g = try laxGeometry()
        let page = Rect(x: 0, y: 0, width: g.format.pageWidthMM, height: g.format.pageHeightMM)
        album.cover?.front.frames[0].rect = page
        let (model, store, undo) = try makeModel(album)
        step(undo) { model.setMargin(6) }
        #expect(store.album.cover?.front.frames[0].rect == page.insetBy(6))
        #expect(undo.undoActionName == "Změnit okraj")
    }

    /// „Srovnat do okraje“ is offered only while a frame intrudes and fixes the book in one step.
    @Test func fitToMarginFixesIntrudingFramesInOneStep() throws {
        var album = try standardAlbum()
        let s = try #require(album.spreads.firstIndex { !$0.frames.isEmpty })
        album.spreads[s].customLayout = true
        album.spreads[s].frames[0].rect = Rect(x: 0, y: 30, width: 100, height: 80)
        let (model, store, undo) = try makeModel(album)
        let before = store.album
        #expect(model.hasFrameIntrudingMargin)

        step(undo) { model.fitToMargin() }
        #expect(!model.hasFrameIntrudingMargin)
        #expect(store.album.marginMM == before.marginMM)
        #expect(store.album.spreads[s].frames[0].rect == Rect(x: 6, y: 30, width: 94, height: 80))
        #expect(undo.undoActionName == "Změnit okraj")
        undo.undo()
        #expect(store.album == before)
        #expect(model.hasFrameIntrudingMargin)
    }

    @Test func newSpreadsAndTemplatesUseTheAlbumMargin() throws {
        var album = try standardAlbum()
        album.marginMM = 25
        let (model, store, undo) = try makeModel(album)
        func rects(_ s: Spread?) -> [Rect] { (s?.frames.map(\.rect) ?? []) + (s?.texts.map(\.rect) ?? []) }
        func instance(_ templateID: String, margin: Double) throws -> Spread {
            let template = try #require(TemplateCatalog.template(id: templateID))
            return TemplateLayout.instantiate(template, geometry: model.geometry, dayKey: nil, marginMM: margin)
        }
        func journalPages(margin: Double) throws -> Spread {
            PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: "opener-2l")),
                               right: try #require(PageLayoutCatalog.layout(id: "grid-4")), kind: .journal,
                               dayKey: nil, id: "x", geometry: model.geometry, marginMM: margin)
        }

        let id = try #require(step(undo) { model.insertSpread(kind: .journal, after: nil) })
        #expect(rects(spread(store.album, id)) == rects(try journalPages(margin: 25)))
        #expect(rects(try journalPages(margin: 25)) != rects(try journalPages(margin: 10)))

        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        let preview = try #require(model.previewTemplateChange(to: "journal-4", in: gallery.id))
        #expect(rects(preview.spread) == rects(try instance("journal-4", margin: 25)))
        #expect(rects(try instance("journal-4", margin: 25)) != rects(try instance("journal-4", margin: 10)))
    }

    @Test func changeTemplateOnCustomLayoutAsksFirst() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })
        model.currentSpreadID = journal.id
        step(undo) {
            model.beginLayoutChange(.frame(journal.frames[0].id))
            model.updateLayout(.frame(journal.frames[0].id), rect: moved(journal.frames[0].rect, dx: 0, dy: 12))
            model.endLayoutChange()
        }
        let custom = try #require(spread(store.album, journal.id))
        #expect(custom.customLayout)
        let revision = store.revision

        // First the layout question, then (journal-5 -> gallery-2 drops the date and title) the texts.
        #expect(model.changeTemplate(to: "gallery-2") == .needsLayoutReplaceConfirmation)
        #expect(store.revision == revision)
        let texts = model.changeTemplate(to: "gallery-2", confirmLayoutReplace: true)
        guard case .needsTextLossConfirmation = texts else {
            Issue.record("expected a text-loss confirmation, got \(texts)")
            return
        }
        #expect(store.revision == revision)
        #expect(model.changeTemplate(to: "no-such-template") == .unavailable)

        let applied = step(undo) {
            model.changeTemplate(to: "gallery-2", confirmTextLoss: true, confirmLayoutReplace: true)
        }
        guard case .applied = applied else {
            Issue.record("expected applied, got \(applied)")
            return
        }
        #expect(spread(store.album, journal.id)?.templateID == "gallery-2")
        #expect(spread(store.album, journal.id)?.customLayout == false)
        #expect(undo.undoActionName == "Použít doporučené rozložení")
        undo.undo()
        #expect(spread(store.album, journal.id) == custom)

        // The spread's own template on a custom layout restores the recommended layout (asked first).
        #expect(model.changeTemplate(to: "journal-5") == .needsLayoutReplaceConfirmation)
        let restored = step(undo) { model.changeTemplate(to: "journal-5", confirmLayoutReplace: true) }
        #expect(restored == .applied(unplacedPhotoIDs: []))
        let reset = try #require(spread(store.album, journal.id))
        #expect(!reset.customLayout)
        #expect(reset.frames.map(\.rect) == journal.frames.map(\.rect))
        #expect(reset.texts == journal.texts)
    }

    @Test func selectedFrameIDMirrorsSelectedItem() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let gallery = try #require(store.album.spreads.first { $0.templateID == "gallery-2" })
        model.currentSpreadID = gallery.id

        model.selectedItem = .frame("photo1")
        #expect(model.selectedFrameID == "photo1")
        model.selectedItem = .text("caption")
        #expect(model.selectedItem == .text("caption"))
        #expect(model.selectedFrameID == nil)
        model.selectedFrameID = "photo2"
        #expect(model.selectedItem == .frame("photo2"))
        model.selectedFrameID = nil
        #expect(model.selectedItem == nil)
        model.selectedItem = .text("nope")
        #expect(model.selectedItem == nil)

        model.selectedItem = .text("caption")
        model.nextSpread()
        #expect(model.selectedItem == nil)  // another spread is shown
    }

    // MARK: Pages: current page, "Zkusit jinak", page layouts

    /// Review Focus 5: three "Zkusit jinak" and three ⌘Z bring the page back step by step.
    @Test func tryAnotherThreeTimesUndoesStepwise() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum())
        let g = model.geometry
        let before = store.album
        model.currentSpreadID = pagesGalleryID
        model.currentPageSide = .left
        #expect(model.tryAnotherAvailability == .available)

        var states = [try #require(spread(store.album, pagesGalleryID))]
        for expected in ["framed-1", "portrait-text", "full"] {
            let outcome = step(undo) { model.tryAnotherLayout() }
            #expect(outcome == .applied(unplacedPhotoIDs: []))
            let after = try #require(spread(store.album, pagesGalleryID))
            #expect(after.pageLayouts == [expected, "grid-4"])
            #expect(pageIDs(after, .left, g) == ["sq"])  // the page's photos, no more, no less
            #expect(pageIDs(after, .right, g) == ["r0", "r1", "r2", "r3"])
            #expect(after.manuallyEdited && !after.customLayout)
            #expect(undo.undoActionName == "Zkusit jinak")
            states.append(after)
        }
        for i in (0..<3).reversed() {
            model.undo()
            #expect(spread(store.album, pagesGalleryID) == states[i])  // one click per step
        }
        #expect(store.album == before)
        #expect(!undo.canUndo)
    }

    @Test func tryAnotherNeedsPage() throws {
        let (model, store, _) = try makeModel(try pagesAlbum())
        model.currentSpreadID = pagesGalleryID
        #expect(model.currentPageSide == nil)
        #expect(model.tryAnotherAvailability == .noPage)
        let revision = store.revision
        #expect(model.tryAnotherLayout() == .unavailable)
        #expect(store.revision == revision)

        // A selected frame or text gives its page (by its centre), else the clicked page.
        model.selectedItem = .frame("R.photo2")
        #expect(model.currentPageSide == .right)
        #expect(model.tryAnotherAvailability == .noAlternative)  // grid-4 is the only layout for 4 ▭
        model.selectedItem = nil
        #expect(model.currentPageSide == nil)
        model.currentPageSide = .left
        #expect(model.tryAnotherAvailability == .available)
        model.selectedItem = .frame("R.photo1")
        #expect(model.currentPageSide == .right)
        model.selectedItem = nil
        #expect(model.currentPageSide == .left)

        // Another spread forgets the page, also on the way back.
        model.currentSpreadID = "intro"
        #expect(model.currentPageSide == nil)
        model.currentPageSide = .right
        #expect(model.tryAnotherAvailability == .notApplicable)  // intro
        model.currentSpreadID = pagesGalleryID
        #expect(model.currentPageSide == nil)

        model.currentPageSide = .left
        model.coverSide = .front
        #expect(model.tryAnotherAvailability == .notApplicable)  // cover
    }

    @Test func tryAnotherIsNotApplicableOnAnEmptyPage() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum())
        let id = try #require(step(undo) { model.insertSpread(kind: .blank, after: nil) })
        model.currentPageSide = .left
        #expect(step(undo) { model.changePageLayout(to: "grid-4") } == .applied(unplacedPhotoIDs: []))
        #expect(spread(store.album, id)?.pageLayouts == ["grid-4", "empty"])
        model.currentPageSide = .right
        #expect(model.tryAnotherAvailability == .notApplicable)
        model.currentPageSide = .left
        #expect(model.tryAnotherAvailability == .noAlternative)  // empty frames, no photos
    }

    @Test func tryAnotherAsksOnManualPage() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum(left: "framed-1"))
        let g = model.geometry
        model.currentSpreadID = pagesGalleryID
        let original = try #require(spread(store.album, pagesGalleryID))
        let frame = try #require(original.frames.first { $0.id == "L.photo1" })
        step(undo) {
            model.beginLayoutChange(.frame(frame.id))
            model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: 0, dy: 5), mode: .move)
            model.endLayoutChange()
        }
        let custom = try #require(spread(store.album, pagesGalleryID))
        #expect(custom.pageLayouts == [nil, "grid-4"])
        model.currentPageSide = .left
        #expect(model.tryAnotherAvailability == .available)

        let revision = store.revision
        #expect(model.tryAnotherLayout() == .needsLayoutReplaceConfirmation)
        #expect(store.revision == revision)

        let outcome = step(undo) { model.tryAnotherLayout(confirmLayoutReplace: true) }
        #expect(outcome == .applied(unplacedPhotoIDs: []))
        let after = try #require(spread(store.album, pagesGalleryID))
        #expect(after.pageLayouts == ["full", "grid-4"])  // the first alternative of a manual page
        #expect(pageIDs(after, .left, g) == ["sq"])
        func right(_ s: Spread) -> ([Frame], [TextBox]) {
            (s.frames.filter { PageSpread.side(of: $0.rect, geometry: g) == .right },
             s.texts.filter { PageSpread.side(of: $0.rect, geometry: g) == .right })
        }
        #expect(right(after) == right(custom))
        #expect(undo.undoActionName == "Zkusit jinak")
        undo.undo()
        #expect(spread(store.album, pagesGalleryID) == custom)
    }

    /// Review Focus 1: a page of an old spread is confirmed first, then only that page is converted.
    @Test func tryAnotherOnAnOldSpreadAsksThenConvertsOnePage() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let g = model.geometry
        let journal = try #require(store.album.spreads.first { $0.templateID == "journal-5" })
        model.currentSpreadID = journal.id
        let side = try #require([PageSide.left, .right].first { side in
            model.currentPageSide = side
            return model.tryAnotherAvailability == .available
        })
        let other: PageSide = side == .left ? .right : .left
        #expect(model.tryAnotherLayout() == .needsLayoutReplaceConfirmation)
        #expect(spread(store.album, journal.id) == journal)

        let outcome = step(undo) { model.tryAnotherLayout(confirmLayoutReplace: true) }
        guard case .applied = outcome else {
            Issue.record("expected applied, got \(outcome)")
            return
        }
        let after = try #require(spread(store.album, journal.id))
        #expect(after.templateID == PageSpread.templateID)
        #expect(after.pageLayouts[side == .left ? 0 : 1] != nil)
        #expect(after.pageLayouts[side == .left ? 1 : 0] == nil)
        #expect(pageIDs(after, other, g) == pageIDs(journal, other, g))
        #expect(Set(pageIDs(after, side, g)) == Set(pageIDs(journal, side, g)))
        undo.undo()
        #expect(spread(store.album, journal.id) == journal)
    }

    @Test func movingFrameMarksOnlyItsPage() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum(left: "framed-1"))
        let original = try #require(spread(store.album, pagesGalleryID))
        let frame = try #require(original.frames.first { $0.id == "L.photo1" })
        step(undo) {
            model.beginLayoutChange(.frame(frame.id), in: pagesGalleryID)
            model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: 0, dy: 5), mode: .move)
            model.endLayoutChange()
        }
        let after = try #require(spread(store.album, pagesGalleryID))
        #expect(after.pageLayouts == [nil, "grid-4"])
        #expect(after.customLayout && after.manuallyEdited)
        #expect(undo.undoActionName == "Upravit rozložení")
    }

    @Test func addingAndDeletingMarkTheItemsPage() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum())
        model.currentSpreadID = pagesGalleryID
        #expect(step(undo) { model.addText(on: .right) } != nil)
        #expect(spread(store.album, pagesGalleryID)?.pageLayouts == ["full", nil])
        undo.undo()
        #expect(step(undo) { model.addFrame(on: .left) } != nil)
        #expect(spread(store.album, pagesGalleryID)?.pageLayouts == [nil, "grid-4"])
        undo.undo()
        #expect(step(undo) { model.deleteItem(.frame("R.photo3")) })
        let deleted = try #require(spread(store.album, pagesGalleryID))
        #expect(deleted.pageLayouts == ["full", nil])
        #expect(deleted.customLayout && deleted.manuallyEdited)
    }

    /// A frame dragged across the spine belongs to both pages' changes: neither page may be
    /// rebuilt from the catalog without it on the next margin change.
    @Test func draggingAFrameAcrossTheSpineMarksBothPages() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum(left: "framed-1"))
        let g = model.geometry
        let original = try #require(spread(store.album, pagesGalleryID))
        let frame = try #require(original.frames.first { $0.id == "L.photo1" })
        step(undo) {
            model.beginLayoutChange(.frame(frame.id), in: pagesGalleryID)
            model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: g.format.pageWidthMM * 0.6, dy: 0),
                               mode: .move)
            model.endLayoutChange()
        }
        let after = try #require(spread(store.album, pagesGalleryID))
        let dragged = try #require(after.frames.first { $0.id == "L.photo1" })
        #expect(PageSpread.side(of: dragged.rect, geometry: g) == .right)
        #expect(after.pageLayouts == [nil, nil])

        step(undo) { model.setMargin(15) }
        let rebuilt = try #require(spread(store.album, pagesGalleryID))
        #expect(rebuilt.frames.first { $0.id == "L.photo1" }?.photoID == "sq")
        #expect(Set(rebuilt.frames.compactMap(\.photoID)) == ["sq", "r0", "r1", "r2", "r3"])
    }

    /// Review finding: after a drag across the spine, a new layout for the page the frame came
    /// from must not give the spread a second `L.photo1`; the next margin change keeps every photo.
    @Test func pageLayoutAfterADragAcrossTheSpineKeepsIDsUnique() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum(left: "framed-1"))
        let g = model.geometry
        let frame = try #require(spread(store.album, pagesGalleryID)?.frames.first { $0.id == "L.photo1" })
        step(undo) {
            model.beginLayoutChange(.frame(frame.id), in: pagesGalleryID)
            model.updateLayout(.frame(frame.id), rect: moved(frame.rect, dx: g.format.pageWidthMM * 0.6, dy: 0),
                               mode: .move)
            model.endLayoutChange()
        }
        model.currentSpreadID = pagesGalleryID
        model.currentPageSide = .left
        #expect(step(undo) { model.changePageLayout(to: "framed-1", confirmLayoutReplace: true) }
            == .applied(unplacedPhotoIDs: []))
        let relaid = try #require(spread(store.album, pagesGalleryID))
        #expect(Set(relaid.frames.map(\.id)).count == relaid.frames.count, "\(relaid.frames.map(\.id))")
        #expect(relaid.pageLayouts == ["framed-1", nil])
        // The dragged frame is now `frame-1` on the right page, still holding its photo.
        #expect(relaid.frames.first { $0.id == "frame-1" }?.photoID == "sq")

        step(undo) { model.setMargin(15) }
        let rebuilt = try #require(spread(store.album, pagesGalleryID))
        #expect(Set(rebuilt.frames.map(\.id)).count == rebuilt.frames.count)
        #expect(Set(rebuilt.frames.compactMap(\.photoID)) == ["sq", "r0", "r1", "r2", "r3"])
    }

    @Test func insertGalleryComposesPages() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum())
        let g = model.geometry
        func composed(_ left: String, _ right: String, _ kind: SpreadKind, _ id: String) throws -> Spread {
            var s = PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: left)),
                                       right: try #require(PageLayoutCatalog.layout(id: right)), kind: kind,
                                       dayKey: day1, id: id, geometry: g, marginMM: store.album.marginMM)
            s.manuallyEdited = true
            return s
        }
        let gallery = try #require(step(undo) { model.insertSpread(kind: .gallery, after: pagesGalleryID) })
        #expect(spread(store.album, gallery) == (try composed("framed-1", "framed-1", .gallery, gallery)))
        #expect(model.currentSpreadID == gallery)
        let journal = try #require(step(undo) { model.insertSpread(kind: .journal, after: pagesGalleryID) })
        #expect(spread(store.album, journal) == (try composed("opener-2l", "grid-4", .journal, journal)))
        let blank = try #require(step(undo) { model.insertSpread(kind: .blank, after: nil) })
        #expect(spread(store.album, blank)?.templateID == "blank")
        #expect(spread(store.album, blank)?.pageLayouts == [])
    }

    @Test func pickerAppliesToCurrentPage() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum())
        let g = model.geometry
        model.currentSpreadID = pagesGalleryID
        #expect(model.availablePageLayouts().isEmpty)  // no page yet
        #expect(model.changePageLayout(to: "mosaic-6") == .unavailable)

        model.currentPageSide = .right
        let offered = model.availablePageLayouts().map(\.id)
        #expect(offered == PageLayoutCatalog.all.map(\.id).filter { $0 != "empty" })
        #expect(model.changePageLayout(to: "empty") == .unavailable)
        #expect(model.changePageLayout(to: "no-such-layout") == .unavailable)
        let revision = store.revision
        #expect(model.changePageLayout(to: "grid-4") == .applied(unplacedPhotoIDs: []))  // its own: nothing
        #expect(store.revision == revision)

        let before = try #require(spread(store.album, pagesGalleryID))
        #expect(step(undo) { model.changePageLayout(to: "mosaic-6") } == .applied(unplacedPhotoIDs: []))
        let after = try #require(spread(store.album, pagesGalleryID))
        #expect(after.pageLayouts == ["full", "mosaic-6"])
        #expect(Set(pageIDs(after, .right, g)) == ["r0", "r1", "r2", "r3"])
        #expect(after.frames.filter { $0.id.hasPrefix("R.") }.count == 6)  // extra frames stay empty
        #expect(pageIDs(after, .left, g) == ["sq"])
        #expect(undo.undoActionName == EditorText.applyLayoutAction)

        // Fewer frames: the extra photos stay selected but unplaced.
        let fewer = step(undo) { model.changePageLayout(to: "landscape-2") }
        guard case .applied(let unplaced) = fewer else {
            Issue.record("expected applied, got \(fewer)")
            return
        }
        #expect(unplaced.count == 2)
        #expect(Set(unplaced).isSubset(of: ["r0", "r1", "r2", "r3"]))
        undo.undo()
        undo.undo()
        #expect(spread(store.album, pagesGalleryID) == before)

        // Intro and closing keep their templates: no page layouts.
        model.currentSpreadID = "intro"
        model.currentPageSide = .left
        #expect(model.availablePageLayouts().isEmpty)
    }

    @Test func pickerOnAManualPageAsksAndKeepsTextsUntilConfirmed() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum(left: "framed-1"))
        model.currentSpreadID = pagesGalleryID
        step(undo) { model.setText("L.caption", "Pláž") }
        model.currentPageSide = .left
        // framed-1 -> full drops the caption.
        let loss = model.changePageLayout(to: "full")
        guard case .needsTextLossConfirmation(let texts) = loss else {
            Issue.record("expected a text-loss confirmation, got \(loss)")
            return
        }
        #expect(texts.map(\.text) == ["Pláž"])
        let applied = step(undo) { model.changePageLayout(to: "full", confirmTextLoss: true) }
        #expect(applied == .applied(unplacedPhotoIDs: []))
        undo.undo()

        #expect(step(undo) { model.addFrame(on: .left) } != nil)  // the page becomes manual
        model.selectedItem = nil
        model.currentPageSide = .left
        #expect(model.changePageLayout(to: "portrait-text") == .needsLayoutReplaceConfirmation)
        #expect(step(undo) { model.changePageLayout(to: "portrait-text", confirmLayoutReplace: true) }
                == .applied(unplacedPhotoIDs: []))
        #expect(spread(store.album, pagesGalleryID)?.pageLayouts == ["portrait-text", "grid-4"])
        #expect(spread(store.album, pagesGalleryID)?.texts.first { $0.id == "L.caption" }?.text == "Pláž")
    }

    @Test func tryAnotherAsksBeforeLosingAText() throws {
        let (model, store, undo) = try makeModel(try pagesAlbum(left: "portrait-text"))
        model.currentSpreadID = pagesGalleryID
        step(undo) { model.setText("L.caption", "Pláž") }
        model.currentPageSide = .left
        // portrait-text -> full (the next one round) has no caption.
        let loss = model.tryAnotherLayout()
        guard case .needsTextLossConfirmation(let texts) = loss else {
            Issue.record("expected a text-loss confirmation, got \(loss)")
            return
        }
        #expect(texts.map(\.text) == ["Pláž"])
        #expect(step(undo) { model.tryAnotherLayout(confirmTextLoss: true) } == .applied(unplacedPhotoIDs: []))
        #expect(spread(store.album, pagesGalleryID)?.pageLayouts == ["full", "grid-4"])
    }

    @Test func draftAndRedraftUseTheLayoutWeights() throws {
        let album = makeAlbum(dayPhotos("a", day1, count: 8))
        let (model, store, undo) = try makeModel(album)
        let liked = LayoutWeights(liked: ["mosaic-6"])
        var calls = 0
        model.layoutWeights = {
            calls += 1
            return liked
        }
        let g = model.geometry
        #expect(step(undo) { model.draftIfEmpty() })
        #expect(calls == 1)
        #expect(store.album == Workflow.draft(album: album, profile: g.profile, format: g.format,
                                              options: DraftOptions(layoutWeights: liked)))
        let drafted = store.album
        step(undo) { _ = model.redraft() }
        #expect(calls == 2)
        let expected = AlbumUpdater.redraft(album: drafted, days: Workflow.days(of: drafted), profile: g.profile,
                                            format: g.format, weights: liked)
        #expect(store.album == expected.album)
    }
}

/// The text bar's model (spec 3.3): the active text, its effective style and style changes as
/// undo steps.
@MainActor
struct EditorTextStyleTests {
    private func box(_ store: AlbumStore, _ spreadID: String, _ id: String) -> TextBox? {
        spread(store.album, spreadID)?.texts.first { $0.id == id }
    }

    /// Lets the run loop end the current event, which closes the undo manager's event group.
    private func endEvent() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func activeTextIsSelectedOrOverlayText() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        #expect(model.activeTextID == nil)
        #expect(model.activeTextStyle == nil)

        model.selectedItem = .frame(journal.frames[0].id)
        #expect(model.activeTextID == nil)
        model.selectedItem = .text("title")
        #expect(model.activeTextID == "title")
        let title = try #require(box(store, journal.id, "title"))
        #expect(model.activeTextStyle
            == SpreadRenderer.resolvedStyle(for: title, pageWidth: model.geometry.format.pageWidthMM))

        // The overlay wins (the canvas deselects when it opens).
        model.overlayTextID = "body"
        #expect(model.activeTextID == "body")
        model.selectedItem = nil
        #expect(model.activeTextID == "body")
        model.overlayTextID = "nope"  // not on this spread
        #expect(model.activeTextID == nil)
        model.overlayTextID = nil
        #expect(model.activeTextID == nil)
    }

    @Test func noActiveTextOnCover() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        model.selectedItem = .text("title")
        model.overlayTextID = "body"
        model.coverSide = .front
        #expect(model.activeTextID == nil)
        #expect(model.activeTextStyle == nil)

        let revision = store.revision
        model.changeTextStyle { $0.bold = true }
        model.resetTextStyle()
        #expect(store.revision == revision)
        #expect(!undo.canUndo)
    }

    @Test func changeTextStyleIsOneUndoStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        model.selectedItem = .text("title")

        step(undo) { model.changeTextStyle { $0.sizePt = 14 } }
        #expect(box(store, journal.id, "title")?.style == TextStyle(sizePt: 14))
        #expect(model.activeTextStyle?.sizePt == 14)
        #expect(undo.undoActionName == "Změnit písmo")

        // The same value again changes nothing and adds no step.
        let revision = store.revision
        model.changeTextStyle { $0.sizePt = 14 }
        #expect(store.revision == revision)
        model.undo()
        #expect(box(store, journal.id, "title")?.style == nil)
        #expect(!undo.canUndo)
    }

    /// Picking the default near-black (or resetting) on an unstyled text of an untouched spread
    /// stores nothing and adds no step, also not by marking the spread as edited.
    @Test func defaultStyleOnUnstyledTextAddsNoStep() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal && !$0.manuallyEdited })
        model.currentSpreadID = journal.id
        model.selectedItem = .text("title")
        let revision = store.revision
        step(undo) { model.changeTextStyle { $0.colorHex = "#1A1A1A" } }
        step(undo) { model.resetTextStyle() }
        #expect(store.revision == revision)  // no write, so no step (the groups stay empty)
        #expect(store.album.spreads.first { $0.id == journal.id }?.manuallyEdited == false)
    }

    @Test func styleChangeWhileEditingKeepsText() throws {
        let (model, store, _) = try makeModel(try standardAlbum())
        let undo = UndoManager()  // groups by event, like the window's
        model.undoManager = undo
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id

        // Double-click: the canvas deselects and opens the overlay.
        model.beginTextEditing("body", in: journal.id)
        model.overlayTextID = "body"
        model.updateText("Ahoj")
        model.changeTextStyle { $0.bold = true }
        endEvent()
        #expect(model.isEditingText)  // typing goes on
        #expect(box(store, journal.id, "body")?.text == "Ahoj")
        #expect(box(store, journal.id, "body")?.style?.bold == true)
        #expect(undo.undoActionName == "Změnit písmo")

        // Typing on after the style change never clobbers the style step.
        model.updateText("Ahoj!")
        model.endTextEditing()
        model.overlayTextID = nil
        endEvent()
        #expect(box(store, journal.id, "body")?.text == "Ahoj!")
        #expect(box(store, journal.id, "body")?.style?.bold == true)
        model.undo(); endEvent()
        #expect(box(store, journal.id, "body")?.text == "Ahoj")
        #expect(box(store, journal.id, "body")?.style?.bold == true)

        model.undo(); endEvent()  // the bold only
        #expect(box(store, journal.id, "body")?.text == "Ahoj")
        #expect(box(store, journal.id, "body")?.style == nil)
        #expect(undo.undoActionName == "Upravit text")
        model.undo(); endEvent()
        #expect(box(store, journal.id, "body")?.text == "")
        #expect(!undo.canUndo)
    }

    @Test func resetTextStyleStoresNil() throws {
        let (model, store, undo) = try makeModel(try standardAlbum())
        let journal = try #require(store.album.spreads.first { $0.kind == .journal })
        model.currentSpreadID = journal.id
        model.selectedItem = .text("title")
        step(undo) {
            model.changeTextStyle {
                $0.fontFamily = "Georgia"
                $0.italic = true
            }
        }
        #expect(box(store, journal.id, "title")?.style == TextStyle(fontFamily: "Georgia", italic: true))

        step(undo) { model.resetTextStyle() }
        #expect(box(store, journal.id, "title")?.style == nil)
        #expect(undo.undoActionName == "Výchozí písmo")
        let revision = store.revision
        model.resetTextStyle()  // already default: no step
        #expect(store.revision == revision)
        model.undo()
        #expect(box(store, journal.id, "title")?.style == TextStyle(fontFamily: "Georgia", italic: true))
    }
}
