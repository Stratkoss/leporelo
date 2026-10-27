# Úvodní obrazovka, duplicitní fotky a volné rozložení: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Úvodní okno ve stylu Fotek s alby z iCloudu, upozornění místo tichého přesunu u fotky, která už v knize je, a volně posouvatelné rámečky a texty s mřížkou, přichytáváním a závazným okrajem stránky.

**Architecture:** Čistá logika v `LeporeloCore`: pravidlo okraje (`MarginRule`), přichytávání (`SnapEngine`), úpravy rozložení v `TemplateLayout` a `AlbumUpdater` a nové varování v `Preflight`. V aplikaci rozšíření `EditorModel` (relace rozložení jako u výřezu, rozhodnutí o duplicitě), interakce v `SpreadCanvasNSView` a nové úvodní okno (`Start/`), které nahrazuje okno „Nové album“ a znovu používá `NewAlbumModel`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI + AppKit, PhotoKit, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-start-a-volne-rozlozeni-design.md` (doplněk k `docs/superpowers/specs/2026-10-26-album-app-design.md`)

## Global Constraints

- macOS 15+, Swift 6 language mode, všechny modelové typy `Sendable`, `Codable`, `Equatable`.
- Před každým `swift`/`xcodebuild` příkazem `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (cíle v `Makefile` to dělají).
- Rozměry v modelu v **milimetrech** (`Double`). Souřadnice dvoustrany: počátek vlevo nahoře, šířka 2 × šířka strany, bez spadávky. Obálka: souřadnice jedné strany.
- Okraj: výchozí **10 mm**, minimum `profile.safeMM` (Canva 6 mm), maximum **30 mm**. Mřížka **5 mm**, mezera pro přichytávání **4 mm**, práh přichytávání **8 bodů** obrazovky, minimální rozměr rámečku a textu **10 mm**.
- Texty UI česky, sentence case, bez vykřičníků. Přesné texty: „Tahle fotka už v knize je“, „Dát i sem“, „Přesunout sem“, „Zrušit“, „Fotka je v knize víckrát“, „Doporučená rozložení“, „Ruční rozložení se nahradí doporučeným.“, „Nahradit“, „Mřížka“, „Přichytávat“, „Okraj“, „Přidat rámeček“, „Přidat text“, „Smazat“, „Odebrat fotku“, „Upravit výřez“, „Obnovit výřez“, „Moje knihy“, „Alba v iCloudu“, „Jinak“, „Podle data…“, „Udělat z toho knihu“.
- Každá uživatelská úprava je jeden krok zpět (undo) přes `AlbumStore.apply`/`replace`, s českým názvem akce.
- Commit po každém úkolu, zprávy anglicky (`feat:`/`fix:`/`test:`/`docs:`), zakončené řádkem `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Nic z `.superpowers/` se necommituje.

## Review Focus

1. **Starý soubor `.leporelo` bez nových klíčů** (`marginMM`, `customLayout`) se musí otevřít s výchozími hodnotami (10 mm, false). Test v Úkolu 1.
2. **Zvětšení okraje u malého rámečku v rohu** (např. 12 × 12 mm u hrany, okraj 30 mm) nesmí rámeček zmenšit pod 10 mm ani ho vystrčit ze stránky. Test v Úkolu 1.
3. **⌘Z uprostřed tažení rámečku** uloží rozpracované tažení jako vlastní krok a vrátí jen ten krok, ne krok před ním (stejně jako dnes u výřezu). Test v Úkolu 6.
4. **Fotka z úvodu nebo z obálky přetažená na dvoustranu dne** se musí taky zeptat, ne ji potichu odebrat odjinud. Test v Úkolu 5.
5. **Změna formátu u ručně upravené dvoustrany** zachová všechny fotky, výřezy a texty, jen rozložení úměrně přepočítá. Test v Úkolu 3.

---

## Struktura souborů

```
Sources/LeporeloCore/
  Model/Album.swift              (upravit: marginMM, dekódování bez klíče)
  Model/Spread.swift             (upravit: customLayout, dekódování bez klíče)
  Layout/MarginRule.swift        (nový: pravidlo okraje)
  Layout/SnapEngine.swift        (nový: cíle a výpočet přichycení)
  Layout/Templates.swift         (upravit: instantiate uplatní okraj)
  Layout/AlbumDrafter.swift      (upravit: předává album.marginMM)
  Layout/AlbumUpdater.swift      (upravit: settingMargin, changeFormat pro ruční rozložení)
  Export/Preflight.swift         (upravit: duplicatePhoto)
