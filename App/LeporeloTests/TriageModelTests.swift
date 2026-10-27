import Foundation
import Testing
import LeporeloCore
@testable import Leporelo

private let june18 = DayKey(year: 2026, month: 6, day: 18)
private let june19 = DayKey(year: 2026, month: 6, day: 19)
/// 2026-06-18 10:00 UTC.
private let base = Date(timeIntervalSince1970: 1_781_776_800)

private func analysis(aesthetic: Double = 0.5, sharpness: Double = 400, utility: Bool = false,
                      closedEyes: Bool = false) -> PhotoAnalysis {
    PhotoAnalysis(aesthetic: aesthetic, sharpness: sharpness, isUtility: utility, faceRects: [],
                  closedEyes: closedEyes, featurePrint: nil)
}

private func photo(_ id: String, minute: Int, day: DayKey? = june18, aesthetic: Double = 0.5,
                   sharpness: Double = 400, selected: Bool = false, series: String? = nil,
                   kind: PhotoKind = .photo, place: String? = nil, utility: Bool = false,
                   closedEyes: Bool = false, state: OriginalState = .missing,
                   analysed: Bool = true) -> Photo {
    Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: base.addingTimeInterval(Double(minute) * 60),
          timeZoneSeconds: 0, location: nil, pixelWidth: 4000, pixelHeight: 3000, kind: kind,
          analysis: analysed ? analysis(aesthetic: aesthetic, sharpness: sharpness, utility: utility,
                                        closedEyes: closedEyes) : nil,
          isSelected: selected, dayKey: day, placeName: place, seriesID: series,
          originalState: state, deletedInSource: false)
}

private func album(_ photos: [Photo]) -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "album-1", title: "Amalfi",
          supplierProfileID: "canva-photobook", formatID: "landscape-8x6in", world: Workflow.world,
          cover: nil, spreads: [], photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
          source: nil, createdAt: Date(timeIntervalSince1970: 1_000))
}

@MainActor
private func makeModel(_ photos: [Photo], drafted: Bool = false) throws -> (TriageModel, AlbumStore, UndoManager) {
    var a = album(photos)
    if drafted { a = try draft(a) }
    let url = makeTempDir().appendingPathComponent("Triage.leporelo")
    let package = try ProjectPackage.create(at: url, album: a)
    let store = AlbumStore(album: a, package: package)
    let undo = UndoManager()
    undo.groupsByEvent = false
    let model = TriageModel(store: store)
    model.undoManager = undo
    return (model, store, undo)
}

private func days(of album: Album) -> [DayGroup] {
    DayGrouper.group(album.photos.values.filter { $0.dayKey != nil }, timeZones: [:], places: [:])
}

private func draft(_ album: Album) throws -> Album {
    let (profile, format) = try ProfileCatalog.format(profileID: album.supplierProfileID, formatID: album.formatID)
    return AlbumDrafter.draft(album: album, days: days(of: album), profile: profile, format: format)
}

/// Runs `body` inside an undo group (the manager does not group by event in tests).
@MainActor
private func grouped(_ undo: UndoManager, _ body: () -> Void) {
    undo.beginUndoGrouping()
    body()
    undo.endUndoGrouping()
}

@MainActor
struct TriageModelTests {
    // MARK: Series

    @Test func seriesCollapsedToHead() throws {
        let (model, _, _) = try makeModel([
            photo("a1", minute: 0, aesthetic: 0.4, series: "series-a1"),
            photo("a2", minute: 1, aesthetic: 0.9, series: "series-a1"),
            photo("a3", minute: 2, aesthetic: 0.6, series: "series-a1"),
            photo("b", minute: 30),
        ])
        let items = model.photos(for: june18)
        #expect(items.map(\.photo.id) == ["a2", "b"])
        #expect(items[0].isSeriesHead)
        #expect(items[0].seriesCount == 3)
        #expect(items[0].seriesChip == "×3")
        #expect(!items[1].isSeriesHead)
        #expect(items[1].seriesCount == 1)
        #expect(items[1].seriesChip == nil)
    }

