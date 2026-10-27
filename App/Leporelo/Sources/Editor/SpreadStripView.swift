import AppKit
import LeporeloCore
import SwiftUI

/// Low-resolution strip thumbnails: `SpreadRenderer.renderPNG`/`renderCoverPNG` on a detached
/// task (never the main thread), cached by `SpreadThumbnailKey` (spread content, geometry, scale,
/// which photos have thumbnails). Images come from the package's stored thumbnails (the hint at
/// this scale is far below 1024 px).
@MainActor
final class SpreadThumbnailCache {
    static let maxEntries = 400
    private var images: [SpreadThumbnailKey: NSImage] = [:]

    func cached(_ key: SpreadThumbnailKey) -> NSImage? { images[key] }

    func render(_ key: SpreadThumbnailKey, content: CanvasContent, album: Album, geometry: PageGeometry,
                package: ProjectPackage) async -> NSImage? {
        if let image = images[key] { return image }
        let renderer = SpreadRenderer(album: album, geometry: geometry,
                                      images: PackageImageProvider(package: package, album: album))
        let options = RenderOptions(showGuides: false, includeBleed: true, pixelsPerMM: key.pixelsPerMM)
        let data = await Task.detached(priority: .utility) { () -> Data? in
            switch content {
            case .spread(let s): await renderer.renderPNG(s, options: options)
            case .cover(let s): await renderer.renderCoverPNG(s, options: options)
            }
        }.value
        guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return nil }
        if images.count >= Self.maxEntries { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }
}

/// Which strip item is shown on the canvas: a spread (the model's current spread) or a cover side.
enum CoverSide: Hashable {
    case front, back
}

/// The strip of spreads at the bottom of the editor (spec 6.4): the cover first (front, back;
/// view only), then every spread. Click shows it on the canvas; drag reorders (`StripDrop`: the
/// intro and the closing stay put); the context menu changes the template, inserts a spread after
/// it or deletes it. Each item shows a badge when it has warnings or errors. The header shows the
/// album-level warnings (page count, selected photos not in the album).
struct SpreadStripView: View {
    let model: EditorModel
    @Binding var coverSide: CoverSide?
    let thumbnails: SpreadThumbnailCache
    let onChangeTemplate: (String) -> Void
    let onDelete: (String) -> Void
    let onShowInTray: (PhotoID) -> Void

    static let itemHeight: CGFloat = 64