Tests/LeporeloCoreTests/
  MarginRuleTests.swift, SnapEngineTests.swift (nové)
  AlbumUpdaterTests.swift, TemplatesTests.swift, PreflightTests.swift, ModelTests.swift (doplnit)
App/Leporelo/Sources/
  Editor/EditorModel.swift       (upravit: duplicity, relace rozložení, přidat/smazat, okraj, šablona)
  Editor/EditorLogic.swift       (upravit: LayoutHandles, LayoutDrag)
  Editor/SpreadCanvasView.swift  (upravit: úchyty, tažení, mřížka, vodítka, režim výřezu, menu, alert)
  Editor/EditorView.swift        (upravit: přepínače Mřížka/Přichytávat/Okraj)
  Editor/TemplatePicker.swift    (upravit: název, potvrzení náhrady ručního rozložení)
  Start/StartModel.swift, StartView.swift, StartPhotoGrid.swift, CreateBookSheet.swift (nové)
  NewAlbum/NewAlbumSheet.swift   (upravit: z okna jen formulář + vytvoření, znovu použité v CreateBookSheet)
  LeporeloApp.swift              (upravit: okno „Leporelo“ místo „Nové album“)
App/LeporeloTests/
  EditorModelTests.swift, EditorLogicTests.swift (doplnit), StartModelTests.swift (nový)
README.md, docs/manual-verification.md (doplnit)
```

---

### Task 1: Okraj v modelu a pravidlo okraje

**Files:**
- Modify: `Sources/LeporeloCore/Model/Album.swift`, `Sources/LeporeloCore/Model/Spread.swift`
- Create: `Sources/LeporeloCore/Layout/MarginRule.swift`
- Test: `Tests/LeporeloCoreTests/MarginRuleTests.swift`, `Tests/LeporeloCoreTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `Album.marginMM: Double` (memberwise init parametr `marginMM: Double = Album.defaultMarginMM` na konci), `public static let defaultMarginMM = 10.0`.
  - `Spread.customLayout: Bool` (init parametr `customLayout: Bool = false` na konci). Pravda, jakmile uživatel rozložení dvoustrany ručně změnil (posun, velikost, přidání, smazání).
  - Obojí s vlastním `init(from:)` přes `decodeIfPresent` s výchozí hodnotou; kódování zůstává syntetizované (klíče `marginMM`, `customLayout`). `formatVersion` se nemění.
  - `public struct MarginRule: Sendable { public init(geometry: PageGeometry, marginMM: Double); public static let maxMarginMM = 30.0; public static let minItemMM = 10.0; public static func clampedMargin(_ mm: Double, profile: SupplierProfile) -> Double; public func pageEdgesX(_ area: PrintArea) -> [Double]; public func conformFrame(_ rect: Rect, area: PrintArea) -> Rect; public func conformText(_ rect: Rect, area: PrintArea) -> Rect; public func conform(_ spread: Spread, area: PrintArea) -> Spread }`
  - `area`: `.spread` a `.page` znamenají dvoustranu (hrany stránek x = 0, w, 2w; hřbet je hrana stránky pro obě strany), `.cover` jednu stranu (x = 0, w). Hrany y vždy 0 a výška strany.

Algoritmus `conformFrame` (testy ho neurčují úplně):
1. Ořízni obdélník do ořezu plochy (0…šířka, 0…výška) a zvětši na nejméně `minItemMM` v každém rozměru (posunem dovnitř).
2. Pro každou svislou hranu najdi nejbližší hranu stránky `e`. Je-li `0 < |v − e| < m`: při `|v − e| < m/2` nastav `v = e`, jinak `v = e ± m` (na stranu, kde hrana ležela). Stejně pro vodorovné hrany s hranami 0 a výška.
3. Je-li po kroku 2 rozměr na některé ose menší než `minItemMM`, dostane rámeček na té ose rozsah od hrany stránky `e` nejbližší původnímu středu po `e + max(m, minItemMM)` směrem dovnitř stránky (rámeček do spadávky, žádná hrana v pásu).

`conformText`: obdélník se vejde do `pageRect(side:).insetBy(m)` stránky, na které leží jeho střed (u obálky jediná stránka). Posun dovnitř, a když je větší než ten box, zmenší se na něj.

`conform(_ spread:area:)` uplatní `conformFrame` na všechny rámečky a `conformText` na všechny texty; fotky, výřezy, texty a příznaky nemění.

