import CoreGraphics
import Foundation
import Testing
@testable import LeporeloCore

// MARK: Helpers

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("leporelo-pipeline-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func photo(_ id: String, kind: PhotoKind = .photo, analysis: PhotoAnalysis? = nil,
                   selected: Bool = true, state: OriginalState = .missing,
                   deleted: Bool = false) -> Photo {
    Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: 1_782_864_000),
          timeZoneSeconds: 7200, location: nil, pixelWidth: 4000, pixelHeight: 3000, kind: kind,
          analysis: analysis, isSelected: selected, dayKey: DayKey(year: 2026, month: 7, day: 1),
          placeName: nil, seriesID: nil, originalState: state, deletedInSource: deleted)
}

private func album(_ photos: [Photo], spreads: [Spread] = [], source: SourceQuery? = nil) -> Album {
    Album(formatVersion: Album.currentFormatVersion, id: "album-1", title: "Léto",
          supplierProfileID: "saal", formatID: "20x20", world: "journal-gallery", cover: nil,
          spreads: spreads, photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
          source: source, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private let someAnalysis = PhotoAnalysis(aesthetic: 0.5, sharpness: 100, isUtility: false,
                                         faceRects: [], closedEyes: false, featurePrint: nil)

/// Collects callback values from `@Sendable` closures.
private actor Recorder<T: Sendable> {
    private(set) var values: [T] = []
    func append(_ value: T) { values.append(value) }
}

private struct StateChange: Sendable, Equatable {
    var id: PhotoID
    var state: OriginalState
}

private struct Fixture {
    let dir: URL
    let package: ProjectPackage
    init(album: Album) throws {
        dir = makeTempDir()
        package = try ProjectPackage.create(at: dir.appendingPathComponent("Test.leporelo"), album: album)
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// Waits until `count` events matching `predicate` arrived on the fake's event stream.
private func waitForEvents(_ source: FakePhotoSource, count: Int,
                           where predicate: (FakePhotoSource.Event) -> Bool) async {
    var seen = 0
    for await event in source.events where predicate(event) {
        seen += 1
        if seen == count { return }
    }
}

private func isThumbnailStart(_ event: FakePhotoSource.Event) -> Bool {
    if case .thumbnailStarted = event { return true }
    return false
}

private func isOriginalStart(_ event: FakePhotoSource.Event) -> Bool {
    if case .originalStarted = event { return true }
    return false
}

// MARK: AnalysisPipeline

@Suite struct AnalysisPipelineTests {
    @Test func pipelineAnalyzesOnlyUnanalyzedPhotosAndSkipsVideos() async throws {
        let a = album([photo("a"), photo("b", analysis: someAnalysis), photo("v", kind: .video),
                       photo("l", kind: .livePhoto)])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let pipeline = AnalysisPipeline(source: source, package: fx.package, analyzer: ImageAnalyzer())
        let analyzed = Recorder<PhotoID>()
        let progress = Recorder<PipelineProgress>()

        await pipeline.run(album: a,
                           onPhotoAnalyzed: { id, _ in await analyzed.append(id) },
                           onProgress: { await progress.append($0) })

        #expect(Set(await analyzed.values) == ["a", "l"])
        #expect(source.thumbnailCalls("src-a") == 1)
        #expect(source.thumbnailCalls("src-l") == 1)
        #expect(source.thumbnailCalls("src-b") == 0)
        #expect(source.thumbnailCalls("src-v") == 0)
        #expect(fx.package.thumbnail(for: "a") != nil)
        #expect(fx.package.thumbnail(for: "b") == nil)
        #expect(await progress.values.last == PipelineProgress(done: 2, total: 2))
    }

    @Test func pipelineContinuesAfterOneFailure() async throws {
        let a = album([photo("a"), photo("bad"), photo("c")])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        source.failThumbnail("src-bad", with: .notFound("src-bad"))
        let pipeline = AnalysisPipeline(source: source, package: fx.package, analyzer: ImageAnalyzer(),
                                        concurrency: 1)
        let analyzed = Recorder<PhotoID>()
        let progress = Recorder<PipelineProgress>()

        await pipeline.run(album: a,
                           onPhotoAnalyzed: { id, _ in await analyzed.append(id) },
                           onProgress: { await progress.append($0) })

        #expect(Set(await analyzed.values) == ["a", "c"])
        #expect(fx.package.thumbnail(for: "bad") == nil)
        let values = await progress.values
        #expect(values.allSatisfy { $0.total == 3 })
        #expect(values.map(\.done) == values.map(\.done).sorted())
        #expect(values.last == PipelineProgress(done: 3, total: 3))
    }

    @Test func pipelineRespectsConcurrencyLimit() async throws {
        let photos = (0..<8).map { photo("p\($0)") }
        let a = album(photos)
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let pipeline = AnalysisPipeline(source: source, package: fx.package, analyzer: ImageAnalyzer(),
                                        concurrency: 2)
        let analyzed = Recorder<PhotoID>()
        let progress = Recorder<PipelineProgress>()

        await pipeline.run(album: a, onPhotoAnalyzed: { id, _ in await analyzed.append(id) },
                           onProgress: { await progress.append($0) })

        #expect(await analyzed.values.count == 8)
        #expect(source.maxInFlight <= 2)
        #expect(source.totalThumbnailCalls == 8)
        let done = await progress.values.map(\.done)
        #expect(done == done.sorted())
        #expect(done.last == 8)
    }

    @Test func pipelineWithNothingToAnalyzeReportsZeroOfZero() async throws {
        let a = album([photo("b", analysis: someAnalysis), photo("v", kind: .video)])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let pipeline = AnalysisPipeline(source: source, package: fx.package, analyzer: ImageAnalyzer())
        let progress = Recorder<PipelineProgress>()
        await pipeline.run(album: a, onPhotoAnalyzed: { _, _ in }, onProgress: { await progress.append($0) })
        #expect(await progress.values.last == PipelineProgress(done: 0, total: 0))
        #expect(source.totalThumbnailCalls == 0)
    }

    @Test func pipelineCancelStopsNewWorkAndCanRunAgain() async throws {
        let photos = (0..<6).map { photo("p\($0)") }
        let a = album(photos)
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        source.holdThumbnails()
        let pipeline = AnalysisPipeline(source: source, package: fx.package, analyzer: ImageAnalyzer(),
                                        concurrency: 2)
        let analyzed = Recorder<PhotoID>()

        let running = Task {
            await pipeline.run(album: a, onPhotoAnalyzed: { id, _ in await analyzed.append(id) },
                               onProgress: { _ in })
        }
        await waitForEvents(source, count: 2, where: isThumbnailStart)
        await pipeline.cancel()
        await running.value   // returns although the two held calls were never released

        #expect(source.totalThumbnailCalls == 2)
        #expect(await analyzed.values.isEmpty)

        // A fresh run after cancel processes everything.
        source.releaseAll()
        await pipeline.run(album: a, onPhotoAnalyzed: { id, _ in await analyzed.append(id) },
                           onProgress: { _ in })
        #expect(Set(await analyzed.values) == Set(photos.map(\.id)))
    }

    @Test func pipelineStopsWhenCallerTaskIsCancelled() async throws {
        let photos = (0..<6).map { photo("p\($0)") }
        let a = album(photos)
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        source.holdThumbnails()
        let pipeline = AnalysisPipeline(source: source, package: fx.package, analyzer: ImageAnalyzer(),
                                        concurrency: 3)
        let running = Task {
            await pipeline.run(album: a, onPhotoAnalyzed: { _, _ in }, onProgress: { _ in })
        }
        await waitForEvents(source, count: 3, where: isThumbnailStart)
        running.cancel()
        await running.value
        #expect(source.totalThumbnailCalls == 3)
    }
}

// MARK: OriginalsDownloader

@Suite struct OriginalsDownloaderTests {
    @Test func downloaderStoresOriginalAndReportsStates() async throws {
        let a = album([photo("a")])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        source.setOriginal(bytes, ext: "heic", for: "src-a")
        let downloader = OriginalsDownloader(source: source, package: fx.package)
        let changes = Recorder<StateChange>()

        await downloader.enqueue(["a"])
        await downloader.run(album: { a },
                             onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })

        #expect(await changes.values == [StateChange(id: "a", state: .downloading),
                                         StateChange(id: "a", state: .stored(relativePath: "originals/a.heic"))])
        let stored = try Data(contentsOf: fx.package.url.appendingPathComponent("originals/a.heic"))
        #expect(stored == bytes)
    }

    @Test func downloaderGivesUpAfterThreeCloudFailures() async throws {
        let a = album([photo("a"), photo("b")])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        source.cloudUnavailable("src-a", times: 5)
        source.cloudUnavailable("src-b", times: 2)
        let downloader = OriginalsDownloader(source: source, package: fx.package,
                                             retryDelay: .milliseconds(1))
        let changes = Recorder<StateChange>()

        await downloader.enqueue(["a", "b"])
        await downloader.run(album: { a },
                             onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })

        let values = await changes.values
        #expect(values.filter { $0.id == "a" }.map(\.state) == [.downloading, .unavailable])
        #expect(values.filter { $0.id == "b" }.map(\.state)
                == [.downloading, .stored(relativePath: "originals/b.jpg")])
        #expect(source.originalCalls("src-a") == 3)
        #expect(source.originalCalls("src-b") == 3)
    }

    @Test func downloaderSkipsStoredUnknownAndDuplicateIds() async throws {
        let a = album([photo("a"), photo("s", state: .stored(relativePath: "originals/s.jpg"))])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let downloader = OriginalsDownloader(source: source, package: fx.package)
        let changes = Recorder<StateChange>()

        await downloader.enqueue(["a", "a", "ghost", "s"])
        await downloader.enqueue(["a"])
        await downloader.run(album: { a },
                             onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })

        #expect(await changes.values.map(\.id) == ["a", "a"])
        #expect(source.originalCalls("src-a") == 1)
        #expect(source.originalCalls("src-s") == 0)
        #expect(source.originalCalls("src-ghost") == 0)
    }

    @Test func downloaderNotFoundIsUnavailableOtherErrorsAreMissing() async throws {
        let a = album([photo("gone"), photo("denied"), photo("deleted", deleted: true)])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        source.failOriginal("src-gone", with: .notFound("src-gone"))
        source.failOriginal("src-denied", with: .notAuthorized)
        source.cloudUnavailable("src-deleted", times: 1)
        let downloader = OriginalsDownloader(source: source, package: fx.package,
                                             retryDelay: .milliseconds(1))
        let changes = Recorder<StateChange>()

        await downloader.enqueue(["gone", "denied", "deleted"])
        await downloader.run(album: { a },
                             onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })

        let values = await changes.values
        #expect(values.last { $0.id == "gone" }?.state == .unavailable)
        #expect(values.last { $0.id == "denied" }?.state == .missing)
        // Deleted in the source: one attempt only.
        #expect(values.last { $0.id == "deleted" }?.state == .unavailable)
        #expect(source.originalCalls("src-gone") == 1)
        #expect(source.originalCalls("src-deleted") == 1)
    }

    @Test func downloaderPicksUpIdsEnqueuedDuringRunAndReadsCurrentAlbum() async throws {
        let base = album([photo("a")])
        let fx = try Fixture(album: base)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let downloader = OriginalsDownloader(source: source, package: fx.package, concurrency: 1)
        let changes = Recorder<StateChange>()
        // "b" exists only in the album as it is when "b" is processed.
        let current = Recorder<Album>()
        await current.append(base)
        var withB = base
        withB.photos["b"] = photo("b")
        let next = withB

        await downloader.enqueue(["a"])
        await downloader.run(album: { await current.values.last! }, onStateChange: { id, state in
            await changes.append(StateChange(id: id, state: state))
            if id == "a", state == .downloading {
                await current.append(next)
                await downloader.enqueue(["b"])
            }
        })

        #expect(await changes.values.map(\.state) == [
            .downloading, .stored(relativePath: "originals/a.jpg"),
            .downloading, .stored(relativePath: "originals/b.jpg"),
        ])
    }

    @Test func downloaderSecondConcurrentRunReturnsImmediately() async throws {
        let a = album([photo("a")])
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        source.holdOriginals()
        let downloader = OriginalsDownloader(source: source, package: fx.package)
        let changes = Recorder<StateChange>()

        await downloader.enqueue(["a"])
        let first = Task {
            await downloader.run(album: { a },
                                 onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })
        }
        await waitForEvents(source, count: 1, where: isOriginalStart)
        await downloader.run(album: { a },
                             onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })
        #expect(await changes.values.map(\.state) == [.downloading])

        source.releaseAll()
        await first.value
        #expect(await changes.values.map(\.state) == [.downloading, .stored(relativePath: "originals/a.jpg")])
        #expect(source.originalCalls("src-a") == 1)
    }

    @Test func downloaderRespectsConcurrencyLimit() async throws {
        let ids = (0..<9).map { "p\($0)" }
        let a = album(ids.map { photo($0) })
        let fx = try Fixture(album: a)
        defer { fx.cleanup() }
        let source = FakePhotoSource()
        let downloader = OriginalsDownloader(source: source, package: fx.package, concurrency: 3)
        let changes = Recorder<StateChange>()
        await downloader.enqueue(ids)
        await downloader.run(album: { a },
                             onStateChange: { await changes.append(StateChange(id: $0, state: $1)) })
        let stored = await changes.values.filter {
            if case .stored = $0.state { return true }
            return false
        }
        #expect(stored.count == 9)
        #expect(source.maxInFlight <= 3)
    }
}

