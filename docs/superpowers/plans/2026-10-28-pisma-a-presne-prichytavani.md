# Písmo u textu, přesné přichytávání, kontrola lišty — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-text font/size/style with a Canva-like text bar, tiered snapping that prefers the other items, equal-spacing/equal-size hints with purple mm measurements, and a verified editor toolbar.

**Architecture:** Pure logic in `LeporeloCore` (snap tiers and anchored lines in `SnapEngine`, gaps/measurements in a new `SpacingGuides`, `TextStyle` on `TextBox`, style resolution in `SpreadRenderer`), tested with Swift Testing. The app (`App/Leporelo/Sources/Editor`) consumes it: `SpreadCanvasNSView` snaps and draws purple guides, `EditorModel` gets a text-style API, a new SwiftUI `TextToolsBar` sits above the canvas.

**Tech Stack:** Swift 6, SwiftPM (`make test`), SwiftUI + AppKit app via XcodeGen (`make test-app`, `make build-app`), Core Text, Swift Testing (`import Testing`, `@Test`, `#expect`) in the package, XCTest/Swift Testing as already used in `App/LeporeloTests`.

**Spec:** `docs/superpowers/specs/2026-10-28-pisma-a-presne-prichytavani-design.md`

## Global Constraints

- UI copy is Czech, exactly as the spec writes it (e.g. „Výchozí“, „Písmo „X“ v tomto Macu chybí“, „Změnit písmo“ as the undo name).
- All layout values are millimetres; displayed distances use one decimal and a decimal comma with a space and „mm“: `12,5 mm`.
- Snap guides, measurements and labels are purple, one colour: sRGB `#A020F0` (label text white). Selection, current page and crop mode stay `controlAccentColor`.
- Snap threshold stays 8 screen points; ⌘ disables snapping; ⇧ corner resize keeps the ratio and does not snap; arrows move 1 mm (⇧ 5 mm) and never snap.
- Text size range 6–200 pt, conversion `mm = pt * 25.4 / 72`.
- `MarginRule` keeps the last word: targets in a band are never offered; guides the conformed rect no longer touches are not drawn.
- Old books (no style) open unchanged; `TextBox.style` is optional and omitted from JSON when nil.
- No new third-party dependencies. Fonts added only from the same OFL families.
- Comment style and density match the surrounding code (doc comments in English, short, spec references like „spec 2.2“).

## Review Focus

1. A book saved with a text style is reopened, and an old book without the key is opened: both decode, nil style renders exactly as today. (Task 4 test `decodesTextBoxWithoutStyle`, `styleRoundTrips`.)
2. The user changes the font while the text overlay is open (double-click editing): typed text is kept, the style change is one undo step, the overlay shows the new font. (Task 6 test `styleChangeWhileEditingKeepsText`.)
3. An equal-spacing or equal-size target that falls inside the margin band is not offered, and a guide is not drawn after the margin rule moved the item. (Task 2 test `equalSpacingTargetInMarginBandIsDropped`.)
4. A text whose family is not installed: renders with the role's default font, no crash, preflight warns. (Task 5 test `missingFamilyFallsBackAndWarns`.)
5. A text enlarged past its box: the overflow warning uses the new size. (Task 5 test `overflowUsesStyleSize`.)

---

### Task 1: Toolbar check in the running app

Done by the controller in the main session (needs computer use), not a subagent.

**Files:**
- Modify: `docs/manual-verification.md` (new section „G. Lišta editoru (28. 10. 2026)“)
- Fixes: whatever files the failures point to, each with a test where one is possible (`App/LeporeloTests/EditorModelTests.swift`, `EditorLogicTests.swift`)

- [ ] **Step 1:** `make build-app` and `make run-app`; open or create a book with journal, gallery, intro and closing spreads.
- [ ] **Step 2:** Load `anthropic-skills:computer-use` and go through every row of the table in spec §4 (also on the cover, and with the window narrowed so items go to the overflow menu: each must keep a readable label). Note expected vs. actual.
- [ ] **Step 3:** For each failure: write a failing test when the cause is in model/logic code, fix, run `make test-app` (expected: all pass).
- [ ] **Step 4:** Write section G in `docs/manual-verification.md`: one line per item (item, expected, actual, fix or „OK“); items that could not be driven are listed as unchecked boxes for David with the note „neověřeno v aplikaci“.
- [ ] **Step 5:** Commit: `git commit -m "fix: editor toolbar issues found in the toolbar check"` (or `docs: toolbar check results` when nothing failed).