- [ ] **Step 1: Napsat padající testy** (formát `landscape-a4` profilu `canva-photobook`, stránka 297 × 210, okraj 10):
  - `frameEdgeInBandSnapsToNearerSide`: `x 4…100` → `minX == 0`; `x 7…100` → `minX == 10`.
  - `frameOnPageEdgeAndSpineStays`: `x 297…594, y 0…210` beze změny; `x 0…297` beze změny.
  - `frameNearSpineSnaps`: `maxX 290` → `287`; `maxX 295` → `297`; `minX 300` → `297`; `minX 305` → `307`.
  - `textIsClampedInsideMargin`: text `x 2…60, y 200…209` na levé stránce → `minX == 10`, `maxY == 200`.
  - `tinyFrameInCornerKeepsMinimumSize` (Review Focus 2): okraj 30, rámeček `x 2…14, y 2…14` → šířka i výška ≥ 10, celý v `0…297 × 0…210`, žádná hrana v pásu (0, 30).
  - `marginIsClampedToSafeZoneAndMaximum`: `clampedMargin(2) == 6`, `clampedMargin(50) == 30`, `clampedMargin(12) == 12`.
  - V `ModelTests`: `albumWithoutNewKeysDecodesWithDefaults` (Review Focus 1): JSON alba a dvoustrany bez `marginMM`/`customLayout` přes `AlbumCoding.decoder()` → `10` a `false`; zakódování a znovu dekódování zachová hodnoty `14` a `true`.
- [ ] **Step 2: Spustit** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MarginRuleTests|ModelTests"` → FAIL (chybí typy a pole).
- [ ] **Step 3: Implementovat** pole, dekódování a `MarginRule`.
- [ ] **Step 4: Spustit** stejný příkaz a pak `make test` → PASS.
- [ ] **Step 5: Commit** `feat: page margin rule and layout flags`.

### Task 2: Přichytávání

**Files:**
- Create: `Sources/LeporeloCore/Layout/SnapEngine.swift`
- Test: `Tests/LeporeloCoreTests/SnapEngineTests.swift`

**Interfaces:**
- Consumes: `MarginRule.pageEdgesX` (Task 1).
- Produces:
  - `public struct SnapSettings: Sendable, Equatable { public var grid: Bool; public var objects: Bool; public var gridMM: Double = 5; public var gapMM: Double = 4 }`
  - `public struct RectEdges: OptionSet, Sendable { minX, maxX, minY, maxY; public static let all }`
  - `public enum SnapAxis: Sendable { case x, y }`; `public struct SnapGuide: Sendable, Equatable { public var axis: SnapAxis; public var position: Double }` (axis `.x` = svislá čára na x)
  - `public struct SnapTargets: Sendable, Equatable { public var x: [Double]; public var y: [Double] }`
  - `public struct SnapResult: Sendable, Equatable { public var rect: Rect; public var guides: [SnapGuide] }`
  - `public enum SnapEngine { public static func targets(geometry: PageGeometry, marginMM: Double, area: PrintArea, others: [Rect], settings: SnapSettings) -> SnapTargets; public static func snap(_ rect: Rect, moving edges: RectEdges, to targets: SnapTargets, threshold: Double) -> SnapResult }`

Cíle: se `settings.objects` hrany stránek, čáry okraje (hrana stránky ± okraj, jen dovnitř stránky), středy stránek, a z `others` jejich min/mid/max a min − mezera, max + mezera. Se `settings.grid` čáry po `gridMM` od levé horní hrany každé stránky. Obě vypnuté = žádné cíle.
`snap`: při `edges == .all` (posun) se na každé ose vybere z min/mid/max obdélníku ten s nejmenší vzdáleností k cíli ≤ `threshold` a celý obdélník se posune; jinak (změna velikosti) se každá hrana v `edges` přichytí samostatně. Jeden vodicí řádek na každou přichycenou osu nebo hranu. Shoda vzdáleností: menší pozice cíle.

- [ ] **Step 1: Padající testy:** `moveSnapsLeftEdgeToMargin` (minX 11.5, práh 2 → 10, guide x 10), `moveSnapsCenterToPageCenter` (střed 150 → 148.5), `noSnapBeyondThreshold`, `resizeSnapsOnlyMovingEdge` (edges `.maxX`, minX se nezmění ani když je u cíle), `gridTargetsOnlyWhenGridOn` (x 5 a 302 v cílech jen s gridem), `gapTargetsBesideOtherFrames` (other `x 100…150` → cíle 96 a 154), `noTargetsWhenBothOff`.
- [ ] **Step 2:** `swift test --filter SnapEngineTests` → FAIL.
- [ ] **Step 3: Implementovat.**
- [ ] **Step 4:** stejný příkaz → PASS.
- [ ] **Step 5: Commit** `feat: snapping targets and snap computation`.

