import Foundation

/// How strongly the automatic design prefers each layout (spec 6): with nothing liked every layout
/// weighs 1; otherwise liked layouts weigh 3 and the others 1.
public struct LayoutWeights: Sendable, Equatable {
    public static let likedWeight = 3.0

    public var liked: Set<String>

    public init(liked: Set<String> = []) {
        self.liked = liked
    }

    public func weight(_ id: String) -> Double {
        liked.contains(id) ? Self.likedWeight : 1
    }
}

/// One planned page. `photos` are in frame order (`photo1`...`photoN` of the layout) and fit their
/// frames by orientation, except on a rescue page.
public struct PlannedPage: Sendable, Equatable {
    public var layoutID: String
    public var photos: [Photo]

    public init(layoutID: String, photos: [Photo]) {
        self.layoutID = layoutID
        self.photos = photos
    }
}

/// Plans the pages of one day from `PageLayoutCatalog` (spec 4.2-4.3). Pure and deterministic.
///
/// The day is split at its heroes into runs of ordinary photos; each hero is a `full` page in its
/// chronological place and the pages of a run use only the run's photos. Page by page, the
/// candidates are the dense layouts that the first photo of the run plus the earliest fitting
/// photos of the 6-photo window fill (`weight × 1/(1+|n−target|)`, halved when it leaves 1-3
/// photos no single layout fills exactly; the layouts of the two previous pages go last; ties:
/// more photos, then catalog order). With no candidate a rescue page is used.
///
/// Search: taking the first candidate every time (greedy) can paint itself into a corner (12 ▭
/// give opener-3, grid-4, grid-4, full). So each run is searched depth first in that same order
/// for the first complete plan that is clean: no photo in a frame of the other orientation and no
/// layout repeating the previous page (also across the run's ends). The last run with photos must
/// also leave the day with an even page count (spec: even pages, and orientations matching
/// whenever possible, outrank the brief's split rule). A greedy run that already meets that is
/// kept unchanged. The search tries the brief's pages first and only then `extras` (alternative
/// rescue pages, `opener-text` with photos left); failed states are memoized and at most
/// `searchBudget` pages are tried per phase. Nothing found: the greedy run if clean, else the
/// first clean one seen, else the greedy one. A day still odd tries to flip the parity of an
/// earlier run, then falls back to the odd-page rule (`makeEven`).
public enum PagePlanner {
    public static let heroMinLongSidePX = 1800
    public static let heroMinScore = 0.6
    public static let heroPercentile = 0.85
    public static let windowSize = 6
    /// Pages the search may try per plan before it settles for a fallback.
    static let searchBudget = 2000

    /// Photos that may get a whole page (spec 4.2): landscape or square, long side at least
    /// `heroMinLongSidePX`, score at least `heroMinScore` and at least the `heroPercentile`
    /// score of `selected` (the value at index ⌊0.85 × (n − 1)⌋ of the ascending scores).
    /// `excluding` (intro, closing, cover photos) still counts towards the percentile.
    public static func heroCandidates(_ selected: [Photo], excluding: Set<PhotoID>) -> Set<PhotoID> {
        guard !selected.isEmpty else { return [] }
        let scores = selected.map(PhotoScore.score).sorted()
        let percentile = scores[Int((heroPercentile * Double(scores.count - 1)).rounded(.down))]
        return Set(selected.filter { p in
            let s = PhotoScore.score(p)
            return !excluding.contains(p.id) && TemplateLayout.fits(p, .landscape)
                && max(p.pixelWidth, p.pixelHeight) >= heroMinLongSidePX && s >= heroMinScore && s >= percentile
        }.map(\.id))
    }

