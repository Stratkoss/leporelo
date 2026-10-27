import Foundation
import LeporeloCore
import SwiftUI

/// What a refresh changed (for the alert).
struct RefreshReport: Equatable, Sendable {
    var added: Int
    var deleted: Int
}

/// File > "Načíst nové fotky ze zdroje" (spec section 5: the source is a snapshot, refreshed only
/// on demand).
///
/// 1. `SourceSync.refresh` on a snapshot of the store's album, off the main actor (an empty answer
///    for an album with photos throws `SourceSyncError.emptyResult`: nothing is flagged).
/// 2. Days for the NEW photos right away: `GroupingService.assignDays` with an EMPTY resolver
///    (fast; it only fills photos without a day) on the album as it is now plus the new photos.
///    Place names (and day corrections from them) follow later through the background work.
/// 3. ONE synchronous no-undo mutation on the CURRENT album (edits made while the source was read
///    survive): the new photos are added (with their days; a photo whose source identifier is in
///    the album by now is skipped) and the deleted flags of photos still in the album are set as
///    the refresh found them. Photos gone from Photos keep everything else: selection, frames,
///    the stored original.
enum SourceRefresh {
    @MainActor
    static func run(store: AlbumStore, source: any PhotoSource) async throws -> RefreshReport {
        let snapshot = store.album
        let result = try await refresh(snapshot, source: source)
        let added = result.album.photos.values.filter { snapshot.photos[$0.id] == nil }
        let days = await days(of: added, in: store.album)

        var updated = store.album
        var deleted = 0
        for (id, refreshed) in result.album.photos where snapshot.photos[id] != nil {
            guard let current = updated.photos[id], current.deletedInSource != refreshed.deletedInSource else { continue }
            updated.photos[id]?.deletedInSource = refreshed.deletedInSource
            if refreshed.deletedInSource { deleted += 1 }
        }
        var known = Set(updated.photos.values.map(\.sourceIdentifier))
        var inserted = 0
        for var photo in added.sorted(by: Photo.chronological) where !known.contains(photo.sourceIdentifier) {
            known.insert(photo.sourceIdentifier)
            photo.dayKey = days[photo.id] ?? photo.dayKey
            updated.photos[photo.id] = photo
            inserted += 1
        }
        if updated != store.album { store.replaceWithoutUndo(album: updated) }
        return RefreshReport(added: inserted, deleted: deleted)
    }

    @concurrent
    private nonisolated static func refresh(_ album: Album, source: any PhotoSource) async throws
        -> (album: Album, added: Int, deleted: Int) {
        try await SourceSync.refresh(album: album, source: source)
    }

    /// Day keys for `added` computed among the photos of `current` (zones are inferred from the
    /// neighbours), with no geocoding.
    @concurrent
    private nonisolated static func days(of added: [Photo], in current: Album) async -> [PhotoID: DayKey] {
        guard !added.isEmpty else { return [:] }
        var album = current
        for photo in added { album.photos[photo.id] = photo }
        await GroupingService.assignDays(to: &album, resolver: InMemoryPlaceResolver([]))
        var result: [PhotoID: DayKey] = [:]
        for photo in added { if let day = album.photos[photo.id]?.dayKey { result[photo.id] = day } }
        return result
    }
}

/// The refresh alert (Czech, sentence case).
enum RefreshText {
    static let command = "Načíst nové fotky ze zdroje"

    /// "Přidány 2 nové fotky, 1 fotka už v Photos není." / "Žádné změny."
    static func summary(_ report: RefreshReport) -> String {
        if report.added == 0 && report.deleted == 0 { return "Žádné změny." }
        let n = CzechPlural.grouped(report.added)
        let addedText = CzechPlural.choose(report.added, one: "Přidána \(n) nová fotka",
                                           few: "Přidány \(n) nové fotky", many: "Přidáno \(n) nových fotek")
        let deletedText = CzechPlural.choose(report.deleted, one: "už v Photos není", few: "už v Photos nejsou",
                                             many: "už v Photos není")
        return "\(addedText), \(CzechPlural.photos(report.deleted)) \(deletedText)."
    }

    struct Alert: Equatable, Identifiable {
        var title: String
        var message: String
        var id: String { title + message }
    }

    static func success(_ report: RefreshReport) -> Alert {
        Alert(title: "Fotky ze zdroje jsou načtené", message: summary(report))
    }

    static func failure(_ error: any Error) -> Alert {
        switch error {
        case SourceSyncError.emptyResult:
            Alert(title: "Zdroj nevrátil žádné fotky. Fotky v albu zůstávají beze změny.",
                  message: "Zkontrolujte, že má Leporelo úplný přístup k Fotkám a že album ve Fotkách pořád existuje.")
        case PhotoSourceError.notAuthorized:
            Alert(title: BannerText.sourceUnavailable,
                  message: "Povolte Leporelu úplný přístup v Nastavení systému v části Soukromí a zabezpečení › Fotky.")
        default:
            Alert(title: "Fotky ze zdroje nejde načíst", message: error.localizedDescription)
        }
    }
}

/// File > "Načíst nové fotky ze zdroje" of the front album window (nil: no source query, no
/// source, or a refresh is running).
struct RefreshSourceAction {
    let run: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var albumRefresh: RefreshSourceAction? = nil
}
