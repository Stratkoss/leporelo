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

    /// An album as the drafter built it before page layouts (`journal-N` / `gallery-N` templates),
    /// for the updater rules on old books: the journal takes the day's 3-5 best photos, galleries 2
    /// photos each chronologically (the first gallery of a day without a journal gets the date
    /// caption); padding splits galleries, then adds blanks before the closing.
    static func legacyDraft(_ days: [DayGroup], profile: SupplierProfile, format: BookFormat) -> Album {
        typealias Item = (template: String, day: DayKey?, photos: [Photo], texts: [TextRole: String])
        let album = D.album(days)
        let selected = days.sorted { $0.dayKey < $1.dayKey }
            .map { d in (d, d.photos.filter { $0.isSelected && $0.kind != .video }.sorted(by: Photo.chronological)) }
            .filter { !$0.1.isEmpty }
        let all = selected.flatMap(\.1)
        let ranked = all.sorted(by: TemplateLayout.rank)
        let introPhoto = ranked.first(where: \.isLandscape) ?? ranked[0]
        var plan: [Item] = [("intro-1", nil, [introPhoto],
                             [.title: album.title, .body: AlbumDrafter.introBody(selected.map(\.0))])]
        for (group, photos) in selected {
            var rest = photos
            if photos.count >= 3 {
                let journal = Array(photos.sorted(by: TemplateLayout.rank).prefix(5))
                rest = photos.filter { p in !journal.contains { $0.id == p.id } }
                let title = group.placeNames.isEmpty ? AlbumDrafter.noPlaceTitle : group.placeNames.joined(separator: ", ")
                plan.append(("journal-\(journal.count)", group.dayKey, journal,
                             [.date: AlbumDrafter.czechDate(group.dayKey), .title: title, .body: ""]))
            }
            for start in stride(from: 0, to: rest.count, by: 2) {
                let chunk = Array(rest[start..<min(start + 2, rest.count)])
                let caption = photos.count < 3 && start == 0
                    ? AlbumDrafter.dayCaption(group.dayKey, placeNames: group.placeNames) : ""
                plan.append(("gallery-\(chunk.count)", group.dayKey, chunk, [.caption: caption]))
            }
        }
        plan.append(("closing-1", nil, [all.last!], [.caption: ""]))
        let rule = profile.pageCount
        while !rule.isSatisfied(by: plan.count * 2) {
            if let max = rule.max, plan.count * 2 > max { break }
            if let i = plan.firstIndex(where: { $0.template.hasPrefix("gallery-") && $0.photos.count > 1 }) {
                let photo = plan[i].photos.removeLast()
                plan[i].template = "gallery-\(plan[i].photos.count)"
                plan.insert(("gallery-1", plan[i].day, [photo], [.caption: ""]), at: i + 1)
            } else {
                plan.insert(("blank", nil, [], [:]), at: plan.count - 1)
            }
        }
        let geometry = PageGeometry(format: format, profile: profile)
        var counters: [String: Int] = [:]
        var result = album
        result.supplierProfileID = profile.id
        result.formatID = format.id
        result.spreads = plan.map { item in
            let template = TemplateCatalog.template(id: item.template)!
            let id: String
            switch template.kind {
            case .intro: id = "intro"
            case .closing: id = "closing"
            case .blank:
                counters["blank", default: 0] += 1
                id = "blank-\(counters["blank"]!)"
            case .journal, .gallery:
                let base = "\(AlbumDrafter.dayString(item.day))-\(template.kind.rawValue)"
                counters[base, default: 0] += 1
                id = template.kind == .journal && counters[base] == 1 ? base : "\(base)-\(counters[base]!)"
            }
            var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: item.day, id: id,
                                                    marginMM: album.marginMM)
            let assignment = TemplateLayout.assign(template.frames, photos: item.photos)
            for i in spread.frames.indices { spread.frames[i].photoID = assignment[spread.frames[i].id] }
            for (role, text) in item.texts {
                if let i = spread.texts.firstIndex(where: { $0.role == role }) { spread.texts[i].text = text }
            }
            return spread
        }
        result.cover = AlbumDrafter.cover(title: album.title, photoID: introPhoto.id, format: format, profile: profile,
                                          marginMM: album.marginMM)
        return result
    }

    // MARK: - photoSelected

    @Test func selectedPhotoFillsEmptyFrameOfSameDay() throws {
        let (p, f) = try D.canva(Self.lax)
        // 8 photos: journal-5, gallery-2, gallery-1 (see AlbumDrafterTests).
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = Self.legacyDraft(days, profile: p, format: f)
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

    /// A page spread's empty frames take a photo of the fitting orientation first (frame
    /// orientation from the page layout; a manual page's frames fit anything).
    @Test func selectedPhotoFillsFittingFrameOfPageSpread() throws {
        let (p, f) = try D.canva(Self.lax)
        let g = Self.geometry(p, f)
        var a = D.draft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 6))], profile: p, format: f)
        var spread = PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: "portrait-left-2l")),
                                        right: try #require(PageLayoutCatalog.layout(id: "framed-1")),
                                        kind: .gallery, dayKey: Self.june18, id: "2026-06-18-gallery-9",
                                        geometry: g, marginMM: a.marginMM)
        spread.pageLayouts[1] = nil
        a.spreads.insert(spread, at: a.spreads.count - 1)
        a = Self.adding(D.photo("tall", day: Self.june18, minute: 40, landscape: false), to: a)
        a = Self.adding(D.photo("wide", day: Self.june18, minute: 41), to: a)
        a = Self.adding(D.photo("any", day: Self.june18, minute: 42, landscape: false), to: a)
        let count = a.spreads.count
        a = AlbumUpdater.photoSelected("wide", in: a, geometry: g)
        a = AlbumUpdater.photoSelected("tall", in: a, geometry: g)
        let filled = try #require(a.spreads.first { $0.id == spread.id })
        #expect(filled.frames.first { $0.id == "L.photo2" }?.photoID == "wide")   // ▭ frame
        #expect(filled.frames.first { $0.id == "L.photo1" }?.photoID == "tall")   // ▯ frame
        // L.photo3 (▭) is still empty, but the manual page's frame fits a portrait photo.
        a = AlbumUpdater.photoSelected("any", in: a, geometry: g)
        let again = try #require(a.spreads.first { $0.id == spread.id })
        #expect(again.frames.first { $0.id == "R.photo1" }?.photoID == "any")
        #expect(again.frames.first { $0.id == "L.photo3" }?.photoID == nil)
        #expect(a.spreads.count == count)
    }

    /// Spec 4.5.2 on an old book: a day without an empty frame is planned again page by page with
    /// the new photo; its spreads keep their ids in order and the next day follows.
    @Test func selectedPhotoReplansFullLegacyDay() throws {
        let (p, f) = try D.canva(Self.lax)
        let ravello = D.dayPhotos("a", Self.june18, count: 8).map { p in
            var p = p
            p.placeName = "Ravello"
            return p
        }
        let days = [D.day(Self.june18, ravello, places: ["Ravello"]),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        var a = Self.legacyDraft(days, profile: p, format: f)
        let oldIDs = a.spreads.filter { $0.dayKey == Self.june18 }.map(\.id)
        #expect(oldIDs == ["2026-06-18-journal", "2026-06-18-gallery-1", "2026-06-18-gallery-2"])
        let june19 = a.spreads.filter { $0.dayKey == Self.june19 }
        a = Self.adding(D.photo("new", day: Self.june18, minute: 50), to: a)
        let before = a
        a = AlbumUpdater.photoSelected("new", in: a, geometry: Self.geometry(p, f))
        let day = a.spreads.filter { $0.dayKey == Self.june18 }
        #expect(day.allSatisfy { $0.templateID == PageSpread.templateID && $0.pageLayouts.count == 2 })
        #expect(Array(day.map(\.id).prefix(oldIDs.count)) == Array(oldIDs.prefix(day.count)))
        #expect(day.first?.kind == .journal && day.first?.pageLayouts.first.flatMap { $0 }?.hasPrefix("opener") == true)
        #expect(D.text(try #require(day.first), .date) == "čtvrtek 18. června 2026")
        #expect(D.text(try #require(day.first), .title) == "Ravello")
        #expect(day.dropFirst().allSatisfy { $0.kind == .gallery && $0.texts.allSatisfy { $0.text.isEmpty } })
        #expect(day.allSatisfy { !$0.manuallyEdited })
        for s in day { #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)") }
        let placed = D.placed(day)
        #expect(placed.count == 9 && Set(placed) == Set((0..<8).map { "a\($0)" } + ["new"]))
        // The day does not shrink, so the book keeps its page count.
        #expect(day.count >= oldIDs.count)
        #expect(Set(a.spreads.map(\.id)).count == a.spreads.count)
        #expect(a.spreads.filter { $0.dayKey == Self.june19 } == june19)
        let last18 = try #require(a.spreads.lastIndex { $0.dayKey == Self.june18 })
        #expect(a.spreads[last18 + 1].dayKey == Self.june19)
        #expect(a.spreads.first == before.spreads.first && a.spreads.last == before.spreads.last)
        // Idempotent: a placed photo is not placed twice.
        #expect(AlbumUpdater.photoSelected("new", in: a, geometry: Self.geometry(p, f)) == a)
    }

    /// Spec 4.5.2 and 9: the day's automatic spreads are planned again with the new photo; a manual
    /// spread between them stays as it is and the new spreads come after the last automatic one.
    @Test func selectingPhotoReplansAutomaticDay() throws {
        let (p, f) = try D.canva(Self.lax)
        let g = Self.geometry(p, f)
        let days = [D.day(Self.june18, D.mixedPhotos("a", Self.june18, count: 16), places: ["Ravello"]),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        var a = D.draft(days, profile: p, format: f)
        let day18 = a.spreads.indices.filter { a.spreads[$0].dayKey == Self.june18 }
        try #require(day18.count >= 3)
        a.spreads[day18[1]].manuallyEdited = true
        let manual = a.spreads[day18[1]]
        let autoIDs = day18.filter { $0 != day18[1] }.map { a.spreads[$0].id }
        for i in day18 { #expect(a.spreads[i].frames.allSatisfy { $0.photoID != nil }) }
        let june19 = a.spreads.filter { $0.dayKey == Self.june19 }
        a = Self.adding(D.photo("new", day: Self.june18, minute: 7), to: a)

        let b = AlbumUpdater.photoSelected("new", in: a, geometry: g)
        #expect(b.photos["new"]?.isSelected == true)
        #expect(Self.frames(holding: "new", in: b).count == 1)
        let day = b.spreads.filter { $0.dayKey == Self.june18 }
        #expect(day.first == manual)
        let replanned = Array(day.dropFirst())
        #expect(Array(replanned.map(\.id).prefix(autoIDs.count)) == Array(autoIDs.prefix(replanned.count)))
        #expect(replanned.first?.kind == .journal)
        #expect(D.text(try #require(replanned.first), .date) == "čtvrtek 18. června 2026")
        for s in day {
            #expect(s.pageLayouts.count == 2, "\(s.id)")   // whole spreads: an even page count
            #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)")
        }
        let placed = D.placed(day)
        #expect(placed.count == Set(placed).count)
        #expect(Set(placed) == Set((0..<16).map { "a\($0)" } + ["new"]))
        #expect(b.spreads.filter { $0.dayKey == Self.june19 } == june19)
        #expect(Set(b.spreads.map(\.id)).count == b.spreads.count)
        #expect(D.misfits(b).isEmpty)
    }

    /// Spec 4.5.3: every spread of the day is manual, so a new spread follows the day's last one:
    /// the photo on `framed-1` (▭) or `portrait-text` (▯) on the left, an empty right page.
    @Test func selectingPhotoAllManualAddsSpread() throws {
        let (p, f) = try D.canva(Self.lax)
        let g = Self.geometry(p, f)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        var a = D.draft(days, profile: p, format: f)
        for i in a.spreads.indices where a.spreads[i].dayKey == Self.june18 { a.spreads[i].manuallyEdited = true }
        let last18 = try #require(a.spreads.lastIndex { $0.dayKey == Self.june18 })
        a = Self.adding(D.photo("wide", day: Self.june18, minute: 50), to: a)
        a = Self.adding(D.photo("tall", day: Self.june18, minute: 51, landscape: false), to: a)

        for (id, layout) in [("wide", "framed-1"), ("tall", "portrait-text")] {
            let b = AlbumUpdater.photoSelected(id, in: a, geometry: g)
            #expect(b.spreads.count == a.spreads.count + 1)
            let added = b.spreads[last18 + 1]
            #expect(added.pageLayouts == [layout, "empty"])
            #expect(added.templateID == PageSpread.templateID && added.kind == .gallery)
            #expect(added.dayKey == Self.june18 && !added.manuallyEdited && !added.customLayout)
            #expect(added.frames.map(\.id) == ["L.photo1"] && added.frames.map(\.photoID) == [id])
            #expect(added.texts.allSatisfy { $0.text.isEmpty })
            #expect(!a.spreads.map(\.id).contains(added.id) && added.id.hasPrefix("2026-06-18-gallery-"))
            #expect(b.spreads[last18 + 2].dayKey == Self.june19)
            var without = b.spreads
            without.remove(at: last18 + 1)
            #expect(without == a.spreads)
            let fresh = PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: layout)),
                                           right: try #require(PageLayoutCatalog.layout(id: "empty")),
                                           kind: .gallery, dayKey: Self.june18, id: added.id, geometry: g,
                                           marginMM: a.marginMM)
            #expect(added.frames.map(\.rect) == fresh.frames.map(\.rect))
        }
    }

    @Test func selectedPhotoOfNewDayGetsJournalInChronologicalPlace() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 3)),
                    D.day(Self.june20, D.dayPhotos("c", Self.june20, count: 3))]
        var a = D.draft(days, profile: p, format: f)
        #expect(a.spreads.map(\.kind) == [.intro, .journal, .journal, .closing])
        a = Self.adding(D.photo("mid", day: Self.june19, minute: 0, place: "Positano"), to: a)
        a = Self.adding(D.photo("first", day: Self.june17, minute: 0, landscape: false), to: a)
        a = AlbumUpdater.photoSelected("mid", in: a, geometry: Self.geometry(p, f))
        a = AlbumUpdater.photoSelected("first", in: a, geometry: Self.geometry(p, f))
        #expect(a.spreads.map(\.dayKey) == [nil, Self.june17, Self.june18, Self.june19, Self.june20, nil])
        let mid = a.spreads[3]
        #expect(mid.kind == .journal && mid.id == "2026-06-19-journal")
        #expect(mid.pageLayouts == ["opener-text", "full"])   // 4000 × 3000 px: a whole page
        #expect(mid.frames.map(\.photoID) == ["mid"])
        #expect(D.text(mid, .date) == "pátek 19. června 2026")
        #expect(D.text(mid, .title) == "Positano")
        #expect(a.spreads[1].pageLayouts == ["opener-text", "portrait-text"])
        #expect(D.text(a.spreads[1], .date) == "středa 17. června 2026")
        #expect(D.text(a.spreads[1], .title) == AlbumDrafter.noPlaceTitle)
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
        var a = Self.legacyDraft(days, profile: p, format: f)
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
        var a = Self.legacyDraft(days, profile: p, format: f)
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
        var a = Self.legacyDraft(days, profile: p, format: f)
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
        var a = Self.legacyDraft(days, profile: p, format: f)
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

    // Fix round 1, item 2: a kept gallery with a date caption gets no second caption (new spreads
    // leave every caption empty).
    @Test func redraftWithKeptCaptionedGalleryAddsNoSecondCaption() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 2), places: ["Ravello"])]
        var a = Self.legacyDraft(days, profile: p, format: f)
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
        for g in generated {
            #expect(g.texts.filter { $0.role == .caption }.allSatisfy { $0.text.isEmpty }, "\(g.id)")
        }
        // The kept date caption is the day's header (spec 4.1): no opener page, so no second date.
        #expect(generated.allSatisfy { $0.kind == .gallery })
        let dates = Self.daySpreads(r).filter { $0.dayKey == Self.june18 }.flatMap(\.texts)
            .filter { $0.role == .date && !$0.text.isEmpty }
        #expect(dates.isEmpty)
    }

    /// A kept gallery with an ordinary caption is not a day header: the day still gets its opener.
    @Test func redraftWithKeptPlainCaptionKeepsOpener() throws {
        let (p, f) = try D.canva(Self.lax)
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8), places: ["Ravello"])]
        var a = D.draft(days, profile: p, format: f)
        let s = try #require(a.spreads.firstIndex { $0.kind == .gallery })
        a.spreads[s].manuallyEdited = true
        a.spreads[s].texts.append(TextBox(id: "R.note", rect: Rect(x: 300, y: 180, width: 100, height: 15),
                                          role: .caption, text: "Večer"))
        let (r, kept) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        #expect(kept == 1)
        let journal = try #require(r.spreads.first { $0.kind == .journal && $0.dayKey == Self.june18 })
        #expect(D.text(journal, .date) == "čtvrtek 18. června 2026")
    }

    @Test func redraftWithoutManualMatchesDraft() throws {
        let (p, f) = try D.canva()
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8)),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 4))]
        let a = D.draft(days, profile: p, format: f)
        let (r, kept) = AlbumUpdater.redraft(album: a, days: days, profile: p, format: f)
        #expect(kept == 0)
        #expect(r == a)
        // The liked layouts reach the drafter.
        let weights = LayoutWeights(liked: ["opener-2l"])
        let liked = D.draft(days, profile: p, format: f, options: DraftOptions(layoutWeights: weights))
        #expect(liked != a)
        #expect(AlbumUpdater.redraft(album: a, days: days, profile: p, format: f, weights: weights).album == liked)
    }

    // MARK: - changeFormat

    @Test func changeFormatKeepsContent() throws {
        let (p, f) = try D.canva()
        let square = try #require(p.formats.first { $0.id == "square-21" })
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = Self.legacyDraft(days, profile: p, format: f)
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
        var a = Self.legacyDraft(days, profile: p, format: f)
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
        var a = Self.legacyDraft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))], profile: p, format: f)
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

    /// The stepper does not ratchet: 10 -> 20 -> 10 gives every template spread its template
    /// rects back, with photos, crops and texts intact.
    @Test func settingMarginBackRestoresTemplateLayouts() throws {
        let (p, f) = try D.canva()
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = Self.legacyDraft(days, profile: p, format: f)
        let s = try #require(a.spreads.firstIndex { $0.kind == .journal })
        a.spreads[s].frames[0].offset = Point(x: 0.3, y: -0.2)
        a.spreads[s].frames[0].zoom = 1.7
        a.spreads[s].texts[0].text = "Ahoj"
        a.spreads[s].manuallyEdited = true

        let wide = AlbumUpdater.settingMargin(20, in: a, profile: p, format: f)
        #expect(wide.spreads[s].frames.map(\.rect) != a.spreads[s].frames.map(\.rect))
        let back = AlbumUpdater.settingMargin(10, in: wide, profile: p, format: f)
        #expect(back.marginMM == 10)
        #expect(back.spreads == a.spreads)
        #expect(back.spreads[s].frames[0].zoom == 1.7 && back.spreads[s].texts[0].text == "Ahoj")
        let g = Self.geometry(p, f)
        for spread in a.spreads {
            let template = try #require(TemplateCatalog.template(id: spread.templateID))
            let fresh = TemplateLayout.instantiate(template, geometry: g, dayKey: spread.dayKey, id: spread.id)
            #expect(back.spreads.first { $0.id == spread.id }?.frames.map(\.rect) == fresh.frames.map(\.rect))
            #expect(back.spreads.first { $0.id == spread.id }?.texts.map(\.rect) == fresh.texts.map(\.rect))
        }
    }

    /// A custom layout is conformed, not re-instantiated, and keeps its flags.
    @Test func settingMarginConformsOnlyCustomLayouts() throws {
        let (p, f) = try D.canva()
        let days = [D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 8))]
        var a = D.draft(days, profile: p, format: f)
        let s = try #require(a.spreads.firstIndex { !$0.frames.isEmpty })
        a.spreads[s].customLayout = true
        a.spreads[s].frames[0].rect = Rect(x: 30, y: 30, width: 100, height: 100)
        let b = AlbumUpdater.settingMargin(20, in: a, profile: p, format: f)
        #expect(b.spreads[s].frames[0].rect == Rect(x: 30, y: 30, width: 100, height: 100))
        #expect(b.spreads[s].customLayout)
        let c = AlbumUpdater.settingMargin(30, in: a, profile: p, format: f)
        #expect(c.spreads[s].frames[0].rect.minX == 30)
    }

    /// A wide margin pushes the journal's date down: it must not end up on the title, nor the
    /// body on the title (journal-3, landscape A4, margin 20 and 30).
    @Test func wideMarginKeepsJournalTextsApart() throws {
        let (p, f) = try D.canva()
        let g = Self.geometry(p, f)
        for margin in [17.0, 20, 30] {
            for template in TemplateCatalog.all {
                let spread = TemplateLayout.instantiate(template, geometry: g, dayKey: nil, id: "s", marginMM: margin)
                let rule = MarginRule(geometry: g, marginMM: margin)
                for (i, a) in spread.texts.enumerated() {
                    #expect(!rule.textOutsideMargin(a.rect, area: .spread), "\(template.id) \(margin) \(a.id)")
                    #expect(a.rect.size.height >= MarginRule.minItemMM - 1e-9)
                    for b in spread.texts[(i + 1)...] {
                        let apart = a.rect.maxY <= b.rect.minY + 1e-9 || b.rect.maxY <= a.rect.minY + 1e-9
                            || a.rect.maxX <= b.rect.minX + 1e-9 || b.rect.maxX <= a.rect.minX + 1e-9
                        #expect(apart, "\(template.id) margin \(margin): \(a.id) \(a.rect) overlaps \(b.id) \(b.rect)")
                    }
                }
            }
        }
        let journal = try #require(TemplateCatalog.template(id: "journal-3"))
        let wide = TemplateLayout.instantiate(journal, geometry: g, dayKey: nil, id: "s", marginMM: 20)
        let date = try #require(wide.texts.first { $0.id == "date" }).rect
        let title = try #require(wide.texts.first { $0.id == "title" }).rect
        let body = try #require(wide.texts.first { $0.id == "body" }).rect
        #expect(date.minY == 20 && date.maxY <= title.minY && title.maxY <= body.minY && body.maxY <= 190)
    }

    // MARK: - Page spreads

    /// Spec 4.4: a margin change rebuilds every page with a layout id from the catalog; going back
    /// restores the book exactly, with photos and crops.
    @Test func marginChangeRebuildsPagesKeepsPhotos() throws {
        let (p, f) = try D.canva(formatID: "landscape-8x6in")
        let g = Self.geometry(p, f)
        let days = [D.day(Self.june18, D.mixedPhotos("a", Self.june18, count: 12), places: ["Ravello"]),
                    D.day(Self.june19, D.dayPhotos("b", Self.june19, count: 5))]
        var a = D.draft(days, profile: p, format: f)
        #expect(a.marginMM == 10)
        let s = try #require(a.spreads.firstIndex { $0.templateID == PageSpread.templateID && $0.frames.count >= 2 })
        a.spreads[s].frames[1].offset = Point(x: 0.4, y: -0.3)
        a.spreads[s].frames[1].zoom = 1.6

        let wide = AlbumUpdater.settingMargin(20, in: a, profile: p, format: f)
        #expect(wide.marginMM == 20)
        #expect(wide.spreads.map(\.id) == a.spreads.map(\.id))
        #expect(wide.spreads.map(\.pageLayouts) == a.spreads.map(\.pageLayouts))
        #expect(wide.spreads.map(\.customLayout) == a.spreads.map(\.customLayout))
        #expect(wide.spreads.map { $0.frames.map(\.photoID) } == a.spreads.map { $0.frames.map(\.photoID) })
        #expect(wide.spreads.map { $0.frames.map(\.offset) } == a.spreads.map { $0.frames.map(\.offset) })
        #expect(wide.spreads.map { $0.frames.map(\.zoom) } == a.spreads.map { $0.frames.map(\.zoom) })
        #expect(wide.spreads.map { $0.texts.map(\.text) } == a.spreads.map { $0.texts.map(\.text) })
        for spread in wide.spreads where spread.templateID == PageSpread.templateID {
            let fresh = PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: spread.pageLayouts[0]!)),
                                           right: try #require(PageLayoutCatalog.layout(id: spread.pageLayouts[1]!)),
                                           kind: spread.kind, dayKey: spread.dayKey, id: spread.id,
                                           geometry: g, marginMM: 20)
            #expect(spread.frames.map(\.id) == fresh.frames.map(\.id), "\(spread.id)")
            #expect(spread.frames.map(\.rect) == fresh.frames.map(\.rect), "\(spread.id)")
            #expect(spread.texts.map(\.rect) == fresh.texts.map(\.rect), "\(spread.id)")
        }
        let journal = try #require(a.spreads.firstIndex { $0.kind == .journal })
        #expect(wide.spreads[journal].texts.map(\.rect) != a.spreads[journal].texts.map(\.rect))

        let back = AlbumUpdater.settingMargin(10, in: wide, profile: p, format: f)
        #expect(back.spreads == a.spreads)
    }

    /// Spec 4.4: on a format change a page with a layout id is rebuilt from the catalog for the
    /// new format; a manual page is scaled proportionally, as a custom layout.
    @Test func formatChangeKeepsManualPage() throws {
        let (p, small) = try D.canva(Self.lax, formatID: "landscape-8x6in")
        let a4 = try #require(p.formats.first { $0.id == "landscape-a4" })
        let g = Self.geometry(p, small)
        var a = D.draft([D.day(Self.june18, D.dayPhotos("a", Self.june18, count: 4))], profile: p, format: small)
        let grid = try #require(PageLayoutCatalog.layout(id: "grid-4"))
        var spread = PageSpread.compose(left: grid, right: try #require(PageLayoutCatalog.layout(id: "framed-1")),
                                        kind: .gallery, dayKey: Self.june18, id: "manual", geometry: g,
                                        marginMM: a.marginMM)
        for i in spread.frames.indices { spread.frames[i].photoID = "m\(i)" }
        let l2 = try #require(spread.frames.firstIndex { $0.id == "L.photo2" })
        spread.frames[l2].offset = Point(x: -0.5, y: 0.25)
        spread.frames[l2].zoom = 1.3
        let r1 = try #require(spread.frames.firstIndex { $0.id == "R.photo1" })
        let moved = Rect(x: 230, y: 20, width: 120, height: 90)
        spread.frames[r1].rect = moved
        let caption = try #require(spread.texts.firstIndex { $0.id == "R.caption" })
        spread.texts[caption].text = "Večer"
        let captionRect = spread.texts[caption].rect
        spread.pageLayouts = ["grid-4", nil]
        spread.customLayout = true
        spread.manuallyEdited = true
        a.spreads.insert(spread, at: a.spreads.count - 1)

        let b = AlbumUpdater.changeFormat(album: a, to: a4, profile: p)
        let new = try #require(b.spreads.first { $0.id == "manual" })
        #expect(new.pageLayouts == ["grid-4", nil])
        #expect(new.customLayout && new.manuallyEdited && new.templateID == PageSpread.templateID)
        #expect(new.frames.map(\.id) == spread.frames.map(\.id))
        #expect(new.frames.map(\.photoID) == spread.frames.map(\.photoID))
        #expect(new.frames.map(\.offset) == spread.frames.map(\.offset))
        #expect(new.frames.map(\.zoom) == spread.frames.map(\.zoom))
        let ga4 = Self.geometry(p, a4)
        let rule = MarginRule(geometry: ga4, marginMM: 10)
        let left = PageSpread.pageItems(grid, side: .left, geometry: ga4, marginMM: 10)
        #expect(new.frames.filter { $0.id.hasPrefix("L.") }.map(\.rect)
            == left.frames.map { rule.conformFrame($0.rect, area: .spread) })
        let sx = a4.pageWidthMM / small.pageWidthMM, sy = a4.pageHeightMM / small.pageHeightMM
        func scaled(_ r: Rect) -> Rect {
            Rect(x: r.minX * sx, y: r.minY * sy, width: r.size.width * sx, height: r.size.height * sy)
        }
        let right = try #require(new.frames.first { $0.id == "R.photo1" }).rect
        #expect(right == rule.conformFrame(scaled(moved), area: .spread))
        #expect(abs(right.minX - 230 * sx) < 1e-9 && abs(right.size.width - 120 * sx) < 1e-9)
        let newCaption = try #require(new.texts.first { $0.id == "R.caption" })
        #expect(newCaption.text == "Večer")
        #expect(newCaption.rect == rule.conformText(scaled(captionRect), area: .spread))
        // The other spreads follow their page layouts on A4.
        let other = try #require(b.spreads.first { $0.kind == .journal })
        let fresh = PageSpread.compose(left: try #require(PageLayoutCatalog.layout(id: other.pageLayouts[0]!)),
                                       right: try #require(PageLayoutCatalog.layout(id: other.pageLayouts[1]!)),
                                       kind: other.kind, dayKey: other.dayKey, id: other.id, geometry: ga4,
                                       marginMM: 10)
        #expect(other.frames.map(\.rect) == fresh.frames.map(\.rect))
        #expect(other.texts.map(\.rect) == fresh.texts.map(\.rect))
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
        let june19IDs = a.spreads.filter { $0.dayKey == Self.june19 }.map(\.id)

        let b = AlbumUpdater.photoMoved(id, to: Self.june19, in: a, geometry: Self.geometry(p, f))

        #expect(b.photos[id]?.dayKey == Self.june19)
        #expect(b.photos[id]?.isSelected == true)
        #expect(b.photos[id]?.selectionDecidedByUser == decided)  // a move is not a selection decision
        #expect(b.spreads.first { $0.id == gallery.id }?.frames.contains { $0.photoID == id } == false)
        let holders = b.spreads.filter { $0.frames.contains { $0.photoID == id } }
        #expect(holders.map(\.dayKey) == [Self.june19])
        // June 19 had no empty frame: its automatic spreads are planned again with the photo.
        let june19 = b.spreads.filter { $0.dayKey == Self.june19 }
        #expect(holders.map(\.templateID) == [PageSpread.templateID])
        #expect(Array(june19.map(\.id).prefix(june19IDs.count)) == Array(june19IDs.prefix(june19.count)))
        for s in june19 { #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)") }
        #expect(Set(D.placed(june19)) == Set((0..<4).map { "b\($0)" } + [id]))
        #expect(D.text(try #require(june19.first), .date) == "pátek 19. června 2026")
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