### Task 3: Okraj v šablonách, změna okraje a formátu

**Files:**
- Modify: `Sources/LeporeloCore/Layout/Templates.swift`, `AlbumDrafter.swift`, `AlbumUpdater.swift`
- Test: `Tests/LeporeloCoreTests/TemplatesTests.swift`, `RetemplateTests.swift`, `AlbumUpdaterTests.swift`, `AlbumDrafterTests.swift`

**Interfaces:**
- Consumes: `MarginRule` (Task 1).
- Produces:
  - `TemplateLayout.instantiate(_:geometry:dayKey:id:marginMM: Double = Album.defaultMarginMM)`: výsledek prošlý `MarginRule.conform(_, area: .spread)`.
  - `TemplateLayout.retemplate(_:to:geometry:photos:marginMM:)` (stejný výchozí parametr); výsledek má `customLayout = false`.
  - `AlbumDrafter.cover` a drafter používají `album.marginMM`; obálka se uplatní s `area: .cover`.
  - `AlbumUpdater.settingMargin(_ mm: Double, in album: Album, profile: SupplierProfile, format: BookFormat) -> Album`: `marginMM = MarginRule.clampedMargin(mm, profile:)`, pak conform všech dvoustran a obou stran obálky. `manuallyEdited`/`customLayout` nemění.
  - `AlbumUpdater.changeFormat`: dvoustrany s `customLayout == true` se NEpřeinstancují; rámečky a texty se úměrně přepočítají (`x · nováŠířka/stará`, `y · nováVýška/stará`), fotky, výřezy a texty zůstanou, pak conform. Ostatní jako dnes, s `album.marginMM`. Ostatní volání `instantiate` v `AlbumUpdater` předávají `album.marginMM`.

- [ ] **Step 1: Padající testy:**
  - `instantiateConformsTemplateToMargin`: formát `landscape-8x6in` (203.2 × 152.4), šablona `journal-3`, okraj 10 → žádná hrana rámečku ani textu v pásu (0, 10) od hran stránek; `gallery-1` rámeček zůstane `x 203.2…406.4, y 0…152.4`.
  - `retemplateClearsCustomLayout`.
  - `settingMarginConformsAllSpreadsAndCover`: okraj 25 → žádná hrana v pásu (0, 25); `marginMM == 25`; `settingMargin(3)` → `marginMM == 6`.
  - `changeFormatScalesCustomLayout` (Review Focus 5): ručně posunutý rámeček s fotkou, výřezem `(0.3, -0.2)`, zoom 1.5 a textem „Ahoj“ na `landscape-a4` → `square-21`: x přepočítané poměrem 420/594, y 210/210, fotka, výřez, zoom a text stejné, `customLayout` zůstane true.
  - `changeFormatRelaysTemplateSpreads`: dvoustrana bez `customLayout` má po změně rámečky shodné s `instantiate` nového formátu.
- [ ] **Step 2:** `make test` → nové testy FAIL.
- [ ] **Step 3: Implementovat.** Existující testy, které porovnávají přesné obdélníky šablon, upravit na hodnoty po conform a v commitu napsat proč.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5: Commit** `feat: enforce the page margin in templates, margin and format changes`.

### Task 4: Varování o fotce v knize víckrát

**Files:**
- Modify: `Sources/LeporeloCore/Export/Preflight.swift`
- Test: `Tests/LeporeloCoreTests/PreflightTests.swift`

**Interfaces:**
- Produces: issue `id "duplicatePhoto:<spreadID>:<frameID>"`, `.warning`, `message "Fotka je v knize víckrát (poprvé na dvoustraně N)"`, kde N je pořadí první dvoustrany s tou fotkou v `album.spreads` od 1. Počítají se jen rámečky dvoustran `.journal` a `.gallery` v pořadí alba a v pořadí rámečků; varování dostane každý výskyt kromě prvního. V pořadí výsledku je u rámečku za `original`, DPI a obličeji.

- [ ] **Step 1: Padající testy:** `duplicateInTwoDaySpreadsWarnsOnSecond` (jeden issue, na druhém výskytu, zpráva s „dvoustraně 2“, když první je druhá v pořadí), `duplicateInSameSpreadWarns`, `introRepeatOfDayPhotoIsNotDuplicate`, `coverRepeatIsNotDuplicate`, `duplicateIsWarningNotError` (`Preflight.hasErrors` false, když je to jediný problém).
- [ ] **Step 2:** `swift test --filter PreflightTests` → FAIL.
- [ ] **Step 3: Implementovat.**
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5: Commit** `feat: warn about a photo used twice`.

### Task 5: Přetažení fotky, která už v knize je

