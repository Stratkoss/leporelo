import Foundation

public enum PageLayoutRole: String, Sendable, Equatable {
    /// A whole-page photo.
    case hero
    /// The automatic design uses these.
    case dense
    /// Rescue only: the design uses them for a leftover photo.
    case sparse
    /// The first page of a day, with its texts.
    case opener
    case empty
}

/// A cell range of a `columns` x `rows` grid over the whole page, with 3 mm gutters between cells.
/// Outer edges lie on the page edge (bleed).
public struct GridArea: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var column: Int
    public var row: Int
    public var columnSpan: Int
    public var rowSpan: Int

    public init(columns: Int, rows: Int, column: Int, row: Int, columnSpan: Int = 1, rowSpan: Int = 1) {
        self.columns = columns
        self.rows = rows
        self.column = column
        self.row = row
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }
}

public enum PageSlotRect: Sendable, Equatable {
    case grid(GridArea)
    /// Normalized 0...1 against the page shrunk by the book margin.
    case margin(Rect)
}

public struct PageFrameSlot: Sendable, Equatable {
    public var id: String
    public var area: PageSlotRect
    public var orientation: Orientation
    public var priority: Int

    public init(id: String, area: PageSlotRect, orientation: Orientation, priority: Int) {
        self.id = id
        self.area = area
        self.orientation = orientation
        self.priority = priority
    }
}

public struct PageTextSlot: Sendable, Equatable {
    public var id: String
    public var area: PageSlotRect
    public var role: TextRole
    public var placeholder: String

    public init(id: String, area: PageSlotRect, role: TextRole, placeholder: String) {
        self.id = id
        self.area = area
        self.role = role
        self.placeholder = placeholder
    }
}

/// One page. The frame ids are `photo1`, `photo2`, ... in priority order (`photo1` is the main one).
public struct PageLayout: Sendable, Equatable {
    public var id: String
    public var name: String
    public var role: PageLayoutRole
    public var frames: [PageFrameSlot]
    public var texts: [PageTextSlot]

    public init(id: String, name: String, role: PageLayoutRole, frames: [PageFrameSlot], texts: [PageTextSlot]) {
        self.id = id
        self.name = name
        self.role = role
        self.frames = frames
        self.texts = texts
    }

    public var photoCount: Int { frames.count }
}

public enum PageLayoutCatalog {
    public static let gutterMM = 3.0

    private typealias Spec = (cols: Int, rows: Int, col: Int, row: Int, colSpan: Int, rowSpan: Int, Orientation)

    private static func g(_ c: Int, _ r: Int, _ col: Int, _ row: Int, _ cs: Int = 1, _ rs: Int = 1,
                          _ o: Orientation = .landscape) -> Spec {
        (c, r, col, row, cs, rs, o)
    }

    private static func frames(_ specs: [Spec]) -> [PageFrameSlot] {
        specs.enumerated().map { i, s in
            PageFrameSlot(id: "photo\(i + 1)",
                          area: .grid(GridArea(columns: s.cols, rows: s.rows, column: s.col, row: s.row,
                                               columnSpan: s.colSpan, rowSpan: s.rowSpan)),
                          orientation: s.6, priority: i)
        }
    }

