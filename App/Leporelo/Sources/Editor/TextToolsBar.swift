import AppKit
import LeporeloCore
import SwiftUI

/// The text bar above the canvas (spec 3.2): shown while a text is selected or edited
/// (`EditorModel.activeTextStyle`), from the left: "Písmo", "Velikost" (field in pt, stepper,
/// size menu), "Tučně" and "Kurzíva" (⌘B, ⌘I; disabled when the family has no such face),
/// "Zarovnání", "Barva textu" (swatches and "Jiná…"), "Výchozí". Every change is one undo step
/// through `changeTextStyle`/`resetTextStyle`.
///
/// Decision: the editor keeps the bar's height reserved on a spread even when no text is active,
/// so selecting a text never moves the canvas (a moved canvas would shift a running drag and the
/// second click of a double-click). Without an active text the bar says where the text tools
/// are („Písmo a velikost: klikni na text“), so it can be found.
struct TextToolsBar: View {
    let model: EditorModel

    private typealias Alignment = LeporeloCore.TextAlignment

    static let height: CGFloat = 36
    /// "Jiná…" applies its colour after the colour panel rests this long: dragging in the panel
    /// is one undo step, not one per mouse move.
    static let colourDelay: Duration = .milliseconds(400)

    /// The colour panel's latest pick while it waits for `colourDelay`.
    @State private var pendingColour: (textID: String, hex: String)?
    @State private var colourCommit: Task<Void, Never>?

