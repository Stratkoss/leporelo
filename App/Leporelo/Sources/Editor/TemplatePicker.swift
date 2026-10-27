import AppKit
import LeporeloCore
import SwiftUI

/// What `TemplatePicker` offers.
enum TemplatePickerContent {
    /// Spread templates (the intro and the closing).
    case templates([SpreadTemplate])
    /// Page layouts for the current page `side` of a journal, gallery or blank spread.
    case pageLayouts([PageLayout], side: PageSide)
    /// A spread of pages without a current page: "Klikni na stránku".
    case needsPage
}

/// "Doporučená rozložení" ("Doporučené rozložení…"). For the intro and the closing: the templates
/// `EditorModel.availableTemplates(for:)` offers, each with a small rendered preview (blank grey
/// frames, the placeholders as text, conformed to the book's `marginMM`) and its frame count. For
/// a journal, gallery or blank spread: the page layouts for the current page
/// (`EditorModel.availablePageLayouts`), grouped by their number of photos ("1 fotka", "2 fotky",
/// …, "Bez fotek" last), each with a `PageLayoutPreview` and its name; without a current page
/// only "Klikni na stránku". Choosing one runs `attempt(id, confirmTextLoss, confirmLayoutReplace)`
/// (the editor's `changeTemplate` or `changePageLayout`).
/// The confirmations are shown INSIDE this sheet, so they can never be dropped by the sheet's
/// dismissal: a hand-made layout asks "Ruční rozložení se nahradí doporučeným." (with the texts
/// that would be lost, `droppedTexts`, in the same question), otherwise texts that would be lost
/// ask "Tyto texty by se ztratily: …". The sheet closes (`onDone`) only once the change is
/// applied or the user cancels. A refused change says so. On a hand-made layout the current
/// template can be chosen too: it restores the recommended layout.
struct TemplatePicker: View {
    let content: TemplatePickerContent
    /// The spread's template or the current page's layout.
    let currentID: String?
    /// The spread's layout was changed by hand (`Spread.customLayout`; false for a page).
    let customLayout: Bool
    let geometry: PageGeometry
    let marginMM: Double
    let droppedTexts: (_ id: String) -> [TextBox]
    let attempt: (_ id: String, _ confirmTextLoss: Bool, _ confirmLayoutReplace: Bool) -> TemplateChangeOutcome
    let onDone: () -> Void

    private struct PendingLoss: Identifiable {
        let templateID: String
        let texts: [TextBox]
        let layoutConfirmed: Bool
        var id: String { templateID }
    }

    private struct PendingLayout: Identifiable {
        let templateID: String
        let texts: [TextBox]
        var id: String { templateID }
    }