    /// The pages of one day; `photos` are chronological. The page count is even. Photos in
    /// `excluding` (intro, closing, cover) never get a `full` page, not even as a rescue page
    /// (spec 4.2): a single one gets `framed-1`.
    public static func planDay(_ photos: [Photo], heroCandidates: Set<PhotoID>, opener: Bool, target: Int,
                               weights: LayoutWeights, excluding: Set<PhotoID> = []) -> [PlannedPage] {
        let heroes = dayHeroes(photos, candidates: heroCandidates)
        var runs: [[Photo]] = [[]]
        for p in photos {
            if heroes.contains(p.id) { runs.append([]) } else { runs[runs.count - 1].append(p) }
        }
        let heroPages = photos.filter { heroes.contains($0.id) }.map { PlannedPage(layoutID: "full", photos: [$0]) }
        let planner = Planner(target: target, weights: weights, notFull: excluding)
        var parts: [[PlannedPage]] = []
        /// The pages before run `i`.
        func prefix(_ i: Int) -> [PlannedPage] {
            (0..<i).flatMap { parts[$0] + [heroPages[$0]] }
        }
        func plan(_ i: Int, goal: Planner.Goal) -> [PlannedPage] {
            planner.plan(runs[i], opener: opener && i == 0, before: prefix(i).map(\.layoutID),
                         after: i < heroPages.count ? "full" : nil, goal: goal)
        }
        // The last run with photos also evens the day (counting the heroes after it).
        let parityRun = runs.lastIndex { !$0.isEmpty } ?? 0
        for i in runs.indices {
            parts.append(plan(i, goal: i == parityRun ? .even(offset: prefix(i).count + runs.count - 1 - i) : .any))
        }
        var pages = prefix(runs.count - 1) + parts[runs.count - 1]
        // Still odd: an earlier run may change its parity and stay clean.
        if pages.count % 2 == 1 {
            for i in (0..<parityRun).reversed() {
                let other = plan(i, goal: .even(offset: pages.count - parts[i].count))
                if (other.count - parts[i].count) % 2 != 0
                    && planner.isClean(other, before: prefix(i).map(\.layoutID), after: "full") {
                    parts[i] = other
                    pages = prefix(runs.count - 1) + parts[runs.count - 1]
                    break
                }
            }
        }
        planner.makeEven(&pages)
        return pages
    }

    /// Padding (spec 4.3): `pages` (one day's plan) with exactly `extra` more pages, or nil when that
    /// is not possible. Each step splits the page with the most photos (ties: the earlier page; not
    /// an opener, not `full`, at least 2 photos) into two pages, like the odd-page rule: its photos,
    /// chronological, planned again with half the target into exactly 2 pages, else cut
    /// chronologically in two (see `splitting`). 1-photo pages follow the rescue rule (`full` for
    /// a ▭/square with a long side of 1800 px or more, else `framed-1`; ▯ `portrait-text`). A split
    /// must keep orientations matching; a page that cannot split so yields to the next one.
    /// Layouts repeat only where a split forces it. Photos in `excluding` get `framed-1` instead of
    /// `full`, as in `planDay`.
    public static func expand(_ pages: [PlannedPage], by extra: Int, weights: LayoutWeights,
                              excluding: Set<PhotoID> = []) -> [PlannedPage]? {
        let planner = Planner(target: 1, weights: weights, notFull: excluding)
        var result = pages
        for _ in 0..<max(0, extra) {
            guard let split = planner.splitting(result, clean: true) else { return nil }
            result = split
        }
        return result
    }

    /// At most `max(1, count / 6)` best-ranked candidates; a hero right after another hero is an
    /// ordinary photo.
    static func dayHeroes(_ photos: [Photo], candidates: Set<PhotoID>) -> Set<PhotoID> {
        let limit = max(1, photos.count / windowSize)
        let best = Set(photos.filter { candidates.contains($0.id) }.sorted(by: TemplateLayout.rank)
            .prefix(limit).map(\.id))
        var heroes = Set<PhotoID>()
        var previousIsHero = false
        for p in photos {
            previousIsHero = best.contains(p.id) && !previousIsHero
            if previousIsHero { heroes.insert(p.id) }
        }
        return heroes
    }
}

private struct Planner {
    var target: Int
    var weights: LayoutWeights
    /// Photos that never get a `full` page (intro, closing, cover).
    var notFull: Set<PhotoID> = []

    // MARK: Search

    /// What the page count of a planned run should be.
    enum Goal {
        case any
        /// Even together with `offset` other pages.
        case even(offset: Int)
        case exactly(Int)

        func accepts(_ count: Int) -> Bool {
            switch self {
            case .any: return true
            case .even(let offset): return (offset + count) % 2 == 0
            case .exactly(let n): return count == n
            }
        }

        /// The part of the page count that matters for `accepts`.
        func relevant(_ count: Int) -> Int {
            switch self {
            case .any: return 0
            case .even: return count % 2
            case .exactly: return count
            }
        }
    }

