import Foundation

public enum SourceSyncError: Error, Equatable, Sendable {
    /// The source returned no photo at all for an album that has photos. That almost always means
    /// lost or limited Photos access, or an album removed or renamed in Photos, not "every photo
    /// was deleted": the album is left unchanged instead of flagging everything.
    case emptyResult
}

/// "Načíst nové fotky" (spec section 5): the photo source is a snapshot taken when the project was
/// created; this re-runs the stored query on demand. There is no live library observation.
public enum SourceSync {
    /// Re-runs `album.source` and reconciles by `sourceIdentifier`:
    ///
    /// - new identifiers are added as `Photo(source:)`: fresh UUID id, unselected, original
    ///   `.missing`, `dayKey == nil`;
    /// - photos no longer returned get `deletedInSource = true`; everything else about them stays
    ///   (selection, placement in frames, the stored original), so the album keeps working;
    /// - videos are ignored both ways (not added; an old video is never flagged);
    /// - flagged photos that are returned again get the flag cleared.
    ///
    /// `added` counts new photos, `deleted` counts photos flagged by THIS refresh (not ones
    /// already flagged). Without a stored query the album is returned unchanged with (0, 0).
    /// Source errors propagate. An empty result for an album with photos throws
    /// `SourceSyncError.emptyResult` (Task 15 ruling); for an empty album it is (0, 0).
    ///
    /// Follow-up for the caller: run `GroupingService.assignDays` (it only fills photos whose
    /// `dayKey` is nil, i.e. the new ones), then analysis and originals download for the new ids.
    public static func refresh(album: Album, source: any PhotoSource) async throws
        -> (album: Album, added: Int, deleted: Int) {
        guard let query = album.source else { return (album, 0, 0) }
        // Videos are not part of the product: never added, and never flagged as deleted.
        let found = try await source.photos(matching: query).filter { $0.kind != .video }
        if found.isEmpty && album.photos.values.contains(where: { $0.kind != .video }) { throw SourceSyncError.emptyResult }
        let foundIdentifiers = Set(found.map(\.identifier))

        var result = album
        var deleted = 0
        var known: Set<String> = []
        for (id, photo) in album.photos {
            if photo.kind == .video { continue }
            known.insert(photo.sourceIdentifier)
            let present = foundIdentifiers.contains(photo.sourceIdentifier)
            if !present && !photo.deletedInSource {
                result.photos[id]?.deletedInSource = true
                deleted += 1
            } else if present && photo.deletedInSource {
                result.photos[id]?.deletedInSource = false
            }
        }

        var added = 0
        for sourcePhoto in found where !known.contains(sourcePhoto.identifier) {
            known.insert(sourcePhoto.identifier)   // a source listing an identifier twice adds it once
            let photo = Photo(source: sourcePhoto)
            result.photos[photo.id] = photo
            added += 1
        }
        return (result, added, deleted)
    }
}