### Task 2: Tiered, anchored snap lines and spacing guides (core)

**Files:**
- Modify: `Sources/LeporeloCore/Layout/SnapEngine.swift`
- Modify: `Sources/LeporeloCore/Layout/MarginRule.swift` (`allowedTargets` keeps working on the new line type)
- Create: `Sources/LeporeloCore/Layout/SpacingGuides.swift`
- Test: `Tests/LeporeloCoreTests/SnapEngineTests.swift` (update existing tests to the new types), `Tests/LeporeloCoreTests/SpacingGuidesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SnapTier: Int, Sendable, Comparable { case items = 0, page = 1, grid = 2 }
  /// Which point of the moving rectangle a line may catch: `.any` for alignment lines,
  /// `.min`/`.max`/`.centre` for equal spacing and equal size.
  public enum SnapAnchor: Sendable, Equatable { case any, min, centre, max }
  public enum SnapReason: Sendable, Equatable { case alignment, equalSpacing, equalSize }
  public struct SnapLine: Sendable, Equatable { position: Double; tier: SnapTier; anchor: SnapAnchor; reason: SnapReason }
  public struct SnapTargets { var x: [SnapLine]; var y: [SnapLine] }          // replaces [Double]
  public struct SnapResult { var rect: Rect; var guides: [SnapGuide]; var reasons: [SnapAxis: SnapReason] }
  SnapEngine.targets(geometry:marginMM:area:others:settings:) -> SnapTargets      // items: edges+centres of others; page: trim, spine, margin lines, page centre, ±gapMM; grid
  SnapEngine.snap(_:moving:to:threshold:) -> SnapResult                          // signature unchanged
  SnapEngine.guides(_:touching:tolerance:)                                       // unchanged

  public struct Gap: Sendable, Equatable { var axis: SnapAxis; var from: Double; var to: Double; var at: Double; var isEqual: Bool }
  //   a distance to draw: along `axis` from `from` to `to`, at perpendicular position `at`
  public struct SizeMatch: Sendable, Equatable { var axis: SnapAxis; var rect: Rect; var length: Double }
  public enum SpacingGuides {
      static func spacingLines(for rect: Rect, moving edges: RectEdges, others: [Rect], page: Rect) -> SnapTargets
      static func sizeLines(for rect: Rect, moving edges: RectEdges, others: [Rect]) -> SnapTargets
      static func gaps(for rect: Rect, others: [Rect], page: Rect, tolerance: Double = 0.05) -> [Gap]
      static func sizeMatches(for rect: Rect, others: [Rect], tolerance: Double = 0.05) -> [SizeMatch]
  }
  ```
  `page` is the trim rect of the page the rect's centre lies on (`geometry.pageRect(side:)`); only `others` whose centre is on the same page count.

- [ ] **Step 1: Write failing tests in `SnapEngineTests`**
  - `neighbourEdgeBeatsCloserGridLine`: grid on, other `Rect(x: 20, y: 100, width: 3.3, height: 40)` (maxX 23.3); moving `Rect(x: 24.4, y: 30, width: 40, height: 30)`, threshold 4 → `rect.minX == 23.3`.
  - `neighbourEdgeBeatsCloserPageCentre`: other with maxX 147.0 on the left page (page centre 148.5); moving rect whose minX is 148.0, threshold 4 → `minX == 147.0`.
  - `gridUsedWhenNoItemOrPageLineInReach`: no others, grid on, minX 61.2, threshold 2 → `minX == 60`.
  - `edgeBeatsCentreOnTie`: an item line equidistant from the moving rect's centre and its maxX → the maxX snaps.
  - `anchoredLineOnlyCatchesItsPoint`: an `.min`-anchored line at 50 does not move a rect whose maxX is 50.2 and minX 10.
  - Existing tests updated to read `.position` from lines; behaviour for single-tier cases unchanged.