    /// The pages of `run` (ordinary photos between two heroes) between the pages `before` and the
    /// page `after`: the greedy plan if clean and meeting `goal`; else the first such plan in
    /// greedy order, searched first with the brief's pages only and then with `extras`. With
    /// `strict` (the odd-page rule, where only the goal makes the plan useful) the goal outranks
    /// variety: next the first plan meeting it with matching orientations but repeated layouts,
    /// then the greedy plan if it meets it. Otherwise: the greedy plan if clean, else the first
    /// clean plan seen, else the greedy plan.
    func plan(_ run: [Photo], opener: Bool, before: [String], after: String?, goal: Goal,
              strict: Bool = false) -> [PlannedPage] {
        var greedy: [PlannedPage] = []
        var queue = run
        while !isComplete(queue, greedy, opener: opener) {
            let (page, rest) = options(queue, greedy, opener: opener, before: before, extras: false)[0]
            greedy.append(page)
            queue = rest
        }
        let greedyIsClean = isClean(greedy, before: before, after: after)
        if greedyIsClean && goal.accepts(greedy.count) { return greedy }

        var firstClean: [PlannedPage]?
        let phases: [(extras: Bool, variety: Bool)] = [(false, true), (true, true)] + (strict ? [(true, false)] : [])
        for (extras, variety) in phases {
            var budget = PagePlanner.searchBudget
            // States known to lead nowhere. A state is the page count (as far as `goal` cares),
            // the last two layouts and the queue; the queue is its count plus its first 6 photos,
            // because photos past the window were never taken, so the rest is the run's tail.
            var deadEnds = Set<String>()
            func search(_ queue: [Photo], _ pages: [PlannedPage]) -> [PlannedPage]? {
                let recent = Array((before + pages.map(\.layoutID)).suffix(2))
                let key = ([String(goal.relevant(pages.count)), String(queue.count)] + recent
                    + queue.prefix(PagePlanner.windowSize).map(\.id)).joined(separator: "|")
                if deadEnds.contains(key) { return nil }
                if isComplete(queue, pages, opener: opener) {
                    guard !variety || pages.last?.layoutID != after else { return nil }
                    if goal.accepts(pages.count) { return pages }
                    if variety && firstClean == nil { firstClean = pages }
                    return nil
                }
                for (page, rest) in options(queue, pages, opener: opener, before: before, extras: extras) {
                    guard budget > 0 else { return nil }
                    budget -= 1
                    if mismatches(page) > 0 { continue }
                    if variety && page.layoutID == (pages.last?.layoutID ?? before.last) { continue }
                    if let found = search(rest, pages + [page]) { return found }
                }
                deadEnds.insert(key)
                return nil
            }
            if let found = search(run, []) { return found }
        }
        if strict && goal.accepts(greedy.count) { return greedy }
        return greedyIsClean ? greedy : firstClean ?? greedy
    }

    func isComplete(_ queue: [Photo], _ pages: [PlannedPage], opener: Bool) -> Bool {
        queue.isEmpty && !(opener && pages.isEmpty)
    }

    /// The next pages to try, best first, each with the photos left after it. `extras` adds pages
    /// the brief does not offer at this point, for the search only (see `rescue`; `opener-text`
    /// although a photo opener fits).
    func options(_ queue: [Photo], _ pages: [PlannedPage], opener: Bool, before: [String],
                 extras: Bool) -> [(PlannedPage, [Photo])] {
        func rest(_ page: PlannedPage) -> [Photo] {
            let used = Set(page.photos.map(\.id))
            return queue.filter { !used.contains($0.id) }
        }
        if opener && pages.isEmpty { return openerPages(queue, extras: extras).map { ($0, rest($0)) } }
        let recent = Array((before + pages.map(\.layoutID)).suffix(2))
        return densePages(queue, recent: recent, extras: extras).map { ($0, rest($0)) }
    }

    func isClean(_ pages: [PlannedPage], before: [String], after: String?) -> Bool {
        let ids = Array(before.suffix(1)) + pages.map(\.layoutID) + (after.map { [$0] } ?? [])
        return pages.allSatisfy { mismatches($0) == 0 } && zip(ids, ids.dropFirst()).allSatisfy { $0 != $1 }
    }

    func mismatches(_ page: PlannedPage) -> Int {
        guard let layout = PageLayoutCatalog.layout(id: page.layoutID) else { return 0 }
        return zip(page.photos, layout.frames).filter { !TemplateLayout.fits($0, $1.orientation) }.count
    }

    // MARK: Candidates

    private static let catalogIndex = Dictionary(uniqueKeysWithValues:
        PageLayoutCatalog.all.enumerated().map { ($1.id, $0) })

    private struct Candidate {
        var page: PlannedPage
        var excluded: Bool
        var score: Double
        var index: Int
    }

