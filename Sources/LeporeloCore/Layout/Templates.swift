import Foundation

public enum Orientation: String, Sendable, Codable, Equatable {
    case any, landscape, portrait
}

/// Rects are normalized 0...1 against the spread size. `priority` 0 is the main frame.
public struct FrameSlot: Sendable, Codable, Equatable {
    public var id: String
    public var rect: Rect
    public var orientation: Orientation
    public var priority: Int
    public var bleeds: Bool

    public init(id: String, rect: Rect, orientation: Orientation, priority: Int, bleeds: Bool = false) {
        self.id = id
        self.rect = rect
        self.orientation = orientation
        self.priority = priority
        self.bleeds = bleeds
    }
}

public struct TextSlot: Sendable, Codable, Equatable {
    public var id: String
    public var rect: Rect
    public var role: TextRole
    public var placeholder: String

    public init(id: String, rect: Rect, role: TextRole, placeholder: String) {
        self.id = id
        self.rect = rect
        self.role = role
        self.placeholder = placeholder
    }
}

public struct SpreadTemplate: Sendable, Codable, Equatable {
    public var id: String
    public var kind: SpreadKind
    public var photoCount: Int
    public var frames: [FrameSlot]
    public var texts: [TextSlot]

    public init(id: String, kind: SpreadKind, photoCount: Int, frames: [FrameSlot], texts: [TextSlot]) {
        self.id = id
        self.kind = kind
        self.photoCount = photoCount
        self.frames = frames
        self.texts = texts
    }
}

public enum TemplateCatalog {
    private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(x: x, y: y, width: w, height: h)
    }

    // Margins are chosen so that non-bleeding slots stay in the 6 mm safe zone of a
    // 297x210 page (x: 0.0101, y: 0.0286 in spread units); y 0.04...0.96.
    private static let dateText = TextSlot(id: "date", rect: r(0.03, 0.06, 0.23, 0.05),
                                           role: .date, placeholder: "Datum")
    private static let titleText = TextSlot(id: "title", rect: r(0.03, 0.13, 0.23, 0.14),
                                            role: .title, placeholder: "Titulek")
    private static let bodyText = TextSlot(id: "body", rect: r(0.03, 0.30, 0.23, 0.64),
                                           role: .body, placeholder: "Co jsme dnes dělali")
    private static let journalTexts = [dateText, titleText, bodyText]

    /// Portrait photo next to the text column on the left page.
    private static func leftPortrait(id: String, priority: Int) -> FrameSlot {
        FrameSlot(id: id, rect: r(0.28, 0.06, 0.19, 0.88), orientation: .portrait, priority: priority)
    }

    public static let all: [SpreadTemplate] = [
        SpreadTemplate(
            id: "intro-1", kind: .intro, photoCount: 1,
            frames: [FrameSlot(id: "photo1", rect: r(0.5, 0, 0.5, 1), orientation: .any, priority: 0, bleeds: true)],
            texts: [TextSlot(id: "title", rect: r(0.06, 0.38, 0.38, 0.20), role: .title, placeholder: "Název alba"),
                    TextSlot(id: "body", rect: r(0.06, 0.60, 0.38, 0.20), role: .body,
                             placeholder: "Datum a místa")]),

        // Journal-3: text left, tall portrait main on the right with two landscape photos beside it.
        SpreadTemplate(
            id: "journal-3", kind: .journal, photoCount: 3,
            frames: [
                FrameSlot(id: "photo1", rect: r(0.52, 0.06, 0.22, 0.88), orientation: .portrait, priority: 0),
                FrameSlot(id: "photo2", rect: r(0.76, 0.06, 0.21, 0.38), orientation: .landscape, priority: 1),
                FrameSlot(id: "photo3", rect: r(0.76, 0.56, 0.21, 0.38), orientation: .landscape, priority: 2),
            ],
            texts: journalTexts),

        // Journal-4: landscape main on the right, two landscape below it, portrait on the left page.
        SpreadTemplate(
            id: "journal-4", kind: .journal, photoCount: 4,
            frames: [
                FrameSlot(id: "photo1", rect: r(0.52, 0.06, 0.30, 0.56), orientation: .landscape, priority: 0),
                FrameSlot(id: "photo2", rect: r(0.84, 0.06, 0.13, 0.26), orientation: .landscape, priority: 1),
                FrameSlot(id: "photo3", rect: r(0.52, 0.66, 0.15, 0.28), orientation: .landscape, priority: 2),
                leftPortrait(id: "photo4", priority: 3),
            ],
            texts: journalTexts),

        // Journal-5: journal-4 plus a second photo in the right column.
        SpreadTemplate(
            id: "journal-5", kind: .journal, photoCount: 5,
            frames: [
                FrameSlot(id: "photo1", rect: r(0.52, 0.06, 0.30, 0.56), orientation: .landscape, priority: 0),
                FrameSlot(id: "photo2", rect: r(0.84, 0.06, 0.13, 0.26), orientation: .landscape, priority: 1),
                FrameSlot(id: "photo3", rect: r(0.84, 0.36, 0.13, 0.26), orientation: .landscape, priority: 2),
                FrameSlot(id: "photo4", rect: r(0.52, 0.66, 0.15, 0.28), orientation: .landscape, priority: 3),
                leftPortrait(id: "photo5", priority: 4),
            ],
            texts: journalTexts),

        // Gallery-1: one photo bleeding over the right page, caption bottom left.
        SpreadTemplate(
            id: "gallery-1", kind: .gallery, photoCount: 1,
            frames: [FrameSlot(id: "photo1", rect: r(0.5, 0, 0.5, 1), orientation: .any, priority: 0, bleeds: true)],
            texts: [TextSlot(id: "caption", rect: r(0.03, 0.88, 0.30, 0.07), role: .caption, placeholder: "Popisek")]),

        // Gallery-2: one photo per page, portrait left and landscape right.
        SpreadTemplate(
            id: "gallery-2", kind: .gallery, photoCount: 2,
            frames: [
                FrameSlot(id: "photo1", rect: r(0.14, 0.06, 0.22, 0.82), orientation: .portrait, priority: 0),
                FrameSlot(id: "photo2", rect: r(0.53, 0.06, 0.44, 0.80), orientation: .landscape, priority: 1),
            ],
            texts: [TextSlot(id: "caption", rect: r(0.53, 0.89, 0.44, 0.06), role: .caption, placeholder: "Popisek")]),

        // Gallery-3: two landscape photos stacked on the left, a portrait on the right.
        SpreadTemplate(
            id: "gallery-3", kind: .gallery, photoCount: 3,
            frames: [
                FrameSlot(id: "photo1", rect: r(0.64, 0.06, 0.22, 0.80), orientation: .portrait, priority: 0),
                FrameSlot(id: "photo2", rect: r(0.135, 0.06, 0.23, 0.38), orientation: .landscape, priority: 1),
                FrameSlot(id: "photo3", rect: r(0.135, 0.48, 0.23, 0.38), orientation: .landscape, priority: 2),
            ],
            texts: [TextSlot(id: "caption", rect: r(0.03, 0.89, 0.44, 0.06), role: .caption, placeholder: "Popisek")]),

        SpreadTemplate(
            id: "closing-1", kind: .closing, photoCount: 1,
            frames: [FrameSlot(id: "photo1", rect: r(0, 0, 0.5, 1), orientation: .any, priority: 0, bleeds: true)],
            texts: [TextSlot(id: "caption", rect: r(0.60, 0.45, 0.30, 0.10), role: .caption,
                             placeholder: "Závěrečné slovo")]),

        SpreadTemplate(id: "blank", kind: .blank, photoCount: 0, frames: [], texts: []),
    ]

    public static func templates(kind: SpreadKind) -> [SpreadTemplate] {
        all.filter { $0.kind == kind }
    }

    public static func template(id: String) -> SpreadTemplate? {
        all.first { $0.id == id }
    }
}