- [ ] **Step 2:** `make test` → the new tests fail (compile errors count).
- [ ] **Step 3:** Implement in `SnapEngine`: `snap` searches tiers in order and uses the first tier with a hit; inside a tier the nearest distance wins, ties: edge points (min/max) before the centre, then the smaller target. For a move, each axis tries points min/centre/max against lines whose anchor matches (`.any` matches all three). For a resize, the moved edge tries lines anchored `.any` or matching that edge. `reasons` records the winning line's reason per axis. `allowedTargets` filters lines by position as today.
- [ ] **Step 4: Write failing tests in `SpacingGuidesTests`** (A4 landscape spread, margin 10, page = left page trim 0…297 × 0…210)
  - `centresBetweenTwoNeighbours`: others x 10…60 and 160…210 (overlapping y), moving width 60 → a `.min` line at 80 with reason `.equalSpacing` (gaps 20 and 20).
  - `matchesAnExistingGap`: others A 10…60, B 70…120 (gap 10) and C 200…250 in one row; moving rect between B and C → `.min` line at 130 (gap 10 to B) and `.max` line at 190 (gap 10 to C).
  - `neighboursMustOverlapPerpendicular`: an other that does not overlap in y is not a neighbour in x.
  - `otherPageIgnored`: an item on the right page gives no lines.
  - `sizeLinesForResize`: other width 85; resizing maxX of a rect with minX 20 → `.max` line at 105 reason `.equalSize`; moving (`.all`) gives no size lines.
  - `gapsToNeighboursAndPageEdge`: rect with a neighbour on the left only → gaps left (to neighbour), right, top, bottom (to the page trim); `isEqual` true for the gap equal to another pair's gap within 0.05.
  - `equalSpacingTargetInMarginBandIsDropped`: a `.min` spacing line at x 4 (inside the 10 mm band) is removed by `MarginRule.allowedTargets`.
- [ ] **Step 5:** Implement `SpacingGuides` in the new file; `SnapEngine.targets` stays alignment-only, the caller merges spacing/size lines (tier `.items`).
- [ ] **Step 6:** `make test` → all pass.
- [ ] **Step 7:** Commit `feat: snap prefers the other items and offers equal spacing and sizes`.

### Task 3: Canvas uses the tiers and draws purple guides and distances

**Files:**
- Modify: `App/Leporelo/Sources/Editor/SpreadCanvasView.swift` (`snapped`, `drawGuides`, new `drawMeasurements`, arrow nudges)
- Modify: `App/Leporelo/Sources/Editor/EditorLogic.swift` (`EditorText.millimetres`, `SnapStyle.purple`)
- Test: `App/LeporeloTests/EditorLogicTests.swift`

**Interfaces:**
- Consumes: Task 2 (`SnapTargets`, `SnapLine`, `SnapResult.reasons`, `SpacingGuides.*`).
- Produces: `EditorText.millimetres(_ mm: Double) -> String` (`12.5 → "12,5 mm"`, `4 → "4,0 mm"`), `enum SnapStyle { static let purple: NSColor }` (sRGB A020F0).

