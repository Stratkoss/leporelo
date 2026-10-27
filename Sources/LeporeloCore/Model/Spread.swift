import Foundation

public enum SpreadKind: String, Sendable, Codable, Equatable {
    case intro, journal, gallery, closing, blank
}

public struct Frame: Sendable, Codable, Equatable {
    public var id: String
    public var rect: Rect
    public var photoID: PhotoID?
    /// -1..1
    public var offset: Point
    /// >= 1
    public var zoom: Double

    public init(id: String, rect: Rect, photoID: PhotoID?, offset: Point, zoom: Double) {
        self.id = id
        self.rect = rect
        self.photoID = photoID
        self.offset = offset
        self.zoom = zoom
    }
}

public enum TextRole: String, Sendable, Codable, Equatable {
    case date, title, body, caption, pageNumber
}

public struct TextBox: Sendable, Codable, Equatable {
    public var id: String
    public var rect: Rect
    public var role: TextRole
    public var text: String

    public init(id: String, rect: Rect, role: TextRole, text: String) {
        self.id = id
        self.rect = rect
        self.role = role
        self.text = text
    }
}

public struct Spread: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var kind: SpreadKind
    public var templateID: String
    public var dayKey: DayKey?
    public var frames: [Frame]
    public var texts: [TextBox]
    public var manuallyEdited: Bool
    /// True once the user has changed the layout by hand (move, resize, add, delete).
    public var customLayout: Bool

    public init(id: String, kind: SpreadKind, templateID: String, dayKey: DayKey?,
                frames: [Frame], texts: [TextBox], manuallyEdited: Bool, customLayout: Bool = false) {
        self.id = id
        self.kind = kind
        self.templateID = templateID
        self.dayKey = dayKey
        self.frames = frames
        self.texts = texts
        self.manuallyEdited = manuallyEdited
        self.customLayout = customLayout
    }

    /// Spreads written before `customLayout` existed decode it as false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(SpreadKind.self, forKey: .kind)
        templateID = try c.decode(String.self, forKey: .templateID)
        dayKey = try c.decodeIfPresent(DayKey.self, forKey: .dayKey)
        frames = try c.decode([Frame].self, forKey: .frames)
        texts = try c.decode([TextBox].self, forKey: .texts)
        manuallyEdited = try c.decode(Bool.self, forKey: .manuallyEdited)
        customLayout = try c.decodeIfPresent(Bool.self, forKey: .customLayout) ?? false
    }
}

/// Each side is a single-page spread: `rect`s are in the coordinates of one page.
public struct Cover: Sendable, Codable, Equatable {
    public var front: Spread
    public var back: Spread

    public init(front: Spread, back: Spread) {
        self.front = front
        self.back = back
    }
}