    private static func text(_ id: String, _ role: TextRole, _ placeholder: String,
                             _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PageTextSlot {
        PageTextSlot(id: id, area: .margin(Rect(x: x, y: y, width: w, height: h)), role: role,
                     placeholder: placeholder)
    }

    private static func dayTexts(width: Double) -> [PageTextSlot] {
        [text("date", .date, "Datum", 0, 0, width, 0.08),
         text("title", .title, "Titulek", 0, 0.10, width, 0.16),
         text("body", .body, "Co jsme dnes dělali", 0, 0.30, width, 0.70)]
    }

    private static let caption = "Popisek"

    public static let all: [PageLayout] = [
        PageLayout(id: "full", name: "Celá stránka", role: .hero, frames: frames([g(1, 1, 0, 0)]), texts: []),
        PageLayout(id: "framed-1", name: "S bílým okrajem", role: .sparse,
                   frames: [PageFrameSlot(id: "photo1", area: .margin(Rect(x: 0.08, y: 0, width: 0.84, height: 0.84)),
                                          orientation: .landscape, priority: 0)],
                   texts: [text("caption", .caption, caption, 0, 0.88, 1, 0.12)]),
        PageLayout(id: "portrait-text", name: "Na výšku + popisek", role: .sparse,
                   frames: frames([g(2, 1, 0, 0, 1, 1, .portrait)]),
                   texts: [text("caption", .caption, caption, 0.56, 0.4, 0.44, 0.2)]),
        PageLayout(id: "portraits-2", name: "Dvě na výšku", role: .dense,
                   frames: frames([g(2, 1, 0, 0, 1, 1, .portrait), g(2, 1, 1, 0, 1, 1, .portrait)]), texts: []),
        PageLayout(id: "portrait-left-2l", name: "Na výšku + dvě", role: .dense,
                   frames: frames([g(2, 1, 0, 0, 1, 1, .portrait), g(2, 2, 1, 0), g(2, 2, 1, 1)]), texts: []),
        PageLayout(id: "portrait-right-2l", name: "Dvě + na výšku", role: .dense,
                   frames: frames([g(2, 1, 1, 0, 1, 1, .portrait), g(2, 2, 0, 0), g(2, 2, 0, 1)]), texts: []),
        PageLayout(id: "landscape-2", name: "Velká + malá", role: .sparse,
                   frames: frames([g(3, 3, 0, 0, 2, 2), g(3, 3, 2, 2)]),
                   texts: [text("caption", .caption, caption, 0, 0.75, 0.62, 0.25)]),
        PageLayout(id: "grid-4", name: "Čtyři", role: .dense,
                   frames: frames([g(2, 2, 0, 0), g(2, 2, 1, 0), g(2, 2, 0, 1), g(2, 2, 1, 1)]), texts: []),
        PageLayout(id: "mosaic-5", name: "Mozaika 5", role: .dense,
                   frames: frames([g(3, 3, 0, 0, 2, 2), g(3, 3, 2, 0, 1, 2, .portrait),
                                   g(3, 3, 0, 2), g(3, 3, 1, 2), g(3, 3, 2, 2)]), texts: []),
        PageLayout(id: "mosaic-6", name: "Mozaika 6", role: .dense,
                   frames: frames([g(3, 3, 0, 0, 2, 2), g(3, 3, 2, 0), g(3, 3, 2, 1),
                                   g(3, 3, 0, 2), g(3, 3, 1, 2), g(3, 3, 2, 2)]), texts: []),
        PageLayout(id: "opener-portrait", name: "Začátek dne: na výšku", role: .opener,
                   frames: frames([g(2, 1, 1, 0, 1, 1, .portrait)]), texts: dayTexts(width: 0.44)),
        PageLayout(id: "opener-2l", name: "Začátek dne: dvě", role: .opener,
                   frames: frames([g(2, 2, 1, 0), g(2, 2, 1, 1)]), texts: dayTexts(width: 0.44)),
        PageLayout(id: "opener-3", name: "Začátek dne: velká + dvě", role: .opener,
                   frames: frames([g(3, 3, 1, 0, 2, 2), g(3, 3, 1, 2), g(3, 3, 2, 2)]), texts: dayTexts(width: 0.28)),
        PageLayout(id: "opener-text", name: "Začátek dne: jen text", role: .opener, frames: [],
                   texts: [text("date", .date, "Datum", 0.1, 0.25, 0.8, 0.08),
                           text("title", .title, "Titulek", 0.1, 0.35, 0.8, 0.16),
                           text("body", .body, "Co jsme dnes dělali", 0.1, 0.55, 0.8, 0.3)]),
        PageLayout(id: "empty", name: "Prázdná stránka", role: .empty, frames: [], texts: []),
    ]

    public static func layout(id: String) -> PageLayout? {
        all.first { $0.id == id }
    }

    /// The layouts the automatic design chooses from, in catalog order.
    public static var dense: [PageLayout] {
        all.filter { $0.role == .dense }
    }

    /// The layouts the user can mark as favourites.
    public static let favouriteCandidates = ["portraits-2", "portrait-left-2l", "portrait-right-2l",
                                             "grid-4", "mosaic-5", "mosaic-6",
                                             "opener-portrait", "opener-2l", "opener-3"]
}

/// A spread made of two page layouts (`Spread.templateID == "pages"`).
public enum PageSpread {
    public static let templateID = "pages"

