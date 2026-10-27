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
                   aesthetic: Double = 0.5, kind: PhotoKind = .photo) -> Photo {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let key = day ?? day1
    let date = calendar.date(from: DateComponents(year: key.year, month: key.month, day: key.day,
                                                  hour: 9, minute: minute))!
    return Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: date, timeZoneSeconds: 0, location: nil,
                 pixelWidth: landscape ? 4000 : 3000, pixelHeight: landscape ? 3000 : 4000, kind: kind,
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

/// Two days: day1 with 8 photos (journal-5, gallery-2, gallery-1), day2 with 4 (journal-4).
private func standardAlbum() throws -> Album {
    try drafted(makeAlbum(dayPhotos("a", day1, count: 8) + dayPhotos("b", day2, count: 4)))
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
        step(undo) { _ = model.dropPhoto("extra", onFrame: gallery.frames[0].id, in: gallery.id) }
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
        #expect(step(undo) { model.dropPhoto("extra", onFrame: frameID) })

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

        #expect(step(undo) { model.dropPhoto("u", onFrame: journal.frames[1].id, in: journal.id) })
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

        #expect(step(undo) { model.dropPhoto(a, onFrame: journal.frames[2].id, in: journal.id) })
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

        #expect(step(undo) { model.dropPhoto(moved, onFrame: target.frames[slot].id, in: target.id) })
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
        #expect(!model.dropPhoto("v", onFrame: journal.frames[0].id, in: journal.id))
        #expect(!model.dropPhoto("a0", onFrame: "nope", in: journal.id))
        #expect(!model.dropPhoto("ghost", onFrame: journal.frames[0].id, in: journal.id))
        #expect(!undo.canUndo)
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
        #expect(model.trayPhotos.map(\.id) == store.album.selectedPhotos.filter { $0.kind != .video }.map(\.id))
        #expect(!model.trayPhotos.contains { !$0.isSelected })
        #expect(model.placedPhotoIDs == store.album.placedPhotoIDs)
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
        #expect(undo.undoActionName == "Změnit šablonu")

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
        #expect(inserted.templateID == "gallery-1" && inserted.dayKey == day2)
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
        #expect(undo.undoActionName == "Změnit šablonu")

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
        #expect(step(undo) { model.dropPhoto(incoming, onFrame: frameID, in: page.id) })
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