    /// Opener layouts with photos in score order; `opener-text` when none fits (or as an extra).
    func openerPages(_ queue: [Photo], extras: Bool) -> [PlannedPage] {
        let layouts = PageLayoutCatalog.all.filter { $0.role == .opener && $0.photoCount > 0 }
        let pages = ranked(layouts, queue: queue, recent: []).map(\.page)
        return pages + (pages.isEmpty || extras ? [PlannedPage(layoutID: "opener-text", photos: [])] : [])
    }

    /// Dense candidates, best first; the rescue page (and with `extras` its alternatives) when
    /// there is none.
    func densePages(_ queue: [Photo], recent: [String], extras: Bool) -> [PlannedPage] {
        let candidates = ranked(PageLayoutCatalog.dense, queue: queue, recent: recent)
        if candidates.isEmpty {
            let pages = rescue(Array(queue.prefix(PagePlanner.windowSize)))
            return extras ? pages : [pages[0]]
        }
        return candidates.map(\.page)
    }

    private func ranked(_ layouts: [PageLayout], queue: [Photo], recent: [String]) -> [Candidate] {
        let window = Array(queue.prefix(PagePlanner.windowSize))
        let candidates = layouts.compactMap { layout -> Candidate? in
            guard let chosen = Self.fill(layout, from: window) else { return nil }
            let used = Set(chosen.map(\.id))
            let rest = queue.filter { !used.contains($0.id) }
            var score = weights.weight(layout.id) / Double(1 + abs(layout.photoCount - target))
            if (1...3).contains(rest.count) && !Self.fillsExactly(rest) { score *= 0.5 }
            return Candidate(page: Self.page(layout, chosen), excluded: recent.contains(layout.id), score: score,
                             index: Self.catalogIndex[layout.id] ?? 0)
        }
        return candidates.sorted {
            if $0.excluded != $1.excluded { return !$0.excluded }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.page.photos.count != $1.page.photos.count { return $0.page.photos.count > $1.page.photos.count }
            return $0.index < $1.index
        }
    }

    /// No dense layout fits: one photo gets `full` (landscape or square, long side ≥ 1800 px),
    /// `framed-1` (smaller) or `portrait-text`; else a sparse layout the window fills exactly; else
    /// the dense layout with the fewest frames of the wrong orientation (ties: more photos, then
    /// catalog order), never with an empty frame. The first page is the rescue; the others are
    /// only for the search: `framed-1` after `full` (no two full pages in a row, spec 4.2) and,
    /// after a page of several photos, the first photo alone.
    func rescue(_ window: [Photo]) -> [PlannedPage] {
        if window.count == 1, let p = window.first { return single(p) }
        if let sparse = PageLayoutCatalog.all.first(where: {
            $0.role == .sparse && $0.photoCount == window.count && Self.canHold(window, in: $0)
        }) {
            return [Self.page(sparse, window)] + single(window[0])
        }
        let best = PageLayoutCatalog.dense.filter { $0.photoCount <= window.count }
            .map { ($0, Self.looseFill($0, from: window)) }
            .min { a, b in
                if a.1.mismatches != b.1.mismatches { return a.1.mismatches < b.1.mismatches }
                if a.0.photoCount != b.0.photoCount { return a.0.photoCount > b.0.photoCount }
                return (Self.catalogIndex[a.0.id] ?? 0) < (Self.catalogIndex[b.0.id] ?? 0)
            }!
        return [Self.page(best.0, best.1.photos)] + single(window[0])
    }

    /// The pages for one photo: `full` (then `framed-1`), `framed-1` or `portrait-text`. A photo
    /// in `notFull` never gets `full`.
    private func single(_ p: Photo) -> [PlannedPage] {
        let ids = !TemplateLayout.fits(p, .landscape) ? ["portrait-text"]
            : max(p.pixelWidth, p.pixelHeight) >= PagePlanner.heroMinLongSidePX && !notFull.contains(p.id)
            ? ["full", "framed-1"] : ["framed-1"]
        return ids.map { Self.page(PageLayoutCatalog.layout(id: $0)!, [p]) }
    }

    // MARK: Filling

    /// Frames by orientation: landscape, portrait, any.
    private static func capacity(_ layout: PageLayout) -> (landscape: Int, portrait: Int, any: Int) {
        capacity(layout.frames)
    }