    /// Prefix of the frame and text ids of a page: `L.photo1`, `R.caption`.
    public static func prefix(_ side: PageSide) -> String {
        side == .left ? "L." : "R."
    }

    /// The page `rect` belongs to, by its centre; a centre exactly on the spine is the right page.
    public static func side(of rect: Rect, geometry: PageGeometry) -> PageSide {
        rect.minX + rect.size.width / 2 < geometry.format.pageWidthMM ? .left : .right
    }

    /// `area` on page `side` in millimetres, in spread coordinates.
    public static func slotRect(_ area: PageSlotRect, side: PageSide, geometry: PageGeometry,
                                marginMM: Double) -> Rect {
        let page = geometry.pageRect(side: side)
        switch area {
        case .margin(let r):
            let box = page.insetBy(marginMM)
            return Rect(x: box.minX + r.minX * box.size.width, y: box.minY + r.minY * box.size.height,
                        width: r.size.width * box.size.width, height: r.size.height * box.size.height)
        case .grid(let a):
            let gutter = PageLayoutCatalog.gutterMM
            let cellW = (page.size.width - Double(a.columns - 1) * gutter) / Double(a.columns)
            let cellH = (page.size.height - Double(a.rows - 1) * gutter) / Double(a.rows)
            let x0 = Double(a.column) * (cellW + gutter)
            let y0 = Double(a.row) * (cellH + gutter)
            // The last cell ends exactly on the page edge, free of rounding.
            let x1 = a.column + a.columnSpan >= a.columns
                ? page.size.width : x0 + Double(a.columnSpan) * cellW + Double(a.columnSpan - 1) * gutter
            let y1 = a.row + a.rowSpan >= a.rows
                ? page.size.height : y0 + Double(a.rowSpan) * cellH + Double(a.rowSpan - 1) * gutter
            return Rect(x: page.minX + x0, y: page.minY + y0, width: x1 - x0, height: y1 - y0)
        }
    }

    /// Empty frames and texts of `layout` on page `side`, ids prefixed. Not conformed to the margin.
    public static func pageItems(_ layout: PageLayout, side: PageSide, geometry: PageGeometry,
                                 marginMM: Double) -> (frames: [Frame], texts: [TextBox]) {
        let p = prefix(side)
        let frames = layout.frames.map {
            Frame(id: p + $0.id, rect: slotRect($0.area, side: side, geometry: geometry, marginMM: marginMM),
                  photoID: nil, offset: Point(x: 0, y: 0), zoom: 1)
        }
        let texts = layout.texts.map {
            TextBox(id: p + $0.id, rect: slotRect($0.area, side: side, geometry: geometry, marginMM: marginMM),
                    role: $0.role, text: "")
        }
        return (frames, texts)
    }

    /// A spread of two pages, conformed to the page margin (`MarginRule.conform`, area `.spread`).
    public static func compose(left: PageLayout, right: PageLayout, kind: SpreadKind, dayKey: DayKey?, id: String,
                               geometry: PageGeometry, marginMM: Double) -> Spread {
        let l = pageItems(left, side: .left, geometry: geometry, marginMM: marginMM)
        let r = pageItems(right, side: .right, geometry: geometry, marginMM: marginMM)
        let spread = Spread(id: id, kind: kind, templateID: templateID, dayKey: dayKey,
                            frames: l.frames + r.frames, texts: l.texts + r.texts, manuallyEdited: false,
                            pageLayouts: [left.id, right.id])
        return MarginRule(geometry: geometry, marginMM: marginMM).conform(spread, area: .spread)
    }
}
