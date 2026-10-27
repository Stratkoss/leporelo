import Testing
import Foundation
@testable import LeporeloCore

@Suite struct AlbumDrafterTests {
    static let june18 = DayKey(year: 2026, month: 6, day: 18)
    static let june19 = DayKey(year: 2026, month: 6, day: 19)

    static func photo(_ id: String, day: DayKey, minute: Int, landscape: Bool = true,
                      aesthetic: Double = 0.5, selected: Bool = true, place: String? = nil,
                      pixels: (Int, Int)? = nil) -> Photo {
        var c = DateComponents()
        c.year = day.year; c.month = day.month; c.day = day.day; c.hour = 8; c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return Photo(id: id, sourceIdentifier: id, capturedAt: cal.date(from: c)!, timeZoneSeconds: 0,
                     location: nil, pixelWidth: pixels?.0 ?? (landscape ? 4000 : 3000),
                     pixelHeight: pixels?.1 ?? (landscape ? 3000 : 4000),
                     kind: .photo,
                     analysis: PhotoAnalysis(aesthetic: aesthetic, sharpness: 500, isUtility: false,
                                             faceRects: [], closedEyes: false, featurePrint: nil),
                     isSelected: selected, dayKey: day, placeName: place, seriesID: nil,
                     originalState: .missing, deletedInSource: false)
    }

    static func day(_ key: DayKey, _ photos: [Photo], places: [String] = []) -> DayGroup {
        DayGroup(dayKey: key, photos: photos, placeNames: places, timeZoneSeconds: 0)
    }

    static func album(_ days: [DayGroup], title: String = "Amalfi 2026") -> Album {
        var photos: [PhotoID: Photo] = [:]
        for d in days { for p in d.photos { photos[p.id] = p } }
        return Album(formatVersion: Album.currentFormatVersion, id: "a", title: title,
                     supplierProfileID: "canva-photobook", formatID: "landscape-a4", world: "journal-gallery",
                     cover: nil, spreads: [], photos: photos, source: nil,
                     createdAt: Date(timeIntervalSince1970: 0))
    }

    /// Canva profile, A4 landscape by default; `rule` replaces the page-count rule when given.
    static func canva(_ rule: PageCountRule? = nil,
                      formatID: String = "landscape-a4") throws -> (SupplierProfile, BookFormat) {
        var (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: formatID)
        if let rule { p.pageCount = rule }
        return (p, f)
    }

    /// Landscape photos one minute apart; aesthetic 0.3 + (i % 5) * 0.1.
    static func dayPhotos(_ prefix: String, _ key: DayKey, count: Int) -> [Photo] {
        (0..<count).map { photo("\(prefix)\($0)", day: key, minute: $0, aesthetic: 0.3 + Double($0 % 5) * 0.1) }
    }

    static func draft(_ days: [DayGroup], profile: SupplierProfile, format: BookFormat,
                      options: DraftOptions = .init()) -> Album {
        AlbumDrafter.draft(album: album(days), days: days, profile: profile, format: format, options: options)
    }

    static func placed(_ spreads: [Spread]) -> [PhotoID] {
        spreads.flatMap { $0.frames.compactMap(\.photoID) }
    }

    static func text(_ s: Spread, _ role: TextRole) -> String? {
        s.texts.first { $0.role == role }?.text
    }

