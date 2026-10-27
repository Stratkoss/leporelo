import Testing
import Foundation
@testable import LeporeloCore

@Suite struct PagePlannerTests {
    typealias T = AlbumDrafterTests
    static let day = AlbumDrafterTests.june18

    /// One photo per flag, landscape (`true`) or portrait, one minute apart; ids `p0`, `p1`, ...
    static func photos(_ landscape: [Bool]) -> [Photo] {
        landscape.enumerated().map { T.photo("p\($0)", day: day, minute: $0, landscape: $1) }
    }

    static func plan(_ photos: [Photo], heroes: Set<PhotoID> = [], opener: Bool = true, target: Int = 3,
                     liked: Set<String> = []) -> [PlannedPage] {
        PagePlanner.planDay(photos, heroCandidates: heroes, opener: opener, target: target,
                            weights: LayoutWeights(liked: liked))
    }

    static func layout(_ page: PlannedPage) -> PageLayout { PageLayoutCatalog.layout(id: page.layoutID)! }

    /// Every placed photo with the orientation of its frame.
    static func placements(_ pages: [PlannedPage]) -> [(photo: Photo, slot: Orientation)] {
        pages.flatMap { p in zip(p.photos, layout(p).frames.map(\.orientation)).map { ($0, $1) } }
    }

    static func isPortrait(_ p: Photo) -> Bool { p.pixelHeight > p.pixelWidth }

    /// A photo whose `PhotoScore.score` is `score`: the helper's sharpness 500 alone would add 0.4.
    static func scored(_ i: Int, _ score: Double, landscape: Bool = true, pixels: (Int, Int)? = nil) -> Photo {
        var p = T.photo("p\(i)", day: day, minute: i, landscape: landscape, aesthetic: score, pixels: pixels)
        p.analysis?.sharpness = 500 * score
        return p
    }

    static func checkCommon(_ pages: [PlannedPage], _ photos: [Photo]) {
        #expect(pages.count % 2 == 0)
        #expect(pages.flatMap(\.photos).map(\.id).sorted() == photos.map(\.id).sorted())
        #expect(pages.allSatisfy { $0.photos.count == layout($0).photoCount })
    }

    // Padding (spec 4.3): splitting the page with the most photos adds exactly the pages asked for,
    // down to one photo per page; the opener is never split.
    @Test func expandSplitsTheFullestPageDownToSinglePhotos() throws {
        let photos = (0..<4).map { T.photo("p\($0)", day: Self.day, minute: $0, pixels: (1024, 768)) }
        let start = [PlannedPage(layoutID: "opener-text", photos: []),
                     PlannedPage(layoutID: "grid-4", photos: photos)]
        let two = try #require(PagePlanner.expand(start, by: 2, weights: .init()))
        #expect(two.count == 4)
        #expect(two[0].layoutID == "opener-text")
        #expect(two.flatMap(\.photos).map(\.id).sorted() == photos.map(\.id))
        #expect(two.allSatisfy { $0.photos.count == Self.layout($0).photoCount })
        #expect(Self.placements(two).allSatisfy { TemplateLayout.fits($0.photo, $0.slot) })
        #expect(two.dropFirst().map(\.photos.count).max() == 2)

        let singles = try #require(PagePlanner.expand(two, by: 1, weights: .init()))
        #expect(singles.count == 5)
        #expect(singles.dropFirst().allSatisfy { $0.photos.count == 1 && $0.layoutID == "framed-1" })
        #expect(singles.flatMap(\.photos).map(\.id) == photos.map(\.id))   // chronological
        #expect(PagePlanner.expand(singles, by: 1, weights: .init()) == nil)
        // Two photos split only once: by 2 is nil, not a partial expansion.
        let pair = [start[0], PlannedPage(layoutID: "landscape-2", photos: Array(photos.prefix(2)))]
        #expect(PagePlanner.expand(pair, by: 1, weights: .init())?.count == 3)
        #expect(PagePlanner.expand(pair, by: 2, weights: .init()) == nil)
    }