// MARK: SourceSync

@Suite struct SourceSyncTests {
    private static let query = SourceQuery.album(identifier: "amalfi", name: "Amalfi")

    @Test func refreshAddsNewAndMarksDeleted() async throws {
        // "gone" is placed in a frame and its original is in the project.
        var gone = photo("gone", state: .stored(relativePath: "originals/gone.jpg"))
        gone.sourceIdentifier = "id-gone"
        var kept = photo("kept")
        kept.sourceIdentifier = "id-kept"
        let frame = Frame(id: "f1", rect: Rect(x: 0, y: 0, width: 100, height: 100), photoID: "gone",
                          offset: Point(x: 0, y: 0), zoom: 1)
        let spread = Spread(id: "s1", kind: .gallery, templateID: "g1", dayKey: nil, frames: [frame],
                            texts: [], manuallyEdited: false)
        let before = album([gone, kept], spreads: [spread], source: Self.query)
        let source = FakePhotoSource(photos: [.fake("id-kept"), .fake("id-new", minutes: 5),
                                              .fake("id-new2", minutes: 6, kind: .video)])

        let result = try await SourceSync.refresh(album: before, source: source)

        #expect(result.added == 2)
        #expect(result.deleted == 1)
        #expect(source.queries == [Self.query])
        let after = result.album
        // Review Focus 3: the deleted photo is flagged but stays, with its original and its frame.
        let flagged = try #require(after.photos["gone"])
        #expect(flagged.deletedInSource == true)
        #expect(flagged.isSelected == true)
        #expect(flagged.originalState == .stored(relativePath: "originals/gone.jpg"))
        #expect(after.spreads == before.spreads)
        #expect(after.spreads[0].frames[0].photoID == "gone")
        #expect(after.photos["kept"] == kept)
        // New photos: unselected, missing original, no day yet, fresh ids.
        let added = after.photos.values.filter { $0.sourceIdentifier.hasPrefix("id-new") }
        #expect(added.count == 2)
        #expect(added.allSatisfy { !$0.isSelected && $0.originalState == .missing && $0.dayKey == nil })
        #expect(added.allSatisfy { before.photos[$0.id] == nil })
        #expect(Set(added.map(\.sourceIdentifier)) == ["id-new", "id-new2"])
        #expect(after.photos.count == 4)
    }

