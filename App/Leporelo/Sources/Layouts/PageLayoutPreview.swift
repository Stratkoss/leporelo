import LeporeloCore
import SwiftUI

/// A small picture of one page layout (the catalog mockup of spec 3): a white 8 × 6 in page
/// (`canva-photobook` / `landscape-8x6in`, margin 10 mm, `PageSpread.pageItems`), its photos as
/// colour gradients (six colours, in frame order) with ▭ / ▯ in the corner, its texts as grey
/// sample lines ("čtvrtek 18. června", "Ravello"). The same picture for every book format, so a
/// layout always looks the same in the picker and in the favourites.
struct PageLayoutPreview: View {
    let layout: PageLayout
    var side: PageSide = .left

    /// The page the previews are drawn on; nil only if the bundled profile is broken.
    private static let geometry: PageGeometry? = {
        guard let found = try? ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        else { return nil }
        return PageGeometry(format: found.1, profile: found.0)
    }()

    private static let marginMM = 10.0

    /// The mockup's gradients, light end last, in the order the frames take them.
    private static let gradients: [(Color, Color)] = [
        (Color(hex: 0x3F7D5A), Color(hex: 0xA7C47A)),
        (Color(hex: 0xB5653C), Color(hex: 0xE7C08A)),
        (Color(hex: 0x4B4F7A), Color(hex: 0x9AA3D6)),
        (Color(hex: 0x7A4B62), Color(hex: 0xD69AB6)),
        (Color(hex: 0x2F6F80), Color(hex: 0x8FD0D6)),
        (Color(hex: 0x6A8CAF), Color(hex: 0xC9B78F)),
    ]

    private struct Item: Identifiable {
        var id: String
        /// Normalized 0...1 against the page.
        var rect: CGRect
        var kind: Kind

        enum Kind {
            case photo(Orientation, colour: Int)
            case text(TextRole)
        }
    }

    private var items: [Item] {
        guard let g = Self.geometry else { return [] }
        let page = g.pageRect(side: side)
        func normalized(_ r: Rect) -> CGRect {
            CGRect(x: (r.minX - page.minX) / page.size.width, y: (r.minY - page.minY) / page.size.height,
                   width: r.size.width / page.size.width, height: r.size.height / page.size.height)
        }
        let made = PageSpread.pageItems(layout, side: side, geometry: g, marginMM: Self.marginMM)
        let photos = zip(made.frames, layout.frames).enumerated().map { i, pair in
            Item(id: pair.0.id, rect: normalized(pair.0.rect), kind: .photo(pair.1.orientation, colour: i))
        }
        let texts = made.texts.map { Item(id: $0.id, rect: normalized($0.rect), kind: .text($0.role)) }
        return photos + texts
    }

    private static var aspect: CGFloat {
        guard let g = geometry else { return 4 / 3 }
        return g.format.pageWidthMM / g.format.pageHeightMM
    }

    var body: some View {
        Color.white
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack(alignment: .topLeading) {
                        ForEach(items) { item in
                            itemView(item, pageHeight: size.height)
                                .frame(width: item.rect.width * size.width, height: item.rect.height * size.height)
                                .offset(x: item.rect.minX * size.width, y: item.rect.minY * size.height)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            }
            .clipped()
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .environment(\.colorScheme, .light)  // paper stays paper in dark mode
            .accessibilityHidden(true)
    }

    @ViewBuilder private func itemView(_ item: Item, pageHeight h: CGFloat) -> some View {
        switch item.kind {
        case let .photo(orientation, colour):
            let (dark, light) = Self.gradients[colour % Self.gradients.count]
            LinearGradient(colors: [dark, light], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: orientation == .portrait ? "rectangle.portrait" : "rectangle")
                        .font(.system(size: max(h * 0.06, 5)))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(max(h * 0.02, 2))
                }
        case .text(let role):
            sample(role, pageHeight: h)
        }
    }

    /// The sample text of a role, scaled to the page and shrunk to fit its box.
    private func sample(_ role: TextRole, pageHeight h: CGFloat) -> some View {
        let dark = Color(white: 0.2)
        let (text, font, colour, alignment): (String, Font, Color, Alignment) = switch role {
        case .date: ("čtvrtek 18. června", .system(size: h * 0.05, design: .serif), .gray, .topLeading)
        case .title: ("Ravello", .system(size: h * 0.085, weight: .bold, design: .serif), dark, .topLeading)
        case .body: ("Co jsme dnes dělali…", .system(size: h * 0.05, design: .serif).italic(), .gray, .topLeading)
        case .caption, .pageNumber:
            ("Popisek", .system(size: h * 0.055, weight: .semibold, design: .serif), Color(white: 0.3), .center)
        }
        return Text(text)
            .font(font)
            .foregroundStyle(colour)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