    var body: some View {
        Group {
            if let style = model.activeTextStyle {
                ScrollView(.horizontal, showsIndicators: false) {
                    controls(style)
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                }
                .background(.bar)
            } else {
                HStack {
                    Label(EditorText.textBarHint, systemImage: "textformat")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(.bar)
            }
        }
        .frame(height: Self.height)
    }

    private var storedStyle: TextStyle? {
        guard let id = model.activeTextID else { return nil }
        return model.currentSpread?.texts.first { $0.id == id }?.style
    }

    @ViewBuilder private func controls(_ style: ResolvedTextStyle) -> some View {
        let traits = Self.traits(style.family)
        HStack(spacing: 12) {
            FontFamilyPicker(family: style.family,
                             missingFamily: style.isFallback ? storedStyle?.fontFamily : nil) { family in
                // A face the new family lacks would stay stored but hidden and resurface later.
                let available = Self.traits(family)
                model.changeTextStyle {
                    $0.fontFamily = family
                    if !available.bold { $0.bold = false }
                    if !available.italic { $0.italic = false }
                }
            }

            sizeControls(style)

            HStack(spacing: 2) {
                Toggle(isOn: Binding(get: { style.bold && traits.bold },
                                     set: { on in model.changeTextStyle { $0.bold = on } })) {
                    Label(EditorText.bold, systemImage: "bold")
                }
                .keyboardShortcut("b")
                .disabled(!traits.bold)
                .help(EditorText.bold)

                Toggle(isOn: Binding(get: { style.italic && traits.italic },
                                     set: { on in model.changeTextStyle { $0.italic = on } })) {
                    Label(EditorText.italic, systemImage: "italic")
                }
                .keyboardShortcut("i")
                .disabled(!traits.italic)
                .help(EditorText.italic)
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)

            Picker(EditorText.alignment, selection: Binding(get: { style.alignment },
                                                            set: { a in model.changeTextStyle { $0.alignment = a } })) {
                Label(EditorText.alignLeft, systemImage: "text.alignleft").tag(Alignment.left)
                Label(EditorText.alignCenter, systemImage: "text.aligncenter").tag(Alignment.center)
                Label(EditorText.alignRight, systemImage: "text.alignright").tag(Alignment.right)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help(EditorText.alignment)

            colourControls(style)

            Button(EditorText.resetStyle) { model.resetTextStyle() }
                .disabled(storedStyle == nil)
                .help(EditorText.resetStyle)
        }
    }

    // MARK: Size

    @ViewBuilder private func sizeControls(_ style: ResolvedTextStyle) -> some View {
        HStack(spacing: 4) {
            TextField(EditorText.fontSize,
                      value: Binding(get: { style.sizePt }, set: { setSize($0, current: style.sizePt) }),
                      format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .labelsHidden()
                .help(EditorText.fontSize)
            Text("pt")
                .foregroundStyle(.secondary)
            Stepper(EditorText.fontSize) {
                setSize(TextBarPresets.steppedSize(style.sizePt, up: true), current: style.sizePt)
            } onDecrement: {
                setSize(TextBarPresets.steppedSize(style.sizePt, up: false), current: style.sizePt)
            }
            .labelsHidden()
            .help(EditorText.fontSize)
            Menu {
                ForEach(TextBarPresets.sizesPt, id: \.self) { size in
                    Button("\(Int(size)) pt") { setSize(size, current: style.sizePt) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(EditorText.fontSize)
            .accessibilityLabel(EditorText.fontSize)
        }
    }

    /// Stores a size, clamped; nothing when it equals the shown size (leaving the field reparses
    /// its one-decimal text, which must not make a step).
    private func setSize(_ pt: Double, current: Double) {
        guard let size = TextBarPresets.clampedSize(pt), abs(size - current) >= 0.05 else { return }
        model.changeTextStyle { $0.sizePt = size }
    }

    // MARK: Colour

    @ViewBuilder private func colourControls(_ style: ResolvedTextStyle) -> some View {
        let current = style.colorHex.uppercased()
        HStack(spacing: 6) {
            ForEach(TextBarPresets.colours, id: \.hex) { colour in
                Button {
                    model.changeTextStyle { $0.colorHex = colour.hex }
                } label: {
                    Circle()
                        .fill(Color(cgColor: SpreadRenderer.color(hex: colour.hex)))
                        .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay(Circle().strokeBorder(current == colour.hex ? Color.accentColor : .clear,
                                                       lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help("\(EditorText.textColour): \(colour.name)")
                .accessibilityLabel("\(EditorText.textColour): \(colour.name)")
                .accessibilityAddTraits(current == colour.hex ? .isSelected : [])
            }
            ColorPicker(EditorText.otherColour, selection: colourBinding(style), supportsOpacity: false)
                .labelsHidden()
                .help("\(EditorText.textColour): \(EditorText.otherColour)")
        }
    }

    /// The colour panel's binding: shows the waiting pick (so the panel is not reset while it is
    /// dragged), stores it once the panel rests (`colourDelay`) and only on the text it was picked for.
    private func colourBinding(_ style: ResolvedTextStyle) -> Binding<Color> {
        Binding {
            let hex = pendingColour?.textID == model.activeTextID ? pendingColour?.hex : nil
            return Color(cgColor: SpreadRenderer.color(hex: hex ?? style.colorHex))
        } set: { colour in
            guard let textID = model.activeTextID, let hex = TextColour.hex(NSColor(colour)) else { return }
            pendingColour = (textID, hex)
            colourCommit?.cancel()
            colourCommit = Task { @MainActor in
                try? await Task.sleep(for: Self.colourDelay)
                guard !Task.isCancelled, let pending = pendingColour else { return }
                pendingColour = nil
                if model.activeTextID == pending.textID { model.changeTextStyle { $0.colorHex = pending.hex } }
            }
        }
    }

    // MARK: Faces

    /// `FontRegistry.availableTraits` per family (the bar redraws on every edit, e.g. each drag
    /// step; the faces of a family do not change while the app runs).
    @MainActor private static var traitsCache: [String: (bold: Bool, italic: Bool)] = [:]

    @MainActor private static func traits(_ family: String) -> (bold: Bool, italic: Bool) {
        if let cached = traitsCache[family] { return cached }
        let traits = FontRegistry.availableTraits(family: family)
        traitsCache[family] = traits
        return traits
    }
}