- [ ] **Step 1: Failing tests:** `millimetresFormatsWithCommaAndOneDecimal` (12.5 → „12,5 mm“, 4 → „4,0 mm“, 0.04 → „0,0 mm“, 123.456 → „123,5 mm“); `sameEdgeSameViewX`: two rects with equal minX map to identical `CanvasLayout.viewRect(...).minX` at an awkward scale (view 913×611).
- [ ] **Step 2:** `make test-app` → fail.
- [ ] **Step 3:** Implement: `snapped(...)` merges `SnapEngine.targets` with `SpacingGuides.spacingLines` (move) or `sizeLines` (resize) for the other rects, filters with `allowedTargets`, keeps `snapGuides`; new state `measurements: (gaps: [Gap], sizes: [SizeMatch])` computed after `updateLayout` from the conformed rect (`itemRect`) — gaps always while snapping is active, sizes only when `reasons` contains `.equalSize`. `drawGuides` uses `SnapStyle.purple`. `drawMeasurements`: per gap a 1 pt purple line with 4 pt end ticks and a centred label (white 10 pt semibold system font, monospaced digits, on a purple rounded rect radius 3, padding 3×1.5 pt); size matches get a label centred on the rect's edge. Arrow nudges show the gaps of the nudged item and clear them 0.6 s after the last keyUp. Nothing drawn while ⌘ is held. Clear on mouse up and in `endGestures`.
- [ ] **Step 4:** `make test-app` → pass; `make build-app` → succeeds.
- [ ] **Step 5:** Visual check in the running app (controller, computer use): drag a photo next to another, verify it lands flush, purple guides and „x,x mm“ labels appear, equal gaps show equal labels; zoom a screenshot to check flush edges have no 1 px seam. Note the result for Task 8.
- [ ] **Step 6:** Commit `feat: purple snap guides with distances in millimetres`.

### Task 4: TextStyle on TextBox (core model)

**Files:**
- Modify: `Sources/LeporeloCore/Model/Spread.swift`, `Sources/LeporeloCore/Model/AlbumEdit.swift`
- Modify (carry style with the text): `Sources/LeporeloCore/Layout/Templates.swift:293`, `PageEditing.swift:148`, `AlbumUpdater.swift:472` and `:521`
- Test: `Tests/LeporeloCoreTests/ModelTests.swift`, `AlbumEditTests.swift`, `RetemplateTests.swift`, `PageEditingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum TextAlignment: String, Sendable, Codable, Equatable { case left, center, right }
  public struct TextStyle: Sendable, Codable, Equatable {
      public var fontFamily: String?      // nil = role default family
      public var sizePt: Double?          // nil = role default size; stored clamped to 6...200
      public var bold: Bool               // default false
      public var italic: Bool             // default false
      public var alignment: TextAlignment? // nil = role default (page number right on the right page)
      public var colorHex: String?        // "#RRGGBB" sRGB; nil = default near-black
      public init(fontFamily: String? = nil, sizePt: Double? = nil, bold: Bool = false, italic: Bool = false,
                  alignment: TextAlignment? = nil, colorHex: String? = nil)
      public static let sizeRangePt: ClosedRange<Double> = 6...200
  }
  // TextBox gains `public var style: TextStyle?` (init parameter `style: TextStyle? = nil`, last)
  // AlbumEdit gains `case setTextStyle(spreadID: String, textID: String, style: TextStyle?)`,
  // inverse `restoreSpread`; nil or a style equal to `TextStyle()` is stored as nil; sizePt clamped, NaN → nil.
  ```