    @Test func expandedSeriesShowsMembersAfterTheHead() throws {
        let (model, _, _) = try makeModel([
            photo("a1", minute: 0, aesthetic: 0.4, series: "series-a1"),
            photo("a2", minute: 1, aesthetic: 0.9, series: "series-a1"),
            photo("a3", minute: 2, aesthetic: 0.6, series: "series-a1"),
            photo("b", minute: 30),
        ])
        model.toggleSeries("series-a1")
        #expect(model.expandedSeries == ["series-a1"])
        let items = model.photos(for: june18)
        #expect(items.map(\.photo.id) == ["a2", "a1", "a3", "b"])
        #expect(items[0].isSeriesHead && items[0].isExpanded)
        #expect(items[1].badges.contains(.duplicate))
        #expect(items[2].badges.contains(.duplicate))
        #expect(!items[0].badges.contains(.duplicate))
        model.toggleSeries("series-a1")
        #expect(model.photos(for: june18).map(\.photo.id) == ["a2", "b"])
    }

    @Test func seriesHeadTiesBreakByTimeThenID() throws {
        let (model, _, _) = try makeModel([
            photo("x2", minute: 1, series: "s"),
            photo("x1", minute: 1, series: "s"),
            photo("x0", minute: 2, series: "s"),
        ])
        #expect(model.photos(for: june18).map(\.photo.id) == ["x1"])
    }

    @Test func collapsedSeriesShowsHowManyMembersAreSelected() throws {
        let (model, _, _) = try makeModel([
            photo("a1", minute: 0, aesthetic: 0.4, selected: true, series: "s"),
            photo("a2", minute: 1, aesthetic: 0.9, series: "s"),
            photo("a3", minute: 2, aesthetic: 0.6, selected: true, series: "s"),
            photo("a4", minute: 3, aesthetic: 0.1, series: "s"),
        ])
        let head = try #require(model.photos(for: june18).first)
        #expect(head.photo.id == "a2")
        #expect(head.seriesSelectedCount == 2)
        #expect(head.seriesChip == "2 z 4")
        #expect(head.accessibilityLabel.contains("série, 4 fotky, vybrané 2"))
    }

    // MARK: Selection

    @Test func toggleSelectionGoesThroughUndo() throws {
        let (model, store, undo) = try makeModel([photo("p1", minute: 0), photo("p2", minute: 10)])
        grouped(undo) { model.toggleSelection("p1") }
        #expect(store.album.photos["p1"]?.isSelected == true)
        #expect(store.album.photos["p1"]?.selectionDecidedByUser == true)
        #expect(undo.undoActionName == "Vybrat fotku")
        #expect(model.selectedCount(day: june18) == 1)

        undo.undo()
        #expect(store.album.photos["p1"]?.isSelected == false)
        #expect(store.album.photos["p1"]?.selectionDecidedByUser == false)
        #expect(model.selectedCount(day: june18) == 0)

        undo.redo()
        #expect(store.album.photos["p1"]?.isSelected == true)

        grouped(undo) { model.toggleSelection("p1") }
        #expect(store.album.photos["p1"]?.isSelected == false)
        #expect(undo.undoActionName == "Vyřadit fotku")
    }

    @Test func toggleWithSpreadsGoesThroughTheUpdater() throws {
        let photos = (0..<6).map { photo("p\($0)", minute: $0 * 10, selected: true) }
        let (model, store, undo) = try makeModel(photos, drafted: true)
        func placed(_ id: String) -> Bool {
            store.album.spreads.contains { $0.frames.contains { $0.photoID == id } }
        }
        let victim = try #require(store.album.spreads.flatMap(\.frames).compactMap(\.photoID).first)
        let before = store.album

        grouped(undo) { model.toggleSelection(victim) }
        #expect(store.album.photos[victim]?.isSelected == false)
        #expect(!placed(victim))
        #expect(undo.undoActionName == "Vyřadit fotku")

        undo.undo()
        #expect(store.album == before)

        undo.redo()
        #expect(!placed(victim))
        grouped(undo) { model.toggleSelection(victim) }
        #expect(placed(victim))
        #expect(undo.undoActionName == "Vybrat fotku")
    }