**Files:**
- Modify: `App/Leporelo/Sources/Editor/EditorModel.swift`, `App/Leporelo/Sources/Editor/SpreadCanvasView.swift`
- Test: `App/LeporeloTests/EditorModelTests.swift`

**Interfaces:**
- Produces:
  - `enum DuplicatePolicy: Equatable { case ask, keepBoth, move }`
  - `enum DropOutcome: Equatable { case placed; case needsDuplicateDecision(locations: [String]); case rejected }`
  - `@discardableResult func dropPhoto(_ id: PhotoID, onFrame frameID: String, in spreadID: String? = nil, duplicates: DuplicatePolicy = .ask) -> DropOutcome` (nahrazuje dnešní `-> Bool`; dnešní podmínky pro `false` vrací `.rejected`).
  - `func placementLabels(of id: PhotoID, excludingSpread spreadID: String) -> [String]`: „dvoustrana N“ (N = index v `album.spreads` + 1, pořadí alba), „obálka“ (přední nebo zadní strana, jednou).

Chování: ve stejné dvoustraně prohození jako dnes (bez dotazu). Fotka v jiném rámečku jiné dvoustrany nebo obálky: `.ask` → `.needsDuplicateDecision` a nic se nezmění; `.keepBoth` → vloží, ostatní výskyty zůstanou, krok „Vložit fotku“; `.move` → vloží a vyprázdní VŠECHNY ostatní výskyty (dvoustrany všech typů i obálka, výřez se resetuje), jeden krok „Přesunout fotku“. Dnešní výjimka pro úvod, závěr a obálku zmizí.

Canvas: `performDragOperation` při `.needsDuplicateDecision` ukáže `NSAlert` jako sheet okna: `messageText "Tahle fotka už v knize je"`, `informativeText "Je na: dvoustrana 5, obálka."`, tlačítka v pořadí „Dát i sem“ (výchozí), „Přesunout sem“, „Zrušit“. Podle volby zavolá `dropPhoto` znovu s `.keepBoth`/`.move`. Drop vrací `true`, protože rozhodnutí přijde asynchronně.

- [ ] **Step 1: Padající testy:** `dropOfPhotoPlacedElsewhereAsksAndChangesNothing` (revision se nezmění, locations `["dvoustrana 3"]`), `dropKeepBothLeavesOtherFrame`, `dropMoveClearsOtherFramesAsOneUndoStep` (jedno undo vrátí obojí), `dropFromIntroOntoDaySpreadAsks` (Review Focus 4), `dropOfCoverPhotoListsObalka`, `dropWithinSameSpreadStillSwaps`. Existující testy, které počítají s tichým přesunem, přepsat na `.move`.
- [ ] **Step 2:** `make test-app` → nové testy FAIL.
- [ ] **Step 3: Implementovat** model a alert.
- [ ] **Step 4:** `make test-app` → PASS; `make build-app` projde.
- [ ] **Step 5: Commit** `feat: ask before placing a photo that is already in the book`.

### Task 6: Úpravy rozložení v modelu editoru

**Files:**
- Modify: `App/Leporelo/Sources/Editor/EditorModel.swift`, `App/Leporelo/Sources/Editor/TemplatePicker.swift`
- Test: `App/LeporeloTests/EditorModelTests.swift`