    // Ruling 1: 8 selected per day, rule min 2 / multipleOf 2 so padding does not change the order.
    @Test func draftProducesIntroJournalGalleriesClosing() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2))
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 8)),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 8))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(a.spreads.map(\.kind) == [.intro, .journal, .gallery, .gallery, .journal, .gallery, .gallery, .closing])
        #expect(a.spreads.map(\.templateID) == ["intro-1", "journal-5", "gallery-2", "gallery-1",
                                                "journal-5", "gallery-2", "gallery-1", "closing-1"])
        #expect(a.spreads[1...3].allSatisfy { $0.dayKey == Self.june18 })
        #expect(a.spreads[4...6].allSatisfy { $0.dayKey == Self.june19 })
        #expect(AlbumDrafter.pageCount(of: a) == 16)
        #expect(Set(a.spreads.map(\.id)).count == a.spreads.count)
    }

    // Review focus 2.
    @Test func shortTripMeetsMinimumPages() throws {
        let (p, f) = try Self.canva()
        #expect(p.pageCount.min == 20)
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 6))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(AlbumDrafter.pageCount(of: a) >= 20)
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: a)))
        for s in a.spreads where s.kind != .blank {
            #expect(!s.frames.isEmpty, "\(s.templateID)")
            #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.templateID)")
        }
        #expect(a.spreads.first?.kind == .intro)
        #expect(a.spreads.last?.kind == .closing)
        #expect(a.cover?.front.frames.allSatisfy { $0.photoID != nil } == true)
    }

    // Ruling 2.
    @Test func allSelectedPhotosPlacedExactlyOnce() throws {
        let (p, f) = try Self.canva()
        var d1 = Self.dayPhotos("a", Self.june18, count: 7)
        d1.append(Self.photo("a-off", day: Self.june18, minute: 30, selected: false))
        let d2 = Self.dayPhotos("b", Self.june19, count: 4)
        let days = [Self.day(Self.june18, d1), Self.day(Self.june19, d2)]
        let a = Self.draft(days, profile: p, format: f)
        let selected = Set((d1 + d2).filter(\.isSelected).map(\.id))
        let all = Self.placed(a.spreads)
        #expect(Set(all) == selected)
        let dayPlaced = Self.placed(a.spreads.filter { $0.kind == .journal || $0.kind == .gallery })
        #expect(dayPlaced.count == selected.count)
        #expect(Set(dayPlaced) == selected)
        #expect(!all.contains("a-off"))
    }

    @Test func journalDateIsCzech() throws {
        let (p, f) = try Self.canva()
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 3), places: ["Ravello", "Minori"]),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 3))]
        let a = Self.draft(days, profile: p, format: f)
        let journals = a.spreads.filter { $0.kind == .journal }
        #expect(journals.count == 2)
        #expect(Self.text(journals[0], .date) == "čtvrtek 18. června 2026")
        #expect(Self.text(journals[0], .title) == "Ravello, Minori")
        #expect(Self.text(journals[0], .body) == "")
        #expect(Self.text(journals[1], .date) == "pátek 19. června 2026")
        #expect(Self.text(journals[1], .title) == "Bez místa")
    }

    @Test func introTextsAndCover() throws {
        let (p, f) = try Self.canva()
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 3), places: ["Ravello", "Minori"]),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 3), places: ["Minori", "Amalfi"])]
        let a = Self.draft(days, profile: p, format: f)
        let intro = a.spreads[0]
        #expect(Self.text(intro, .title) == "Amalfi 2026")
        #expect(Self.text(intro, .body) == "18. 6. – 19. 6. 2026\nRavello, Minori, Amalfi")
        // Best score 0.5 is shared by a2 and b2; the earlier one wins.
        #expect(intro.frames[0].photoID == "a2")
        #expect(a.spreads.last?.frames[0].photoID == "b2")
        let cover = try #require(a.cover)
        #expect(cover.front.frames.map(\.photoID) == ["a2"])
        #expect(Self.text(cover.front, .title) == "Amalfi 2026")
        #expect(cover.back.frames.isEmpty && cover.back.kind == .blank)
        let page = Rect(x: 0, y: 0, width: f.pageWidthMM, height: f.pageHeightMM)
        #expect(cover.front.frames.allSatisfy { page.contains($0.rect) })
        #expect(cover.front.texts.allSatisfy { page.contains($0.rect) })
    }

    @Test func portraitPhotosPreferPortraitFrames() throws {
        // Lax rule so padding does not split the gallery-2 under test.
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2))
        // Journal-4: three good landscape photos and one weaker portrait photo.
        let d1 = [Self.photo("l0", day: Self.june18, minute: 0, aesthetic: 0.9),
                  Self.photo("p0", day: Self.june18, minute: 1, landscape: false, aesthetic: 0.2),
                  Self.photo("l1", day: Self.june18, minute: 2, aesthetic: 0.8),
                  Self.photo("l2", day: Self.june18, minute: 3, aesthetic: 0.7)]
        // Journal-5 takes the five best; the gallery-2 gets a landscape then a portrait photo.
        var d2 = (0..<5).map { Self.photo("j\($0)", day: Self.june19, minute: $0, aesthetic: 0.9) }
        d2 += [Self.photo("gl", day: Self.june19, minute: 10, aesthetic: 0.1),
               Self.photo("gp", day: Self.june19, minute: 11, landscape: false, aesthetic: 0.1)]
        let a = Self.draft([Self.day(Self.june18, d1), Self.day(Self.june19, d2)], profile: p, format: f)
        let j4 = try #require(a.spreads.first { $0.templateID == "journal-4" })
        #expect(j4.frames.first { $0.id == "photo4" }?.photoID == "p0")   // portrait slot
        #expect(j4.frames.first { $0.id == "photo1" }?.photoID == "l0")   // best photo on the main frame
        let g2 = try #require(a.spreads.first { $0.templateID == "gallery-2" && $0.dayKey == Self.june19 })
        #expect(g2.frames.first { $0.id == "photo1" }?.photoID == "gp")
        #expect(g2.frames.first { $0.id == "photo2" }?.photoID == "gl")
    }

    @Test func portraitMainFrameOfJournal3() throws {
        let (p, f) = try Self.canva()
        let d = [Self.photo("l0", day: Self.june18, minute: 0, aesthetic: 0.9),
                 Self.photo("p0", day: Self.june18, minute: 1, landscape: false, aesthetic: 0.5),
                 Self.photo("l1", day: Self.june18, minute: 2, aesthetic: 0.8)]
        let a = Self.draft([Self.day(Self.june18, d)], profile: p, format: f)
        let j3 = try #require(a.spreads.first { $0.templateID == "journal-3" })
        #expect(j3.frames.first { $0.id == "photo1" }?.photoID == "p0")
        #expect(j3.frames.allSatisfy { $0.photoID != nil })
    }

    @Test func smallDayHasNoEmptyFrames() throws {
        let (p, f) = try Self.canva()
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 2), places: ["Ravello"]),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 1))]
        let a = Self.draft(days, profile: p, format: f)
        for s in a.spreads where s.kind != .blank {
            #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)")
        }
        let first = try #require(a.spreads.first { $0.dayKey == Self.june18 })
        #expect(Self.text(first, .caption) == "čtvrtek 18. června 2026, Ravello")
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: a)))
    }

    @Test func paddingSplitsGalleriesBeforeAddingBlank() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 14, max: nil, multipleOf: 2))
        // intro + journal-5 + gallery-2 + gallery-2 + closing = 10 pages; 14 needs two splits.
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 9))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(a.spreads.map(\.templateID) == ["intro-1", "journal-5", "gallery-1", "gallery-1",
                                                "gallery-1", "gallery-1", "closing-1"])
        #expect(Set(Self.placed(Array(a.spreads[1...5]))).count == 9)
        // The journal takes the five best (a4, a3, a8, a2, a7); the rest stays chronological.
        #expect(Self.placed(Array(a.spreads[2...5])) == ["a0", "a1", "a5", "a6"])
        #expect(Set(a.spreads.map(\.id)).count == a.spreads.count)
    }

    @Test func blankPaddingGoesBeforeClosing() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 12, max: nil, multipleOf: 4))
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 5))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(a.spreads.map(\.kind) == [.intro, .journal, .blank, .blank, .blank, .closing])
        #expect(AlbumDrafter.pageCount(of: a) == 12)
    }

    @Test func overMaximumKeepsContent() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: 6, multipleOf: 2))
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 9))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(Self.placed(a.spreads.filter { $0.kind == .journal || $0.kind == .gallery }).count == 9)
        #expect(AlbumDrafter.pageCount(of: a) == 10)
    }

    @Test func noClosingOption() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2))
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 3))]
        let a = Self.draft(days, profile: p, format: f, options: DraftOptions(includeClosing: false))
        #expect(a.spreads.map(\.kind) == [.intro, .journal])
    }

    @Test func deterministic() throws {
        let (p, f) = try Self.canva()
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 8)),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 5))]
        #expect(Self.draft(days, profile: p, format: f) == Self.draft(days, profile: p, format: f))
    }

    // Ruling 5.
    @Test func albumOrderingTiebreaksOnID() {
        let ps = ["c", "a", "b"].map { Self.photo($0, day: Self.june18, minute: 0) }
        let a = Self.album([Self.day(Self.june18, ps)])
        #expect(a.selectedPhotos.map(\.id) == ["a", "b", "c"])
        #expect(a.photosByDay()[Self.june18]?.map(\.id) == ["a", "b", "c"])
    }

    // Fix round 1, item 1: with no orientation match the main frame still gets the best photo.
    @Test func mainFrameGetsBestPhotoWithoutOrientationMatch() {
        let ps = [Self.photo("w", day: Self.june18, minute: 0, aesthetic: 0.1),
                  Self.photo("m", day: Self.june18, minute: 1, aesthetic: 0.5),
                  Self.photo("b", day: Self.june18, minute: 2, aesthetic: 0.9)]
        for id in ["journal-3", "gallery-3"] {
            let t = TemplateCatalog.template(id: id)!
            let main = t.frames.first { $0.priority == 0 }!
            let assignment = TemplateLayout.assign(t.frames, photos: ps)
            #expect(assignment[main.id] == "b", "\(id)")
            #expect(Set(assignment.values) == ["w", "m", "b"], "\(id)")
        }
    }

    // Fix round 1, item 2: the intro body comes from a template slot, so rebuilding keeps it.
    @Test func introBodyIsATemplateSlot() throws {
        let (p, f) = try Self.canva()
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 3), places: ["Ravello"])]
        let a = Self.draft(days, profile: p, format: f)
        let intro = a.spreads[0]
        let rebuilt = TemplateLayout.instantiate(TemplateCatalog.template(id: intro.templateID)!,
                                                 geometry: PageGeometry(format: f, profile: p),
                                                 dayKey: nil, id: intro.id)
        #expect(rebuilt.texts.map(\.id) == intro.texts.map(\.id))
        #expect(rebuilt.texts.contains { $0.id == "body" && $0.role == .body })
        #expect(Self.text(intro, .body) == "18. 6. 2026\nRavello")
    }

    // Fix round 1, item 3: the cover is rebuildable for any format.
    @Test func coverBuilderUsesFormatPageSize() throws {
        let (p, _) = try Self.canva()
        let square = try #require(p.formats.first { $0.id == "square-21" })
        let cover = AlbumDrafter.cover(title: "Léto", photoID: "x", format: square, profile: p)
        let page = Rect(x: 0, y: 0, width: square.pageWidthMM, height: square.pageHeightMM)
        #expect(cover.front.frames.map(\.rect) == [page])
        #expect(cover.front.frames.map(\.photoID) == ["x"])
        let safe = page.insetBy(p.safeMM)
        #expect(cover.front.texts.allSatisfy { safe.contains($0.rect) })
        #expect(Self.text(cover.front, .title) == "Léto")
        #expect(cover.back.kind == .blank && cover.back.frames.isEmpty)
    }

    // Final fix wave C3: a 10-day trip with 220 selected photos is above Canva's 98 pages with 2
    // photos per gallery (~204 pages); the drafter plans again with 3 per gallery.
    @Test func longTripReplansWithThreePhotosPerGallery() throws {
        let (p, f) = try Self.canva()
        #expect(p.pageCount.max == 98)
        let days = (0..<10).map { i -> DayGroup in
            let key = DayKey(year: 2026, month: 6, day: 10 + i)
            return Self.day(key, Self.dayPhotos("d\(i)-", key, count: 22))
        }
        let a = Self.draft(days, profile: p, format: f)
        let two = Self.draft(days, profile: try Self.canva(PageCountRule(min: 20, max: nil, multipleOf: 2)).0,
                             format: f)
        let galleries = a.spreads.filter { $0.kind == .gallery }
        #expect(galleries.contains { $0.templateID == "gallery-3" })
        #expect(!two.spreads.contains { $0.templateID == "gallery-3" })
        #expect(AlbumDrafter.pageCount(of: two) == 204)
        // Per day: journal-5 + 17 photos in 6 galleries (3,3,3,3,3,2) = 7 spreads; + intro + closing.
        #expect(AlbumDrafter.pageCount(of: a) == (10 * 7 + 2) * 2)
        #expect(AlbumDrafter.pageCount(of: a) < AlbumDrafter.pageCount(of: two))
        // Nothing dropped.
        #expect(Self.placed(a.spreads.filter { $0.kind == .journal || $0.kind == .gallery }).count == 220)
    }

    @Test func tripThatFitsWithThreePerGalleryIsUnderTheMaximum() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: 20, multipleOf: 2))
        // 2 days x 13 photos: 2 per gallery = 1 + 2 x (1 + 4) + 1 = 12 spreads (24 pages);
        // 3 per gallery = 1 + 2 x (1 + 3) + 1 = 10 spreads (20 pages).
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 13)),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 13))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(AlbumDrafter.pageCount(of: a) == 20)
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: a)))
    }

    @Test func normalTripKeepsTwoPerGallery() throws {
        let (p, f) = try Self.canva()
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 12)),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 12))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(!a.spreads.contains { $0.templateID == "gallery-3" })
        #expect(a.spreads.filter { $0.kind == .gallery }.allSatisfy { $0.frames.count <= 2 })
    }

    // Final fix wave C7: videos are never laid out, even when selected.
    @Test func selectedVideosAreNotDrafted() throws {
        let (p, f) = try Self.canva()
        var photos = Self.dayPhotos("a", Self.june18, count: 6)
        photos[0].kind = .video
        photos[0].analysis = PhotoAnalysis(aesthetic: 1, sharpness: 900, isUtility: false, faceRects: [],
                                           closedEyes: false, featurePrint: nil)
        let a = Self.draft([Self.day(Self.june18, photos)], profile: p, format: f)
        let placed = Self.placed(a.spreads) + (a.cover?.front.frames.compactMap(\.photoID) ?? [])
        #expect(!placed.contains("a0"))
        #expect(Set(Self.placed(a.spreads)) == Set(photos.dropFirst().map(\.id)))
    }
}
