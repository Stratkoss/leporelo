import Foundation

public enum AlbumEdit: Sendable, Codable, Equatable {
    /// A user (de)selection: sets `isSelected` and marks it `selectionDecidedByUser`.
    case setSelected(PhotoID, Bool)
    /// Stores both selection fields verbatim. Used as the exact-restore inverse of `setSelected`.
    case restorePhotoSelection(PhotoID, isSelected: Bool, decided: Bool)
    case setFramePhoto(spreadID: String, frameID: String, photoID: PhotoID?)
    case swapFramePhotos(spreadID: String, frameA: String, frameB: String)
    case setFrameTransform(spreadID: String, frameID: String, offset: Point, zoom: Double)
    case setText(spreadID: String, textID: String, text: String)
    /// Sets (or with nil clears) a text's own style; see `Album.sanitizedTextStyle`.
    case setTextStyle(spreadID: String, textID: String, style: TextStyle?)
    case moveSpread(from: Int, to: Int)
    case insertSpread(Spread, at: Int)
    case deleteSpread(id: String)
    /// Template change; marks the stored spread `manuallyEdited = true`.
    case replaceSpread(Spread)
    /// Stores the spread verbatim (flag included). Used as the exact-restore inverse of spread edits.
    case restoreSpread(Spread)
    case setPhotoDay(PhotoID, DayKey?)
    case setTitle(String)
}

public enum AlbumEditError: Error, Equatable {
    case unknownSpread, unknownFrame, unknownText, unknownPhoto, badIndex, duplicateSpread
}

extension Album {
    /// The largest frame zoom an edit stores.
    public static let maxFrameZoom = 100.0

    /// Zoom as stored: NaN or infinite -> 1 (JSON cannot encode them, every save would fail),
    /// then clamped to 1...`maxFrameZoom`.
    static func sanitizedZoom(_ zoom: Double) -> Double {
        zoom.isFinite ? min(maxFrameZoom, max(1, zoom)) : 1
    }

    /// A text style as stored: nil or a style equal to the default -> nil, size clamped to
    /// `TextStyle.sizeRangePt` (NaN or infinite -> nil, JSON cannot encode them), the default
    /// colour (`SpreadRenderer.defaultColorHex`, any letter case) -> nil.
    static func sanitizedTextStyle(_ style: TextStyle?) -> TextStyle? {
        guard var style else { return nil }
        if style.colorHex?.caseInsensitiveCompare(SpreadRenderer.defaultColorHex) == .orderedSame {
            style.colorHex = nil
        }
        if let size = style.sizePt {
            style.sizePt = size.isFinite
                ? min(TextStyle.sizeRangePt.upperBound, max(TextStyle.sizeRangePt.lowerBound, size)) : nil
        }
        return style == TextStyle() ? nil : style
    }

    /// Offset component as stored: NaN or infinite -> 0, then clamped to -1...1.
    static func sanitizedOffset(_ value: Double) -> Double {
        value.isFinite ? min(1, max(-1, value)) : 0
    }