**Interfaces:**
- Consumes: `MarginRule`, `AlbumUpdater.settingMargin`, `Spread.customLayout` (Tasks 1, 3).
- Produces:
  - `enum LayoutItem: Hashable { case frame(String), text(String) }`
  - `var selectedItem: LayoutItem?`; dnešní `selectedFrameID` zůstává jako vypočtená vlastnost nad `selectedItem` (get: id rámečku nebo nil; set: `.frame(id)` nebo nil), aby stávající volání fungovala.
  - Relace rozložení (vzor `TransformSession`, stejná pravidla pro `commitSessions`, `asOwnStep`, `displayedSpread`, `hasPendingSession`, `pendingSessionActionName`): `func beginLayoutChange(_ item: LayoutItem, in spreadID: String? = nil)`, `func updateLayout(_ item: LayoutItem, rect: Rect)` (model uplatní `conformFrame`/`conformText` s `area: .spread` a `album.marginMM`), `func endLayoutChange()` → jeden krok „Upravit rozložení“ přes `.replaceSpread`, s `manuallyEdited = true`, `customLayout = true`.
  - `@discardableResult func addFrame(on side: PageSide, in spreadID: String? = nil) -> String?`: id `frame-N` (nejmenší volné N), obdélník na středu stránky o polovině šířky a výšky stránky, conform, vybere ho, krok „Přidat rámeček“.
  - `@discardableResult func addText(on side: PageSide, in spreadID: String? = nil) -> String?`: id `text-N`, role `.caption`, 60 × 12 mm, vodorovně na středu, spodní hrana na `výška − okraj`, krok „Přidat text“.
  - `@discardableResult func deleteItem(_ item: LayoutItem, in spreadID: String? = nil) -> Bool`: rámeček (i s fotkou: fotka zůstane vybraná, ale neumístěná) nebo text, krok „Smazat“.
  - `var marginMM: Double { store.album.marginMM }`; `func setMargin(_ mm: Double)`: `store.replace(album: AlbumUpdater.settingMargin(...), actionName: "Změnit okraj", ...)`; nic, pokud se hodnota po oříznutí nemění.
  - `TemplateChangeOutcome.needsLayoutReplaceConfirmation`; `changeTemplate(to:in:confirmTextLoss:confirmLayoutReplace: Bool = false)`: u `customLayout == true` bez potvrzení vrátí nejdřív tohle, pak teprve kontrola textů. `TemplatePicker`: nadpis „Doporučená rozložení“, alert „Ruční rozložení se nahradí doporučeným.“ s „Nahradit“ / „Zrušit“.
  - Všechny nové úpravy volají `commitSessions()` na začátku, jako stávající.

- [ ] **Step 1: Padající testy:** `layoutSessionIsOneUndoStep`, `layoutChangeConformsToMargin` (posun do pásu okraje skončí na okraji), `layoutChangeMarksSpreadCustomAndManual`, `undoDuringLayoutSessionCommitsThenUndoesOnlyIt` (Review Focus 3), `addFrameIsCenteredConformedAndSelected`, `addFrameIdsAreUnique`, `deleteEmptyFrameRemovesIt`, `deleteFrameWithPhotoLeavesPhotoUnplaced`, `deleteTextRemovesIt`, `setMarginIsOneUndoStepAndConforms`, `changeTemplateOnCustomLayoutAsksFirst`, `selectedFrameIDMirrorsSelectedItem`.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3: Implementovat.**
- [ ] **Step 4:** `make test-app` → PASS.
- [ ] **Step 5: Commit** `feat: free layout editing in the editor model`.

### Task 7: Interakce na plátně, mřížka, vodítka, přepínače

**Files:**
- Modify: `App/Leporelo/Sources/Editor/EditorLogic.swift`, `SpreadCanvasView.swift`, `EditorView.swift`, `README.md`, `docs/manual-verification.md`
- Test: `App/LeporeloTests/EditorLogicTests.swift`

**Interfaces:**
- Consumes: `SnapEngine` (Task 2), relace a akce z Task 6.
- Produces:
  - `enum LayoutHandles { static func hit(_ p: Point, rect: Rect, tolerance: Double) -> RectEdges? }`: rohy (dvě hrany) mají přednost před stranami; uvnitř mimo úchyty nil.
  - `enum LayoutDrag { static func rect(from start: Rect, edges: RectEdges, delta: Point, keepAspect: Bool, minSize: Double) -> Rect }`: `.all` = posun; jinak pohyb jen daných hran; `keepAspect` u rohu drží poměr start obdélníku (řídí větší z posunů); nikdy pod `minSize`, protější hrana stojí.
  - Canvas (`SpreadCanvasNSView`):
    - Vlastnosti `snapSettings: SnapSettings` a `showGrid: Bool` předané z `EditorView` přes `SpreadCanvasView`.
    - Klik vybere rámeček nebo text (`model.selectedItem`). Na vybraném se kreslí 8 úchytů (čtverečky 7 bodů v barvě akcentu).
    - Tažení: úchyt → změna velikosti, uvnitř → posun (práh 3 body jako dnes). Každá událost: `LayoutDrag.rect` → `SnapEngine.snap` (cíle z ostatních rámečků a textů dvoustrany, práh `8 / layout.scale` mm; s ⌘ bez přichycení) → `model.updateLayout`. Na konci `endLayoutChange`. Během tažení se kreslí vodítka (`SnapGuide`, 1 bod, akcent, přes celou dvoustranu).
    - Dvojklik na fotku: režim výřezu (`cropFrameID`); v něm tažení posouvá výřez dnešním kódem, rámeček má čárkovaný okraj v barvě akcentu. Esc, Return nebo klik mimo ho ukončí. Kolečko a sevření zoomují výřez i mimo režim, jako dnes. ⌥ + tažení beze změny. Dvojklik na text beze změny.
    - Šipky: mimo režim výřezu posun vybrané položky o 1 mm (⇧ 5 mm) jako jedna relace od keyDown po keyUp (vzor dnešní `arrowSession`); v režimu výřezu dnešní chování.
    - Delete: rámeček s fotkou → `clearFrame`; prázdný rámeček nebo text → `deleteItem`.
    - `menu(for:)`: „Přidat rámeček“, „Přidat text“ (na stránku pod kurzorem), „Smazat“, „Odebrat fotku“, „Upravit výřez“, „Obnovit výřez“ (jen ty, které dávají smysl pro položku pod kurzorem).
    - Mřížka (`showGrid`): čáry po 5 mm v ořezu každé stránky, `separatorColor` s nízkou průhledností, pod úchyty a vodítky.
    - Fotka se dál kreslí oříznutá na rámeček (renderer se nemění).
  - `EditorView` toolbar: `Toggle("Mřížka")` (`@AppStorage("editor.showGrid")`, výchozí false; řídí `showGrid` i `snapSettings.grid`), `Toggle("Přichytávat")` (`@AppStorage("editor.snapObjects")`, výchozí true), `Stepper("Okraj: \(Int(model.marginMM)) mm", ...)` v rozsahu `profile.safeMM…30` po 1 mm → `model.setMargin`. Přidat i tlačítka „Přidat rámeček“ a „Přidat text“ (na pravou stránku).
  - Nápověda pod plátnem (dnešní text) přepsat: „Tažením rámeček posunete, za rohy změníte velikost (⇧ drží poměr, ⌘ vypne přichytávání). Dvojklikem upravíte výřez fotky, s klávesou ⌥ fotku přetáhnete do jiného rámečku. Dvojklik na text ho upraví.“
