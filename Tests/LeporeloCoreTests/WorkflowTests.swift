import Foundation
import Testing
@testable import LeporeloCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("leporelo-workflow-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sourcePhoto(_ id: String, _ t: TimeInterval, zone: Int? = 7200) -> SourcePhoto {
    SourcePhoto(identifier: id, capturedAt: Date(timeIntervalSince1970: t), timeZoneSeconds: zone,
                location: nil, pixelWidth: 4000, pixelHeight: 3000, kind: .photo, isCloudOnly: false)
}

private func photo(_ id: String, _ t: TimeInterval, day: Int?, selected: Bool = false,
                   decided: Bool = false, place: String? = nil) -> Photo {
    Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: t),
          timeZoneSeconds: 7200, location: nil, pixelWidth: 4000, pixelHeight: 3000, kind: .photo,
          analysis: nil, isSelected: selected, selectionDecidedByUser: decided,
          dayKey: day.map { DayKey(year: 2026, month: 7, day: $0) },
          placeName: place, seriesID: nil, originalState: .missing, deletedInSource: false)
}

private func album(_ photos: [Photo]) -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "a", title: "Léto",
          supplierProfileID: "canva-photobook", formatID: "landscape-8x6in", world: Workflow.world,
          cover: nil, spreads: [], photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
          source: nil, createdAt: Date(timeIntervalSince1970: 0))
}

@Suite struct WorkflowTests {
    /// 2026-07-01 00:00 +02:00
    let day1 = 1_782_856_800.0

    @Test func buildAlbumFetchesGroupsAndSaves() async throws {
        let source = FakePhotoSource(photos: [
            sourcePhoto("a.jpg", day1 + 3600),
            sourcePhoto("b.jpg", day1 + 7200),
            sourcePhoto("c.jpg", day1 + 86_400 + 3600),
        ])
        let query = SourceQuery.album(identifier: "trip", name: "Trip")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = try ProjectPackage.create(at: dir.appendingPathComponent("T.leporelo"), album: album([]))
        let before = Date().addingTimeInterval(-0.001)  // createdAt is rounded to the millisecond

        let built = try await Workflow.buildAlbum(
            from: source, query: query, title: "Léto", profileID: "canva-photobook",
            formatID: "landscape-a4", package: package, resolver: InMemoryPlaceResolver([]))

        #expect(source.queries == [query])
        #expect(built.title == "Léto")
        #expect(built.supplierProfileID == "canva-photobook")
        #expect(built.formatID == "landscape-a4")
        #expect(built.world == "journal-gallery")
        #expect(built.source == query)
        #expect(built.createdAt >= before)
        #expect(built.spreads.isEmpty && built.cover == nil)
        #expect(built.photos.count == 3)
        #expect(Set(built.photos.values.map(\.sourceIdentifier)) == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(built.photos.values.allSatisfy { !$0.isSelected && $0.originalState == .missing })
        let days = built.photos.values.reduce(into: [String: DayKey]()) { $0[$1.sourceIdentifier] = $1.dayKey }
        #expect(days["a.jpg"] == DayKey(year: 2026, month: 7, day: 1))
        #expect(days["b.jpg"] == DayKey(year: 2026, month: 7, day: 1))
        #expect(days["c.jpg"] == DayKey(year: 2026, month: 7, day: 2))

        let (_, reopened) = try ProjectPackage.open(package.url)
        #expect(reopened == built)
    }

