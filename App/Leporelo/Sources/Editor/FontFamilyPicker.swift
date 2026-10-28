import CoreText
import LeporeloCore
import SwiftUI

/// "Písmo" in the text bar (spec 3.2): a button with the text's family that opens a popover with a
/// search field and the families, the two book fonts first, a divider, then every family of this
/// Mac A–Z (`FontRegistry.allFamilies`), each name drawn in its own font.
///
/// Decision: a popover with a `List` instead of a menu: a menu of ~600 families can neither be
/// searched nor drawn lazily. Return in the search field picks the first match.
struct FontFamilyPicker: View {
    /// The family the text is drawn with.
    let family: String
    /// The stored family when this Mac does not have it (the text falls back to its role's font).
    let missingFamily: String?
    let onPick: (String) -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 4) {
                if let missingFamily {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(EditorText.missingFont(missingFamily))
                }
                Text(missingFamily ?? family)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
        }
        .help(EditorText.fontFamily)
        .accessibilityLabel("\(EditorText.fontFamily): \(missingFamily ?? family)")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FontFamilyList(current: missingFamily ?? family) { picked in
                isOpen = false
                onPick(picked)
            }
        }
    }
}

/// The popover's content: the search field and the lazily drawn families.
private struct FontFamilyList: View {
    let current: String
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var families: [String] = []
    @FocusState private var searchFocused: Bool

    private static let bookFamilies = [FontRegistry.titleFont, FontRegistry.textFont]

    var body: some View {
        let book = Self.bookFamilies.filter { FontFamilyFilter.matches($0, query: query) }
        let rest = families.filter { !Self.bookFamilies.contains($0) && FontFamilyFilter.matches($0, query: query) }
        VStack(spacing: 0) {
            TextField(EditorText.searchFont, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = book.first ?? rest.first { onPick(first) } }
                .padding(8)
            Divider()
            if book.isEmpty && rest.isEmpty {
                Text(EditorText.noFontFound)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(book, id: \.self, content: row)
                    if !book.isEmpty && !rest.isEmpty { Divider() }
                    ForEach(rest, id: \.self, content: row)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 280, height: 360)
        .onAppear {
            families = FontRegistry.allFamilies()
            searchFocused = true
        }
    }

    private func row(_ family: String) -> some View {
        Button {
            onPick(family)
        } label: {
            HStack {
                Text(family)
                    .font(Self.font(family))
                    .lineLimit(1)
                Spacer()
                if family == current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(family)
    }

    /// The family's regular face at 14 pt, matched by family name like the renderer does
    /// (`Font.custom` wants a face name, which a family name is not always).
    private static func font(_ family: String) -> Font {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, 14, nil))
    }
}