    @State private var pendingLoss: PendingLoss?
    @State private var pendingLayout: PendingLayout?
    @State private var showsUnavailable = false

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]
    private let pageColumns = [GridItem(.adaptive(minimum: 140), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(EditorText.recommendedLayouts).font(.title3.bold())
            Text("Fotky se rozmístí znovu, texty zůstanou, kde to jde.")
                .foregroundStyle(.secondary)
            switch content {
            case .templates(let templates):
                ScrollView { templateGrid(templates).padding(2) }
            case let .pageLayouts(layouts, side):
                ScrollView { pageGrid(layouts, side: side).padding(2) }
            case .needsPage:
                ContentUnavailableView(EditorText.clickPage, systemImage: "cursorarrow.click")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Zrušit", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 640, minHeight: 360, idealHeight: 460)
        .alert(EditorText.applyLayoutQuestion, isPresented: Binding(get: { pendingLoss != nil },
                                                                    set: { if !$0 { pendingLoss = nil } }),
               presenting: pendingLoss) { pending in
            Button(EditorText.applyLayout, role: .destructive) {
                choose(pending.templateID, confirmTextLoss: true, confirmLayoutReplace: pending.layoutConfirmed)
            }
            Button("Zrušit", role: .cancel) {}
        } message: { pending in
            Text(EditorText.textLoss(pending.texts))
        }
        .alert(EditorText.replaceLayoutQuestion,
               isPresented: Binding(get: { pendingLayout != nil }, set: { if !$0 { pendingLayout = nil } }),
               presenting: pendingLayout) { pending in
            Button(EditorText.replaceLayout, role: .destructive) {
                choose(pending.templateID, confirmTextLoss: !pending.texts.isEmpty, confirmLayoutReplace: true)
            }
            Button("Zrušit", role: .cancel) {}
        } message: { pending in
            if !pending.texts.isEmpty { Text(EditorText.textLoss(pending.texts)) }
        }
        .alert("Rozložení nejde použít", isPresented: $showsUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Dvoustrana se mezitím změnila. Zkuste to prosím znovu.")
        }
    }

    private func choose(_ templateID: String, confirmTextLoss: Bool = false, confirmLayoutReplace: Bool = false) {
        switch attempt(templateID, confirmTextLoss, confirmLayoutReplace) {
        case .applied:
            pendingLoss = nil
            pendingLayout = nil
            onDone()
        case .needsLayoutReplaceConfirmation:
            pendingLayout = PendingLayout(templateID: templateID, texts: droppedTexts(templateID))
        case .needsTextLossConfirmation(let texts):
            pendingLoss = PendingLoss(templateID: templateID, texts: texts, layoutConfirmed: confirmLayoutReplace)
        case .unavailable:
            pendingLoss = nil
            pendingLayout = nil
            showsUnavailable = true
        }
    }

    // MARK: Spread templates

    private func templateGrid(_ templates: [SpreadTemplate]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(templates, id: \.id) { template in
                Button { choose(template.id) } label: { cell(template) }
                    .buttonStyle(.plain)
                    .disabled(template.id == currentID && !customLayout)
                    .accessibilityLabel(EditorText.templateLabel(template)
                                        + (template.id == currentID ? ", současné rozložení" : ""))
            }
        }
    }

    private func cell(_ template: SpreadTemplate) -> some View {
        let isCurrent = template.id == currentID
        return VStack(spacing: 6) {
            Group {
                if let image = TemplatePreview.image(template, geometry: geometry, marginMM: marginMM, width: 360) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.white
                }
            }
            .frame(height: 70)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isCurrent ? 3 : 1))
            HStack(spacing: 4) {
                Text(EditorText.templateLabel(template)).font(.callout)
                if isCurrent { Text("· současná").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(6)
        .contentShape(Rectangle())
    }

    // MARK: Page layouts

    /// The layouts grouped by photo count, ascending, the layouts without photos last; catalog
    /// order inside a group.
    nonisolated static func groups(_ layouts: [PageLayout]) -> [(count: Int, layouts: [PageLayout])] {
        let counts = Set(layouts.map(\.photoCount)).sorted { a, b in a == 0 ? false : b == 0 ? true : a < b }
        return counts.map { n in (n, layouts.filter { $0.photoCount == n }) }
    }

    private func pageGrid(_ layouts: [PageLayout], side: PageSide) -> some View {
        LazyVGrid(columns: pageColumns, alignment: .leading, spacing: 14) {
            ForEach(Self.groups(layouts), id: \.count) { group in
                Section {
                    ForEach(group.layouts, id: \.id) { layout in
                        Button { choose(layout.id) } label: { pageCell(layout, side: side) }
                            .buttonStyle(.plain)
                            .disabled(layout.id == currentID)
                            .accessibilityLabel(EditorText.pageLayoutLabel(layout)
                                                + (layout.id == currentID ? ", současné rozložení" : ""))
                    }
                } header: {
                    Text(EditorText.pageLayoutGroup(group.count))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func pageCell(_ layout: PageLayout, side: PageSide) -> some View {
        let isCurrent = layout.id == currentID
        return VStack(spacing: 6) {
            PageLayoutPreview(layout: layout, side: side)
                .overlay(Rectangle()
                    .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.4),
                                  lineWidth: isCurrent ? 3 : 1))
                .frame(height: 90)
            HStack(spacing: 4) {
                Text(layout.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                if isCurrent { Text("· současná").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(6)
        .contentShape(Rectangle())
    }
}

/// A template rendered with empty (grey) frames and its placeholder texts, conformed to the page
/// margin, synchronously (no images to load; a few milliseconds), cached per template, geometry,
/// margin and width.
@MainActor
enum TemplatePreview {
    private static var cache: [String: NSImage] = [:]

    static func image(_ template: SpreadTemplate, geometry: PageGeometry, marginMM: Double, width: Int) -> NSImage? {
        let key = "\(template.id)|\(geometry.profile.id)|\(geometry.format.id)|\(marginMM)|\(width)"
        if let image = cache[key] { return image }
        var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: nil, id: "preview",
                                                marginMM: marginMM)
        for i in spread.texts.indices {
            spread.texts[i].text = template.texts.first { $0.id == spread.texts[i].id }?.placeholder ?? ""
        }
        let area = CanvasLayout.visibleArea(geometry: geometry, isCover: false)
        let ppmm = Double(width) / area.size.width
        let height = max(Int((area.size.height * ppmm).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let album = Album(formatVersion: Album.currentFormatVersion, id: "preview", title: "", supplierProfileID: geometry.profile.id,
                          formatID: geometry.format.id, world: Workflow.world, cover: nil, spreads: [], photos: [:],
                          source: nil, createdAt: Date(timeIntervalSince1970: 0))
        SpreadRenderer(album: album, geometry: geometry, images: PlaceholderImageProvider())
            .draw(spread, images: [:], into: ctx, options: RenderOptions(showGuides: false, includeBleed: true, pixelsPerMM: ppmm))
        guard let cgImage = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        cache[key] = image
        return image
    }
}