public enum TemplateLayout {
    /// Converts normalized slots to millimetres, then conforms the result to the page margin
    /// (`MarginRule.conform`, area `.spread`), so no frame edge lies in the band next to a page
    /// edge and texts stay inside the margin box. Frame and text ids come from the slot ids, so
    /// they are stable across formats; the spread id is injectable for tests.
    public static func instantiate(_ t: SpreadTemplate, geometry: PageGeometry, dayKey: DayKey?,
                                   id: String = UUID().uuidString,
                                   marginMM: Double = Album.defaultMarginMM) -> Spread {
        let size = geometry.spreadSize
        func scaled(_ r: Rect) -> Rect {
            Rect(x: r.minX * size.width, y: r.minY * size.height,
                 width: r.size.width * size.width, height: r.size.height * size.height)
        }
        let spread = Spread(
            id: id, kind: t.kind, templateID: t.id, dayKey: dayKey,
            frames: t.frames.map {
                Frame(id: $0.id, rect: scaled($0.rect), photoID: nil, offset: Point(x: 0, y: 0), zoom: 1)
            },
            texts: t.texts.map { TextBox(id: $0.id, rect: scaled($0.rect), role: $0.role, text: "") },
            manuallyEdited: false)
        return MarginRule(geometry: geometry, marginMM: marginMM).conform(spread, area: .spread)
    }
}

// MARK: - Photo assignment (shared by the drafter and `retemplate`)

extension TemplateLayout {
    /// Frame id -> photo id. Frames are visited in priority order:
    /// - the main frame (priority 0) takes the best remaining photo of matching orientation, or, if
    ///   none matches, the best remaining photo outright, before any other frame is filled;
    /// - pass 1: every other oriented frame takes the best remaining photo of matching orientation;
    /// - pass 2: frames still empty (`.any` frames and frames with no match) take the best remaining
    ///   photo. No frame stays empty while photos remain; with more photos than frames the
    ///   lowest-ranked ones are left out.
    /// "Best" is `rank`: `PhotoScore.score` descending, ties by `capturedAt`, then id.
    public static func assign(_ slots: [FrameSlot], photos: [Photo]) -> [String: PhotoID] {
        var remaining = photos.sorted(by: rank)
        let ordered = slots.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        var result: [String: PhotoID] = [:]
        if let main = ordered.first, main.priority == 0, !remaining.isEmpty {
            let i = remaining.firstIndex(where: { fits($0, main.orientation) }) ?? 0
            result[main.id] = remaining.remove(at: i).id
        }
        for slot in ordered where slot.orientation != .any && result[slot.id] == nil {
            if let i = remaining.firstIndex(where: { fits($0, slot.orientation) }) {
                result[slot.id] = remaining.remove(at: i).id
            }
        }
        for slot in ordered where result[slot.id] == nil && !remaining.isEmpty {
            result[slot.id] = remaining.removeFirst().id
        }
        return result
    }

