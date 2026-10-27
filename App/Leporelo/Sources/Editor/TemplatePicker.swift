import AppKit
import LeporeloCore
import SwiftUI

/// "Změnit šablonu…": the templates `EditorModel.availableTemplates(for:)` offers for a spread,
/// each with a small rendered preview (blank grey frames, the placeholders as text) and its
/// frame count. Choosing one runs `attempt(templateID, confirmTextLoss)` (the editor's
/// `changeTemplate`). When texts would be lost, the confirmation ("Tyto texty by se ztratily: …")
/// is shown INSIDE this sheet, so it can never be dropped by the sheet's dismissal; the sheet
/// closes (`onDone`) only once the change is applied or the user cancels. A refused change says so.
struct TemplatePicker: View {
    let templates: [SpreadTemplate]
    let currentTemplateID: String?
    let geometry: PageGeometry
    let attempt: (_ templateID: String, _ confirmTextLoss: Bool) -> TemplateChangeOutcome
    let onDone: () -> Void

    private struct PendingLoss: Identifiable {
        let templateID: String
        let texts: [TextBox]
        var id: String { templateID }
    }

    @State private var pendingLoss: PendingLoss?
    @State private var showsUnavailable = false

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Změnit šablonu").font(.title3.bold())
            Text("Fotky se rozmístí znovu, texty zůstanou, kde to jde.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(templates, id: \.id) { template in
                        Button { choose(template.id, confirmed: false) } label: { cell(template) }
                            .buttonStyle(.plain)
                            .disabled(template.id == currentTemplateID)
                            .accessibilityLabel(EditorText.templateLabel(template)
                                                + (template.id == currentTemplateID ? ", současná šablona" : ""))
                    }
                }
                .padding(2)
            }
            HStack {
                Spacer()
                Button("Zrušit", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 640, minHeight: 360, idealHeight: 460)
        .alert("Změnit šablonu?", isPresented: Binding(get: { pendingLoss != nil },
                                                        set: { if !$0 { pendingLoss = nil } }),
               presenting: pendingLoss) { pending in
            Button("Změnit šablonu", role: .destructive) { choose(pending.templateID, confirmed: true) }
            Button("Zrušit", role: .cancel) {}
        } message: { pending in
            Text(EditorText.textLoss(pending.texts))
        }
        .alert("Šablonu nejde použít", isPresented: $showsUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Dvoustrana se mezitím změnila. Zkuste to prosím znovu.")
        }
    }

    private func choose(_ templateID: String, confirmed: Bool) {
        switch attempt(templateID, confirmed) {
        case .applied:
            pendingLoss = nil
            onDone()
        case .needsTextLossConfirmation(let texts):
            pendingLoss = PendingLoss(templateID: templateID, texts: texts)
        case .unavailable:
            pendingLoss = nil
            showsUnavailable = true
        }
    }

    private func cell(_ template: SpreadTemplate) -> some View {
        let isCurrent = template.id == currentTemplateID
        return VStack(spacing: 6) {
            Group {
                if let image = TemplatePreview.image(template, geometry: geometry, width: 360) {
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
}

/// A template rendered with empty (grey) frames and its placeholder texts, synchronously (no
/// images to load; a few milliseconds), cached per template, geometry and width.
@MainActor
enum TemplatePreview {
    private static var cache: [String: NSImage] = [:]

    static func image(_ template: SpreadTemplate, geometry: PageGeometry, width: Int) -> NSImage? {
        let key = "\(template.id)|\(geometry.profile.id)|\(geometry.format.id)|\(width)"
        if let image = cache[key] { return image }
        var spread = TemplateLayout.instantiate(template, geometry: geometry, dayKey: nil, id: "preview")
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
