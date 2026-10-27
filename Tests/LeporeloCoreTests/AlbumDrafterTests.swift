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

    static let june20 = DayKey(year: 2026, month: 6, day: 20)

    /// The day spreads (journal and gallery), in book order.
    static func daySpreads(_ a: Album) -> [Spread] {
        a.spreads.filter { $0.kind == .journal || $0.kind == .gallery }
    }

    /// Every page of `spreads`: its layout id ("" without one) and its frames' photos in frame order.
    static func pages(_ spreads: [Spread]) -> [(layout: String, photos: [PhotoID])] {
        spreads.flatMap { s in
            [PageSide.left, .right].enumerated().map { i, side in
                let layout = i < s.pageLayouts.count ? s.pageLayouts[i] ?? "" : ""
                return (layout, s.frames.filter { $0.id.hasPrefix(PageSpread.prefix(side)) }.compactMap(\.photoID))
            }
        }
    }

    /// Mixed orientations (every third photo portrait), aesthetic 0.2 + (i * 7 % 8) * 0.1.
    static func mixedPhotos(_ prefix: String, _ key: DayKey, count: Int) -> [Photo] {
        (0..<count).map {
            photo("\(prefix)\($0)", day: key, minute: $0, landscape: $0 % 3 != 2,
                  aesthetic: 0.2 + Double($0 * 7 % 8) * 0.1)
        }
    }

    /// Photos on pages whose frame wants the other orientation.
    static func misfits(_ a: Album) -> [PhotoID] {
        pages(daySpreads(a)).flatMap { page -> [PhotoID] in
            guard let layout = PageLayoutCatalog.layout(id: page.layout) else { return [] }
            return zip(page.photos, layout.frames).filter { id, frame in
                !TemplateLayout.fits(a.photos[id]!, frame.orientation)
            }.map(\.0)
        }
    }

    // Ruling 1, page by page: intro, the days in order (each starting with its journal), closing.
    @Test func draftProducesIntroDaySpreadsClosing() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 8)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 8))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(a.spreads.first?.kind == .intro && a.spreads.first?.templateID == "intro-1")
        #expect(a.spreads.last?.kind == .closing && a.spreads.last?.templateID == "closing-1")
        let middle = Array(a.spreads.dropFirst().dropLast())
        #expect(middle == Self.daySpreads(a))
        let keys = middle.compactMap(\.dayKey)
        #expect(keys.count == middle.count && keys == keys.sorted())
        for key in [Self.june18, Self.june19] {
            let ofDay = middle.filter { $0.dayKey == key }
            #expect(ofDay.map(\.kind) == [.journal] + Array(repeating: .gallery, count: ofDay.count - 1))
            let base = AlbumDrafter.dayString(key)
            #expect(ofDay.map(\.id) == ["\(base)-journal"] + (1..<ofDay.count).map { "\(base)-gallery-\($0)" })
        }
        #expect(Set(a.spreads.map(\.id)).count == a.spreads.count)
    }

    @Test func daySpreadsAreComposedPages() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 10), places: ["Ravello", "Minori"]),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 7))]
        let a = Self.draft(days, profile: p, format: f)
        let spreads = Self.daySpreads(a)
        #expect(!spreads.isEmpty)
        for s in spreads {
            #expect(s.templateID == "pages", "\(s.id)")
            #expect(s.pageLayouts.count == 2, "\(s.id)")
            #expect(s.pageLayouts.allSatisfy { $0.flatMap(PageLayoutCatalog.layout(id:)) != nil }, "\(s.id)")
        }
        for key in [Self.june18, Self.june19] {
            let ofDay = spreads.filter { $0.dayKey == key }
            let first = try #require(ofDay.first)
            #expect(first.kind == .journal)
            #expect(first.pageLayouts.first??.hasPrefix("opener-") == true)
            #expect(Self.text(first, .date) == AlbumDrafter.czechDate(key))
            #expect(Self.text(first, .body) == "")
            #expect(ofDay.dropFirst().allSatisfy { $0.kind == .gallery })
            // Only the opener page has the day's texts.
            #expect(Self.pages(ofDay).dropFirst().allSatisfy { !$0.layout.hasPrefix("opener-") })
        }
        #expect(Self.text(spreads.first { $0.dayKey == Self.june18 }!, .title) == "Ravello, Minori")
        #expect(Self.text(spreads.first { $0.dayKey == Self.june19 }!, .title) == "Bez místa")
    }

    // Spec 8: 40 photos of mixed orientations and scores in 3 days.
    @Test func noEmptyFramesAndEveryPhotoPlaced() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        #expect(p.pageCount.min == 20)
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 15)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 13)),
                    Self.day(Self.june20, Self.mixedPhotos("c", Self.june20, count: 12))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(Self.daySpreads(a).allSatisfy { $0.templateID == "pages" })
        for s in a.spreads where s.kind != .blank {
            #expect(!s.frames.isEmpty, "\(s.id)")
            #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)")
        }
        let selected = Set(days.flatMap(\.photos).map(\.id))
        let placed = Self.placed(Self.daySpreads(a))
        #expect(placed.count == selected.count)
        #expect(Set(placed) == selected)
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: a)))
        #expect(Self.misfits(a).isEmpty)
        // Spec 8: no `empty` page inside a day; no two adjacent pages with the same layout (the
        // rulings allow a forced repeat in a portrait-only run or after a parity split; this book
        // has neither, so the check is strict); every hero of a day is on a `full` page.
        let pages = Self.pages(Self.daySpreads(a))
        #expect(!pages.contains { $0.layout == "empty" || $0.layout.isEmpty }, "\(pages.map(\.layout))")
        #expect(zip(pages, pages.dropFirst()).allSatisfy { $0.layout != $1.layout }, "\(pages.map(\.layout))")
        let titlePhotos = Set([a.spreads.first, a.spreads.last].compactMap { $0?.frames.first?.photoID })
        let candidates = PagePlanner.heroCandidates(days.flatMap(\.photos), excluding: titlePhotos)
        let heroes = days.flatMap { PagePlanner.dayHeroes($0.photos, candidates: candidates) }
        #expect(heroes.count >= 3)
        let full = Set(pages.filter { $0.layout == "full" }.flatMap(\.photos))
        #expect(Set(heroes).isSubset(of: full), "heroes \(heroes.sorted()), full \(full.sorted())")
    }

    @Test func introPhotoIsNotAHero() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        // Scores below the hero minimum except "star" (the intro photo) and "hero".
        var photos = (0..<12).map {
            Self.photo("a\($0)", day: Self.june18, minute: $0, aesthetic: 0.1 + Double($0 % 3) * 0.1)
        }
        photos[3] = Self.photo("star", day: Self.june18, minute: 3, aesthetic: 0.95)
        photos[8] = Self.photo("hero", day: Self.june18, minute: 8, aesthetic: 0.9)
        let a = Self.draft([Self.day(Self.june18, photos)], profile: p, format: f)
        #expect(a.spreads.first?.frames.first?.photoID == "star")
        let pages = Self.pages(Self.daySpreads(a))
        let full = pages.filter { $0.layout == "full" }.flatMap(\.photos)
        #expect(full.contains("hero"))
        #expect(!full.contains("star"))
        #expect(pages.contains { $0.photos.contains("star") })
    }

    // Spec 4.2: padding splits a short book into 1-photo pages, but the intro and closing photos
    // stay ordinary photos (never `full`) in the day.
    @Test func paddingKeepsIntroAndClosingPhotosOffFullPages() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        // Scores below the hero minimum; "star" is the intro photo, "last" the closing photo.
        // Without the exclusion both land on `full` pages here.
        var photos = (0..<10).map { Self.photo("a\($0)", day: Self.june18, minute: $0, aesthetic: 0.1 + Double($0 % 3) * 0.05) }
        photos[3] = Self.photo("star", day: Self.june18, minute: 3, aesthetic: 0.95)
        photos[9] = Self.photo("last", day: Self.june18, minute: 9, aesthetic: 0.1)
        let a = Self.draft([Self.day(Self.june18, photos)], profile: p, format: f)
        #expect(a.spreads.first?.frames.first?.photoID == "star")
        #expect(a.spreads.last?.frames.first?.photoID == "last")
        let pages = Self.pages(Self.daySpreads(a))
        #expect(pages.filter { $0.photos.count == 1 }.count >= 4)   // padded down to single photos
        let full = pages.filter { $0.layout == "full" }.flatMap(\.photos)
        #expect(!full.contains("star"))
        #expect(!full.contains("last"))
        #expect(pages.contains { $0.photos.contains("star") })
        #expect(pages.contains { $0.photos.contains("last") })
        #expect(Self.misfits(a).isEmpty)
    }

    @Test func galleryOnlyDayHasNoOpenerAndSkipsExcludedPhotos() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 7)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 5))]
        let a = AlbumDrafter.draft(album: Self.album(days), days: days, profile: p, format: f, options: .init(),
                                   includeIntro: true, reservedSpreads: 0, excludedFromDays: ["a0", "b1"],
                                   galleryOnlyDays: [Self.june18])
        let june18 = Self.daySpreads(a).filter { $0.dayKey == Self.june18 }
        #expect(!june18.isEmpty && june18.allSatisfy { $0.kind == .gallery && $0.templateID == "pages" })
        #expect(Self.pages(june18).allSatisfy { !$0.layout.hasPrefix("opener-") })
        #expect(june18.allSatisfy { $0.texts.allSatisfy(\.text.isEmpty) })
        #expect(Self.daySpreads(a).first { $0.dayKey == Self.june19 }?.kind == .journal)
        let placed = Self.placed(Self.daySpreads(a))
        #expect(Set(placed) == Set(days.flatMap(\.photos).map(\.id)).subtracting(["a0", "b1"]))
        #expect(placed.count == 10)
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

    @Test func portraitPhotosGoToPortraitFrames() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let d1 = [Self.photo("l0", day: Self.june18, minute: 0, aesthetic: 0.9),
                  Self.photo("p0", day: Self.june18, minute: 1, landscape: false, aesthetic: 0.2),
                  Self.photo("l1", day: Self.june18, minute: 2, aesthetic: 0.8),
                  Self.photo("l2", day: Self.june18, minute: 3, aesthetic: 0.7),
                  Self.photo("p1", day: Self.june18, minute: 4, landscape: false, aesthetic: 0.6),
                  Self.photo("l3", day: Self.june18, minute: 5, aesthetic: 0.5),
                  Self.photo("l4", day: Self.june18, minute: 6, aesthetic: 0.4)]
        let d2 = Self.mixedPhotos("b", Self.june19, count: 9)
        let a = Self.draft([Self.day(Self.june18, d1), Self.day(Self.june19, d2)], profile: p, format: f)
        #expect(Self.misfits(a).isEmpty)
        #expect(Set(Self.placed(Self.daySpreads(a))) == Set((d1 + d2).map(\.id)))
    }

    // Spec 4.2: the day's portrait photo gets a portrait frame, not a crop into a landscape one.
    @Test func lonePortraitGetsPortraitFrame() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        let d = [Self.photo("l0", day: Self.june18, minute: 0, aesthetic: 0.9),
                 Self.photo("p0", day: Self.june18, minute: 1, landscape: false, aesthetic: 0.5),
                 Self.photo("l1", day: Self.june18, minute: 2, aesthetic: 0.8)]
        let a = Self.draft([Self.day(Self.june18, d)], profile: p, format: f)
        let page = try #require(Self.pages(Self.daySpreads(a)).first { $0.photos.contains("p0") })
        let layout = try #require(PageLayoutCatalog.layout(id: page.layout))
        let frame = layout.frames[page.photos.firstIndex(of: "p0")!]
        #expect(frame.orientation == .portrait)
        #expect(Self.daySpreads(a).allSatisfy { $0.frames.allSatisfy { $0.photoID != nil } })
    }

    @Test func smallDayHasNoEmptyFrames() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 2), places: ["Ravello"]),
                    Self.day(Self.june19, Self.dayPhotos("b", Self.june19, count: 1))]
        let a = Self.draft(days, profile: p, format: f)
        for s in a.spreads where s.kind != .blank {
            #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)")
        }
        let first = try #require(a.spreads.first { $0.dayKey == Self.june18 })
        #expect(first.kind == .journal)
        #expect(Self.text(first, .date) == "čtvrtek 18. června 2026")
        #expect(Self.text(first, .title) == "Ravello")
        let second = try #require(a.spreads.first { $0.dayKey == Self.june19 })
        #expect(second.pageLayouts.first == "opener-text")
        #expect(Set(Self.placed(Self.daySpreads(a))) == ["a0", "a1", "b0"])
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: a)))
    }

    // Padding: the day with the most photos per page (no opener, no full; ties: the earlier day)
    // gets exactly 2 more pages by splitting its fullest pages, before any blank spread.
    @Test func paddingSplitsTheDensestDayBeforeAddingBlank() throws {
        let (lax, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 9)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 40))]
        let loose = Self.draft(days, profile: lax, format: f)
        func dayPages(_ a: Album, _ key: DayKey) -> [(layout: String, photos: [PhotoID])] {
            Self.pages(Self.daySpreads(a).filter { $0.dayKey == key })
        }
        func average(_ pages: [(layout: String, photos: [PhotoID])]) -> Double {
            let ordinary = pages.filter { !$0.layout.hasPrefix("opener-") && $0.layout != "full" }
            return Double(ordinary.map(\.photos.count).reduce(0, +)) / Double(max(ordinary.count, 1))
        }
        let densest = average(dayPages(loose, Self.june19)) > average(dayPages(loose, Self.june18))
            ? Self.june19 : Self.june18
        let other = densest == Self.june18 ? Self.june19 : Self.june18
        let min = AlbumDrafter.pageCount(of: loose) + 2
        let (p, _) = try Self.canva(PageCountRule(min: min, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let a = Self.draft(days, profile: p, format: f)
        #expect(!a.spreads.contains { $0.kind == .blank })
        #expect(AlbumDrafter.pageCount(of: a) == min)
        #expect(dayPages(a, densest).count == dayPages(loose, densest).count + 2)
        #expect(dayPages(a, other).map(\.layout) == dayPages(loose, other).map(\.layout))
        #expect(Self.placed(Self.daySpreads(a)).count == 49)
        #expect(Self.misfits(a).isEmpty)
        #expect(Set(a.spreads.map(\.id)).count == a.spreads.count)
    }

    // Spec 4.3: a small book reaches Canva's 20 pages with photo pages first; blanks only once no
    // day has a page of 2+ photos left to split.
    @Test func smallBookFillsPhotoPagesBeforeBlanks() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        let photos = Self.mixedPhotos("a", Self.june18, count: 12)
        let a = Self.draft([Self.day(Self.june18, photos)], profile: p, format: f)
        #expect(AlbumDrafter.pageCount(of: a) == 20)
        let days = Self.daySpreads(a)
        let pages = Self.pages(days)
        // Before splitting: 6 day pages and 5 blank spreads.
        #expect(pages.count > 6)
        #expect(a.spreads.filter { $0.kind == .blank }.count < 5)
        // Blanks only because the day cannot get 2 more pages.
        if a.spreads.contains(where: { $0.kind == .blank }) {
            let planned = pages.map { PlannedPage(layoutID: $0.layout, photos: $0.photos.map { a.photos[$0]! }) }
            #expect(PagePlanner.expand(planned, by: 2, weights: .init()) == nil)
        }
        for s in a.spreads where s.kind != .blank { #expect(s.frames.allSatisfy { $0.photoID != nil }, "\(s.id)") }
        let placed = Self.placed(days)
        #expect(placed.count == 12 && Set(placed) == Set(photos.map(\.id)))
        #expect(pages.count % 2 == 0)
        #expect(Self.misfits(a).isEmpty)
    }

    // A day of one photo cannot get more pages: blank spreads go before the closing.
    @Test func blankPaddingGoesBeforeClosing() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 12, max: nil, multipleOf: 4), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 1))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(a.spreads.map(\.kind) == [.intro, .journal, .blank, .blank, .blank, .closing])
        #expect(a.spreads.filter { $0.kind == .blank }.map(\.id) == ["blank-1", "blank-2", "blank-3"])
        #expect(AlbumDrafter.pageCount(of: a) == 12)
    }

    @Test func overMaximumKeepsContent() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: 6, multipleOf: 2), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 30))]
        let a = Self.draft(days, profile: p, format: f)
        #expect(Self.placed(Self.daySpreads(a)).count == 30)
        #expect(AlbumDrafter.pageCount(of: a) > 6)
        #expect(!a.spreads.contains { $0.kind == .blank })
    }

    @Test func noClosingOption() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.dayPhotos("a", Self.june18, count: 3))]
        let a = Self.draft(days, profile: p, format: f, options: DraftOptions(includeClosing: false))
        #expect(a.spreads.first?.kind == .intro)
        #expect(a.spreads.dropFirst().allSatisfy { $0.kind == .journal || $0.kind == .gallery })
        #expect(a.spreads.dropFirst().first?.kind == .journal)
    }

    @Test func deterministic() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 8)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 5))]
        #expect(Self.draft(days, profile: p, format: f) == Self.draft(days, profile: p, format: f))
    }

    // The day's pages are the planner's, with the liked weights; frame L.photoK / R.photoK holds
    // the page's K-th photo.
    @Test func dayPagesComeFromThePlannerWithTheLikedWeights() throws {
        let (p, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let photos = Self.mixedPhotos("a", Self.june18, count: 14)
        let weights = LayoutWeights(liked: ["mosaic-5", "portraits-2"])
        let a = Self.draft([Self.day(Self.june18, photos)], profile: p, format: f,
                           options: DraftOptions(layoutWeights: weights))
        let intro = try #require(a.spreads.first?.frames.first?.photoID)
        let closing = try #require(a.spreads.last?.frames.first?.photoID)
        let planned = PagePlanner.planDay(photos, heroCandidates: PagePlanner.heroCandidates(photos, excluding: [intro, closing]),
                                          opener: true, target: 3, weights: weights, excluding: [intro, closing])
        let pages = Self.pages(Self.daySpreads(a))
        #expect(pages.map(\.layout) == planned.map(\.layoutID))
        #expect(pages.map(\.photos) == planned.map { $0.photos.map(\.id) })
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

    // Review focus 4: 400 photos in 10 days are above Canva's 98 pages at 3 photos per page; the
    // drafter plans again with 4, then 5 photos per page, and drops nothing.
    @Test func overMaximumReplansDenser() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        #expect(p.pageCount.max == 98)
        let days = (0..<10).map { i -> DayGroup in
            let key = DayKey(year: 2026, month: 6, day: 10 + i)
            return Self.day(key, Self.mixedPhotos("d\(i)-", key, count: 40))
        }
        let a = Self.draft(days, profile: p, format: f)
        let (noMax, _) = try Self.canva(PageCountRule(min: 20, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let three = Self.draft(days, profile: noMax, format: f, options: DraftOptions(photosPerPage: 3))
        let four = Self.draft(days, profile: noMax, format: f, options: DraftOptions(photosPerPage: 4))
        let five = Self.draft(days, profile: noMax, format: f, options: DraftOptions(photosPerPage: 5))
        #expect(AlbumDrafter.pageCount(of: three) > 98)
        #expect(AlbumDrafter.pageCount(of: a) < AlbumDrafter.pageCount(of: three))
        #expect(a.spreads == (AlbumDrafter.pageCount(of: four) <= 98 ? four : five).spreads)
        let placed = Self.placed(Self.daySpreads(a))
        #expect(placed.count == 400)
        #expect(Set(placed).count == 400)
    }

    @Test func tripThatFitsAtFourPerPageIsUnderTheMaximum() throws {
        let (lax, f) = try Self.canva(PageCountRule(min: 2, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 20)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 20))]
        let three = Self.draft(days, profile: lax, format: f)
        let four = Self.draft(days, profile: lax, format: f, options: DraftOptions(photosPerPage: 4))
        #expect(AlbumDrafter.pageCount(of: four) < AlbumDrafter.pageCount(of: three))
        let max = AlbumDrafter.pageCount(of: four)
        let (p, _) = try Self.canva(PageCountRule(min: 2, max: max, multipleOf: 2), formatID: "landscape-8x6in")
        let a = Self.draft(days, profile: p, format: f)
        #expect(a.spreads == four.spreads)
        #expect(p.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: a)))
    }

    @Test func normalTripKeepsThreePerPage() throws {
        let (p, f) = try Self.canva(formatID: "landscape-8x6in")
        let days = [Self.day(Self.june18, Self.mixedPhotos("a", Self.june18, count: 12)),
                    Self.day(Self.june19, Self.mixedPhotos("b", Self.june19, count: 12))]
        let a = Self.draft(days, profile: p, format: f)
        let (noMax, _) = try Self.canva(PageCountRule(min: 20, max: nil, multipleOf: 2), formatID: "landscape-8x6in")
        #expect(AlbumDrafter.pageCount(of: a) <= 98)
        #expect(a.spreads == Self.draft(days, profile: noMax, format: f).spreads)
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