- [ ] **Step 1: Failing tests:** `decodesTextBoxWithoutStyle` (JSON of today's TextBox → `style == nil`); `styleRoundTrips`; `nilStyleIsNotEncoded` (encoded JSON has no `"style"` key); `setTextStyleAndUndo` (apply, inverse restores the spread incl. `manuallyEdited`); `setTextStyleClampsSize` (300 → 200, 2 → 6, NaN → nil); `emptyStyleStoredAsNil`; `retemplateCarriesStyle` (Templates retemplate by role keeps style); `pageLayoutChangeCarriesStyle` (PageEditing and AlbumUpdater paths keep style with the text).
- [ ] **Step 2:** `make test` → fail.
- [ ] **Step 3:** Implement; at each carry-over site copy `.style` next to `.text`.
- [ ] **Step 4:** `make test` → pass.
- [ ] **Step 5:** Commit `feat: a text can carry its own font, size and style`.

### Task 5: Renderer resolves styles; italic book fonts; missing-font warning

**Files:**
- Add: `Sources/LeporeloCore/Resources/Fonts/Fraunces-Italic.ttf`, `SchibstedGrotesk-Italic.ttf` (variable TTFs from the google/fonts repo, `ofl/fraunces/Fraunces-Italic[SOFT,WONK,opsz,wght].ttf` and `ofl/schibstedgrotesk/SchibstedGrotesk-Italic[wght].ttf`, renamed; add their OFL.txt next to the existing licence files if any are kept there)
- Modify: `Sources/LeporeloCore/Render/FontRegistry.swift`, `Sources/LeporeloCore/Render/SpreadRenderer.swift`, `Sources/LeporeloCore/Export/Preflight.swift`
- Test: `Tests/LeporeloCoreTests/SpreadRendererTests.swift`, `PreflightTests.swift`

**Interfaces:**
- Consumes: Task 4 `TextStyle`.
- Produces:
  ```swift
  public struct ResolvedTextStyle: Sendable, Equatable {
      public var family: String; public var sizePt: Double; public var bold: Bool; public var italic: Bool
      public var alignment: TextAlignment; public var colorHex: String; public var isFallback: Bool
  }
  SpreadRenderer.resolvedStyle(for box: TextBox, pageWidth: Double?) -> ResolvedTextStyle
  //   pageWidth non-nil on a spread: page number defaults to .right on the right page; default colour "#1A1A1A"
  SpreadRenderer.ctFont(for style: ResolvedTextStyle) -> CTFont       // size in mm (sizePt * 25.4 / 72)
  FontRegistry.isFamilyAvailable(_ family: String) -> Bool
  FontRegistry.availableTraits(family: String) -> (bold: Bool, italic: Bool)
  FontRegistry.allFamilies() -> [String]   // book fonts first, then installed families A–Z, no duplicates
  ```
- [ ] **Step 1: Failing tests:** `defaultStyleMatchesRoleFont` (nil style → family/size as `font(for:)`, title ≈ 28.06 pt); `styleSizeAndFamilyApplied` ("Helvetica", 14 pt → CTFont family Helvetica, size 14·25.4/72 mm); `boldOfVariableBookFont` (Fraunces bold → `wght` variation 700 or bold trait present); `italicBookFontsResolve` (Fraunces and Schibsted Grotesk italic → `CTFontGetSymbolicTraits` contains `.traitItalic`); `alignmentAndColourApplied` (attributed text paragraph alignment center, colour #FF0000); `overflowUsesStyleSize` (text fits at default size, overflows at 60 pt); `missingFamilyFallsBackAndWarns` (family "NoSuchFont123" → `isFallback`, renderer uses the role font, Preflight issue id prefix `missingFont:`, message „Písmo „NoSuchFont123“ v tomto Macu chybí“, severity warning); `allFamiliesStartWithBookFonts`.
- [ ] **Step 2:** `make test` → fail.
- [ ] **Step 3:** Implement: register the four files; build fonts via `CTFontDescriptor` with family + symbolic traits; for a family with a `wght` axis set the variation (700 bold, default otherwise) instead of the trait; italic book fonts are their own registered families/styles — pick them by trait. `attributedText` and `textOverflows` use `resolvedStyle` + `ctFont`; `drawText` uses the resolved alignment and colour.
- [ ] **Step 4:** `make test` → pass (incl. `PDFExporterTests`).
- [ ] **Step 5:** Commit `feat: render each text with its own font, size, style and colour`.

### Task 6: EditorModel text-style API

**Files:**
- Modify: `App/Leporelo/Sources/Editor/EditorModel.swift`
- Test: `App/LeporeloTests/EditorModelTests.swift`

**Interfaces:**
- Consumes: Task 4 (`AlbumEdit.setTextStyle`), Task 5 (`resolvedStyle`).
- Produces:
  ```swift
  /// The text the canvas overlay edits (set by SpreadCanvasNSView when the overlay opens/closes).
  var overlayTextID: String?
  /// The text the text bar acts on: the overlay's text, else the selected text; nil on the cover.
  var activeTextID: String? { get }
  /// The effective style of `activeTextID` (nil when none).
  var activeTextStyle: ResolvedTextStyle? { get }
  /// One undo step "Změnit písmo": applies `change` to the active text's stored style (starting
  /// from `TextStyle()` when nil). A running text session is stored first and keeps going.
  func changeTextStyle(_ change: (inout TextStyle) -> Void)
  /// One undo step "Výchozí písmo": style back to nil.
  func resetTextStyle()
  ```
- [ ] **Step 1: Failing tests:** `activeTextIsSelectedOrOverlayText`; `noActiveTextOnCover`; `changeTextStyleIsOneUndoStep` (size 14 then undo → nil); `styleChangeWhileEditingKeepsText` (begin text editing, `updateText("Ahoj")`, `overlayTextID` set, `changeTextStyle { $0.bold = true }` → stored text „Ahoj“, bold true; one undo removes the bold only); `resetTextStyleStoresNil`.
- [ ] **Step 2:** `make test-app` → fail.
- [ ] **Step 3:** Implement; while a text session runs, store its text (`storeSessionText`) and apply the style as its own step without ending the session (the next keystroke amends or starts a step as today).
- [ ] **Step 4:** `make test-app` → pass.
- [ ] **Step 5:** Commit `feat: editor model changes the style of the active text`.

### Task 7: Text bar above the canvas; canvas shows styles

**Files:**
- Create: `App/Leporelo/Sources/Editor/TextToolsBar.swift`, `App/Leporelo/Sources/Editor/FontFamilyPicker.swift`
- Modify: `App/Leporelo/Sources/Editor/EditorView.swift` (bar above `issueBanner`, only when `model.activeTextID != nil`), `App/Leporelo/Sources/Editor/SpreadCanvasView.swift` (set `model.overlayTextID` in `beginTextOverlay`/`finishTextEditing`; overlay and placeholder use `SpreadRenderer.resolvedStyle` font, alignment, colour; `font(for:scale:)` takes the box), `App/Leporelo/Sources/Editor/EditorLogic.swift` (`TextBarPresets`)
- Test: `App/LeporeloTests/EditorLogicTests.swift`

**Interfaces:**
- Consumes: Task 6 API, Task 5 `FontRegistry.allFamilies/availableTraits`.
- Produces: `enum TextBarPresets { static let sizesPt: [Double] = [8, 9, 10, 11, 12, 14, 18, 24, 28, 36, 48, 72]; static let colours: [(name: String, hex: String)] }` with „Téměř černá“ #1A1A1A, „Bílá“ #FFFFFF, „Tmavě šedá“ #4A4A4A, „Terakota“ #B5543A, „Olivová“ #6B7046, „Modrošedá“ #4F6475, „Písková“ #C2A878; `FontFamilyFilter.matches(_ family: String, query: String) -> Bool` (case- and diacritics-insensitive substring).
- [ ] **Step 1: Failing tests:** `familyFilterIgnoresCaseAndDiacritics` („frau“ matches „Fraunces“, „GROTESK“ matches „Schibsted Grotesk“, „helvetica neue“ matches „Helvetica Neue“, „times“ does not match „Fraunces“, empty query matches everything); `sizePresetsInRange` (all within `TextStyle.sizeRangePt`).
- [ ] **Step 2:** `make test-app` → fail.
- [ ] **Step 3:** Implement the bar (left to right): family button opening a popover with a search field and a list of families each drawn in its own font (book fonts, divider, the rest); size `TextField` (pt, commits on Return/focus loss) + `Stepper` + presets menu; bold and italic toggles (`.keyboardShortcut("b")`, `("i")`, disabled when `availableTraits` lacks them); alignment segmented picker; colour swatches + `ColorPicker` „Jiná…“; „Výchozí“ button. All through `changeTextStyle`/`resetTextStyle`.
- [ ] **Step 4:** `make test-app` → pass; `make build-app` → succeeds.
- [ ] **Step 5:** Visual check (controller, computer use): select a text, change family/size/bold/italic/alignment/colour, double-click to edit (overlay matches), ⌘Z, export a PDF and compare.
- [ ] **Step 6:** Commit `feat: text bar with font, size, style, alignment and colour`.

### Task 8: Manual checklist and final verification

**Files:**
- Modify: `docs/manual-verification.md` (section G: add text bar and snapping checks, with results of the visual checks from Tasks 3 and 7)

- [ ] **Step 1:** `make test && make test-app` → all pass (paste the summary lines in the report).
- [ ] **Step 2:** Add checklist lines for what was not verified in the app.
- [ ] **Step 3:** Commit `docs: manual checks for the text bar and snapping`.