    private static func capacity(_ frames: [PageFrameSlot]) -> (landscape: Int, portrait: Int, any: Int) {
        let o = frames.map(\.orientation)
        return (o.filter { $0 == .landscape }.count, o.filter { $0 == .portrait }.count, o.filter { $0 == .any }.count)
    }

    /// Whether `photos` can go into distinct frames of `layout` with matching orientation
    /// (squares fit any frame).
    static func canHold(_ photos: [Photo], in layout: PageLayout,
                                capacity c: (landscape: Int, portrait: Int, any: Int)? = nil) -> Bool {
        canHold(photos, capacity: c ?? capacity(layout))
    }

    private static func canHold(_ photos: [Photo], capacity c: (landscape: Int, portrait: Int, any: Int)) -> Bool {
        let wide = photos.filter { !TemplateLayout.fits($0, .portrait) }.count
        let tall = photos.filter { !TemplateLayout.fits($0, .landscape) }.count
        return wide <= c.landscape + c.any && tall <= c.portrait + c.any
            && photos.count <= c.landscape + c.portrait + c.any
    }

    /// Whether one dense or sparse layout takes exactly `photos`, orientations matching.
    private static func fillsExactly(_ photos: [Photo]) -> Bool {
        PageLayoutCatalog.all.contains {
            ($0.role == .dense || $0.role == .sparse) && $0.photoCount == photos.count && canHold(photos, in: $0)
        }
    }

    /// The first photo of `window` plus the earliest others that fit the remaining frames, or nil
    /// when the layout cannot be filled that way.
    private static func fill(_ layout: PageLayout, from window: [Photo]) -> [Photo]? {
        guard let first = window.first, canHold([first], in: layout) else { return nil }
        var chosen = [first]
        for p in window.dropFirst() where chosen.count < layout.photoCount && canHold(chosen + [p], in: layout) {
            chosen.append(p)
        }
        return chosen.count == layout.photoCount ? chosen : nil
    }

    /// Like `fill`, but frames no fitting photo is left for take the earliest remaining photos.
    /// `window` has at least `layout.photoCount` photos.
    private static func looseFill(_ layout: PageLayout, from window: [Photo]) -> (photos: [Photo], mismatches: Int) {
        var c = capacity(layout)
        var forced: [Photo] = []
        var fitting: [Photo] = []
        if let first = window.first {
            if canHold([first], in: layout) {
                fitting = [first]
            } else {
                // It takes a frame of the other orientation.
                forced = [first]
                if TemplateLayout.fits(first, .portrait) { c.landscape -= 1 } else { c.portrait -= 1 }
            }
        }
        for p in window.dropFirst() where canHold(fitting + [p], in: layout, capacity: c) {
            fitting.append(p)
        }
        let used = Set((forced + fitting).map(\.id))
        let extra = window.filter { !used.contains($0.id) }.prefix(layout.photoCount - forced.count - fitting.count)
        return (forced + fitting + extra, forced.count + extra.count)
    }

    /// `photos` in the frames of `layout`, in frame order.
    private static func page(_ layout: PageLayout, _ photos: [Photo]) -> PlannedPage {
        let assignment = assignment(layout, photos)
        return PlannedPage(layoutID: layout.id, photos: layout.frames.compactMap { assignment[$0.id] })
    }

    /// Frame id -> photo for `photos` in the frames of `layout`. When every photo can fit a frame
    /// of its orientation, frames in priority order take the best-ranked photo that fits and leaves
    /// the others a fitting frame each (a frame no photo can take stays empty): like
    /// `TemplateLayout.assign`, but a square never takes the frame a ▯ or ▭ needs. Otherwise (a
    /// rescue page, more photos than frames) `TemplateLayout.assign` decides.
    static func assignment(_ layout: PageLayout, _ photos: [Photo]) -> [String: Photo] {
        let frames = layout.frames.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        var result: [String: Photo] = [:]
        if photos.count <= layout.photoCount && canHold(photos, in: layout) {
            var remaining = photos.sorted(by: TemplateLayout.rank)
            for (k, frame) in frames.enumerated() where !remaining.isEmpty {
                let later = capacity(Array(frames[(k + 1)...]))
                let i = remaining.indices.first { i in
                    var rest = remaining
                    rest.remove(at: i)
                    return TemplateLayout.fits(remaining[i], frame.orientation) && canHold(rest, capacity: later)
                }
                if let i { result[frame.id] = remaining.remove(at: i) }
            }
        } else {
            let slots = frames.map {
                FrameSlot(id: $0.id, rect: Rect(x: 0, y: 0, width: 1, height: 1), orientation: $0.orientation,
                          priority: $0.priority)
            }
            let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            result = TemplateLayout.assign(slots, photos: photos).compactMapValues { byID[$0] }
        }
        return result
    }

