import AppKit
import LeporeloCore
import SwiftUI

/// The photo tray on the right of the editor (spec 6.4): `EditorModel.trayPhotos` (the current
/// day and its neighbours, selected first; or "Celý výběr") in a 96 pt grid. Placed photos get a
/// small dot, selected photos that are in no frame a warning marker, unselected ones are dimmed.
/// Dragging a photo carries its id (`PhotoPasteboard`) onto a frame of the canvas.
///
/// Decision: a SwiftUI `LazyVGrid` instead of the triage grid's `NSCollectionView`: the tray holds
/// three days or the selection (tens to a few hundred photos), so cell reuse is not needed, and
/// `PhotoCell` is the 160 pt triage cell with its own badges and click semantics. Thumbnails reuse
/// the triage `ThumbnailLoader` (its own instance, so the tray's cache does not evict the grid's).
struct PhotoTrayView: View {
    let model: EditorModel
    let loader: ThumbnailLoader
    /// A photo to scroll to and ring briefly (from the "not in the album" list).
    @Binding var highlighted: PhotoID?

    static let cellSide: CGFloat = 96
    private let columns = [GridItem(.adaptive(minimum: cellSide, maximum: cellSide), spacing: 6)]

    var body: some View {
        let photos = model.trayPhotos
        let placed = model.placedPhotoIDs
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(EditorText.tray).font(.headline)
                    Spacer()
                    Toggle(EditorText.wholeSelection, isOn: Binding(
                        get: { model.trayShowsAll },
                        set: { model.trayShowsAll = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            Divider()
            if photos.isEmpty {
                ContentUnavailableView("Žádné fotky", systemImage: "photo.on.rectangle",
                                       description: Text("Tento den nemá žádné fotky."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(photos, id: \.id) { photo in
                                TrayCell(photo: photo, isPlaced: placed.contains(photo.id),
                                         isHighlighted: highlighted == photo.id, loader: loader,
                                         package: model.store.package)
                                    .id(photo.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: highlighted) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(EditorText.tray)
    }

    private var caption: String {
        if model.trayShowsAll { return "Všechny vybrané fotky alba" }
        guard let day = model.trayDay else { return "" }
        return "\(TriageText.shortDate(day)) a sousední dny, vybrané první"
    }
}

private struct TrayCell: View {
    let photo: Photo
    let isPlaced: Bool
    let isHighlighted: Bool
    let loader: ThumbnailLoader
    let package: ProjectPackage

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: PhotoTrayView.cellSide, height: PhotoTrayView.cellSide)
                    .clipped()
                    .opacity(photo.isSelected ? 1 : 0.4)
            }
        }
        .frame(width: PhotoTrayView.cellSide, height: PhotoTrayView.cellSide)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomLeading) {
            if isPlaced {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .padding(5)
                    .help("Fotka je v albu")
            }
        }
        .overlay(alignment: .topTrailing) {
            if photo.isSelected && !isPlaced {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .yellow)
                    .padding(4)
                    .help("Vybraná fotka není v albu")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, lineWidth: isHighlighted ? 3 : 0))
        .onDrag {
            let provider = NSItemProvider(object: PhotoDrag.payload(for: photo.id) as NSString)
            let id = photo.id
            provider.registerDataRepresentation(forTypeIdentifier: PhotoPasteboard.typeIdentifier,
                                                visibility: .ownProcess) { completion in
                completion(Data(id.utf8), nil)
                return nil
            }
            return provider
        }
        .task(id: "\(photo.id)|\(photo.analysis != nil)") {
            image = loader.cached(photo.id)
            if image == nil {
                image = await loader.load(photo.id, maxPixel: ThumbnailLoader.maxPixel(for: photo), from: package)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Přetáhněte fotku do rámečku na dvoustraně")
    }

    private var accessibilityLabel: String {
        var parts = ["Fotka \(EditorText.photoLabel(photo))", photo.isSelected ? "vybraná" : "nevybraná"]
        if isPlaced { parts.append("v albu") } else if photo.isSelected { parts.append("není v albu") }
        return parts.joined(separator: ", ")
    }
}
