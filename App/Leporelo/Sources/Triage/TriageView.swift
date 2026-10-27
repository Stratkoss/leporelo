import LeporeloCore
import SwiftUI

/// What "Navrhnout album" does. Task 21 (the editor) installs it with `.environment(\.proposeAlbum, ...)`;
/// without it the button is disabled with a tooltip.
struct ProposeAlbumAction {
    let run: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var proposeAlbum: ProposeAlbumAction? = nil
}

/// Třídění (spec 6.2): the days on the left, the day's photos in the middle, the "Jen doporučené"
/// switch on top, the selection count, page estimate and "Navrhnout album" at the bottom.
/// Dragging a photo onto a day in the list moves it there.
struct TriageView: View {
    let model: TriageModel

    @Environment(\.undoManager) private var undoManager
    @Environment(\.proposeAlbum) private var proposeAlbum
    @State private var dropTarget: DayEntryID?

    var body: some View {
        HStack(spacing: 0) {
            dayList
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 340)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                grid
                Divider()
                footer
            }
        }
        .onAppear {
            AlbumStore.configure(undoManager)
            model.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, manager in
            AlbumStore.configure(manager)
            model.undoManager = manager
        }
    }

    // MARK: Days

    private var dayList: some View {
        let selection = Binding<DayEntryID?>(
            get: { model.visibleEntry },
            set: { model.currentEntry = $0 })
        return List(selection: selection) {
            ForEach(model.dayEntries) { entry in
                dayRow(entry).tag(entry.id)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Dny")
    }

    @ViewBuilder private func dayRow(_ entry: DayEntry) -> some View {
        let row = Text(entry.label)
            .lineLimit(2)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(dropTarget == entry.id ? 1 : 0))
            .accessibilityLabel(entry.accessibilityLabel)
        if case .day(let key) = entry.id {
            row.dropDestination(for: String.self) { strings, _ in
                guard let id = strings.lazy.compactMap(PhotoDrag.photoID(from:)).first else { return false }
                model.move(id, to: key)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = entry.id } else if dropTarget == entry.id { dropTarget = nil }
            }
        } else {
            row.help("Fotky bez data přetáhněte do správného dne")
        }
    }

    // MARK: Grid

    private var header: some View {
        HStack {
            Toggle(TriageText.onlyRecommended, isOn: Binding(
                get: { model.showOnlyRecommended },
                set: { model.showOnlyRecommended = $0 }))
                .toggleStyle(.switch)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var grid: some View {
        let entry = model.visibleEntry
        let items = entry.map { model.items(for: $0) } ?? []
        if items.isEmpty {
            ContentUnavailableView(model.showOnlyRecommended ? "Žádné doporučené fotky" : "Žádné fotky",
                                   systemImage: "photo.on.rectangle",
                                   description: Text(model.showOnlyRecommended
                                                     ? "Vypněte „Jen doporučené“, uvidíte všechny fotky dne."
                                                     : "Vyberte v seznamu jiný den."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhotoGridView(items: items, entry: entry, package: model.store.package,
                          onToggle: { model.toggleSelection($0) },
                          onSeriesChip: { model.toggleSeries($0) })
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(model.footerText)
                .monospacedDigit()
            Spacer()
            Button(TriageText.propose) { proposeAlbum?.run() }
                .keyboardShortcut(.defaultAction)
                .disabled(proposeAlbum == nil || model.selectedTotal == 0)
                .help(proposeAlbum == nil ? TriageText.proposeUnavailable : "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Owns the `TriageModel` of one store. The model is created once per store identity (on appear
/// and when the store changes), never in `init`: `State(initialValue:)` would evaluate a throwaway
/// model on every body evaluation of the window.
struct TriageContainer: View {
    let store: AlbumStore
    @State private var model: TriageModel?

    var body: some View {
        Group {
            if let model, model.store === store {
                TriageView(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: makeModel)
        .onChange(of: ObjectIdentifier(store)) { makeModel() }
    }

    private func makeModel() {
        if model?.store !== store { model = TriageModel(store: store) }
    }
}