    @Test func buildAlbumPropagatesSourceErrors() async throws {
        let source = FakePhotoSource()
        source.setPhotosError(.notAuthorized)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = try ProjectPackage.create(at: dir.appendingPathComponent("T.leporelo"), album: album([]))
        await #expect(throws: PhotoSourceError.notAuthorized) {
            _ = try await Workflow.buildAlbum(
                from: source, query: .dateRange(start: .distantPast, end: .distantFuture), title: "x",
                profileID: "canva-photobook", formatID: "landscape-a4", package: package,
                resolver: InMemoryPlaceResolver([]))
        }
    }

    @Test func recommendAndDraftSelectsPerDayMarksSeriesAndDrafts() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        // Day 1: 12 photos 10 min apart; day 2: a 3-photo burst (1 s apart, no feature prints) + 9 more.
        var photos: [Photo] = (0..<12).map { photo("d1-\($0)", day1 + Double($0) * 600, day: 1) }
        let d2 = day1 + 86_400
        photos += (0..<3).map { photo("d2-burst-\($0)", d2 + Double($0), day: 2) }
        photos += (0..<9).map { photo("d2-\($0)", d2 + 3600 + Double($0) * 600, day: 2) }
        let input = album(photos)

        let out = Workflow.recommendAndDraft(album: input, profile: profile, format: format)

        let selected = out.photos.values.filter(\.isSelected)
        #expect(selected.filter { $0.dayKey?.day == 1 }.count == Recommender.targetCount(photoCount: 12))
        #expect(selected.filter { $0.dayKey?.day == 2 }.count == Recommender.targetCount(photoCount: 12))
        let burst = (0..<3).map { out.photos["d2-burst-\($0)"]! }
        #expect(burst.allSatisfy { $0.seriesID == "series-d2-burst-0" })
        #expect(burst.filter(\.isSelected).count == 1)  // series losers are never recommended
        #expect(out.photos["d1-0"]?.seriesID == nil)
        #expect(!out.spreads.isEmpty && out.cover != nil)
        #expect(profile.pageCount.isSatisfied(by: AlbumDrafter.pageCount(of: out)))
        let framed = Set(out.spreads.flatMap(\.frames).compactMap(\.photoID))
        #expect(framed == Set(selected.map(\.id)))
        // Deterministic.
        #expect(Workflow.recommendAndDraft(album: input, profile: profile, format: format) == out)
    }

    @Test func recommendAndDraftReplacesStaleSelection() throws {
        // Preselected but undecided (e.g. an earlier recommendation): the new recommendation decides.
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        let photos = (0..<20).map { photo("p\($0)", day1 + Double($0) * 600, day: 1, selected: true) }
        let out = Workflow.recommendAndDraft(album: album(photos), profile: profile, format: format)
        #expect(out.photos.values.filter(\.isSelected).count == Recommender.targetCount(photoCount: 20))
    }

    @Test func recommendationsApplyOnlyOnce() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        let photos = (0..<20).map { photo("p\($0)", day1 + Double($0) * 600, day: 1) }
        let first = Workflow.recommendAndDraft(album: album(photos), profile: profile, format: format)
        let recommended = Set(first.photos.values.filter(\.isSelected).map(\.id))
        #expect(recommended.count == Recommender.targetCount(photoCount: 20))
        #expect(first.photos.values.allSatisfy { !$0.selectionDecidedByUser })  // a recommendation is no decision

        // The user deselects a recommended photo and selects a photo that was not recommended.
        let dropped = recommended.sorted()[0]
        let added = try #require(Set(first.photos.keys).subtracting(recommended).sorted().first)
        var edited = try first.applying(.setSelected(dropped, false)).album
        edited = try edited.applying(.setSelected(added, true)).album

        let second = Workflow.recommendAndDraft(album: edited, profile: profile, format: format)
        #expect(second.photos[dropped]?.isSelected == false)
        #expect(second.photos[dropped]?.selectionDecidedByUser == true)
        #expect(second.photos[added]?.isSelected == true)
        #expect(second.photos[added]?.selectionDecidedByUser == true)
        // Undecided photos get the recommendation again.
        for id in Set(photos.map(\.id)).subtracting([dropped, added]) {
            #expect(second.photos[id]?.isSelected == recommended.contains(id), "\(id)")
        }
        let framed = Set(second.spreads.flatMap(\.frames).compactMap(\.photoID))
        #expect(framed == Set(second.photos.values.filter(\.isSelected).map(\.id)))
        #expect(!framed.contains(dropped) && framed.contains(added))
        // And a third run changes nothing.
        #expect(Workflow.recommendAndDraft(album: second, profile: profile, format: format) == second)
    }

    @Test func recommendAndDraftKeepsDecidedSelectionOfUndatedPhoto() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        var photos = (0..<10).map { photo("p\($0)", day1 + Double($0) * 600, day: 1) }
        photos.append(photo("undated", day1 + 5 * 86_400, day: nil, selected: true, decided: true))
        let out = Workflow.recommendAndDraft(album: album(photos), profile: profile, format: format)
        #expect(out.photos["undated"]?.isSelected == true)  // the user's decision stands
        #expect(!out.spreads.flatMap(\.frames).contains { $0.photoID == "undated" })  // no day, not placed
    }

    @Test func recommendAndDraftKeepsPlaceNamesFromPhotos() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        let photos = (0..<10).map { photo("p\($0)", day1 + Double($0) * 600, day: 1, place: "Positano") }
        let out = Workflow.recommendAndDraft(album: album(photos), profile: profile, format: format)
        let intro = try #require(out.spreads.first { $0.kind == .intro })
        #expect(intro.texts.first { $0.role == .body }?.text.contains("Positano") == true)
        let journal = try #require(out.spreads.first { $0.kind == .journal })
        #expect(journal.texts.first { $0.role == .title }?.text == "Positano")
    }

    @Test func recommendAndDraftUnselectsUndatedPreselectedPhoto() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        var photos = (0..<10).map { photo("p\($0)", day1 + Double($0) * 600, day: 1) }
        // No dayKey (never grouped), alone on another day, preselected by an earlier state, undecided.
        photos.append(photo("undated", day1 + 5 * 86_400, day: nil, selected: true))
        let out = Workflow.recommendAndDraft(album: album(photos), profile: profile, format: format)
        #expect(out.photos["undated"]?.isSelected == false)
        #expect(!out.spreads.flatMap(\.frames).contains { $0.photoID == "undated" })
        #expect(out.photos.values.filter(\.isSelected).count == Recommender.targetCount(photoCount: 10))
    }

    @Test func recommendAndDraftIsDeterministicForEqualTimestampsAndOrder() throws {
        let (profile, format) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-8x6in")
        // Pairs of photos with identical capturedAt (ties broken by id), 2 days.
        var photos: [Photo] = []
        for i in 0..<8 {
            for twin in ["a", "b"] {
                photos.append(photo("d1-\(i)\(twin)", day1 + Double(i) * 600, day: 1))
                photos.append(photo("d2-\(i)\(twin)", day1 + 86_400 + Double(i) * 600, day: 2))
            }
        }
        let forward = album(photos)
        var backward = album([])
        for p in photos.reversed() { backward.photos[p.id] = p }
        var shuffled = album([])
        var rng = SystemRandomNumberGenerator()
        for p in photos.shuffled(using: &rng) { shuffled.photos[p.id] = p }

        let reference = Workflow.recommendAndDraft(album: forward, profile: profile, format: format)
        #expect(Workflow.recommendAndDraft(album: backward, profile: profile, format: format) == reference)
        #expect(Workflow.recommendAndDraft(album: shuffled, profile: profile, format: format) == reference)
    }

    @Test func nowIsOnTheMillisecondGrid() {
        let t = Workflow.now().timeIntervalSince1970 * 1000
        #expect(t == t.rounded())
    }

    @Test func defaultFormatPrefersLandscape() {
        func profile(_ ids: [String]) -> SupplierProfile {
            SupplierProfile(id: "p", name: "p",
                            formats: ids.map { BookFormat(id: $0, name: $0, pageWidthMM: 200, pageHeightMM: 200) },
                            pageMode: .singlePages, coverMode: .frontOnly,
                            pageCount: PageCountRule(min: 20, max: nil, multipleOf: 2), bleedMM: 3, safeMM: 6,
                            output: OutputSpec(fileType: "pdf", dpi: 300, jpegQuality: 0.9, separateCover: true),
                            verified: false, sourceURL: "", uploadSteps: [])
        }
        #expect(Workflow.defaultFormat(of: profile(["square-21", "landscape-a4", "landscape-b"]))?.id == "landscape-a4")
        #expect(Workflow.defaultFormat(of: profile(["square-21", "portrait"]))?.id == "square-21")
        #expect(Workflow.defaultFormat(of: profile([])) == nil)
    }
}