    @Test func videosAreNeverShownOrCounted() throws {
        var photos = (0..<6).map { photo("p\($0)", minute: $0 * 5, selected: $0 < 3) }
        photos += [photo("v1", minute: 1, selected: true, kind: .video), photo("v2", minute: 2, kind: .video),
                   photo("v3", minute: 3, day: nil, kind: .video)]
        let (model, store, undo) = try makeModel(photos)
        let clean = try makeModel(Array(photos.prefix(6))).0

        let items = model.photos(for: june18)
        #expect(items.map(\.photo.id) == (0..<6).map { "p\($0)" })
        #expect(!items.contains { $0.badges.contains(.video) })
        #expect(model.dayEntries.map(\.id) == [.day(june18)])   // the undated video makes no "Bez data"
        #expect(model.dayEntries.first?.total == 6)
        #expect(model.dayEntries.first?.selected == 3)
        #expect(model.selectedTotal == 3)
        #expect(model.footerText == clean.footerText)
        #expect(model.estimatedPages == clean.estimatedPages)
        model.showOnlyRecommended = true
        #expect(!model.photos(for: june18).contains { $0.photo.kind == .video })
        // The stored photos stay as they are, and a video cannot be selected.
        #expect(store.album.photos["v2"] != nil)
        model.toggleSelection("v2")
        #expect(store.album.photos["v2"]?.isSelected == false)
        #expect(!undo.canUndo)
    }

    // MARK: Badges

    @Test func badgesComeFromTheAnalysis() throws {
        let (model, _, _) = try makeModel([
            photo("blur", minute: 0, sharpness: 5),
            photo("eyes", minute: 10, closedEyes: true),
            photo("shot", minute: 20, utility: true),
            photo("cloudSelected", minute: 30, selected: true, state: .downloading),
            photo("cloudNot", minute: 40, state: .missing),
            photo("stored", minute: 50, selected: true, state: .stored(relativePath: "originals/x.jpg")),
            photo("unanalysed", minute: 60, analysed: false),
        ])
        let badges = Dictionary(uniqueKeysWithValues: model.photos(for: june18).map { ($0.photo.id, $0.badges) })
        #expect(badges["blur"] == [.blurred])
        #expect(badges["eyes"] == [.closedEyes])
        #expect(badges["shot"] == [.screenshot])
        #expect(badges["cloudSelected"] == [.cloud])
        #expect(badges["cloudNot"] == [])
        #expect(badges["stored"] == [])
        #expect(badges["unanalysed"] == [])
    }

    @Test func accessibilityLabelDescribesTheCell() throws {
        let (model, _, _) = try makeModel([photo("p", minute: 0, sharpness: 5, selected: true,
                                                 state: .stored(relativePath: "o"))])
        #expect(model.photos(for: june18).first?.accessibilityLabel == "Fotka, vybraná, rozmazaná")
    }

    // MARK: Recommended filter

    @Test func showOnlyRecommendedHidesTheRest() throws {
        // 10 eligible photos -> the recommender's target is 8; two blurred ones are never recommended.
        var photos = (0..<10).map { photo("p\($0)", minute: $0 * 10, aesthetic: Double($0) / 10) }
        photos.append(photo("blurred", minute: 200, sharpness: 2))
        photos.append(photo("blurredSelected", minute: 210, sharpness: 2, selected: true))
        let (model, store, _) = try makeModel(photos)
        #expect(model.photos(for: june18).count == 12)
        #expect(!model.showOnlyRecommended)

        model.showOnlyRecommended = true
        let visible = Set(model.photos(for: june18).map(\.photo.id))
        let day = try #require(days(of: store.album).first)
        let recommended = Recommender.recommend(day: day, series: [])
        #expect(recommended.count == 8)
        #expect(visible == recommended.union(["blurredSelected"]))
    }

