import Testing
import Foundation
@testable import LeporeloCore

@Suite struct PreflightTests {
    // Canva A4 landscape: page 297 x 210, spread 594 x 210, bleed 3, safe 6, singlePages, frontOnly.
    static func setup(verified: Bool = true, rule: PageCountRule? = nil) throws -> (SupplierProfile, BookFormat) {
        var (p, f) = try ProfileCatalog.format(profileID: "canva-photobook", formatID: "landscape-a4")
        p.verified = verified
        p.pageCount = rule ?? PageCountRule(min: 2, max: nil, multipleOf: 2)
        return (p, f)
    }

    static func photo(_ id: String, w: Int = 4000, h: Int = 3000, state: OriginalState = .stored(relativePath: "o.jpg"),
                      faces: [Rect] = []) -> Photo {
        Photo(id: id, sourceIdentifier: id, capturedAt: Date(timeIntervalSince1970: 0), timeZoneSeconds: 0,
              location: nil, pixelWidth: w, pixelHeight: h, kind: .photo,
              analysis: PhotoAnalysis(aesthetic: 0.5, sharpness: 500, isUtility: false, faceRects: faces,
                                      closedEyes: false, featurePrint: nil),
              isSelected: true, dayKey: nil, placeName: nil, seriesID: nil, originalState: state,
              deletedInSource: false)
    }

    static func frame(_ id: String = "f1", _ r: Rect = Rect(x: 20, y: 20, width: 150, height: 100),
                      photo: PhotoID? = "p1") -> Frame {
        Frame(id: id, rect: r, photoID: photo, offset: Point(x: 0, y: 0), zoom: 1)
    }

    static func frame(_ r: Rect) -> Frame { frame("f1", r) }
    static func frame(photo: PhotoID?) -> Frame { frame("f1", Rect(x: 20, y: 20, width: 150, height: 100), photo: photo) }

    static func spread(_ id: String = "s1", kind: SpreadKind = .gallery, frames: [Frame] = [frame()],
                       texts: [TextBox] = []) -> Spread {
        Spread(id: id, kind: kind, templateID: "t", dayKey: nil, frames: frames, texts: texts, manuallyEdited: false)
    }

    static func spread(frames: [Frame]) -> Spread { spread("s1", frames: frames) }
    static func spread(texts: [TextBox]) -> Spread { spread("s1", texts: texts) }

    static func album(spreads: [Spread], photos: [Photo] = [photo("p1")], cover: Cover? = nil) -> Album {
        Album(formatVersion: 1, id: "a", title: "T", supplierProfileID: "canva-photobook",
              formatID: "landscape-a4", world: "journal-gallery", cover: cover, spreads: spreads,
              photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }), source: nil,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    static func cover(photo: PhotoID? = "p1", frameRect: Rect = Rect(x: 0, y: 0, width: 297, height: 210),
                      texts: [TextBox] = []) -> Cover {
        let front = Spread(id: "cover-front", kind: .intro, templateID: "cover-front", dayKey: nil,
                           frames: [frame("photo1", frameRect, photo: photo)], texts: texts, manuallyEdited: false)
        let back = Spread(id: "cover-back", kind: .blank, templateID: "blank", dayKey: nil,
                          frames: [], texts: [], manuallyEdited: false)
        return Cover(front: front, back: back)
    }

    static func check(_ a: Album, verified: Bool = true, rule: PageCountRule? = nil) throws -> [PreflightIssue] {
        let (p, f) = try setup(verified: verified, rule: rule)
        return Preflight.check(album: a, profile: p, format: f)
    }

    static func goodAlbum() -> Album {
        // Two different photos: the same photo on two day spreads would give a duplicatePhoto warning.
        album(spreads: [spread("s1"), spread("s2", frames: [frame(photo: "p2")])],
              photos: [photo("p1"), photo("p2")], cover: cover())
    }

    static func body(_ text: String) -> TextBox {
        TextBox(id: "body", rect: Rect(x: 20, y: 130, width: 100, height: 40), role: .body, text: text)
    }

    /// Issues of spread `s1` of an album whose second spread `s2` is a clean filler.
    static func issuesOfS1(_ s1: Spread, photos: [Photo] = [photo("p1")], cover: Cover? = cover()) throws -> [PreflightIssue] {
        try check(album(spreads: [s1, spread("s2")], photos: photos, cover: cover)).filter { $0.spreadID == "s1" }
    }

    // MARK: -