    // MARK: Even page count

    /// `pages` with one page split into two: the page with the most photos first (ties: the
    /// earlier page; not an opener, not `full`, at least 2 photos), its photos (chronological)
    /// planned with half the target into exactly 2 pages between its neighbours. With `clean`
    /// (padding) both new pages must have matching orientations. When the page does not split
    /// that way (a 2- or 3-photo page re-planned stays one page) its photos are cut
    /// chronologically in two (cuts nearest the middle first), each part one page with matching
    /// orientations; e.g. `grid-4` of ▭ becomes `landscape-2` twice, ▯▯ becomes two
    /// `portrait-text`. Nil when no page splits.
    func splitting(_ pages: [PlannedPage], clean: Bool) -> [PlannedPage]? {
        func role(_ page: PlannedPage) -> PageLayoutRole? { PageLayoutCatalog.layout(id: page.layoutID)?.role }
        let splittable = pages.indices
            .filter { role(pages[$0]) != .opener && pages[$0].layoutID != "full" && pages[$0].photos.count >= 2 }
            .sorted { (pages[$0].photos.count, -$0) > (pages[$1].photos.count, -$1) }
        for i in splittable {
            let photos = pages[i].photos.sorted(by: Photo.chronological)
            let before = pages[..<i].map(\.layoutID)
            let after = i + 1 < pages.count ? pages[i + 1].layoutID : nil
            let half = Planner(target: max(1, photos.count / 2), weights: weights, notFull: notFull)
            let two = half.plan(photos, opener: false, before: before, after: after, goal: .exactly(2), strict: true)
            var split: [PlannedPage]?
            if two.count == 2 && (!clean || two.allSatisfy { mismatches($0) == 0 }) {
                split = two
            } else {
                let cuts = (1..<photos.count).sorted { (abs(2 * $0 - photos.count), $0) < (abs(2 * $1 - photos.count), $1) }
                for cut in cuts {
                    guard let first = onePage(Array(photos[..<cut]), before: before, after: nil),
                          let second = onePage(Array(photos[cut...]), before: before + [first.layoutID], after: after)
                    else { continue }
                    split = [first, second]
                    break
                }
            }
            if let split {
                var result = pages
                result.replaceSubrange(i...i, with: split)
                return result
            }
        }
        return nil
    }

    /// `photos` as exactly one page with matching orientations, or nil.
    private func onePage(_ photos: [Photo], before: [String], after: String?) -> PlannedPage? {
        let planner = Planner(target: photos.count, weights: weights, notFull: notFull)
        let pages = planner.plan(photos, opener: false, before: before, after: after, goal: .exactly(1), strict: true)
        return pages.count == 1 && mismatches(pages[0]) == 0 ? pages[0] : nil
    }

    func makeEven(_ pages: inout [PlannedPage]) {
        func role(_ page: PlannedPage) -> PageLayoutRole? { PageLayoutCatalog.layout(id: page.layoutID)?.role }
        while pages.count % 2 == 1 {
            if let split = splitting(pages, clean: false) {
                pages = split
            } else if let first = pages.first, role(first) == .opener, !first.photos.isEmpty {
                let photos = first.photos.sorted(by: Photo.chronological)
                // An odd number of pages for the opener's photos evens the day.
                let ordinary = plan(photos, opener: false, before: ["opener-text"],
                                    after: pages.count > 1 ? pages[1].layoutID : nil, goal: .even(offset: pages.count),
                                    strict: true)
                pages.replaceSubrange(0...0, with: [PlannedPage(layoutID: "opener-text", photos: [])] + ordinary)
            } else {
                pages.append(PlannedPage(layoutID: "empty", photos: []))
            }
        }
    }
}

// MARK: - Shared with page editing

extension PagePlanner {
    /// Frame id -> photo, orientation-safe where possible (see `Planner.assignment`).
    static func assignment(_ layout: PageLayout, _ photos: [Photo]) -> [String: Photo] {
        Planner.assignment(layout, photos)
    }

    /// Whether `photos` can go into distinct frames of `layout` with matching orientation.
    static func canHold(_ photos: [Photo], in layout: PageLayout) -> Bool {
        Planner.canHold(photos, in: layout)
    }
}