    // MARK: Pages

    @Test func estimatedPagesMatchesDrafter() throws {
        let photos = (0..<40).map { i in
            photo("p\(i)", minute: i * 7, day: i < 25 ? june18 : june19, selected: i % 3 != 0)
        }
        let (model, store, undo) = try makeModel(photos)
        #expect(model.estimatedPages == AlbumDrafter.pageCount(of: try draft(store.album)))
        #expect(model.estimatedPages > 0)

        for i in 0..<10 { grouped(undo) { model.toggleSelection("p\(i * 3)") } }
        #expect(model.estimatedPages == AlbumDrafter.pageCount(of: try draft(store.album)))
    }

    @Test func footerUsesCzechPlurals() {
        #expect(TriageText.footer(selected: 148, pages: 36) == "Vybráno 148 fotek · odhad 36 stran")
        // Final fix wave C3: above the supplier's maximum the footer warns.
        #expect(TriageText.pageMaximumWarning(pages: 100, maximum: 98) == "Přesahuje maximum 98 stran")
        #expect(TriageText.pageMaximumWarning(pages: 98, maximum: 98) == nil)
        #expect(TriageText.pageMaximumWarning(pages: 400, maximum: nil) == nil)
        #expect(TriageText.pageMaximumWarning(pages: 2000, maximum: 1000) == "Přesahuje maximum 1\u{00A0}000 stran")
        #expect(TriageText.footer(selected: 1, pages: 4) == "Vybrána 1 fotka · odhad 4 strany")
        #expect(TriageText.footer(selected: 3, pages: 0) == "Vybrány 3 fotky · odhad 0 stran")
        #expect(TriageText.footer(selected: 3000, pages: 98) == "Vybráno 3\u{00A0}000 fotek · odhad 98 stran")
    }

    // MARK: Days