    @Test func cleanAlbumHasNoErrors() throws {
        let issues = try Self.check(Self.goodAlbum())
        #expect(issues.isEmpty)
        #expect(!Preflight.hasErrors(issues))
        let unverified = try Self.check(Self.goodAlbum(), verified: false)
        #expect(unverified.count == 1)
        #expect(unverified[0].severity == .warning)
        #expect(unverified[0].message == "Rozměry formátu nejsou ověřené")
        #expect(!Preflight.hasErrors(unverified))
    }

    @Test func missingOriginalIsError() throws {
        let issues = try Self.issuesOfS1(Self.spread(), photos: [Self.photo("p1", state: .missing)])
        #expect(issues.count == 1)
        #expect(issues[0].severity == .error)
        #expect(issues[0].message == "Originál fotky ještě není v projektu")
        #expect(issues[0].frameID == "f1")
        #expect(Preflight.hasErrors(issues))
    }

    @Test func originalStates() throws {
        func msgs(_ s: OriginalState, deleted: Bool = false) throws -> [String] {
            var p = Self.photo("p1", state: s)
            p.deletedInSource = deleted
            return try Self.issuesOfS1(Self.spread(), photos: [p]).map(\.message)
        }
        #expect(try msgs(.downloading) == ["Originál fotky se ještě stahuje"])
        #expect(try msgs(.unavailable) == ["Originál fotky není dostupný v iCloudu"])
        #expect(try msgs(.stored(relativePath: "x"), deleted: true).isEmpty)
    }

    @Test func lowResolutionIsErrorBelow150WarningBelow220() throws {
        let small = Self.photo("p1", w: 2048, h: 1536)
        // 2048x1536 over a page-wide frame of 297 mm inside the page vertically (no bleed on x? it touches
        // both x edges, so bleed applies there): 297 + 6 = 303 mm -> 171 DPI -> warning.
        let w = try Self.issuesOfS1(Self.spread(frames: [Self.frame(Rect(x: 0, y: 0, width: 297, height: 210))]),
                                    photos: [small])
        #expect(w.count == 1)
        #expect(w[0].severity == .warning)
        #expect(w[0].message == "Fotka má jen 171 DPI, pro tisk je potřeba 220")
        // Page-wide but not touching the page edge at the spine side: left edge bleeds, right edge (spine
        // in per-page rendering) bleeds too. Use a frame spanning 297 mm shifted off the edges: exactly 175.
        let inner = try Self.issuesOfS1(Self.spread(frames: [Self.frame(Rect(x: 148.5, y: 20, width: 297, height: 150))]),
                                        photos: [small])
        #expect(inner.map(\.message) == ["Fotka má jen 175 DPI, pro tisk je potřeba 220"])
        #expect(inner[0].severity == .warning)

        // Over the whole spread (594 mm): 88 DPI -> error.
        let e = try Self.issuesOfS1(Self.spread(frames: [Self.frame(Rect(x: 0, y: 20, width: 594, height: 170))]),
                                    photos: [small])
        #expect(e.count == 1)
        #expect(e[0].severity == .error)
        #expect(e[0].message == "Fotka má jen 86 DPI, pro tisk je potřeba 220")
    }

    @Test func dpiUsesBleedOnOuterEdgesOnly() throws {
        // Exactly enough for the 297 mm trim at 220 DPI, short once the bleed is added.
        let widthPx = Int((220.0 * 297.0 / 25.4).rounded(.up))
        let p = Self.photo("p1", w: widthPx, h: widthPx * 3 / 4)
        let onEdge = try Self.issuesOfS1(Self.spread(frames: [Self.frame(Rect(x: 0, y: 0, width: 297, height: 210))]),
                                         photos: [p])
        #expect(onEdge.contains { $0.severity == .warning && $0.message.hasPrefix("Fotka má jen") })
        let inside = try Self.issuesOfS1(Self.spread(frames: [Self.frame(Rect(x: 148.5, y: 20, width: 297, height: 150))]),
                                         photos: [p])
        #expect(inside.isEmpty)
    }

