import Testing
import Foundation
@testable import LeporeloCore

@Suite struct AlbumUpdaterTests {
    typealias D = AlbumDrafterTests
    static let june17 = DayKey(year: 2026, month: 6, day: 17)
    static let june18 = D.june18
    static let june19 = D.june19
    static let june20 = DayKey(year: 2026, month: 6, day: 20)
    static let lax = PageCountRule(min: 2, max: nil, multipleOf: 2)

    static func geometry(_ p: SupplierProfile, _ f: BookFormat) -> PageGeometry {
        PageGeometry(format: f, profile: p)
    }

    /// Adds an unselected photo to the album's photo library (not placed anywhere).
    static func adding(_ photo: Photo, to album: Album) -> Album {
        var a = album
        var p = photo
        p.isSelected = false
        a.photos[p.id] = p
        return a
    }

    static func frames(holding id: PhotoID, in album: Album) -> [Frame] {
        album.spreads.flatMap { s in s.frames.filter { $0.photoID == id } }
    }

    static func daySpreads(_ a: Album) -> [Spread] {
        a.spreads.filter { $0.kind == .journal || $0.kind == .gallery }
    }

    // MARK: - photoSelected

    @Test func selectedPhotoFillsEmptyFrameOfSameDay() throws {
        let (p, f) = try D.canva(Self.lax)
        // 8 photos: journal-5, gallery-2, gallery-1 (see AlbumDrafterTests).
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = D.draft(days, profile: p, format: f)
        let g2 = try #require(a.spreads.first { $0.templateID == "gallery-2" })
        for id in g2.frames.compactMap(\.photoID) { a = AlbumUpdater.photoDeselected(id, in: a) }
        #expect(a.spreads.first { $0.id == g2.id }?.frames.allSatisfy { $0.photoID == nil } == true)

        // A landscape photo skips the empty portrait frame (photo1) for the landscape one (photo2).
        a = Self.adding(D.photo("new", day: Self.june18, minute: 50), to: a)
        let count = a.spreads.count
        a = AlbumUpdater.photoSelected("new", in: a, geometry: Self.geometry(p, f))
        #expect(a.spreads.count == count)
        let spread = try #require(a.spreads.first { $0.id == g2.id })
        #expect(spread.frames.first { $0.id == "photo2" }?.photoID == "new")
        #expect(spread.frames.first { $0.id == "photo1" }?.photoID == nil)
        #expect(a.photos["new"]?.isSelected == true)
        #expect(a.photos["new"]?.selectionDecidedByUser == true)  // a user selection is a decision
        #expect(a.photos.values.filter { $0.id != "new" && $0.id != "new2" }.allSatisfy { photo in
            photo.selectionDecidedByUser == g2.frames.contains { $0.photoID == photo.id }
        })

        // A second landscape photo falls back to the remaining (portrait) empty frame.
        a = Self.adding(D.photo("new2", day: Self.june18, minute: 51), to: a)
        a = AlbumUpdater.photoSelected("new2", in: a, geometry: Self.geometry(p, f))
        #expect(a.spreads.first { $0.id == g2.id }?.frames.first { $0.id == "photo1" }?.photoID == "new2")
        #expect(a.spreads.count == count)
    }

    @Test func selectedPhotoAddsGalleryWhenFull() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        var a = D.draft(days, profile: p, format: f)
        let lastJune18 = try #require(a.spreads.lastIndex { $0.dayKey == Self.june18 })
        a = Self.adding(D.photo("new", day: Self.june18, minute: 50), to: a)
        let before = a
        a = AlbumUpdater.photoSelected("new", in: a, geometry: Self.geometry(p, f))
        #expect(a.spreads.count == before.spreads.count + 1)
        let added = a.spreads[lastJune18 + 1]
        #expect(added.templateID == "gallery-1" && added.kind == .gallery)
        #expect(added.dayKey == Self.june18)
        #expect(added.frames.map(\.photoID) == ["new"])
        #expect(added.id == "2026-06-18-gallery-3")
        #expect(added.manuallyEdited == false)
        #expect(Set(a.spreads.map(\.id)).count == a.spreads.count)
        #expect(a.spreads[lastJune18 + 2].dayKey == Self.june19)
        // Idempotent: a placed photo is not placed twice.
        #expect(AlbumUpdater.photoSelected("new", in: a, geometry: Self.geometry(p, f)) == a)
    }

    @Test func selectedPhotoOfNewDayGetsGalleryInChronologicalPlace() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 3)),
                    D.day(Self.june20, D.dayPhotos("c", Self.june20, count: 3))]
        var a = D.draft(days, profile: p, format: f)
        #expect(a.spreads.map(\.kind) == [.intro, .journal, .journal, .closing])
        a = Self.adding(D.photo("mid", day: Self.june19, minute: 0, place: "Positano"), to: a)
        a = Self.adding(D.photo("first", day: Self.june17, minute: 0), to: a)
        a = AlbumUpdater.photoSelected("mid", in: a, geometry: Self.geometry(p, f))
        a = AlbumUpdater.photoSelected("first", in: a, geometry: Self.geometry(p, f))
        #expect(a.spreads.map(\.dayKey) == [nil, Self.june17, Self.june18, Self.june19, Self.june20, nil])
        let mid = a.spreads[3]
        #expect(mid.templateID == "gallery-1" && mid.id == "2026-06-19-gallery-1")
        #expect(mid.frames.map(\.photoID) == ["mid"])
        #expect(D.text(mid, .caption) == "pátek 19. června 2026, Positano")
        #expect(D.text(a.spreads[1], .caption) == "středa 17. června 2026")
        for s in a.spreads where s.kind != .blank { #expect(s.frames.allSatisfy { $0.photoID != nil }) }
    }

    @Test func selectedPhotoWithoutDayIsIgnored() throws {
        let (p, f) = try D.canva(Self.lax)
        var a = D.draft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 3))], profile: p, format: f)
        var loose = D.photo("loose", day: Self.june18, minute: 9)
        loose.dayKey = nil
        a = Self.adding(loose, to: a)
        // Unchanged, so the selection is not recorded as decided either.
        #expect(AlbumUpdater.photoSelected("loose", in: a, geometry: Self.geometry(p, f)) == a)
        #expect(AlbumUpdater.photoSelected("unknown", in: a, geometry: Self.geometry(p, f)) == a)
    }

    // MARK: - photoDeselected

    @Test func deselectedPhotoClearsFrameKeepsSpread() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = D.draft(days, profile: p, format: f)
        // a4 is the best photo: in the intro, the journal and on the cover.
        let jIndex = try #require(a.spreads.firstIndex { $0.kind == .journal })
        let fIndex = try #require(a.spreads[jIndex].frames.firstIndex { $0.photoID == "a4" })
        a.spreads[jIndex].frames[fIndex].offset = Point(x: 0.5, y: -0.5)
        a.spreads[jIndex].frames[fIndex].zoom = 1.5
        let before = a
        let after = AlbumUpdater.photoDeselected("a4", in: a)
        #expect(after.spreads.map(\.id) == before.spreads.map(\.id))
        #expect(after.spreads.map(\.manuallyEdited) == before.spreads.map(\.manuallyEdited))
        #expect(Self.frames(holding: "a4", in: after).isEmpty)
        let cleared = after.spreads[jIndex].frames[fIndex]
        #expect(cleared.photoID == nil && cleared.offset == Point(x: 0, y: 0) && cleared.zoom == 1)
        #expect(after.spreads[0].frames[0].photoID == nil)          // intro
        #expect(after.cover?.front.frames[0].photoID == nil)        // cover
        #expect(after.photos["a4"]?.isSelected == false)
        #expect(after.photos["a4"]?.selectionDecidedByUser == true)  // a user deselection is a decision
        #expect(before.photos["a4"]?.selectionDecidedByUser == false)
        // Other frames are untouched.
        #expect(after.spreads[jIndex].frames.filter { $0.id != cleared.id }
            == before.spreads[jIndex].frames.filter { $0.id != cleared.id })
    }

    // MARK: - redraft

    @Test func redraftKeepsManualSpreadsAndCountsThem() throws {
        let (p, f) = try D.canva()   // min 20 pages
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8), places: ["Ravello"]),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 6))]
        var a = D.draft(days, profile: p, format: f)
        let journal18 = try #require(a.spreads.first { $0.kind == .journal && $0.dayKey == Self.june18 })
        a = try a.applying(.setText(spreadID: journal18.id, textID: "body", text: "Výlet lodí")).album
        // A manual gallery of June 19 whose photos are then all deselected: it must survive.
        let gallery19 = try #require(a.spreads.last { $0.kind == .gallery && $0.dayKey == Self.june19 })
        a = try a.applying(.setText(spreadID: gallery19.id, textID: "caption", text: "Večer")).album
        for id in gallery19.frames.compactMap(\.photoID) { a = AlbumUpdater.photoDeselected(id, in: a) }
        // A selection change outside the manual spreads.
        let outside = try #require(a.spreads.first {
            $0.kind == .gallery && $0.dayKey == Self.june18 && !$0.manuallyEdited
        }?.frames.first?.photoID)
        a = AlbumUpdater.photoDeselected(outside, in: a)
        let manual = a.spreads.filter(\.manuallyEdited)
        #expect(manual.count == 2)

        let (r, kept) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        #expect(kept == 2)
        for m in manual { #expect(r.spreads.contains(m), "\(m.id)") }
        #expect(Set(r.spreads.map(\.id)).count == r.spreads.count)
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: r)))
        #expect(r.spreads.first?.kind == .intro && r.spreads.last?.kind == .closing)

        // Every selected photo sits in exactly one day spread; manual photos only in their spread.
        let selected = Set(r.photos.values.filter(\.isSelected).map(\.id))
        let placed = D.placed(Self.daySpreads(r))
        #expect(Set(placed) == selected)
        #expect(placed.count == selected.count)
        #expect(!placed.contains(outside))
        let generated = r.spreads.filter { !$0.manuallyEdited }
        // Intro/closing may repeat a day photo (fix round 1); generated day spreads may not.
        #expect(Set(D.placed(manual)).isDisjoint(with: D.placed(Self.daySpreads(r).filter { !$0.manuallyEdited })))

        // Day spreads stay chronological; non-blank generated spreads have no empty frame.
        let keys = Self.daySpreads(r).compactMap(\.dayKey)
        #expect(keys == keys.sorted())
        for s in generated where s.kind != .blank { #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)") }
        #expect(r.cover?.front.frames.first?.photoID == a.cover?.front.frames.first?.photoID)
        // Deterministic.
        #expect(AlbumUpdater.redraft(album: a, days: days, profile: p, format: f).album == r)
    }

    // Fix round 1, item 1: an empty leftover pool must not drop the intro and closing.
    @Test func redraftWithEveryDaySpreadManualKeepsIntroAndClosing() throws {
        let (p, f) = try D.canva()   // min 20 pages
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        var a = D.draft(days, profile: p, format: f)
        for s in Self.daySpreads(a) {
            a = try a.applying(.setText(spreadID: s.id, textID: s.texts[0].id, text: "ručně")).album
        }
        let manual = a.spreads.filter(\.manuallyEdited)
        #expect(manual.count == Self.daySpreads(a).count)
        let (r, kept) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        #expect(kept == manual.count)
        for m in manual { #expect(r.spreads.contains(m), "\(m.id)") }
        #expect(r.spreads.first?.kind == .intro)
        #expect(r.spreads.last?.kind == .closing)
        #expect(r.spreads.first?.frames.first?.photoID != nil)
        #expect(r.spreads.last?.frames.first?.photoID != nil)
        #expect(r.cover?.front.frames.first?.photoID != nil)
        #expect(Self.daySpreads(r).count == manual.count)
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: r)))
        #expect(Set(r.spreads.map(\.id)).count == r.spreads.count)
    }

    // Fix round 1, item 2: a kept journal means no second journal and no second date header.
    @Test func redraftWithKeptJournalAddsHeaderlessGalleries() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8), places: ["Ravello"])]
        var a = D.draft(days, profile: p, format: f)
        let journal = try #require(a.spreads.first { $0.kind == .journal })
        #expect(journal.templateID == "journal-5")
        a = try a.applying(.setText(spreadID: journal.id, textID: "body", text: "Loď")).album
        let kept = try #require(a.spreads.first { $0.id == journal.id })
        let leftover = Set(a.selectedPhotos.map(\.id)).subtracting(kept.frames.compactMap(\.photoID))
        #expect(leftover.count == 3)

        let (r, count) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        #expect(count == 1)
        let day = Self.daySpreads(r)
        #expect(day.filter { $0.kind == .journal } == [kept])
        let galleries = day.filter { $0.kind == .gallery }
        #expect(!galleries.isEmpty)
        for g in galleries {
            #expect(g.texts.allSatisfy { $0.text.isEmpty }, "\(g.id)")
        }
        let placed = D.placed(galleries)
        #expect(placed.count == 3 && Set(placed) == leftover)
    }

    // Fix round 1, item 2: a kept gallery with a date caption suppresses captions of new galleries.
    @Test func redraftWithKeptCaptionedGalleryAddsNoSecondCaption() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 2), places: ["Ravello"])]
        var a = D.draft(days, profile: p, format: f)
        let first = try #require(Self.daySpreads(a).first)
        #expect(D.text(first, .caption) == "čtvrtek 18. června 2026, Ravello")
        // Keep the captioned gallery but move one photo out of it into the pool.
        let moved = try #require(first.frames.last?.photoID)
        a = AlbumUpdater.photoDeselected(moved, in: a)
        a = try a.applying(.setText(spreadID: first.id, textID: "caption", text: "čtvrtek 18. června 2026, Ravello")).album
        a.photos[moved]?.isSelected = true
        let (r, _) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        let generated = Self.daySpreads(r).filter { !$0.manuallyEdited }
        #expect(D.placed(generated) == [moved])
        for g in generated { #expect(D.text(g, .caption) == "", "\(g.id)") }
    }

    @Test func redraftWithoutManualMatchesDraft() throws {
        let (p, f) = try D.canva()
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        let a = D.draft(days, profile: p, format: f)
        let (r, kept) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        #expect(kept == 0)
        #expect(r == a)
    }

    // MARK: - changeFormat

    @Test func changeFormatKeepsContent() throws {
        let (p, f) = try D.canva()
        let square = try #require(p.formats.first { $0.id == "square-21" })
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = D.draft(days, profile: p, format: f)
        let j = try #require(a.spreads.firstIndex { $0.kind == .journal })
        a = try a.applying(.setFrameTransform(spreadID: a.spreads[j].id, frameID: "photo1",
                                              offset: Point(x: 0.3, y: -0.2), zoom: 1.4)).album
        a = try a.applying(.setText(spreadID: a.spreads[j].id, textID: "body", text: "Ahoj")).album
        // A spread whose template is not in the catalog is kept verbatim.
        let foreign = Spread(id: "foreign", kind: .gallery, templateID: "custom-x", dayKey: Self.june18,
                             frames: [], texts: [], manuallyEdited: true)
        a.spreads.insert(foreign, at: 2)

        let b = AlbumUpdater.changeFormat(album: a, to: square, profile: p)
        #expect(b.formatID == "square-21")
        #expect(b.supplierProfileID == a.supplierProfileID)
        #expect(b.spreads.map(\.id) == a.spreads.map(\.id))
        #expect(b.spreads.map(\.kind) == a.spreads.map(\.kind))
        #expect(b.spreads.map(\.dayKey) == a.spreads.map(\.dayKey))
        #expect(b.spreads.map(\.manuallyEdited) == a.spreads.map(\.manuallyEdited))
        #expect(b.spreads.map { $0.frames.map(\.photoID) } == a.spreads.map { $0.frames.map(\.photoID) })
        #expect(b.spreads.map { $0.frames.map(\.offset) } == a.spreads.map { $0.frames.map(\.offset) })
        #expect(b.spreads.map { $0.frames.map(\.zoom) } == a.spreads.map { $0.frames.map(\.zoom) })
        #expect(b.spreads.map { $0.texts.map(\.text) } == a.spreads.map { $0.texts.map(\.text) })
        #expect(b.spreads[2] == foreign)
        #expect(b.spreads[j].frames[0].rect != a.spreads[j].frames[0].rect)
        let size = PageGeometry(format: square, profile: p).spreadSize
        for s in b.spreads where s.id != "foreign" {
            for fr in s.frames {
                #expect(fr.rect.maxX <= size.width + 1e-9 && fr.rect.maxY <= size.height + 1e-9)
            }
        }
        let cover = try #require(b.cover)
        #expect(cover.front.frames.map(\.rect) == [Rect(x: 0, y: 0, width: 210, height: 210)])
        #expect(cover.front.frames.map(\.photoID) == a.cover?.front.frames.map(\.photoID))
        #expect(D.text(cover.front, .title) == "Amalfi 2026")
        // Round trip back restores the original layout.
        #expect(AlbumUpdater.changeFormat(album: b, to: f, profile: p) == a)
    }

    @Test func changeFormatScalesCustomLayout() throws {
        let (p, f) = try D.canva()
        let square = try #require(p.formats.first { $0.id == "square-21" })
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = D.draft(days, profile: p, format: f)
        let j = try #require(a.spreads.firstIndex { $0.kind == .journal })
        a.spreads[j].customLayout = true
        a.spreads[j].frames[0].rect = Rect(x: 320, y: 40, width: 100, height: 100)
        a.spreads[j].frames[0].offset = Point(x: 0.3, y: -0.2)
        a.spreads[j].frames[0].zoom = 1.5
        a = try a.applying(.setText(spreadID: a.spreads[j].id, textID: "body", text: "Ahoj")).album
        let old = a.spreads[j]

        let b = AlbumUpdater.changeFormat(album: a, to: square, profile: p)
        let new = b.spreads[j]
        #expect(new.customLayout)
        #expect(new.templateID == old.templateID && new.id == old.id)
        let sx = 420.0 / 594.0, sy = 210.0 / 210.0
        let expected = Rect(x: 320 * sx, y: 40 * sy, width: 100 * sx, height: 100 * sy)
        #expect(new.frames[0].rect == MarginRule(geometry: PageGeometry(format: square, profile: p), marginMM: 10)
            .conformFrame(expected, area: .spread))
        // This rect needs no conform, so it is exactly the proportional one.
        #expect(abs(new.frames[0].rect.minX - expected.minX) < 1e-9)
        #expect(abs(new.frames[0].rect.size.width - expected.size.width) < 1e-9)
        #expect(new.frames[0].rect.minY == 40 && new.frames[0].rect.size.height == 100)
        #expect(new.frames.map(\.photoID) == old.frames.map(\.photoID))
        #expect(new.frames[0].offset == Point(x: 0.3, y: -0.2) && new.frames[0].zoom == 1.5)
        #expect(new.texts.map(\.text) == old.texts.map(\.text))
        #expect(new.texts.first { $0.id == "body" }?.text == "Ahoj")
        // The other spreads still follow their templates.
        let g = PageGeometry(format: square, profile: p)
        let other = try #require(b.spreads.firstIndex { $0.kind == .gallery })
        let fresh = TemplateLayout.instantiate(try #require(TemplateCatalog.template(id: b.spreads[other].templateID)),
                                               geometry: g, dayKey: b.spreads[other].dayKey, id: "x")
        #expect(b.spreads[other].frames.map(\.rect) == fresh.frames.map(\.rect))
    }

    @Test func changeFormatRelaysTemplateSpreads() throws {
        let (p, f) = try D.canva()
        let square = try #require(p.formats.first { $0.id == "square-21" })
        var a = D.draft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))], profile: p, format: f)
        a.marginMM = 20
        let b = AlbumUpdater.changeFormat(album: a, to: square, profile: p)
        let g = PageGeometry(format: square, profile: p)
        for s in b.spreads {
            let fresh = TemplateLayout.instantiate(try #require(TemplateCatalog.template(id: s.templateID)),
                                                   geometry: g, dayKey: s.dayKey, id: s.id, marginMM: 20)
            #expect(s.frames.map(\.rect) == fresh.frames.map(\.rect), "\(s.id)")
            #expect(s.texts.map(\.rect) == fresh.texts.map(\.rect), "\(s.id)")
        }
    }

    // MARK: - settingMargin

    @Test func settingMarginConformsAllSpreadsAndCover() throws {
        let (p, f) = try D.canva()
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = D.draft(days, profile: p, format: f)
        a.spreads[1].manuallyEdited = true
        a.spreads[2].customLayout = true
        let g = Self.geometry(p, f)

        let b = AlbumUpdater.settingMargin(25, in: a, profile: p, format: f)
        #expect(b.marginMM == 25)
        #expect(b.spreads.map(\.manuallyEdited) == a.spreads.map(\.manuallyEdited))
        #expect(b.spreads.map(\.customLayout) == a.spreads.map(\.customLayout))
        #expect(b.spreads.map { $0.frames.map(\.photoID) } == a.spreads.map { $0.frames.map(\.photoID) })
        let rule = MarginRule(geometry: g, marginMM: 25)
        let edges = rule.pageEdgesX(.spread)
        for s in b.spreads {
            for r in s.frames.map(\.rect) + s.texts.map(\.rect) {
                #expect(TemplatesTests.hasNoEdgeInBand(r, edgesX: edges, height: f.pageHeightMM, margin: 25), "\(s.id) \(r)")
            }
        }
        let cover = try #require(b.cover)
        let coverEdges = rule.pageEdgesX(.cover)
        for s in [cover.front, cover.back] {
            for r in s.frames.map(\.rect) + s.texts.map(\.rect) {
                #expect(TemplatesTests.hasNoEdgeInBand(r, edgesX: coverEdges, height: f.pageHeightMM, margin: 25))
            }
        }
        #expect(AlbumUpdater.settingMargin(3, in: a, profile: p, format: f).marginMM == 6)
        #expect(AlbumUpdater.settingMargin(99, in: a, profile: p, format: f).marginMM == 30)
    }

    // MARK: - photoMoved (Task 21a)

    @Test func movedPhotoLeavesItsDaySpreadAndJoinsTheNewDay() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        let a = D.draft(days, profile: p, format: f)
        let gallery = try #require(a.spreads.first { $0.kind == .gallery && $0.dayKey == Self.june18 })
        let id = try #require(gallery.frames.compactMap(\.photoID).first)
        let decided = a.photos[id]?.selectionDecidedByUser

        let b = AlbumUpdater.photoMoved(id, to: Self.june19, in: a, geometry: Self.geometry(p, f))

        #expect(b.photos[id]?.dayKey == Self.june19)
        #expect(b.photos[id]?.isSelected == true)
        #expect(b.photos[id]?.selectionDecidedByUser == decided)  // a move is not a selection decision
        #expect(b.spreads.first { $0.id == gallery.id }?.frames.contains { $0.photoID == id } == false)
        let holders = b.spreads.filter { $0.frames.contains { $0.photoID == id } }
        #expect(holders.map(\.dayKey) == [Self.june19])
        #expect(holders.map(\.templateID) == ["gallery-1"])
        // Inserted after June 19's last spread.
        let lastJune19 = try #require(b.spreads.lastIndex { $0.dayKey == Self.june19 })
        #expect(b.spreads[lastJune19].id == holders[0].id)
    }

    @Test func movedIntroPhotoKeepsIntroAndCover() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        let a = D.draft(days, profile: p, format: f)
        let intro = try #require(a.spreads.first { $0.kind == .intro })
        let id = try #require(intro.frames.first?.photoID)
        let oldDay = try #require(a.photos[id]?.dayKey)
        let target = oldDay == Self.june18 ? Self.june19 : Self.june18

        let b = AlbumUpdater.photoMoved(id, to: target, in: a, geometry: Self.geometry(p, f))

        #expect(b.spreads.first { $0.kind == .intro }?.frames.first?.photoID == id)
        #expect(b.cover == a.cover)
        let dayHolders = b.spreads.filter {
            ($0.kind == .journal || $0.kind == .gallery) && $0.frames.contains { $0.photoID == id }
        }
        #expect(dayHolders.map(\.dayKey) == [target])
    }

    @Test func movedUnselectedPhotoOnlyChangesItsDay() throws {
        let (p, f) = try D.canva(Self.lax)
        var a = D.draft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 4))], profile: p, format: f)
        a = Self.adding(D.photo("u", day: Self.june18, minute: 40), to: a)
        let b = AlbumUpdater.photoMoved("u", to: Self.june19, in: a, geometry: Self.geometry(p, f))
        var expected = a
        expected.photos["u"]?.dayKey = Self.june19
        #expect(b == expected)
    }

    // Final fix wave C7: Core never places a video.
    @Test func selectedOrMovedVideoIsNotPlaced() throws {
        let (p, f) = try D.canva(Self.lax)
        var a = D.draft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 4))], profile: p, format: f)
        var video = D.photo("v", day: Self.june18, minute: 40)
        video.kind = .video
        a = Self.adding(video, to: a)
        #expect(AlbumUpdater.photoSelected("v", in: a, geometry: Self.geometry(p, f)) == a)
        var selected = a
        selected.photos["v"]?.isSelected = true
        let moved = AlbumUpdater.photoMoved("v", to: Self.june19, in: selected, geometry: Self.geometry(p, f))
        var expected = selected
        expected.photos["v"]?.dayKey = Self.june19
        #expect(moved == expected)
        #expect(Self.frames(holding: "v", in: moved).isEmpty)
    }
}

