import Foundation
import Testing
@testable import LeporeloCore

struct CzechPluralTests {
    @Test func formsFollowCzechRules() {
        let expected: [Int: String] = [0: "fotek", 1: "fotka", 2: "fotky", 3: "fotky", 4: "fotky",
                                       5: "fotek", 11: "fotek", 21: "fotek", 22: "fotek", 148: "fotek",
                                       -1: "fotek"]
        for (n, word) in expected {
            #expect(CzechPlural.choose(n, one: "fotka", few: "fotky", many: "fotek") == word, "n = \(n)")
        }
    }

    @Test func countUsesCzechGrouping() {
        #expect(CzechPlural.photos(1) == "1 fotka")
        #expect(CzechPlural.photos(3) == "3 fotky")
        #expect(CzechPlural.photos(148) == "148 fotek")
        #expect(CzechPlural.photos(3000) == "3\u{00A0}000 fotek")
        #expect(CzechPlural.pages(1) == "1 strana")
        #expect(CzechPlural.pages(4) == "4 strany")
        #expect(CzechPlural.pages(36) == "36 stran")
        #expect(CzechPlural.grouped(12345) == "12\u{00A0}345")
    }
}

struct BackgroundFieldsMergeTests {
    private func photo(_ id: String, selected: Bool = false) -> Photo {
        Photo(id: id, sourceIdentifier: "src-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
              timeZoneSeconds: nil, location: nil, pixelWidth: 40, pixelHeight: 30, kind: .photo,
              analysis: nil, isSelected: selected, dayKey: DayKey(year: 2026, month: 6, day: 18),
              placeName: nil, seriesID: nil, originalState: .missing, deletedInSource: false)
    }

    private func album(_ photos: [Photo], title: String = "A") -> Album {
        Album(formatVersion: 1, id: "a", title: title, supplierProfileID: "s", formatID: "f",
              world: "journal-gallery", cover: nil, spreads: [],
              photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }), source: nil,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func userFieldsComeFromRestoredBackgroundFieldsFromCurrent() {
        let restored = album([photo("p1", selected: false), photo("p2")], title: "Old")
        var current = album([photo("p1", selected: true), photo("p2")], title: "New")
        let analysis = PhotoAnalysis(aesthetic: 0.7, sharpness: 300, isUtility: false, faceRects: [],
                                     closedEyes: false, featurePrint: nil)
        current.photos["p1"]?.analysis = analysis
        current.photos["p1"]?.originalState = .stored(relativePath: "originals/p1.jpg")
        current.photos["p1"]?.seriesID = "series-p1"
        current.photos["p1"]?.placeName = "Positano"
        current.photos["p1"]?.deletedInSource = true
        current.photos["p1"]?.dayKey = DayKey(year: 2026, month: 6, day: 19)

        let merged = restored.keepingBackgroundFields(of: current)
        #expect(merged.title == "Old")
        let p1 = merged.photos["p1"]!
        #expect(p1.isSelected == false)
        #expect(p1.dayKey == DayKey(year: 2026, month: 6, day: 18))
        #expect(p1.analysis == analysis)
        #expect(p1.originalState == .stored(relativePath: "originals/p1.jpg"))
        #expect(p1.seriesID == "series-p1")
        #expect(p1.placeName == "Positano")
        #expect(p1.deletedInSource)
        #expect(merged.photos["p2"] == restored.photos["p2"])
    }

    @Test func photosOnlyInOneAlbumAreKept() {
        var onlyRestored = photo("old")
        onlyRestored.placeName = "Ravello"
        let restored = album([photo("p1"), onlyRestored])
        let current = album([photo("p1"), photo("added")])
        let merged = restored.keepingBackgroundFields(of: current)
        #expect(Set(merged.photos.keys) == ["p1", "old", "added"])
        #expect(merged.photos["old"] == onlyRestored)
        #expect(merged.photos["added"] == current.photos["added"])
    }

    @Test func identicalAlbumsMergeToThemselves() {
        let a = album([photo("p1", selected: true)])
        #expect(a.keepingBackgroundFields(of: a) == a)
    }
}