    /// Applies `edit` and returns the new album plus the edit that undoes it exactly.
    ///
    /// Inverse strategy: every edit that touches the content of one spread (and sets
    /// `manuallyEdited = true` on it) is inverted by `restoreSpread(previousSpread)`, so the
    /// previous `manuallyEdited` flag comes back with it. Other edits invert structurally.
    public func applying(_ edit: AlbumEdit) throws -> (album: Album, inverse: AlbumEdit) {
        var album = self

        /// Mutates one spread, marks it edited, and returns the restoring inverse.
        func mutateSpread(_ id: String, _ body: (inout Spread) throws -> Void) throws -> AlbumEdit {
            guard let index = album.spreads.firstIndex(where: { $0.id == id }) else {
                throw AlbumEditError.unknownSpread
            }
            let previous = album.spreads[index]
            var spread = previous
            try body(&spread)
            spread.manuallyEdited = true
            album.spreads[index] = spread
            return .restoreSpread(previous)
        }

        func frameIndex(_ spread: Spread, _ id: String) throws -> Int {
            guard let i = spread.frames.firstIndex(where: { $0.id == id }) else {
                throw AlbumEditError.unknownFrame
            }
            return i
        }

        switch edit {
        case let .setSelected(id, selected):
            return try applying(.restorePhotoSelection(id, isSelected: selected, decided: true))

        case let .restorePhotoSelection(id, selected, decided):
            guard let photo = album.photos[id] else { throw AlbumEditError.unknownPhoto }
            album.photos[id]?.isSelected = selected
            album.photos[id]?.selectionDecidedByUser = decided
            return (album, .restorePhotoSelection(id, isSelected: photo.isSelected,
                                                  decided: photo.selectionDecidedByUser))

        case let .setFramePhoto(spreadID, frameID, photoID):
            if let photoID, album.photos[photoID] == nil { throw AlbumEditError.unknownPhoto }
            let inverse = try mutateSpread(spreadID) { spread in
                spread.frames[try frameIndex(spread, frameID)].photoID = photoID
            }
            return (album, inverse)

        case let .swapFramePhotos(spreadID, frameA, frameB):
            let inverse = try mutateSpread(spreadID) { spread in
                let a = try frameIndex(spread, frameA)
                let b = try frameIndex(spread, frameB)
                let photoA = spread.frames[a].photoID
                spread.frames[a].photoID = spread.frames[b].photoID
                spread.frames[b].photoID = photoA
            }
            return (album, inverse)

        case let .setFrameTransform(spreadID, frameID, offset, zoom):
            let inverse = try mutateSpread(spreadID) { spread in
                let i = try frameIndex(spread, frameID)
                spread.frames[i].zoom = Self.sanitizedZoom(zoom)
                spread.frames[i].offset = Point(x: Self.sanitizedOffset(offset.x),
                                                y: Self.sanitizedOffset(offset.y))
            }
            return (album, inverse)

        case let .setText(spreadID, textID, text):
            let inverse = try mutateSpread(spreadID) { spread in
                guard let i = spread.texts.firstIndex(where: { $0.id == textID }) else {
                    throw AlbumEditError.unknownText
                }
                spread.texts[i].text = text
            }
            return (album, inverse)

        case let .setTextStyle(spreadID, textID, style):
            let inverse = try mutateSpread(spreadID) { spread in
                guard let i = spread.texts.firstIndex(where: { $0.id == textID }) else {
                    throw AlbumEditError.unknownText
                }
                spread.texts[i].style = Self.sanitizedTextStyle(style)
            }
            return (album, inverse)

        case let .moveSpread(from, to):
            guard album.spreads.indices.contains(from), album.spreads.indices.contains(to) else {
                throw AlbumEditError.badIndex
            }
            let spread = album.spreads.remove(at: from)
            album.spreads.insert(spread, at: to)
            return (album, .moveSpread(from: to, to: from))

        case let .insertSpread(spread, at):
            guard (0...album.spreads.count).contains(at) else { throw AlbumEditError.badIndex }
            // A duplicate id would make the inverse deleteSpread remove the wrong spread.
            guard !album.spreads.contains(where: { $0.id == spread.id }) else {
                throw AlbumEditError.duplicateSpread
            }
            album.spreads.insert(spread, at: at)
            return (album, .deleteSpread(id: spread.id))

        case let .deleteSpread(id):
            guard let index = album.spreads.firstIndex(where: { $0.id == id }) else {
                throw AlbumEditError.unknownSpread
            }
            let removed = album.spreads.remove(at: index)
            return (album, .insertSpread(removed, at: index))

        case let .replaceSpread(spread):
            var marked = spread
            marked.manuallyEdited = true
            return try applying(.restoreSpread(marked))

        case let .restoreSpread(spread):
            guard let index = album.spreads.firstIndex(where: { $0.id == spread.id }) else {
                throw AlbumEditError.unknownSpread
            }
            let previous = album.spreads[index]
            album.spreads[index] = spread
            return (album, .restoreSpread(previous))

        case let .setPhotoDay(id, day):
            guard let photo = album.photos[id] else { throw AlbumEditError.unknownPhoto }
            album.photos[id]?.dayKey = day
            return (album, .setPhotoDay(id, photo.dayKey))

        case let .setTitle(title):
            let previous = album.title
            album.title = title
            return (album, .setTitle(previous))
        }
    }
}
