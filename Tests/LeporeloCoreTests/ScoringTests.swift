import Testing
import Foundation
@testable import LeporeloCore

@Suite struct ScoringTests {
    static let base = ISO8601DateFormatter().date(from: "2026-06-18T08:00:00Z")!

    static func photo(_ id: String, at offset: TimeInterval, aesthetic: Double = 0.5, sharpness: Double = 100,
                      utility: Bool = false, kind: PhotoKind = .photo, print: Data? = nil) -> Photo {
        Photo(id: id, sourceIdentifier: id, capturedAt: base.addingTimeInterval(offset), timeZoneSeconds: 0,
              location: nil, pixelWidth: 4000, pixelHeight: 3000, kind: kind,
              analysis: PhotoAnalysis(aesthetic: aesthetic, sharpness: sharpness, isUtility: utility,
                                      faceRects: [], closedEyes: false, featurePrint: print),
              isSelected: false, dayKey: nil, placeName: nil, seriesID: nil,
              originalState: .missing, deletedInSource: false)
    }

    static func day(_ photos: [Photo]) -> DayGroup {
        DayGroup(dayKey: DayKey(year: 2026, month: 6, day: 18), photos: photos, placeNames: [], timeZoneSeconds: 0)
    }

    @Test func targetCountBounds() {
        #expect(Recommender.targetCount(photoCount: 3) == 3)
        #expect(Recommender.targetCount(photoCount: 30) == 8)
        #expect(Recommender.targetCount(photoCount: 90) == 15)
        #expect(Recommender.targetCount(photoCount: 200) == 20)
    }

    @Test func videosAndUtilityNeverRecommended() {
        let ps = [Self.photo("a", at: 0), Self.photo("v", at: 600, kind: .video),
                  Self.photo("u", at: 1200, utility: true), Self.photo("b", at: 1800)]
        let rec = Recommender.recommend(day: Self.day(ps), series: [])
        #expect(rec == ["a", "b"])
    }

    @Test func bestOfSeriesPicked() {
        let ps = [Self.photo("s1", at: 0, aesthetic: 0.3), Self.photo("s2", at: 5, aesthetic: 0.9),
                  Self.photo("s3", at: 10, aesthetic: 0.5)]
        let series = [Series(id: "x", photoIDs: ["s1", "s2", "s3"])]
        #expect(Recommender.recommend(day: Self.day(ps), series: series) == ["s2"])
    }

    @Test func seriesDetectionByTimeAndSimilarity() {
        let fp = Data([1])
        let close = [Self.photo("a", at: 10, print: fp), Self.photo("b", at: 0, print: fp)]
        let s = SeriesDetector.detect(close, distance: { _, _ in 0.1 })
        #expect(s == [Series(id: "series-b", photoIDs: ["b", "a"])])
        let far = [Self.photo("a", at: 0, print: fp), Self.photo("b", at: 120, print: fp)]
        #expect(SeriesDetector.detect(far, distance: { _, _ in 0.1 }).isEmpty)
        let dissimilar = [Self.photo("a", at: 0, print: fp), Self.photo("b", at: 10, print: fp)]
        #expect(SeriesDetector.detect(dissimilar, distance: { _, _ in 0.9 }).isEmpty)
        let applied = SeriesDetector.apply(s, to: close)
        #expect(applied.allSatisfy { $0.seriesID == "series-b" })
    }

    @Test func spreadsAcrossDay() {
        var ps = (0..<20).map { Self.photo("p\($0)", at: Double($0) * 3, aesthetic: 0.9) }
        ps.append(Self.photo("late", at: 5 * 3600, aesthetic: 0.1))
        let rec = Recommender.recommend(day: Self.day(ps), series: [])
        #expect(rec.contains("late"))
        #expect(rec.count == 8)
    }

    @Test func reachesTargetWhenSpacingRunsOut() {
        let ps = (0..<30).map { Self.photo("p\($0)", at: Double($0) * 10) }
        #expect(Recommender.recommend(day: Self.day(ps), series: []).count == 8)
    }

    @Test func deterministicOnTies() {
        let ps = (0..<30).map { Self.photo("p\($0)", at: Double($0) * 10) }
        let a = Recommender.recommend(day: Self.day(ps), series: [])
        #expect(a == Recommender.recommend(day: Self.day(ps.reversed()), series: []))
    }
}