    @Test func pageCountViolation() throws {
        let rule = PageCountRule(min: 20, max: nil, multipleOf: 2)
        let issues = try Self.check(Self.goodAlbum(), rule: rule)
        let i = try #require(issues.first { $0.message.hasPrefix("Album má 4 strany, dodavatel chce") })
        #expect(i.severity == .error)
        #expect(i.message == "Album má 4 strany, dodavatel chce min. 20 stran, sudý počet")
        #expect(i.spreadID == nil)
        let capped = try Self.check(Self.goodAlbum(), rule: PageCountRule(min: 2, max: 2, multipleOf: 8))
        #expect(capped.first { $0.id == "pageCount" }?.message
                == "Album má 4 strany, dodavatel chce min. 2 stran, max. 2 stran, násobek 8")
    }

    @Test func emptyFrameErrorExceptBlank() throws {
        let empty = Self.spread("s1", frames: [Self.frame(photo: nil)])
        let blank = Self.spread("s2", kind: .blank, frames: [])
        let issues = try Self.check(Self.album(spreads: [empty, blank], cover: Self.cover()))
        let e = issues.filter { $0.severity == .error }
        #expect(e.count == 1)
        #expect(e[0].spreadID == "s1" && e[0].frameID == "f1")
        #expect(e[0].message == "Rámeček je prázdný, vyberte fotku nebo dvoustranu smažte")
        let c = try Self.check(Self.album(spreads: [Self.spread("s1"), blank], cover: Self.cover(photo: nil)))
        #expect(c.contains { $0.spreadID == "cover-front" && $0.frameID == "photo1" && $0.severity == .error })
    }

    @Test func faceInBleedWarns() throws {
        // Frame covers the whole left page; a face in the top-left corner of the image lies partly in the
        // bleed (the image is cover-fitted into the bleed-extended frame).
        let page = Rect(x: 0, y: 0, width: 297, height: 210)
        let p = Self.photo("p1", faces: [Rect(x: 0.0, y: 0.0, width: 0.05, height: 0.05)])
        let w = try Self.issuesOfS1(Self.spread(frames: [Self.frame(page)]), photos: [p])
        #expect(w.count == 1)
        #expect(w[0].severity == .warning && w[0].frameID == "f1")
        #expect(w[0].message.contains("bličej"))
        let ok = Self.photo("p1", faces: [Rect(x: 0.45, y: 0.4, width: 0.1, height: 0.1)])
        #expect(try Self.issuesOfS1(Self.spread(frames: [Self.frame(page)]), photos: [ok]).isEmpty)
    }

    @Test func faceNearSpineWarns() throws {
        // Frame on the right page starting at the spine; the face at the left edge of the image.
        let r = Rect(x: 297, y: 20, width: 200, height: 150)
        let p = Self.photo("p1", faces: [Rect(x: 0.0, y: 0.4, width: 0.05, height: 0.1)])
        let w = try Self.issuesOfS1(Self.spread(frames: [Self.frame(r)]), photos: [p])
        #expect(w.count == 1)
        #expect(w[0].message.contains("hřbet"))
        let q = Self.photo("p1", faces: [Rect(x: 0.1, y: 0.4, width: 0.05, height: 0.1)])
        #expect(try Self.issuesOfS1(Self.spread(frames: [Self.frame(r)]), photos: [q]).isEmpty)
    }

    @Test func textOutsideSafeZoneWarns() throws {
        let bad = TextBox(id: "t1", rect: Rect(x: 2, y: 20, width: 100, height: 20), role: .caption, text: "x")
        let bleed = TextBox(id: "t2", rect: Rect(x: -1, y: 20, width: 100, height: 20), role: .caption, text: "x")
        let fine = TextBox(id: "t3", rect: Rect(x: 20, y: 20, width: 100, height: 20), role: .caption, text: "x")
        let w = try Self.issuesOfS1(Self.spread(texts: [bad, bleed, fine]))
        #expect(w.map(\.severity) == [.warning, .warning])
        #expect(Set(w.map(\.id)).count == 2)
        #expect(w[0].message.contains("bezpečn"))
        #expect(w[1].message.contains("spadáv"))
    }

    @Test func coverChecked() throws {
        let t = TextBox(id: "title", rect: Rect(x: 1, y: 1, width: 50, height: 10), role: .title, text: "Amalfi")
        let a = Self.album(spreads: [Self.spread("s1"), Self.spread("s2")],
                           photos: [Self.photo("p1", w: 1000, h: 750, state: .missing)],
                           cover: Self.cover(texts: [t]))
        let issues = try Self.check(a).filter { $0.spreadID == "cover-front" }
        #expect(issues.contains { $0.severity == .error && $0.message == "Originál fotky ještě není v projektu" })
        #expect(issues.contains { $0.severity == .error && $0.message.hasPrefix("Fotka má jen") })
        #expect(issues.contains { $0.severity == .warning && $0.frameID == nil })
        let none = Self.album(spreads: [Self.spread("s1")], cover: nil)
        let n = try Self.check(none).first { $0.id == "noCover" }
        #expect(n?.severity == .error)
        #expect(n?.message == "Album nemá obálku")
        #expect(n?.spreadID == nil)
        var (p, f) = try Self.setup()
        p.coverMode = .none
        #expect(!Preflight.check(album: none, profile: p, format: f).contains { $0.id == "noCover" })
    }

    @Test func zeroSpreadsAndDanglingPhoto() throws {
        let issues = try Self.check(Self.album(spreads: [], photos: [], cover: nil))
        #expect(issues.map(\.id) == ["noCover", "pageCount"])
        #expect(issues[1].message.hasPrefix("Album má 0 stran, dodavatel chce"))
        let d = try Self.issuesOfS1(Self.spread(frames: [Self.frame(photo: "ghost")]))
        #expect(d.count == 1)
        #expect(d[0].severity == .error)
        #expect(d[0].message == "Fotka chybí v albu")
    }

    @Test func journalBodyEmptyWarns() throws {
        // One photo per spread: a repeated photo would add a duplicatePhoto warning.
        func day(_ id: String, _ kind: SpreadKind, _ photo: PhotoID, texts: [TextBox] = []) -> Spread {
            Self.spread(id, kind: kind, frames: [Self.frame(photo: photo)], texts: texts)
        }
        let empty = day("s1", .journal, "p1", texts: [Self.body("  ")])
        let none = day("s2", .journal, "p2")
        let ok = day("s3", .journal, "p3", texts: [Self.body("Dnes jsme šli na pláž.")])
        let gallery = day("s4", .gallery, "p4")
        let w = try Self.check(Self.album(spreads: [empty, none, ok, gallery],
                                          photos: ["p1", "p2", "p3", "p4"].map { Self.photo($0) },
                                          cover: Self.cover()))
        #expect(w.map(\.spreadID) == ["s1", "s2"])
        #expect(w.allSatisfy { $0.severity == .warning })
    }

    @Test func idsAreStableAndOrdered() throws {
        let a = Self.album(spreads: [Self.spread("s1", frames: [Self.frame(photo: nil)]),
                                     Self.spread("s2", frames: [Self.frame(photo: nil)])],
                           cover: Self.cover(photo: nil))
        let rule = PageCountRule(min: 20, max: nil, multipleOf: 2)
        let one = try Self.check(a, verified: false, rule: rule)
        #expect(one == (try Self.check(a, verified: false, rule: rule)))
        #expect(one.map(\.id) == ["emptyFrame:s1:f1", "emptyFrame:s2:f1", "emptyFrame:cover-front:photo1",
                                  "pageCount", "unplacedSelected", "unverified"])
    }

    // MARK: Unplaced selected photos (Task 21a)

    static func video(_ id: String) -> Photo {
        var v = photo(id)
        v.kind = .video
        return v
    }

    static func unselected(_ id: String) -> Photo {
        var p = photo(id)
        p.isSelected = false
        return p
    }

    @Test func unplacedSelectedPhotosGiveOneAlbumWarning() throws {
        let photos = [Self.photo("p1"), Self.photo("p2"), Self.photo("p3"), Self.unselected("p4"), Self.video("v1")]
        let issues = try Self.check(Self.album(spreads: [Self.spread("s1"), Self.spread("s2")], photos: photos,
                                               cover: Self.cover()))
        let unplaced = issues.filter { $0.id == "unplacedSelected" }
        #expect(unplaced.count == 1)
        #expect(unplaced[0].severity == .warning)
        #expect(unplaced[0].spreadID == nil && unplaced[0].frameID == nil)
        #expect(unplaced[0].message == "2 vybrané fotky nejsou v albu")
        #expect(!Preflight.hasErrors(issues))
    }

    @Test func unplacedMessageUsesCzechPlurals() throws {
        func message(_ n: Int) throws -> String? {
            let extra = (0..<n).map { Self.photo("x\($0)") }
            return try Self.check(Self.album(spreads: [Self.spread("s1"), Self.spread("s2")],
                                             photos: [Self.photo("p1")] + extra, cover: Self.cover()))
                .first { $0.id == "unplacedSelected" }?.message
        }
        #expect(try message(0) == nil)
        #expect(try message(1) == "1 vybraná fotka není v albu")
        #expect(try message(4) == "4 vybrané fotky nejsou v albu")
        #expect(try message(5) == "5 vybraných fotek není v albu")
    }

    @Test func coverPhotoCountsAsPlaced() throws {
        let photos = [Self.photo("p1"), Self.photo("c")]
        let issues = try Self.check(Self.album(spreads: [Self.spread("s1"), Self.spread("s2")], photos: photos,
                                               cover: Self.cover(photo: "c")))
        #expect(!issues.contains { $0.id == "unplacedSelected" })
    }

    @Test func noUnplacedWarningBeforeTheFirstDraft() throws {
        let issues = try Self.check(Self.album(spreads: [], photos: [Self.photo("p1"), Self.photo("p2")]))
        #expect(!issues.contains { $0.id == "unplacedSelected" })
    }

    @Test func placedPhotoIDsCoverSpreadsAndCover() {
        let a = Self.album(spreads: [Self.spread("s1", frames: [Self.frame("f1", photo: "p1"), Self.frame("f2", photo: nil)])],
                           photos: [Self.photo("p1"), Self.photo("c"), Self.photo("x")], cover: Self.cover(photo: "c"))
        #expect(a.placedPhotoIDs == ["p1", "c"])
        #expect(a.unplacedSelectedPhotos.map(\.id) == ["x"])
    }

    // MARK: Final fix wave

    @Test func dpiIsShownRoundedDown() throws {
        // 1765 px over a 299.6 mm wide drawn image: 149.6 DPI -> "149", an error (below 150).
        let px = 1767
        let frameMM = Double(px) / 149.8 * 25.4
        let p = Self.photo("p1", w: px, h: px * 3 / 4)
        let issues = try Self.issuesOfS1(Self.spread(frames: [Self.frame(Rect(x: 148.5, y: 20, width: frameMM,
                                                                              height: 150))]), photos: [p])
        #expect(issues.map(\.message) == ["Fotka má jen 149 DPI, pro tisk je potřeba 220"])
        #expect(issues.first?.severity == .error)
    }

    @Test func unavailableDeletedInSourceDoesNotMentionICloud() throws {
        var p = Self.photo("p1", state: .unavailable)
        p.deletedInSource = true
        let issues = try Self.issuesOfS1(Self.spread(), photos: [p])
        #expect(issues.map(\.message) == ["Fotka už není ve Fotkách a originál nebyl stažen"])
        #expect(issues.first?.severity == .error)
    }

    @Test func placedVideoIsAnError() throws {
        var v = Self.photo("p1")
        v.kind = .video
        let issues = try Self.issuesOfS1(Self.spread(), photos: [v])
        #expect(issues.map(\.id) == ["video:s1:f1"])
        #expect(issues.first?.message == "Video nelze vložit do alba")
        #expect(issues.first?.severity == .error)
    }

    static let longBody = String(repeating: "Ráno jsme vyrazili lodí z Amalfi do Positana a celý den se koupali. ", count: 30)

    @Test func longTextInSmallBoxWarns() throws {
        let box = TextBox(id: "body", rect: Rect(x: 20, y: 130, width: 100, height: 20), role: .body, text: Self.longBody)
        #expect(SpreadRenderer.textOverflows(box))
        let issues = try Self.issuesOfS1(Self.spread(texts: [box]))
        let overflow = issues.filter { $0.id == "textOverflow:s1:body" }
        #expect(overflow.count == 1)
        #expect(overflow.first?.severity == .warning)
        #expect(overflow.first?.textID == "body")
        #expect(overflow.first?.frameID == nil)
        #expect(overflow.first?.message == "Text se nevejde do rámečku, konec se nevytiskne")
    }

    @Test func shortOrEmptyTextDoesNotWarn() throws {
        for text in ["Krátký text", "", "   \n ", "Dva řádky\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"] {
            let box = TextBox(id: "body", rect: Rect(x: 20, y: 130, width: 100, height: 20), role: .body, text: text)
            #expect(!SpreadRenderer.textOverflows(box), "\(text)")
            let issues = try Self.issuesOfS1(Self.spread(texts: [box]))
            #expect(!issues.contains { $0.id.hasPrefix("textOverflow") }, "\(text)")
        }
    }

    @Test func overflowIsSkippedWithoutFonts() throws {
        let box = TextBox(id: "body", rect: Rect(x: 20, y: 130, width: 100, height: 20), role: .body, text: Self.longBody)
        let (p, f) = try Self.setup()
        let album = Self.album(spreads: [Self.spread(texts: [box]), Self.spread("s2")], cover: Self.cover())
        #expect(Preflight.check(album: album, profile: p, format: f, fontsAvailable: true)
            .contains { $0.id == "textOverflow:s1:body" })
        #expect(!Preflight.check(album: album, profile: p, format: f, fontsAvailable: false)
            .contains { $0.id.hasPrefix("textOverflow") })
    }

    @Test func textIssuesCarryTheTextID() throws {
        let box = TextBox(id: "cap", rect: Rect(x: 1, y: 130, width: 100, height: 20), role: .caption, text: "Popisek")
        let issues = try Self.issuesOfS1(Self.spread(texts: [box]))
        #expect(issues.map(\.id) == ["textSafe:s1:cap"])
        #expect(issues.first?.textID == "cap")
    }

    // MARK: Photo used twice

    static func duplicateIssues(_ issues: [PreflightIssue]) -> [PreflightIssue] {
        issues.filter { $0.id.hasPrefix("duplicatePhoto") }
    }

    @Test func duplicateInTwoDaySpreadsWarnsOnSecond() throws {
        // The first occurrence is on the second spread of the album (after an intro).
        let intro = Self.spread("s0", kind: .intro, frames: [Self.frame(photo: nil)])
        let first = Self.spread("s1", frames: [Self.frame("f1", photo: "p1")])
        let second = Self.spread("s2", kind: .journal, frames: [Self.frame("f9", photo: "p1")],
                                 texts: [Self.body("Text")])
        let issues = Self.duplicateIssues(try Self.check(Self.album(spreads: [intro, first, second],
                                                                     cover: Self.cover(photo: "p1"))))
        #expect(issues.count == 1)
        #expect(issues[0].id == "duplicatePhoto:s2:f9")
        #expect(issues[0].severity == .warning)
        #expect(issues[0].spreadID == "s2")
        #expect(issues[0].frameID == "f9")
        #expect(issues[0].message == "Fotka je v knize víckrát (poprvé na dvoustraně 2)")
    }

    @Test func duplicateInSameSpreadWarns() throws {
        let s1 = Self.spread("s1", frames: [Self.frame("f1", photo: "p1"),
                                            Self.frame("f2", Rect(x: 200, y: 20, width: 150, height: 100), photo: "p1"),
                                            Self.frame("f3", Rect(x: 400, y: 20, width: 150, height: 100), photo: "p1")])
        let issues = Self.duplicateIssues(try Self.check(Self.album(spreads: [s1], cover: Self.cover())))
        #expect(issues.map(\.id) == ["duplicatePhoto:s1:f2", "duplicatePhoto:s1:f3"])
        #expect(issues.allSatisfy { $0.message == "Fotka je v knize víckrát (poprvé na dvoustraně 1)" })
    }

    @Test func introRepeatOfDayPhotoIsNotDuplicate() throws {
        let intro = Self.spread("s0", kind: .intro, frames: [Self.frame("f1", photo: "p1")])
        let day = Self.spread("s1", frames: [Self.frame("f1", photo: "p1")])
        let closing = Self.spread("s2", kind: .closing, frames: [Self.frame("f1", photo: "p1")])
        let issues = try Self.check(Self.album(spreads: [intro, day, closing], cover: Self.cover()))
        #expect(Self.duplicateIssues(issues).isEmpty)
    }

    @Test func coverRepeatIsNotDuplicate() throws {
        let issues = try Self.check(Self.album(spreads: [Self.spread("s1"), Self.spread("s2", frames: [Self.frame(photo: nil)])],
                                               cover: Self.cover(photo: "p1")))
        #expect(Self.duplicateIssues(issues).isEmpty)
    }

    @Test func duplicateIsWarningNotError() throws {
        let issues = try Self.check(Self.album(spreads: [Self.spread("s1"), Self.spread("s2")], cover: Self.cover()))
        #expect(issues.map(\.id) == ["duplicatePhoto:s2:f1"])
        #expect(!Preflight.hasErrors(issues))
    }

    @Test func duplicateComesAfterOtherIssuesOfTheFrame() throws {
        let small = Self.photo("p1", w: 2048, h: 1536)
        let big = Rect(x: 0, y: 0, width: 297, height: 210)
        let a = Self.album(spreads: [Self.spread("s1", frames: [Self.frame("f1", big)]),
                                     Self.spread("s2", frames: [Self.frame("f1", big)])],
                           photos: [small], cover: Self.cover())
        let ids = try Self.check(a).map(\.id).filter { $0.hasSuffix(":s2:f1") }
        #expect(ids == ["dpi:s2:f1", "duplicatePhoto:s2:f1"])
    }
}
