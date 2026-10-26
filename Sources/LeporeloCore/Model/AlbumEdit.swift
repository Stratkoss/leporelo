import Foundation

public enum AlbumEdit: Sendable, Codable, Equatable {
    case setSelected(PhotoID, Bool)
    case setFramePhoto(spreadID: String, frameID: String, photoID: PhotoID?)
    case swapFramePhotos(spreadID: String, frameA: String, frameB: String)
    case setFrameTransform(spreadID: String, frameID: String, offset: Point, zoom: Double)
    case setText(spreadID: String, textID: String, text: String)
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
            guard let photo = album.photos[id] else { throw AlbumEditError.unknownPhoto }
            album.photos[id]?.isSelected = selected
            return (album, .setSelected(id, photo.isSelected))

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
                spread.frames[i].zoom = max(1, zoom)
                spread.frames[i].offset = Point(x: min(1, max(-1, offset.x)),
                                                y: min(1, max(-1, offset.y)))
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
