import LeporeloCore
import SwiftUI

/// "Která rozložení se ti líbí?" (spec 6): the nine layouts the draft chooses from, as page
/// previews to mark with a heart. "Hotovo" hands over the marked ones (`onFinish`), "Přeskočit"
/// calls `onSkip`: the caller decides what skipping means. The first-time sheet and the menu
/// window show the same view.
struct FavoriteLayoutsView: View {
    let onFinish: (Set<String>) -> Void
    let onSkip: () -> Void

    @State private var liked: Set<String>

    init(initial: Set<String>, onFinish: @escaping (Set<String>) -> Void, onSkip: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onSkip = onSkip
        _liked = State(initialValue: initial)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
    private let layouts = PageLayoutCatalog.favouriteCandidates.compactMap(PageLayoutCatalog.layout(id:))

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Která rozložení se ti líbí?")
                    .font(.title2.bold())
                Text("Nejlepší fotky dostanou celou stránku vždycky. Vyber, co se ti líbí dál – návrh je bude používat častěji.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(layouts, id: \.id) { layout in
                    tile(layout)
                }
            }
            HStack {
                Spacer()
                Button("Přeskočit") { onSkip() }
                Button("Hotovo") { onFinish(liked) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func tile(_ layout: PageLayout) -> some View {
        let isLiked = liked.contains(layout.id)
        return Button {
            if isLiked { liked.remove(layout.id) } else { liked.insert(layout.id) }
        } label: {
            VStack(spacing: 6) {
                PageLayoutPreview(layout: layout)
                HStack(spacing: 4) {
                    Text(layout.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? Color.accentColor : .secondary)
                }
                .font(.callout)
            }
            .padding(8)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: isLiked ? 2 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.name)
        .accessibilityValue(isLiked ? "Oblíbené" : "Neoznačené")
        .accessibilityAddTraits(isLiked ? .isSelected : [])
    }
}

/// Leporelo > "Oblíbená rozložení…": the same choice in a window of its own, filled with what is
/// stored each time the window appears. "Hotovo" stores the choice, "Přeskočit" keeps the stored
/// favourites (it only records that the choice was offered); both close the window.
struct FavoriteLayoutsWindow: View {
    static let windowID = "favorite-layouts"

    @Environment(\.dismissWindow) private var dismissWindow
    /// Bumped each time the window appears: the choice is made afresh from the stored favourites,
    /// never with hearts left over from an earlier opening of the window.
    @State private var appearance = 0

    var body: some View {
        // The container's `onAppear` fires when the window appears, not when the choice inside
        // gets its new identity.
        VStack(spacing: 0) {
            FavoriteLayoutsView(initial: LayoutPreferences().liked) { liked in
                var preferences = LayoutPreferences()
                preferences.finish(liked: liked)
                dismissWindow(id: Self.windowID)
            } onSkip: {
                var preferences = LayoutPreferences()
                preferences.skip()
                dismissWindow(id: Self.windowID)
            }
            .id(appearance)
        }
        .onAppear { appearance += 1 }
        .frame(width: 640)
        .fixedSize()
    }
}