    @State private var draggingID: String?
    @State private var dropGap: Int?
    @State private var showsUnplaced = false
    @State private var showsAlbumIssues = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let album = model.store.album
        let geometry = model.geometry
        VStack(alignment: .leading, spacing: 4) {
            header(album)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        if let cover = album.cover {
                            coverItem(cover.front, side: .front, album: album, geometry: geometry)
                            coverItem(cover.back, side: .back, album: album, geometry: geometry)
                            Divider().frame(height: Self.itemHeight)
                        }
                        let kinds = album.spreads.map(\.kind)
                        ForEach(Array(album.spreads.enumerated()), id: \.element.id) { index, spread in
                            spreadItem(spread, index: index, kinds: kinds, album: album, geometry: geometry)
                                .id(spread.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.currentSpreadID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
        .padding(.top, 6)
        .frame(height: Self.itemHeight + 62)
    }

    // MARK: Header: album-level warnings

    @ViewBuilder private func header(_ album: Album) -> some View {
        let albumIssues = model.allIssues.filter { $0.spreadID == nil && $0.id != "unplacedSelected" }
        let unplaced = model.unplacedSelectedPhotos
        HStack(spacing: 12) {
            Text("\(EditorText.spreads) · \(CzechPlural.pages(album.spreads.count * 2))")
                .font(.headline)
            if !albumIssues.isEmpty {
                Button {
                    showsAlbumIssues = true
                } label: {
                    Label(EditorText.problems(albumIssues.count) + " alba",
                          systemImage: albumIssues.contains { $0.severity == .error }
                              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(albumIssues.contains { $0.severity == .error } ? .red : .orange)
                .popover(isPresented: $showsAlbumIssues) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(albumIssues) { Text($0.message) }
                    }
                    .padding()
                    .frame(minWidth: 260)
                }
            }
            if !unplaced.isEmpty {
                Button {
                    showsUnplaced = true
                } label: {
                    Label(model.allIssues.first { $0.id == "unplacedSelected" }?.message
                              ?? CzechPlural.photos(unplaced.count),
                          systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Kliknutím zobrazíte, které to jsou")
                .popover(isPresented: $showsUnplaced) { unplacedList(unplaced) }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    private func unplacedList(_ photos: [Photo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kliknutím fotku najdete v zásobníku").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(photos, id: \.id) { photo in
                        Button {
                            showsUnplaced = false
                            onShowInTray(photo.id)
                        } label: {
                            Text(EditorText.photoLabel(photo))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding()
        .frame(minWidth: 260)
    }

    // MARK: Items

    private func itemWidth(isCover: Bool, geometry: PageGeometry) -> CGFloat {
        let area = CanvasLayout.visibleArea(geometry: geometry, isCover: isCover)
        return Self.itemHeight * area.size.width / max(area.size.height, 1)
    }

    private func pixelsPerMM(isCover: Bool, geometry: PageGeometry) -> Double {
        SpreadThumbnailKey.pixelsPerMM(height: Self.itemHeight, backingScale: displayScale,
                                       visibleHeightMM: CanvasLayout.visibleArea(geometry: geometry, isCover: isCover).size.height)
    }

    private func coverItem(_ page: Spread, side: CoverSide, album: Album, geometry: PageGeometry) -> some View {
        let key = SpreadThumbnailKey(spread: page, geometry: geometry, photos: album.photos,
                                     pixelsPerMM: pixelsPerMM(isCover: true, geometry: geometry))
        let label = side == .front ? "Obálka přední" : "Obálka zadní"
        return VStack(spacing: 3) {
            StripThumbnail(key: key, content: .cover(page), album: album, geometry: geometry,
                           package: model.store.package, cache: thumbnails)
                .frame(width: itemWidth(isCover: true, geometry: geometry), height: Self.itemHeight)
                .overlay(selectionBorder(coverSide == side))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.commitSessions()
            coverSide = side
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private func spreadItem(_ spread: Spread, index: Int, kinds: [SpreadKind], album: Album,
                            geometry: PageGeometry) -> some View {
        let key = SpreadThumbnailKey(spread: spread, geometry: geometry, photos: album.photos,
                                     pixelsPerMM: pixelsPerMM(isCover: false, geometry: geometry))
        let issues = model.issues(for: spread.id)
        let width = itemWidth(isCover: false, geometry: geometry)
        let isCurrent = coverSide == nil && model.currentSpreadID == spread.id
        let item = VStack(spacing: 3) {
            StripThumbnail(key: key, content: .spread(spread), album: album, geometry: geometry,
                           package: model.store.package, cache: thumbnails)
                .frame(width: width, height: Self.itemHeight)
                .overlay(selectionBorder(isCurrent))
                .overlay(alignment: .topTrailing) {
                    if !issues.isEmpty {
                        let isError = WarningBadge.severity(issues) == .error
                        Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isError ? Color.red : Color.orange)
                            .padding(3)
                            .help(EditorText.problems(issues.count))
                    }
                }
                .overlay(alignment: .leading) { dropIndicator(dropGap == index) }
                .overlay(alignment: .trailing) { dropIndicator(index == kinds.count - 1 && dropGap == kinds.count) }
            Text("\(index + 1) · \(EditorText.kindName(spread.kind))")
                .font(.caption2)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            coverSide = nil
            model.currentSpreadID = spread.id
        }
        .contextMenu { contextMenu(spread) }
        .onDrop(of: [.plainText, .utf8PlainText],
                delegate: StripDropDelegate(index: index, width: width, kinds: kinds, model: model,
                                            draggingID: $draggingID, dropGap: $dropGap))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EditorText.stripLabel(index: index, kind: spread.kind, day: spread.dayKey,
                                                  issues: issues.count))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)

        return Group {
            if StripDrop.canDrag(index: index, kinds: kinds) {
                item.onDrag {
                    draggingID = spread.id
                    return NSItemProvider(object: SpreadDrag.payload(for: spread.id) as NSString)
                }
            } else {
                item
            }
        }
    }

    @ViewBuilder private func contextMenu(_ spread: Spread) -> some View {
        Button(EditorText.changeTemplate) { onChangeTemplate(spread.id) }
            .disabled(model.availableTemplates(for: spread.id).count < 2)
        Menu(EditorText.insertAfter) {
            ForEach(EditorText.insertableKinds, id: \.self) { kind in
                Button(EditorText.insertKindName(kind)) {
                    coverSide = nil
                    model.insertSpread(kind: kind, after: spread.id)
                }
            }
        }
        Divider()
        Button(EditorText.deleteSpread, role: .destructive) { onDelete(spread.id) }
    }

    private func selectionBorder(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isSelected ? 3 : 1)
    }

    private func dropIndicator(_ visible: Bool) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 3)
            .offset(x: 0)
            .opacity(visible ? 1 : 0)
            .padding(.horizontal, -6)
    }
}

/// One thumbnail: white paper until the render arrives.
struct StripThumbnail: View {
    let key: SpreadThumbnailKey
    let content: CanvasContent
    let album: Album
    let geometry: PageGeometry
    let package: ProjectPackage
    let cache: SpreadThumbnailCache

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium)
            }
        }
        .task(id: key) {
            if let cached = cache.cached(key) {
                image = cached
                return
            }
            if let rendered = await cache.render(key, content: content, album: album, geometry: geometry,
                                                 package: package) {
                image = rendered
            }
        }
    }
}

/// Reorder drop on a strip item: the left half drops before it, the right half after it
/// (`StripDrop`); refused before the intro, after the closing and onto its own place.
struct StripDropDelegate: DropDelegate {
    let index: Int
    let width: CGFloat
    let kinds: [SpreadKind]
    let model: EditorModel
    @Binding var draggingID: String?
    @Binding var dropGap: Int?