    // Spec 4.2: the intro and closing photos never get a whole page, not even as a rescue page.
    @Test func excludedPhotosGetFramedInsteadOfFull() throws {
        let photo = T.photo("p0", day: Self.day, minute: 0)
        #expect(PagePlanner.planDay([photo], heroCandidates: [], opener: true, target: 3, weights: .init())
            .map(\.layoutID) == ["opener-text", "full"])
        #expect(PagePlanner.planDay([photo], heroCandidates: [], opener: true, target: 3, weights: .init(),
                                    excluding: ["p0"]).map(\.layoutID) == ["opener-text", "framed-1"])
        let photos = Self.photos([true, true])
        let pair = [PlannedPage(layoutID: "opener-text", photos: []),
                    PlannedPage(layoutID: "landscape-2", photos: photos)]
        let split = try #require(PagePlanner.expand(pair, by: 1, weights: .init(), excluding: ["p0", "p1"]))
        #expect(split.map(\.layoutID) == ["opener-text", "framed-1", "framed-1"])
    }

    @Test func twelveLandscapesEvenNoRepeatsNoMismatch() {
        let photos = Self.photos(Array(repeating: true, count: 12))
        let pages = Self.plan(photos)
        Self.checkCommon(pages, photos)
        #expect(Self.layout(pages[0]).role == .opener)
        #expect(zip(pages, pages.dropFirst()).allSatisfy { $0.layoutID != $1.layoutID })
        #expect(Self.placements(pages).allSatisfy { !($0.photo.isLandscape && $0.slot == .portrait) })
    }

    @Test func portraitsGoToPortraitSlots() {
        let photos = Self.photos([false, true, false, true, false, true, true, true])
        let pages = Self.plan(photos)
        Self.checkCommon(pages, photos)
        #expect(Self.placements(pages).allSatisfy { !(Self.isPortrait($0.photo) && $0.slot == .landscape) })
    }

    @Test func threePortraitsOnly() {
        let photos = Self.photos([false, false, false])
        let pages = Self.plan(photos)
        Self.checkCommon(pages, photos)
        #expect(Self.placements(pages).allSatisfy { $0.slot == .portrait })
    }

    @Test func heroKeepsChronologicalPlace() throws {
        let photos = Self.photos(Array(repeating: true, count: 10))
        let hero = photos[5]
        let pages = Self.plan(photos, heroes: [hero.id])
        Self.checkCommon(pages, photos)
        let h = try #require(pages.firstIndex { $0.photos.contains(hero) })
        #expect(pages[h] == PlannedPage(layoutID: "full", photos: [hero]))
        #expect(pages[..<h].flatMap(\.photos).allSatisfy { $0.capturedAt < hero.capturedAt })
        #expect(pages[(h + 1)...].flatMap(\.photos).allSatisfy { $0.capturedAt > hero.capturedAt })
    }

    @Test func heroCandidatesThresholds() {
        // Scores 0.10 ... 0.95; the 85th percentile is the score at index 16 (0.816), above 0.6.
        let high = (0..<20).map { i -> Photo in
            let s = 0.1 + 0.85 * Double(i) / 19
            switch i {
            case 16: return Self.scored(i, s, pixels: (2048, 1536))
            case 17: return Self.scored(i, s, pixels: (1024, 768))
            case 18: return Self.scored(i, s, landscape: false)
            default: return Self.scored(i, s)
            }
        }
        #expect(abs(PhotoScore.score(high[0]) - 0.1) < 1e-9 && abs(PhotoScore.score(high[19]) - 0.95) < 1e-9)
        // 15 (0.77, 4000 px) is above 0.6 but below the percentile; 19 is excluded.
        #expect(PagePlanner.heroCandidates(high, excluding: ["p19"]) == ["p16"])

        // Scores 0.10 ... 0.65; the percentile (0.563) is below 0.6, so 0.6 decides: 17 (0.592) is out.
        let low = (0..<20).map { i -> Photo in
            let s = 0.1 + 0.55 * Double(i) / 19
            return i == 19 ? Self.scored(i, s, pixels: (2048, 2048)) : Self.scored(i, s)
        }
        #expect(PagePlanner.heroCandidates(low, excluding: []) == ["p18", "p19"])
        #expect(PagePlanner.heroCandidates([], excluding: []) == [])
    }

    @Test func singlePhotoDays() {
        let big = T.photo("a", day: Self.day, minute: 0, pixels: (4000, 3000))
        let small = T.photo("b", day: Self.day, minute: 0, pixels: (1024, 768))
        let tall = T.photo("c", day: Self.day, minute: 0, landscape: false)
        #expect(Self.plan([big]) == [PlannedPage(layoutID: "opener-text", photos: []),
                                     PlannedPage(layoutID: "full", photos: [big])])
        #expect(Self.plan([small]).map(\.layoutID) == ["opener-text", "framed-1"])
        #expect(Self.plan([tall]).map(\.layoutID) == ["opener-text", "portrait-text"])
    }

    @Test func likedLayoutWins() {
        let photos = Self.photos(Array(repeating: true, count: 10))
        // grid-4: 1/(1+1) = 0.5 against mosaic-6: 1/(1+3) = 0.25; liked mosaic-6: 3 * 0.25 = 0.75.
        #expect(Self.plan(photos, opener: false).first?.layoutID == "grid-4")
        #expect(Self.plan(photos, opener: false, liked: ["mosaic-6"]).first?.layoutID == "mosaic-6")
    }

    @Test func twoLandscapesLeftUseLandscapeTwo() {
        let photos = Self.photos(Array(repeating: true, count: 6))
        let pages = Self.plan(photos, opener: false)
        #expect(pages.map(\.layoutID) == ["grid-4", "landscape-2"])
        #expect(pages[0].photos == Array(photos[0..<4]).sorted(by: TemplateLayout.rank))
    }

    // Greedy gives opener-3, grid-4, full (odd); the search prefers an even, clean day over
    // splitting pages afterwards.
    @Test func eightLandscapesMakeTwoDensePages() {
        let photos = Self.photos(Array(repeating: true, count: 8))
        #expect(Self.plan(photos).map(\.layoutID) == ["opener-2l", "mosaic-6"])
    }

    // One photo between two heroes: a full page there would make three in a row.
    @Test func fullPagesAreNotAdjacent() {
        let photos = Self.photos(Array(repeating: true, count: 13))
        let pages = Self.plan(photos, heroes: ["p5", "p7"])
        Self.checkCommon(pages, photos)
        #expect(zip(pages, pages.dropFirst()).allSatisfy { $0.layoutID != $1.layoutID })
        #expect(pages.contains(PlannedPage(layoutID: "framed-1", photos: [photos[6]])))
    }

    // A square ranks first (earliest of equal scores) but must not take the ▯ frame the ▯ needs.
    @Test func squaresLeaveFramesToOrientedPhotos() {
        let square = T.photo("s", day: Self.day, minute: 0, pixels: (3000, 3000))
        let tall = T.photo("t", day: Self.day, minute: 1, landscape: false)
        let photos = [square, tall] + (2..<7).map { T.photo("l\($0)", day: Self.day, minute: $0) }
        let pages = Self.plan(photos, opener: false)
        Self.checkCommon(pages, photos)
        #expect(pages.first?.layoutID == "portrait-left-2l")
        #expect(pages.first?.photos.first == tall)
        #expect(Self.placements(pages).allSatisfy { TemplateLayout.fits($0.photo, $0.slot) })
    }

    // The odd-page rule splits mosaic-6 although the split repeats grid-4; no empty page while
    // the day has an opener.
    @Test func oddDayWithOpenerSplitsInsteadOfEmpty() {
        let photos = Self.photos(Array(repeating: true, count: 12))
        let pages = Self.plan(photos, heroes: ["p0", "p11"])
        Self.checkCommon(pages, photos)
        #expect(pages.map(\.layoutID) == ["opener-text", "full", "grid-4", "grid-4", "landscape-2", "full"])
    }

    @Test func noOpenerWhenDisabled() {
        let days = [Self.photos([true]), Self.photos([false]), Self.photos([false, false, false]),
                    Self.photos(Array(repeating: true, count: 12)),
                    Self.photos([false, true, false, true, false, true, true, true])]
        for photos in days {
            let pages = Self.plan(photos, opener: false)
            Self.checkCommon(pages, photos)
            #expect(pages.allSatisfy { Self.layout($0).role != .opener })
        }
    }

    /// Spec 8 invariants on a long mixed day with heroes; also keeps the search fast.
    @Test func mixedDayInvariants() {
        let pattern: [Bool] = (0..<60).map { $0 % 3 != 1 || $0 % 7 == 0 }
        let photos = Self.photos(pattern)
        let heroes: Set<PhotoID> = ["p6", "p7", "p21", "p42"]
        let pages = Self.plan(photos, heroes: heroes)
        Self.checkCommon(pages, photos)
        // p7 follows p6 directly, so it is an ordinary photo.
        for i in [6, 21, 42] { #expect(pages.contains(PlannedPage(layoutID: "full", photos: [photos[i]]))) }
        #expect(!pages.contains { $0.layoutID == "full" && $0.photos == [photos[7]] })
        #expect(zip(pages, pages.dropFirst()).allSatisfy { $0.layoutID != $1.layoutID })
    }
}