    /// A square photo fits both a landscape and a portrait frame.
    public static func fits(_ photo: Photo, _ orientation: Orientation) -> Bool {
        switch orientation {
        case .any: return true
        case .landscape: return photo.pixelWidth >= photo.pixelHeight
        case .portrait: return photo.pixelHeight >= photo.pixelWidth
        }
    }

    /// Best score first; ties by `capturedAt`, then `id`.
    static func rank(_ a: Photo, _ b: Photo) -> Bool {
        let sa = PhotoScore.score(a), sb = PhotoScore.score(b)
        if sa != sb { return sa > sb }
        return Photo.chronological(a, b)
    }
}

// MARK: - Template change

/// The outcome of `TemplateLayout.retemplate`.
public struct RetemplateResult: Sendable, Equatable {
    /// The spread on the new template (`manuallyEdited = true`).
    public var spread: Spread
    /// Photos of the old spread that got no frame (the new template has fewer frames),
    /// chronological. They stay selected; the preflight reports them as not in the album.
    public var unplacedPhotoIDs: [PhotoID]
    /// Non-empty texts of the old spread that have no slot in the new template, in old order.
    /// Applying the result loses them, so the caller asks the user first.
    public var droppedTexts: [TextBox]

    public init(spread: Spread, unplacedPhotoIDs: [PhotoID], droppedTexts: [TextBox]) {
        self.spread = spread
        self.unplacedPhotoIDs = unplacedPhotoIDs
        self.droppedTexts = droppedTexts
    }
}

extension TemplateLayout {
    /// `spread` re-laid on `template` (spec 6.4 "změnit šablonu dvoustrany"). Pure.
    ///
    /// - Keeps the spread id and dayKey; kind and templateID come from the template; frames and
    ///   text boxes are a fresh instance of the template for `geometry`; `manuallyEdited = true`.
    /// - Photos: the old spread's photos (frame order, each once; ids missing from `photos` are
    ///   skipped, the preflight reports those already) are assigned with `assign`, the drafter's
    ///   orientation- and score-aware assignment, so the best photo lands in the main frame.
    ///   Offsets and zooms reset (the frame shapes change). Extra photos go to
    ///   `unplacedPhotoIDs`; extra frames stay empty (the preflight blocks the export until the
    ///   user fills them, deletes the spread or switches back).
    /// - `customLayout` is false again: the layout is the template's, conformed to `marginMM`.
    /// - Texts: each new slot takes the old text with the same id, else the first not yet used old
    ///   text with the same role. Old texts that are not whitespace-only and found no slot are
    ///   returned in `droppedTexts`; nothing is lost silently.
    public static func retemplate(_ spread: Spread, to template: SpreadTemplate, geometry: PageGeometry,
                                  photos: [PhotoID: Photo],
                                  marginMM: Double = Album.defaultMarginMM) -> RetemplateResult {
        var result = instantiate(template, geometry: geometry, dayKey: spread.dayKey, id: spread.id,
                                 marginMM: marginMM)
        result.manuallyEdited = true
        result.customLayout = false

        var seen = Set<PhotoID>()
        let old = spread.frames.compactMap(\.photoID).filter { seen.insert($0).inserted }.compactMap { photos[$0] }
        let assignment = assign(template.frames, photos: old)
        for i in result.frames.indices {
            result.frames[i].photoID = assignment[result.frames[i].id]
        }
        let placed = Set(assignment.values)
        let unplaced = old.filter { !placed.contains($0.id) }.sorted(by: Photo.chronological).map(\.id)

        // Two passes, so a slot matched by id is never taken by another slot's role fallback.
        var used = Set<Int>()
        var filled = Set<Int>()
        for byID in [true, false] {
            for i in result.texts.indices where !filled.contains(i) {
                let box = result.texts[i]
                let match = spread.texts.indices.first {
                    !used.contains($0) && (byID ? spread.texts[$0].id == box.id : spread.texts[$0].role == box.role)
                }
                if let match {
                    used.insert(match)
                    filled.insert(i)
                    result.texts[i].text = spread.texts[match].text
                    result.texts[i].style = spread.texts[match].style
                }
            }
        }
        let dropped = spread.texts.indices.filter { i in
            !used.contains(i) && !spread.texts[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { spread.texts[$0] }
        return RetemplateResult(spread: result, unplacedPhotoIDs: unplaced, droppedTexts: dropped)
    }
}
