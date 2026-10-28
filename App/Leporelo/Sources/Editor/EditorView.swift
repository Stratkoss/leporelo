import AppKit
import LeporeloCore
import SwiftUI

/// What "Exportovat…" does: opens the export sheet. `AlbumContent` installs it with
/// `.environment(\.exportAlbum, ...)` and publishes it for the File menu; nil without spreads.
struct ExportAlbumAction {
    let run: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var exportAlbum: ExportAlbumAction? = nil
}

extension FocusedValues {
    @Entry var albumExport: ExportAlbumAction? = nil
}

/// Ladění (spec 6.4): the big spread in the middle (`SpreadCanvasView`) with the text bar above it
/// (`TextToolsBar`, spec 3.2) and a banner for the spread's problems that belong to no frame,
/// the tray on the right (`PhotoTrayView`), the strip at the bottom (`SpreadStripView`); toolbar:
/// "Zkusit jinak" (the current page, spec 5), "Přidat rámeček", "Přidat text" (on the current
/// page, else the right one), "Mřížka", "Přichytávat", "Okraj", "Navrhnout znovu", "Formát",
/// "Exportovat…" (the window adds "Třídění | Dvoustrany" and "Zpět do třídění"). The grid and
/// snapping switches are remembered for the app (`@AppStorage`); the margin belongs to the book
/// (`EditorModel.setMargin`).
struct EditorView: View {
    let model: EditorModel
    let onBackToTriage: () -> Void

    @Environment(\.undoManager) private var undoManager
    @Environment(\.exportAlbum) private var exportAlbum

    @State private var loader = ThumbnailLoader()
    @State private var thumbnails = SpreadThumbnailCache()
    @State private var trayHighlight: PhotoID?
    @State private var showsSpreadIssues = false

    @State private var templateSpreadID: String?
    @State private var deleteCandidate: String?
    @State private var showsRedraft = false
    @State private var redraftKept = 0
    @State private var formatCandidate: BookFormat?
    /// "Zkusit jinak" asks "Ruční rozložení se nahradí doporučeným." (a manual or old page).
    @State private var asksTryAnotherReplace = false
    /// "Zkusit jinak" asks about these texts; separate from the question above, which an answer
    /// to it may follow.
    @State private var tryAnotherLoss: TryAnotherLoss?

    private struct TryAnotherLoss {
        let texts: [TextBox]
        let layoutConfirmed: Bool
    }

