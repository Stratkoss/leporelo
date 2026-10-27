import Foundation
import Photos
import Testing
import LeporeloCore
@testable import Leporelo

private func profiles() throws -> [SupplierProfile] { try ProfileCatalog.all() }

private var prague: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
    return calendar
}

@MainActor
struct NewAlbumModelTests {
    @Test func lowResolutionWarningTriggersAbove50Percent() throws {
        let model = NewAlbumModel(source: FakePhotoSource(), profiles: try profiles())
        let big = SourcePhoto.fake("big", width: 4032, height: 3024)
        let small = SourcePhoto.fake("small", width: 2048, height: 1536)
        let smallPortrait = SourcePhoto.fake("portrait", width: 1536, height: 2048)

        #expect(model.lowResolutionWarning(for: []) == nil)
        #expect(model.lowResolutionWarning(for: [big, small]) == nil)  // exactly 50 %: no warning
        let warning = model.lowResolutionWarning(for: [big, small, smallPortrait])
        #expect(warning == NewAlbumModel.lowResolutionMessage)
        #expect(warning?.hasPrefix("Fotky z tohoto zdroje jsou zmenšené") == true)
        // 2049 px is not reduced; videos (1920 px) do not count at all.
        let justAbove = SourcePhoto.fake("above", width: 2049, height: 1000)
        let video = SourcePhoto.fake("video", kind: .video, width: 1920, height: 1080)
        #expect(model.lowResolutionWarning(for: [justAbove, video, video, small]) == nil)
    }

    @Test func createAlbumAssignsDays() async throws {
        let source = FakePhotoSource(photos: [
            .fake("a", minutes: 60), .fake("b", minutes: 120), .fake("c", minutes: 24 * 60 + 60),
        ])
        let model = NewAlbumModel(source: source, profiles: try profiles())
        model.title = "Léto"
        let url = makeTempDir().appendingPathComponent("Léto.leporelo")

        let (package, album) = try await model.createAlbum(packageURL: url)

        #expect(package.url == url)
        #expect(album.title == "Léto")
        #expect(album.supplierProfileID == "canva-photobook")
        #expect(album.formatID == "landscape-8x6in")
        #expect(album.photos.count == 3)
        #expect(album.source == model.query)
        #expect(source.queries == [try #require(model.query)])
        let days = album.photos.values.reduce(into: [String: DayKey]()) { $0[$1.sourceIdentifier] = $1.dayKey }
        #expect(days["a"] == DayKey(year: 2026, month: 7, day: 1))
        #expect(days["b"] == DayKey(year: 2026, month: 7, day: 1))
        #expect(days["c"] == DayKey(year: 2026, month: 7, day: 2))
        #expect(album.photos.values.allSatisfy { $0.analysis == nil && !$0.isSelected && $0.placeName == nil })
        // The first state is saved before the album opens.
        #expect(try ProjectPackage.open(url).1 == album)
    }