- [ ] **Step 1: Padající testy** v `EditorLogicTests`: `handleHitCornersBeforeSides`, `handleMissInsideReturnsNil`, `moveTranslatesWholeRect`, `resizeMovesOnlyGivenEdges`, `cornerResizeKeepsAspectWithShift`, `resizeNeverBelowMinimum`.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3: Implementovat** logiku, plátno a toolbar.
- [ ] **Step 4:** `make test-app` → PASS, `make build-app` projde.
- [ ] **Step 5: Doplnit** `docs/manual-verification.md` o ruční průchod: posun a změna velikosti s mřížkou i bez, vodítka u okraje a středu, okraj 10 → 20 mm (rámečky se odsunou, ⌘Z vrátí), rámeček přetažený k hraně jde do spadávky, rámeček nejde nechat v pásu okraje, režim výřezu a Esc, ⌘Z uprostřed tažení. README: odstavec o editoru.
- [ ] **Step 6: Commit** `feat: move and resize frames with grid, snapping and margin`.

### Task 8: Úvodní okno ve stylu Fotek

**Files:**
- Create: `App/Leporelo/Sources/Start/StartModel.swift`, `StartView.swift`, `StartPhotoGrid.swift`, `CreateBookSheet.swift`, `App/LeporeloTests/StartModelTests.swift`
- Modify: `App/Leporelo/Sources/LeporeloApp.swift`, `App/Leporelo/Sources/NewAlbum/NewAlbumSheet.swift`, `App/Leporelo/Sources/AlbumWindow.swift` (místa, která dnes otevírají okno/list „Nové album“), `README.md`, `docs/manual-verification.md`