    private func target(_ info: DropInfo) -> (gap: Int, to: Int)? {
        guard let id = draggingID, let from = model.spreadIndex(of: id) else { return nil }
        let gap = StripDrop.gap(hoverIndex: index, trailingHalf: info.location.x > width / 2)
        return StripDrop.moveIndex(from: from, gap: gap, kinds: kinds).map { (gap, $0) }
    }

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let t = target(info)
        dropGap = t?.gap
        return DropProposal(operation: t == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        dropGap = nil
    }

    /// SwiftUI has no drag-end callback, so `draggingID` can be stale (a strip drag that ended
    /// elsewhere): the dropped text must really be that spread's payload, never a photo.
    /// False unless this strip is dragging a spread onto a valid gap (`StripDrop.decision`). When
    /// the drag pasteboard already names that spread the move happens now; otherwise the payload is
    /// loaded from the item provider and checked before the move (the return value cannot wait for
    /// that asynchronous check).
    func performDrop(info: DropInfo) -> Bool {
        defer {
            dropGap = nil
            draggingID = nil
        }
        guard let t = target(info) else { return false }
        let payload = NSPasteboard(name: .drag).string(forType: .string)
        switch StripDrop.decision(draggingID: draggingID, payload: payload) {
        case .reject:
            return false
        case .move(let id):
            model.moveSpread(id, to: t.to)
            return true
        case .loadPayload(let id):
            guard let provider = info.itemProviders(for: [.plainText, .utf8PlainText]).first else { return false }
            let model = model
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                let loaded = (object as? NSString).map { $0 as String } ?? ""
                Task { @MainActor in
                    guard SpreadDrag.spreadID(from: loaded) == id else { return }
                    model.moveSpread(id, to: t.to)
                }
            }
            return true
        }
    }
}