    @Test func createAlbumFromAnEmptySourceFailsAndRemovesThePackage() async throws {
        let model = NewAlbumModel(source: FakePhotoSource(), profiles: try profiles())
        let url = makeTempDir().appendingPathComponent("Prázdné.leporelo")
        await #expect(throws: NewAlbumError.noPhotosInRange) {
            _ = try await model.createAlbum(packageURL: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(NewAlbumError.noPhotosInRange.localizedDescription == "V tomto rozmezí nejsou žádné fotky")
    }

    @Test func createAlbumFailureRemovesOnlyThePackageItCreated() async throws {
        let source = FakePhotoSource(photos: [.fake("a")])
        source.setPhotosError(.notAuthorized)
        let model = NewAlbumModel(source: source, profiles: try profiles())
        let url = makeTempDir().appendingPathComponent("Chyba.leporelo")
        await #expect(throws: PhotoSourceError.notAuthorized) {
            _ = try await model.createAlbum(packageURL: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // An existing package is never replaced or deleted.
        let existing = makeTempDir().appendingPathComponent("Staré.leporelo")
        let old = makeTestAlbum(title: "Staré")
        _ = try ProjectPackage.create(at: existing, album: old)
        source.setPhotosError(nil)
        await #expect(throws: ProjectError.alreadyExists) {
            _ = try await model.createAlbum(packageURL: existing)
        }
        #expect(try ProjectPackage.open(existing).1 == old)
        #expect(NewAlbumModel.errorMessage(for: PhotoSourceError.notAuthorized).contains("přístup k Fotkám"))
        #expect(NewAlbumModel.errorMessage(for: ProjectError.alreadyExists) == "Album s tímto názvem už existuje.")
    }

    @Test func defaultsAreTheLastSevenDaysAndTheFirstProfile() throws {
        // 2026-10-27 15:30 in Prague.
        let now = Date(timeIntervalSince1970: 1_793_111_400)
        let model = NewAlbumModel(source: FakePhotoSource(), profiles: try profiles(), now: now, calendar: prague)
        #expect(model.title == "Nové album")
        #expect(model.profileID == "canva-photobook")
        #expect(model.formatID == "landscape-8x6in")
        #expect(model.formats.map(\.name).contains("Čtverec 210 × 210 mm (záloha, neověřeno u Canvy)"))
        #expect(model.queryMode == .dateRange)
        #expect(model.end == now)
        let start = try #require(prague.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let afterEnd = try #require(prague.date(from: DateComponents(year: 2026, month: 10, day: 28)))
        #expect(model.start == start)
        // The range covers whole days: from the start day's midnight to the midnight after `end`.
        #expect(model.query == .dateRange(start: start, end: afterEnd))
        #expect(model.unverifiedFormatNote == "Rozměry formátu nejsou ověřené u dodavatele.")

        model.formatID = "square-21"
        #expect(model.format?.id == "square-21")
    }

    @Test func albumModeNeedsASelectedAlbumAndWarnsForSharedOnes() async throws {
        let shared = SourceAlbum(identifier: "s1", name: "Rodina", count: 40, isShared: true)
        let own = SourceAlbum(identifier: "a1", name: "Itálie", count: 120, isShared: false)
        let source = FakePhotoSource(photos: [.fake("a")], albums: [own, shared])
        let model = NewAlbumModel(source: source, profiles: try profiles())
        await model.loadAlbums()
        #expect(model.albums == [own, shared])

        model.queryMode = .album
        #expect(model.query == nil)
        #expect(!model.canCreate)
        model.selectedAlbum = shared
        #expect(model.query == .album(identifier: "s1", name: "Rodina"))
        #expect(model.sharedAlbumWarning?.hasPrefix("Sdílené album iCloudu zmenšuje fotky na zhruba 2") == true)
        await model.refreshPreview()
        #expect(model.photoCount == 1)
        #expect(model.canCreate)  // a shared album can still be used
        model.selectedAlbum = own
        #expect(model.sharedAlbumWarning == nil)
    }

    @Test func previewCountsPhotosWarnsAndBlocksAnEmptySource() async throws {
        let source = FakePhotoSource(photos: [])
        let model = NewAlbumModel(source: source, profiles: try profiles())
        await model.refreshPreview()
        #expect(model.photoCount == 0)
        #expect(model.emptySourceMessage == "V tomto rozmezí nejsou žádné fotky")
        #expect(!model.canCreate)

        source.setPhotos([.fake("a", width: 1024, height: 768), .fake("b", width: 2048, height: 1365)])
        await model.refreshPreview()
        #expect(model.photoCount == 2)
        #expect(model.emptySourceMessage == nil)
        #expect(model.warning == NewAlbumModel.lowResolutionMessage)
        #expect(model.canCreate)
        #expect(model.photoCountText == "Fotek ve zdroji: 2")

        model.title = "   "
        #expect(!model.canCreate)
    }

    @Test func packageNameComesFromTheTitle() {
        #expect(NewAlbumModel.packageFileName(for: "Léto 2026") == "Léto 2026.leporelo")
        #expect(NewAlbumModel.packageFileName(for: "  Řím/Neapol: den 1 ") == "Řím-Neapol- den 1.leporelo")
        #expect(NewAlbumModel.packageFileName(for: "   ") == "Nové album.leporelo")
        #expect(NewAlbumModel.packageFileName(for: ".skryté") == "skryté.leporelo")
    }

    @Test func photoAccessExplainsEveryStatus() {
        #expect(PhotoAccess(.authorized) == .authorized)
        #expect(PhotoAccess(.authorized).allowsForm)
        for status: PHAuthorizationStatus in [.notDetermined, .denied, .restricted, .limited] {
            #expect(!PhotoAccess(status).allowsForm)
        }
        #expect(PhotoAccess(.notDetermined).actionTitle == "Povolit přístup k Fotkám")
        #expect(PhotoAccess(.denied).actionTitle == "Otevřít Nastavení systému")
        #expect(PhotoAccess(.restricted) == .denied)
        #expect(PhotoAccess(.limited).explanation.contains("úplný přístup"))
        #expect(PhotoAccess.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
    }
}