**Interfaces:**
- Consumes: `PhotoSource.albums()`, `photos(matching:)`, `thumbnail(for:maxPixel:)`; `NewAlbumModel` beze změny API kromě níže.
- Produces:
  - `enum StartItem: Hashable { case book(URL), album(String) /* SourceAlbum.identifier */, dateRange }`
  - `@MainActor @Observable final class StartModel { init(source: any PhotoSource, recentBooks: @escaping @MainActor () -> [URL], now: Date = Date(), calendar: Calendar = .current); private(set) var books: [URL]; private(set) var albums: [SourceAlbum]; var selection: StartItem?; var start: Date; var end: Date /* výchozí jako NewAlbumModel */; private(set) var photos: [SourcePhoto]; private(set) var accessProblem: String?; var selectedAlbum: SourceAlbum?; var query: SourceQuery?; func load() async; func loadPhotos() async /* zahodí výsledek pro mezitím změněný query */; func makeNewAlbumModel(profiles: [SupplierProfile]) -> NewAlbumModel? }`
  - `makeNewAlbumModel`: pro album `queryMode = .album`, `selectedAlbum`, `albums`, `title = album.name` (prázdný název → „Nové album“); pro `.dateRange` `queryMode = .dateRange`, `start`, `end`, výchozí název; pro knihu nebo nic nil.
  - `accessProblem`: `NewAlbumModel.errorMessage(for:)` chyby z `albums()`/`photos(matching:)`; při `notAuthorized` pravá strana ukáže dnešní výzvu z `PhotoAccess.swift`.
  - `NewAlbumSheet.swift`: vytváření (`create`, `choosePackageURL`, `openDocument`) vytáhnout do `struct AlbumCreation` nebo jiné sdílené funkce, kterou volá `CreateBookSheet`; `NewAlbumForm` dostane režim bez výběru zdroje (zdroj je daný z úvodu). Samostatné okno „Nové album“ zmizí.
  - `CreateBookSheet`: název, dodavatel (jen když je víc profilů), formát, upozornění (`sharedAlbumWarning`, `warning`, `unverifiedFormatNote`), počet fotek, „Založit“ → panel Uložit → vytvoření → otevření dokumentu → zavření úvodního okna (`dismissWindow(id: StartView.windowID)`).
  - `StartView` (`static let windowID = "start"`): `NavigationSplitView`; sidebar se sekcemi „Moje knihy“ (název souboru bez přípony; klik = `openDocument(at:)`), „Alba v iCloudu“ (název, počet, u sdíleného ikona `person.2` s tooltipem `NewAlbumModel.sharedAlbumMessage`), „Jinak“ → „Podle data…“. Detail: hlavička (název, „N fotek“, tlačítko „Udělat z toho knihu“), u data dva `DatePicker` („Od“, „Do“), pod tím `StartPhotoGrid`.
  - `StartPhotoGrid`: `LazyVGrid` s adaptivními buňkami kolem 110 bodů, náhled `thumbnail(maxPixel: 256)` načtený v `.task(id:)` buňky a zrušený při zmizení. Pokud album s 3 000 fotkami při scrollu drhne, přepnout na `NSCollectionView` jako v třídění a napsat to do commitu.
  - `LeporeloApp`: `Window("Leporelo", id: StartView.windowID) { StartView() }` s `.defaultLaunchBehavior(.presented)` místo okna „Nové album“; `FileCommands` ⌘N „Nové album…“ otevře úvodní okno; v menu Okno položka „Úvod“. Panel Otevřít při spuštění potlačit registrací `UserDefaults` `NSShowAppCentricOpenPanelInsteadOfUntitledFile = false` v `init()` (ověřit ručně; když nepomůže, najít jinou cestu a zapsat ji do commitu). `NSDocumentController.shared` číst jen ve view (`.task`), nikdy při stavbě scén a příkazů (viz komentář u `FileCommands`).
- [ ] **Step 1: Padající testy** (`FakePhotoSource`): `loadListsAlbumsAndBooks`, `selectingAlbumLoadsItsPhotos`, `staleAlbumPhotosAreDropped` (výběr změněný během načítání), `dateRangeQueryUsesWholeDays`, `newAlbumModelFromAlbumIsPreset` (název, režim, album), `newAlbumModelFromDateRange`, `newAlbumModelForBookIsNil`, `notAuthorizedSetsAccessProblem`.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3: Implementovat** model, view, sheet a změny aplikace. Testy `NewAlbumModelTests` musí dál projít.
- [ ] **Step 4:** `make test-app` → PASS, `make build-app` projde.
- [ ] **Step 5: Doplnit** `docs/manual-verification.md`: spuštění ukáže úvodní okno (žádný panel Otevřít), alba odpovídají Fotkám, mřížka alba se scrolluje plynule, sdílené album varuje, „Udělat z toho knihu“ založí a otevře knihu, ⌘N úvod znovu otevře, poslední knihy se otevřou klikem. README: „Nové album“ přepsat na úvodní okno.
- [ ] **Step 6: Commit** `feat: Photos-style start window with iCloud albums`.

---

## Self-review (provedeno při psaní)

- Pokrytí specu: úvodní okno (T8), dotaz u duplicity a varování (T5, T4), volné rozložení s úchyty, mřížkou a přichytáváním (T2, T6, T7), závazný okraj při tažení, šablonách, změně okraje a formátu (T1, T3, T6), „Doporučená rozložení“ a potvrzení (T6), fotka jen v rámečku (renderer beze změny, T7). Zásobník už umístěné fotky označuje, tam se nic nemění.
- Typy: `RectEdges`, `SnapSettings`, `SnapTargets` z T2 se v T7 používají se stejnými jmény; `LayoutItem` a `selectedItem` z T6 v T7; `DropOutcome` z T5 jen v canvasu.
- Review Focus: každá položka má test v uvedeném úkolu.