    @Test func dayLabelShowsDatePlacesAndCounts() {
        #expect(TriageText.dayLabel(june18, placeNames: ["Positano", "Ravello"], selected: 14, total: 212)
                == "čt 18. 6. · Positano, Ravello · 14/212")
        #expect(TriageText.dayLabel(june19, placeNames: [], selected: 0, total: 3)
                == "pá 19. 6. · bez místa · 0/3")
        #expect(TriageText.dayLabel(june18, placeNames: ["A", "B", "C", "D"], selected: 1, total: 2)
                == "čt 18. 6. · A, B, C… · 1/2")
    }

    @Test func dayEntriesFollowTheAlbum() throws {
        let (model, _, _) = try makeModel([
            photo("a", minute: 0, selected: true, place: "Positano"),
            photo("b", minute: 5, place: "Ravello"),
            photo("c", minute: 10, place: "Positano"),
            photo("d", minute: 0, day: june19),
            photo("x", minute: 0, day: nil),
        ])
        #expect(model.days.map(\.dayKey) == [june18, june19])
        #expect(model.dayEntries.map(\.label) == [
            "čt 18. 6. · Positano, Ravello · 1/3",
            "pá 19. 6. · bez místa · 0/1",
            "Bez data · 0/1",
        ])
        #expect(model.dayEntries.map(\.id) == [.day(june18), .day(june19), .undated])
        #expect(model.items(for: .undated).map(\.photo.id) == ["x"])
        // init does no grouping: no entry is chosen yet, the first one is shown.
        #expect(model.currentEntry == nil)
        #expect(model.visibleEntry == .day(june18))
        #expect(model.currentDay == june18)
        model.currentDay = june19
        #expect(model.currentEntry == .day(june19))
        #expect(model.currentDay == june19)
    }

    @Test func undatedPhotoCanBeMovedIntoADay() throws {
        let (model, store, undo) = try makeModel([photo("a", minute: 0), photo("x", minute: 3, day: nil)])
        model.currentEntry = .undated
        grouped(undo) { model.move("x", to: june18) }
        #expect(store.album.photos["x"]?.dayKey == june18)
        #expect(model.dayEntries.map(\.id) == [.day(june18)])
        #expect(model.photos(for: june18).map(\.photo.id) == ["a", "x"])
        // The current entry vanished: the model falls back to the first day.
        #expect(model.visibleEntry == .day(june18))
    }

    @Test func moveChangesDayAndRegroups() throws {
        let (model, store, undo) = try makeModel([
            photo("a", minute: 0), photo("b", minute: 10), photo("c", minute: 0, day: june19),
        ])
        grouped(undo) { model.move("b", to: june19) }
        #expect(store.album.photos["b"]?.dayKey == june19)
        #expect(model.photos(for: june18).map(\.photo.id) == ["a"])
        #expect(Set(model.photos(for: june19).map(\.photo.id)) == ["b", "c"])
        #expect(model.days.map { $0.photos.count } == [1, 2])
        #expect(undo.undoActionName == "Přesunout fotku do dne")

        undo.undo()
        #expect(model.photos(for: june18).map(\.photo.id) == ["a", "b"])
        #expect(model.photos(for: june19).map(\.photo.id) == ["c"])

        // Moving a photo onto its own day does nothing.
        model.move("a", to: june18)
        #expect(undo.redoActionName == "Přesunout fotku do dne")
    }

    @Test func movingTheLastPhotoRemovesTheDay() throws {
        let (model, _, undo) = try makeModel([photo("a", minute: 0), photo("c", minute: 0, day: june19)])
        grouped(undo) { model.move("a", to: june19) }
        #expect(model.days.map(\.dayKey) == [june19])
        #expect(model.photos(for: june18).isEmpty)
    }

    @Test func dragPayloadRoundTrips() {
        #expect(PhotoDrag.photoID(from: PhotoDrag.payload(for: "ABC-123")) == "ABC-123")
        #expect(PhotoDrag.photoID(from: "some dropped text") == nil)
        #expect(PhotoDrag.photoID(from: PhotoDrag.payload(for: "")) == nil)
    }

    @Test func thumbnailLoaderDecodesAtCellSizeAndCaches() async throws {
        let (_, store, _) = try makeModel([photo("p", minute: 0)])
        let loader = ThumbnailLoader()
        // No thumbnail yet: nothing, and nothing cached.
        #expect(await loader.load("p", maxPixel: 480, from: store.package) == nil)
        try store.package.storeThumbnail(FakePhotoSource.image(size: 1024, seed: 1), for: "p")
        let image = try #require(await loader.load("p", maxPixel: 480, from: store.package))
        #expect(max(image.width, image.height) == 480)
        #expect(loader.cached("p") != nil)
    }

    /// Aspect fill into the 160 pt square needs the SHORT side at 320 px on Retina.
    @Test func thumbnailDecodeSizeKeepsTheShortSideSharp() {
        #expect(ThumbnailLoader.maxPixel(width: 4000, height: 3000) == 427) // 4:3
        #expect(ThumbnailLoader.maxPixel(width: 3000, height: 2000) == 480) // 3:2
        #expect(ThumbnailLoader.maxPixel(width: 2000, height: 3000) == 480) // portrait
        #expect(ThumbnailLoader.maxPixel(width: 1000, height: 1000) == 320)
        #expect(ThumbnailLoader.maxPixel(width: 8000, height: 1000) == ProjectPackage.thumbnailMaxPixelSize)
        #expect(ThumbnailLoader.maxPixel(width: 0, height: 0) == 320) // unknown size
    }

    // MARK: Grid click decision

    @Test func clickTogglesOnlyAPlainClickOnOneSelectablePhoto() {
        let a = IndexPath(item: 0, section: 0), b = IndexPath(item: 1, section: 0)
        #expect(GridClick.shouldToggle(down: a, up: a, didStartDrag: false, isVideo: false))
        #expect(!GridClick.shouldToggle(down: a, up: a, didStartDrag: true, isVideo: false))
        #expect(!GridClick.shouldToggle(down: a, up: b, didStartDrag: false, isVideo: false))
        #expect(!GridClick.shouldToggle(down: a, up: nil, didStartDrag: false, isVideo: false))
        #expect(!GridClick.shouldToggle(down: nil, up: nil, didStartDrag: false, isVideo: false))
        #expect(!GridClick.shouldToggle(down: a, up: a, didStartDrag: false, isVideo: true))
    }

    @Test func modelInitDoesNotGroup() throws {
        let (_, store, _) = try makeModel([photo("a", minute: 0)])
        let model = TriageModel(store: store)
        #expect(!model.hasDerivedData)
        _ = model.days
        #expect(model.hasDerivedData)
    }

    // MARK: Performance sanity (generous bounds: catches accidental quadratic work only)

    @Test func modelQueriesStayFastOn3000Photos() throws {
        var photos: [Photo] = []
        for i in 0..<3000 {
            let day = DayKey(year: 2026, month: 6, day: 18 + i / 300)
            photos.append(photo(String(format: "p%04d", i), minute: (i % 300) * 2, day: day,
                                aesthetic: Double(i % 97) / 97, selected: i % 5 == 0,
                                series: i % 10 < 3 ? "s\(i / 10)" : nil, place: "Místo \(i / 300)"))
        }
        let (model, _, undo) = try makeModel(photos)
        let clock = ContinuousClock()

        let query = clock.measure {
            for entry in model.dayEntries { _ = model.items(for: entry.id) }
        }
        let pages = clock.measure { _ = model.estimatedPages }
        model.showOnlyRecommended = true
        let filtered = clock.measure { _ = model.photos(for: june18) }
        let toggle = clock.measure {
            grouped(undo) { model.toggleSelection("p0001") }
            _ = model.photos(for: june18)
            _ = model.estimatedPages
        }
        print("3000 photos: all days \(query), pages \(pages), filtered day \(filtered), toggle \(toggle)")
        #expect(query < .seconds(2))
        #expect(pages < .seconds(5))
        #expect(filtered < .seconds(1))
        #expect(toggle < .seconds(5))
        #expect(model.estimatedPages > 0)
    }

    // MARK: Task 21a: moves of placed photos, actual page count

    @Test func movingAPlacedPhotoMovesItIntoTheNewDaysLayout() throws {
        let photos = (0..<8).map { photo("a\($0)", minute: $0 * 10, selected: true) }
            + (0..<4).map { photo("b\($0)", minute: $0 * 10, day: june19, selected: true) }
        let (model, store, undo) = try makeModel(photos, drafted: true)
        let gallery = try #require(store.album.spreads.first { $0.kind == .gallery && $0.dayKey == june18 && !$0.manuallyEdited })
        let id = try #require(gallery.frames.compactMap(\.photoID).first)
        let before = store.album

        grouped(undo) { model.move(id, to: june19) }
        #expect(store.album.photos[id]?.dayKey == june19)
        let holders = store.album.spreads.filter { ($0.kind == .gallery || $0.kind == .journal) && $0.frames.contains { $0.photoID == id } }
        #expect(holders.map(\.dayKey) == [june19])
        #expect(undo.undoActionName == "Přesunout fotku do dne")

        undo.undo()
        #expect(store.album == before)
    }

    @Test func movingAPhotoOfAManualSpreadLeavesTheLayout() throws {
        let photos = (0..<8).map { photo("a\($0)", minute: $0 * 10, selected: true) }
            + (0..<4).map { photo("b\($0)", minute: $0 * 10, day: june19, selected: true) }
        var a = try draft(album(photos))
        let index = try #require(a.spreads.firstIndex { $0.kind == .gallery && $0.dayKey == june18 })
        a.spreads[index].manuallyEdited = true
        let id = try #require(a.spreads[index].frames.compactMap(\.photoID).first)
        let url = makeTempDir().appendingPathComponent("Manual.leporelo")
        let store = AlbumStore(album: a, package: try ProjectPackage.create(at: url, album: a))
        let model = TriageModel(store: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        grouped(undo) { model.move(id, to: june19) }
        var expected = a
        expected.photos[id]?.dayKey = june19
        #expect(store.album == expected)  // only the day changed; the editor shows it where it is
        #expect(undo.undoActionName == "Přesunout fotku do dne")
    }

    /// Spec 6: the liked layouts also count when triage lays a day out again (selecting a photo,
    /// moving a placed one): the model reads `layoutWeights` and passes them to the updater.
    @Test func selectingAndMovingUseTheLikedLayouts() throws {
        // Every third photo portrait: the liked layouts change how such a day is laid out.
        func mixed(_ p: Photo, _ i: Int) -> Photo {
            var p = p
            if i % 3 == 2 { (p.pixelWidth, p.pixelHeight) = (3000, 4000) }
            return p
        }
        let photos = (0..<8).map { mixed(photo("a\($0)", minute: $0 * 10, selected: true), $0) }
            + [mixed(photo("new", minute: 85), 2)]
            + (0..<6).map { mixed(photo("b\($0)", minute: $0 * 10, day: june19, selected: true), $0) }
        let (model, store, undo) = try makeModel(photos, drafted: true)
        let (profile, format) = try ProfileCatalog.format(profileID: store.album.supplierProfileID,
                                                          formatID: store.album.formatID)
        let geometry = PageGeometry(format: format, profile: profile)
        let liked = LayoutWeights(liked: ["portraits-2", "portrait-right-2l", "grid-4"])
        var reads = 0
        model.layoutWeights = {
            reads += 1
            return liked
        }

        let before = store.album
        let withLiked = AlbumUpdater.photoSelected("new", in: before, geometry: geometry, weights: liked)
        // The liked layouts make a difference here, so the check below tells them apart.
        #expect(withLiked != AlbumUpdater.photoSelected("new", in: before, geometry: geometry))
        grouped(undo) { model.toggleSelection("new") }
        #expect(reads == 1)
        #expect(store.album == withLiked)

        // A placed photo of June 18 whose move the liked layouts lay out differently on June 19.
        let selected = store.album
        let placed = selected.spreads.filter { $0.kind == .gallery && $0.dayKey == june18 && !$0.manuallyEdited }
            .flatMap { $0.frames.compactMap(\.photoID) }
        let id = try #require(placed.first { id in
            AlbumUpdater.photoMoved(id, to: june19, in: selected, geometry: geometry, weights: liked)
                != AlbumUpdater.photoMoved(id, to: june19, in: selected, geometry: geometry)
        })
        let moved = AlbumUpdater.photoMoved(id, to: june19, in: selected, geometry: geometry, weights: liked)
        grouped(undo) { model.move(id, to: june19) }
        #expect(reads == 2)
        #expect(store.album == moved)
    }

    @Test func footerShowsActualPagesOnceThereAreSpreads() throws {
        let photos = (0..<10).map { photo("p\($0)", minute: $0 * 10, selected: true) }
        let (estimate, _, _) = try makeModel(photos)
        #expect(estimate.pageCount == estimate.estimatedPages)
        #expect(estimate.pagesAreEstimated)
        #expect(estimate.footerText == TriageText.footer(selected: 10, pages: estimate.estimatedPages))

        let (model, store, _) = try makeModel(photos, drafted: true)
        #expect(!model.pagesAreEstimated)
        #expect(model.pageCount == store.album.spreads.count * 2)
        #expect(model.footerText == "Vybráno 10 fotek · \(store.album.spreads.count * 2) stran")
        #expect(TriageText.footer(selected: 1, pages: 36, estimated: false) == "Vybrána 1 fotka · 36 stran")
    }
}
