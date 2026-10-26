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
    /// Converts normalized slots to millimetres. Frame and text ids come from the slot ids, so
    /// they are stable across formats; the spread id is injectable for tests.
    public static func instantiate(_ t: SpreadTemplate, geometry: PageGeometry, dayKey: DayKey?,
                                   id: String = UUID().uuidString) -> Spread {
        let size = geometry.spreadSize
        func scaled(_ r: Rect) -> Rect {
            Rect(x: r.minX * size.width, y: r.minY * size.height,
                 width: r.size.width * size.width, height: r.size.height * size.height)
        }
        return Spread(
            id: id, kind: t.kind, templateID: t.id, dayKey: dayKey,
            frames: t.frames.map {
                Frame(id: $0.id, rect: scaled($0.rect), photoID: nil, offset: Point(x: 0, y: 0), zoom: 1)
            },
            texts: t.texts.map { TextBox(id: $0.id, rect: scaled($0.rect), role: $0.role, text: "") },
            manuallyEdited: false)
    }
}