    @Test func refreshClearsFlagOnReappearanceAndCountsOnlyNewlyDeleted() async throws {
        var old = photo("old", deleted: true)
        old.sourceIdentifier = "id-old"
        var back = photo("back", deleted: true)
        back.sourceIdentifier = "id-back"
        var here = photo("here")
        here.sourceIdentifier = "id-here"
        let before = album([old, back, here], source: Self.query)
        let source = FakePhotoSource(photos: [.fake("id-back")])

        let result = try await SourceSync.refresh(album: before, source: source)

        #expect(result.added == 0)
        #expect(result.deleted == 1)   // only "here"; "old" was already flagged
        #expect(result.album.photos["old"]?.deletedInSource == true)
        #expect(result.album.photos["back"]?.deletedInSource == false)
        #expect(result.album.photos["here"]?.deletedInSource == true)
    }

    @Test func refreshWithoutSourceQueryIsANoOp() async throws {
        let before = album([photo("a")])
        let source = FakePhotoSource(photos: [.fake("x")])
        let result = try await SourceSync.refresh(album: before, source: source)
        #expect(result.album == before)
        #expect(result.added == 0 && result.deleted == 0)
        #expect(source.photosCalls == 0)
    }

    @Test func refreshPropagatesSourceErrors() async throws {
        let before = album([photo("a")], source: Self.query)
        let source = FakePhotoSource()
        source.setPhotosError(.notAuthorized)
        await #expect(throws: PhotoSourceError.notAuthorized) {
            _ = try await SourceSync.refresh(album: before, source: source)
        }
    }
}