    /// "Mřížka": draws the 5 mm grid and snaps to it.
    @AppStorage("editor.showGrid") private var showGrid = false
    /// "Přichytávat": snaps to page edges, margins, centres and the other items.
    @AppStorage("editor.snapObjects") private var snapObjects = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if canvasContent != nil { TextToolsBar(model: model) }
                    issueBanner
                    canvas
                    Text(model.coverSide == nil ? EditorText.canvasHint : EditorText.coverReadOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                PhotoTrayView(model: model, loader: loader, highlighted: $trayHighlight)
                    .frame(width: 236)
            }
            Divider()
            SpreadStripView(model: model,
                            coverSide: Binding(get: { model.coverSide }, set: { model.coverSide = $0 }),
                            thumbnails: thumbnails,
                            onChangeTemplate: openLayoutPicker,
                            onDelete: requestDelete,
                            onShowInTray: showInTray)
        }
        .toolbar { toolbar }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .onDisappear { model.commitSessions() }
        .sheet(item: Binding(get: { templateSpreadID.map(SheetID.init) }, set: { templateSpreadID = $0?.id })) { sheet in
            layoutPicker(sheet.id)
        }
        .alert(EditorText.replaceLayoutQuestion, isPresented: $asksTryAnotherReplace) {
            Button(EditorText.replaceLayout, role: .destructive) { tryAnother(confirmLayoutReplace: true) }
            Button("Zrušit", role: .cancel) {}
        }
        .alert(EditorText.applyLayoutQuestion, isPresented: Binding(get: { tryAnotherLoss != nil },
                                                                    set: { if !$0 { tryAnotherLoss = nil } }),
               presenting: tryAnotherLoss) { loss in
            Button(EditorText.applyLayout, role: .destructive) {
                tryAnother(confirmLayoutReplace: loss.layoutConfirmed, confirmTextLoss: true)
            }
            Button("Zrušit", role: .cancel) {}
        } message: { loss in
            Text(EditorText.textLoss(loss.texts))
        }
        .alert(EditorText.deleteTitle(), isPresented: Binding(get: { deleteCandidate != nil },
                                                             set: { if !$0 { deleteCandidate = nil } }),
               presenting: deleteCandidate) { id in
            Button(EditorText.deleteSpread, role: .destructive) { model.deleteSpread(id) }
            Button("Zrušit", role: .cancel) {}
        } message: { _ in
            Text(EditorText.deleteMessage)
        }
        .alert(EditorText.redraft, isPresented: $showsRedraft) {
            Button(EditorText.redraft) { model.redraft() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(EditorText.redraftMessage(redraftKept))
        }
        .alert(EditorText.formatChange, isPresented: Binding(get: { formatCandidate != nil },
                                                            set: { if !$0 { formatCandidate = nil } }),
               presenting: formatCandidate) { format in
            Button("Změnit formát") { model.changeFormat(to: format.id) }
            Button("Zrušit", role: .cancel) {}
        } message: { format in
            Text("\(format.name). \(EditorText.formatMessage)")
        }
    }

    private struct SheetID: Identifiable {
        let id: String
    }

    /// "Doporučená rozložení" for the spread: page layouts for its current page (journal, gallery,
    /// blank), else its templates (intro, closing).
    @ViewBuilder private func layoutPicker(_ spreadID: String) -> some View {
        let spread = model.store.album.spreads.first { $0.id == spreadID }
        if model.offersPageLayouts(for: spreadID) {
            TemplatePicker(content: model.currentPageSide.map { .pageLayouts(model.availablePageLayouts(), side: $0) }
                               ?? .needsPage,
                           currentID: model.currentPageLayoutID,
                           customLayout: false,
                           geometry: model.geometry,
                           marginMM: model.marginMM,
                           droppedTexts: { model.previewPageLayoutChange(to: $0)?.droppedTexts ?? [] },
                           attempt: { layoutID, confirmTextLoss, confirmLayoutReplace in
                               model.changePageLayout(to: layoutID, confirmTextLoss: confirmTextLoss,
                                                      confirmLayoutReplace: confirmLayoutReplace)
                           },
                           onDone: { templateSpreadID = nil })
        } else {
            TemplatePicker(content: .templates(model.availableTemplates(for: spreadID)),
                           currentID: spread?.templateID,
                           customLayout: spread?.customLayout ?? false,
                           geometry: model.geometry,
                           marginMM: model.marginMM,
                           droppedTexts: { model.previewTemplateChange(to: $0, in: spreadID)?.droppedTexts ?? [] },
                           attempt: { templateID, confirmTextLoss, confirmLayoutReplace in
                               model.changeTemplate(to: templateID, in: spreadID, confirmTextLoss: confirmTextLoss,
                                                    confirmLayoutReplace: confirmLayoutReplace)
                           },
                           onDone: { templateSpreadID = nil })
        }
    }

    /// Opens the picker for a spread. Page layouts apply to the current page, so the spread
    /// becomes the current one first (keeping its page when it already is).
    private func openLayoutPicker(_ spreadID: String) {
        if model.coverSide != nil || model.currentSpreadID != spreadID { model.currentSpreadID = spreadID }
        templateSpreadID = spreadID
    }

    // MARK: Canvas

    private var canvasContent: CanvasContent? {
        if let coverSide = model.coverSide, let cover = model.store.album.cover {
            return .cover(coverSide == .front ? cover.front : cover.back)
        }
        return model.currentSpread.map(CanvasContent.spread)
    }

    @ViewBuilder private var canvas: some View {
        let store = model.store
        if let content = canvasContent {
            SpreadCanvasView(content: content, album: store.album, revision: store.revision,
                             geometry: model.geometry, package: store.package,
                             issues: model.issues(for: content.page.id),
                             selectedItem: content.isCover ? nil : model.selectedItem,
                             currentPageSide: content.isCover ? nil : model.currentPageSide,
                             snapSettings: SnapSettings(grid: showGrid, objects: snapObjects),
                             showGrid: showGrid,
                             isEditingText: model.isEditingText, model: model,
                             onChangeLayout: openLayoutPicker)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Album zatím nemá dvoustrany", systemImage: "book.pages",
                                   description: Text("Vraťte se do třídění a navrhněte album."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "2 problémy na této dvoustraně": the problems that no frame or text icon shows.
    @ViewBuilder private var issueBanner: some View {
        if let content = canvasContent {
            let unanchored = IssueAnchors(model.issues(for: content.page.id), spread: content.page).unanchored
            if !unanchored.isEmpty {
                let isError = WarningBadge.severity(unanchored) == .error
                HStack {
                    Button {
                        showsSpreadIssues = true
                    } label: {
                        Label(EditorText.issueBanner(unanchored.count),
                              systemImage: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isError ? .red : .orange)
                    .popover(isPresented: $showsSpreadIssues) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(unanchored) { Text($0.message) }
                        }
                        .padding()
                        .frame(minWidth: 260)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    // MARK: Toolbar

    /// Layout edits need a spread on the canvas (the cover is read-only).
    private var canEditLayout: Bool { model.coverSide == nil && model.currentSpreadID != nil }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            let availability = model.tryAnotherAvailability
            Button { tryAnother() } label: { Label(EditorText.tryAnother, systemImage: "shuffle") }
                .disabled(availability != .available)
                .help(EditorText.tryAnotherHelp(availability))

            Button(EditorText.addFrame, systemImage: "rectangle.badge.plus") {
                model.addFrame(on: model.currentPageSide ?? .right)
            }
            .disabled(!canEditLayout)
            .help(EditorText.addFrame)

            Button(EditorText.addText, systemImage: "character.textbox") {
                model.addText(on: model.currentPageSide ?? .right)
            }
            .disabled(!canEditLayout)
            .help(EditorText.addText)

            Toggle(EditorText.grid, systemImage: "grid", isOn: $showGrid)
                .help(EditorText.grid)

            Toggle(EditorText.snap, systemImage: "square.and.line.vertical.and.square", isOn: $snapObjects)
                .help(EditorText.snap)

            let profile = model.geometry.profile
            Stepper(value: Binding(get: { model.marginMM }, set: { model.setMargin($0) }),
                    in: profile.safeMM...max(profile.safeMM, MarginRule.maxMarginMM), step: 1) {
                Text(EditorText.margin(model.marginMM))
                    .monospacedDigit()
            }
            .help(EditorText.margin(model.marginMM))
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(EditorText.backToTriage, systemImage: "square.grid.3x3") {
                model.commitSessions()
                onBackToTriage()
            }
            .help(EditorText.backToTriage)

            Button(EditorText.redraft, systemImage: "wand.and.stars") {
                model.commitSessions()
                redraftKept = model.redraftPreview()
                showsRedraft = true
            }
            .help(EditorText.redraft)

            Menu(EditorText.formatMenu, systemImage: "rectangle.ratio.3.to.4") {
                ForEach(model.geometry.profile.formats, id: \.id) { format in
                    Button {
                        if format.id != model.store.album.formatID { formatCandidate = format }
                    } label: {
                        if format.id == model.store.album.formatID {
                            Label(format.name, systemImage: "checkmark")
                        } else {
                            Text(format.name)
                        }
                    }
                }
            }
            .help(EditorText.formatMenu)

            Button(EditorText.export, systemImage: "square.and.arrow.up") {
                model.commitSessions()
                exportAlbum?.run()
            }
            .disabled(exportAlbum == nil)
            .help(EditorText.export)
        }
    }

    // MARK: Actions

    /// "Zkusit jinak"; a manual page or a lost text asks first.
    private func tryAnother(confirmLayoutReplace: Bool = false, confirmTextLoss: Bool = false) {
        switch model.tryAnotherLayout(confirmLayoutReplace: confirmLayoutReplace, confirmTextLoss: confirmTextLoss) {
        case .applied, .unavailable:
            break
        case .needsLayoutReplaceConfirmation:
            asksTryAnotherReplace = true
        case .needsTextLossConfirmation(let texts):
            tryAnotherLoss = TryAnotherLoss(texts: texts, layoutConfirmed: confirmLayoutReplace)
        }
    }

    /// Confirmation only when the spread holds photos or text; an empty one goes at once (undoable).
    private func requestDelete(_ spreadID: String) {
        guard let spread = model.store.album.spreads.first(where: { $0.id == spreadID }) else { return }
        let hasContent = spread.frames.contains { $0.photoID != nil }
            || spread.texts.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if hasContent {
            deleteCandidate = spreadID
        } else {
            model.deleteSpread(spreadID)
        }
    }

    private func showInTray(_ photoID: PhotoID) {
        model.showInTray(photoID)
        trayHighlight = photoID
        Task {
            try? await Task.sleep(for: .seconds(2))
            if trayHighlight == photoID { trayHighlight = nil }
        }
    }
}
