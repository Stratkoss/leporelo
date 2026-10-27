# Rozložení po stránkách, „Zkusit jinak“, oblíbená rozložení: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatický návrh skládá knihu z jednostránkových rozložení (velké fotky do kraje, orientace sedí, nejlepší fotky přes celou stránku, střídání), editor umí „Zkusit jinak“ u jedné stránky a aplikace se jednou zeptá na oblíbená rozložení.

**Architecture:** V `LeporeloCore`:
- katalog jednostránkových rozložení (`PageLayoutCatalog`) a skládání dvoustrany ze dvou stránek (`PageSpread`), dvoustrana si pamatuje rozložení stránek v `Spread.pageLayouts`;
- plánovač stránek dne (`PagePlanner`), který používá `AlbumDrafter`;
- operace nad jednou stránkou (`PageEditing`) pro „Zkusit jinak“ a picker;
- `AlbumUpdater` se učí dvoustrany po stránkách.

V aplikaci:
- `EditorModel` dostane aktuální stránku a „Zkusit jinak“, picker nabízí rozložení stránek;
- nový modul `Layouts/` (předvolby, náhled stránky, výběr oblíbených) zapojený do „Udělat z toho knihu“ a do menu.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI + AppKit, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-rozlozeni-stranek-design.md` (doplněk k `2026-10-26-album-app-design.md` a `2026-10-27-start-a-volne-rozlozeni-design.md`)

## Global Constraints

- **Platforma a typy:** macOS 15+, Swift 6 language mode; všechny modelové typy `Sendable`, `Codable` (kde jsou v modelu), `Equatable`.
- **Build:** před každým `swift`/`xcodebuild` je potřeba `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Používej cíle `make test` (jádro) a `make test-app` (aplikace), ty to nastaví.
- **Rozměry:** v modelu v **milimetrech** (`Double`). Souřadnice dvoustrany mají počátek vlevo nahoře, šířka je 2 × šířka strany. Stránka 8×6 in = 203,2 × 152,4 mm.
- **Mezera mezi fotkami:** `PageLayoutCatalog.gutterMM = 3`.
- **Hrdinové:** delší strana ≥ `1800` px, skóre ≥ `0.6` a ≥ 85. percentil skóre vybraných fotek; za den nejvýš `max(1, n / 6)`.
- **Plánování:** okno `6` fotek, cíl hustoty `3` (při překročení maxima stran `4`, pak `5`).
- **Váhy:** nic neoznačeno → 1 všem; jinak označená 3, ostatní 1.
- **Hutná rozložení** (automatický výběr): `portraits-2`, `portrait-left-2l`, `portrait-right-2l`, `grid-4`, `mosaic-5`, `mosaic-6`. **Řídká** (jen záchrana): `framed-1`, `portrait-text`, `landscape-2`. **Opener:** `opener-portrait`, `opener-2l`, `opener-3`, `opener-text`. Dále `full` a `empty`.
- **Pořadí v katalogu** (rozhoduje při shodě): `full`, `framed-1`, `portrait-text`, `portraits-2`, `portrait-left-2l`, `portrait-right-2l`, `landscape-2`, `grid-4`, `mosaic-5`, `mosaic-6`, `opener-portrait`, `opener-2l`, `opener-3`, `opener-text`, `empty`.
- **Výběr oblíbených (9, v tomto pořadí):** `portraits-2`, `portrait-left-2l`, `portrait-right-2l`, `grid-4`, `mosaic-5`, `mosaic-6`, `opener-portrait`, `opener-2l`, `opener-3`.
- **Texty UI** česky, sentence case, bez vykřičníků. Přesně:
  - názvy rozložení z tabulky v oddílu 3 specu;
  - „Zkusit jinak“, „Klikni na stránku“, „Pro tyhle fotky jiné rozložení není“;
  - „Ruční rozložení se nahradí doporučeným.“, „Nahradit“;
  - „Která rozložení se ti líbí?“, „Nejlepší fotky dostanou celou stránku vždycky. Vyber, co se ti líbí dál – návrh je bude používat častěji.“;
  - „Přeskočit“, „Hotovo“, „Oblíbená rozložení…“.
- **Undo:** každá uživatelská úprava je jeden krok zpět přes `AlbumStore.apply`/`replace`, s českým názvem akce. „Zkusit jinak“ má akci „Zkusit jinak“.
- **Commity:** po každém úkolu, zprávy anglicky (`feat:`/`fix:`/`test:`/`docs:`), zakončené řádkem `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nic z `.superpowers/` se necommituje.
- **Testy jádra:** použij existující pomocníky z `Tests/LeporeloCoreTests/AlbumDrafterTests.swift` (`photo(_:day:minute:landscape:aesthetic:…)`, `day`, `album`, `canva`). Pro rozměry 8×6 použij formát `landscape-8x6in`; pomocník `canva` dnes vrací `landscape-a4`, přidej mu parametr `formatID` s výchozí hodnotou `landscape-a4`.

## Review Focus

1. **Stará kniha** se dvoustranami `journal-*`/`gallery-*` (bez klíče `pageLayouts`) se musí otevřít, změnit formát i okraj. „Zkusit jinak“ na ní nejdřív potvrdí a pak převede jen vybranou stránku. Testy: Úkol 1 (dekódování), Úkol 5 (převod).
2. **Den jen s fotkami na výšku** v lichém počtu (např. 3 ▯): žádné prázdné rámečky, sudý počet stran, ▯ nikdy v ▭ rámečku, pokud to jde jinak. Test: Úkol 2.
3. **Sdílené album se zmenšenými fotkami:** 2048 px na delší straně je hrdina, 1024 px ne, a samotná fotka 1024 px na šířku dostane `framed-1`, ne `full`. Test: Úkol 2.
4. **Kniha přes maximum stran** (např. 400 fotek, Canva max 98): návrh plánuje znovu s cílem 4 a 5, nic se nemaže. Test: Úkol 3.
5. **Trojí „Zkusit jinak“ a trojí ⌘Z** vrátí stránku krok po kroku do původního stavu. Test: Úkol 6.

---

## Struktura souborů

```
Sources/LeporeloCore/
  Model/Spread.swift              (upravit: pageLayouts, dekódování bez klíče)
  Layout/PageLayouts.swift        (nový: PageLayout, PageLayoutCatalog, PageSpread)
  Layout/PagePlanner.swift        (nový: LayoutWeights, PlannedPage, PagePlanner)
  Layout/PageEditing.swift        (nový: operace nad jednou stránkou)
  Layout/Templates.swift          (upravit: fits pro čtvercové fotky)
  Layout/AlbumDrafter.swift       (upravit: plánování po stránkách)
  Layout/AlbumUpdater.swift       (upravit: dvoustrany po stránkách)
Tests/LeporeloCoreTests/
  PageLayoutsTests.swift, PagePlannerTests.swift, PageEditingTests.swift (nové)
  AlbumDrafterTests.swift, AlbumUpdaterTests.swift, … (upravit očekávání)
App/Leporelo/Sources/
  Editor/EditorModel.swift, EditorView.swift, SpreadCanvasView.swift, TemplatePicker.swift (upravit)
  Layouts/PageLayoutPreview.swift (nový, Úkol 6), LayoutPreferences.swift, FavoriteLayoutsView.swift (nové, Úkol 7)
  Start/CreateBookSheet.swift, LeporeloApp.swift (upravit, Úkol 7)
App/LeporeloTests/
  EditorModelTests.swift (upravit), LayoutPreferencesTests.swift (nový)
docs/manual-verification.md (upravit)
```

---

### Task 1: Katalog stránek a dvoustrana ze dvou stránek

**Files:**
- Create: `Sources/LeporeloCore/Layout/PageLayouts.swift`, `Tests/LeporeloCoreTests/PageLayoutsTests.swift`
- Modify: `Sources/LeporeloCore/Model/Spread.swift`, `Sources/LeporeloCore/Layout/Templates.swift` (`fits`), `Tests/LeporeloCoreTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `enum PageLayoutRole: String { hero, dense, sparse, opener, empty }`
  - `struct GridArea { columns, rows, column, row, columnSpan, rowSpan: Int }`
  - `enum PageSlotRect { case grid(GridArea); case margin(Rect) }`. `margin` je normalizovaný 0…1 vůči rámečku stránky zmenšenému o `marginMM`.
  - `struct PageFrameSlot { id: String; area: PageSlotRect; orientation: Orientation; priority: Int }`
  - `struct PageTextSlot { id; area; role: TextRole; placeholder: String }`
  - `struct PageLayout { id, name: String; role: PageLayoutRole; frames: [PageFrameSlot]; texts: [PageTextSlot]; var photoCount: Int }`
  - `enum PageLayoutCatalog`:
    - `static let gutterMM = 3.0`
    - `static let all: [PageLayout]` (pořadí z Global Constraints)
    - `static func layout(id: String) -> PageLayout?`
    - `static var dense: [PageLayout]`
    - `static let favouriteCandidates: [String]`
  - `enum PageSpread`:
    - `static let templateID = "pages"`
    - `static func prefix(_ side: PageSide) -> String` (`"L."` / `"R."`)
    - `static func side(of rect: Rect, geometry: PageGeometry) -> PageSide` (podle středu; střed přesně na hřbetu = `.right`)
    - `static func slotRect(_ area: PageSlotRect, side: PageSide, geometry: PageGeometry, marginMM: Double) -> Rect` (v mm, v souřadnicích dvoustrany)
    - `static func pageItems(_ layout: PageLayout, side: PageSide, geometry: PageGeometry, marginMM: Double) -> (frames: [Frame], texts: [TextBox])` (prázdné fotky a texty, id s prefixem)
    - `static func compose(left: PageLayout, right: PageLayout, kind: SpreadKind, dayKey: DayKey?, id: String, geometry: PageGeometry, marginMM: Double) -> Spread` (`templateID = "pages"`, `pageLayouts = [left.id, right.id]`, výsledek prošlý `MarginRule.conform(_, area: .spread)`)
  - `Spread.pageLayouts: [String?]`: výchozí `[]`, init parametr `pageLayouts: [String?] = []`.

- [ ] **Step 1: Write the failing tests**

  Testy v `PageLayoutsTests` na geometrii `canva-photobook` / `landscape-8x6in`, okraj 10:
  - `catalogOrderAndIDs`: `PageLayoutCatalog.all.map(\.id)` se rovná pořadí z Global Constraints a `favouriteCandidates` se rovná seznamu 9 id.
  - `fullCoversRightPage`: `compose(left: full, right: full)` dá `R.photo1` s rect `(203.2, 0, 203.2, 152.4)`.
  - `gridFourHasThreeMillimetreGutters`: rámečky `grid-4` na levé stránce mají šířku `(203.2 − 3) / 2` a výšku `(152.4 − 3) / 2`, s přesností 0,001. `L.photo2.minX − L.photo1.maxX == 3`.
  - `denseAndHeroCoverage`: u každého rozložení s rolí `.hero` nebo `.dense` je součet ploch rámečků ≥ 0,85 × plocha stránky.
  - `slotsMatchOrientation`: u každého rozložení je ▯ slot vyšší než široký a ▭ slot širší než vysoký.
  - `noOverlaps`: rámečky a texty jednoho rozložení se nepřekrývají a leží uvnitř stránky.
  - `composeConformsToMargin`: u každého rozložení po `compose` platí `MarginRule.conform(spread) == spread`.
- [ ] **Step 2:** Do `ModelTests` přidej `oldSpreadDecodesWithoutPageLayouts`: JSON dvoustrany bez klíče `pageLayouts` se dekóduje s `pageLayouts == []`. Přidej i test round-trip `[ "grid-4", nil ]`.
- [ ] **Step 3:** Do testu `fits` přidej `squareFitsBoth`: fotka 3000 × 3000 pasuje do `.landscape` i `.portrait`.
- [ ] **Step 4: Run test to verify it fails.** Spusť `make test`. Očekávané selhání je kompilace kvůli chybějícím typům.
- [ ] **Step 5: Implement.** Rozložení napiš přesně takto. Zápis `g(c,r,col,row[,cs,rs])` znamená `.grid` a `m(x,y,w,h)` znamená `.margin`. Šířka sloupce je `(W − (c−1)·3)/c` a rozpětí přičítá mezery.

  **Rozložení s jednou fotkou nebo bez fotek**

  | id | fotky | texty |
  |---|---|---|
  | `full` | photo1 `g(1,1,0,0)` ▭ | – |
  | `framed-1` | photo1 `m(0.08,0,0.84,0.84)` ▭ | caption `m(0,0.88,1,0.12)` |
  | `portrait-text` | photo1 `g(2,1,0,0)` ▯ | caption `m(0.56,0.4,0.44,0.2)` |
  | `opener-text` | – | date `m(0.1,0.25,0.8,0.08)`, title `m(0.1,0.35,0.8,0.16)`, body `m(0.1,0.55,0.8,0.3)` |
  | `empty` | – | – |

  **Rozložení s více fotkami**

  | id | photo1 | photo2 | další fotky |
  |---|---|---|---|
  | `portraits-2` | `g(2,1,0,0)` ▯ | `g(2,1,1,0)` ▯ | – |
  | `portrait-left-2l` | `g(2,1,0,0)` ▯ | `g(2,2,1,0)` ▭ | photo3 `g(2,2,1,1)` ▭ |
  | `portrait-right-2l` | `g(2,1,1,0)` ▯ | `g(2,2,0,0)` ▭ | photo3 `g(2,2,0,1)` ▭ |
  | `landscape-2` | `g(3,3,0,0,2,2)` ▭ | `g(3,3,2,2)` ▭ | – |
  | `grid-4` | `g(2,2,0,0)` ▭ | `g(2,2,1,0)` ▭ | photo3 `g(2,2,0,1)` ▭, photo4 `g(2,2,1,1)` ▭ |
  | `mosaic-5` | `g(3,3,0,0,2,2)` ▭ | `g(3,3,2,0,1,2)` ▯ | photo3–5 `g(3,3,0…2,2)` ▭ |
  | `mosaic-6` | `g(3,3,0,0,2,2)` ▭ | `g(3,3,2,0)` ▭ | photo3 `g(3,3,2,1)` ▭; photo4–6 `g(3,3,0…2,2)` ▭ |
  | `opener-portrait` | `g(2,1,1,0)` ▯ | – | – |
  | `opener-2l` | `g(2,2,1,0)` ▭ | `g(2,2,1,1)` ▭ | – |
  | `opener-3` | `g(3,3,1,0,2,2)` ▭ | `g(3,3,1,2)` ▭ | photo3 `g(3,3,2,2)` ▭ |

  Další pravidla:
  - **Texty openerů:**
    - `opener-portrait` a `opener-2l`: date `m(0,0,0.44,0.08)`, title `m(0,0.10,0.44,0.16)`, body `m(0,0.30,0.44,0.70)`.
    - `opener-3`: stejné hodnoty y a výšky, ale šířka `0.28`.
    - `landscape-2`: caption `m(0,0.75,0.62,0.25)`.
  - **Priority:** `photo1` má prioritu 0, další 1, 2, …
  - **Zástupné texty** jsou jako v `TemplateCatalog`: „Datum“, „Titulek“, „Co jsme dnes dělali“, „Popisek“.
  - **Role:**
    - `full` je `.hero`;
    - `framed-1`, `portrait-text` a `landscape-2` jsou `.sparse`;
    - `opener-*` jsou `.opener`;
    - `empty` je `.empty`;
    - ostatní jsou `.dense`.
  - **Názvy** jsou česky ze specu.
  - **`fits`:** čtvercová fotka (`pixelWidth == pixelHeight`) pasuje do obou orientací.
- [ ] **Step 6: Run tests.** Spusť `make test`. Projde vše, i dosavadní testy.
- [ ] **Step 7: Commit.** `feat: page layout catalog and spreads composed of two pages`

### Task 2: Plánovač stránek dne

**Files:**
- Create: `Sources/LeporeloCore/Layout/PagePlanner.swift`, `Tests/LeporeloCoreTests/PagePlannerTests.swift`

**Interfaces:**
- Consumes: `PageLayoutCatalog`, `TemplateLayout.fits`, `TemplateLayout.rank`, `PhotoScore.score`.
- Produces:
  - `struct LayoutWeights { var liked: Set<String>; init(liked: Set<String> = []); func weight(_ id: String) -> Double }`
  - `struct PlannedPage: Equatable { var layoutID: String; var photos: [Photo] }`. `photos` jsou v pořadí rámečků photo1…N a do slotů pasují orientací, kromě záchrany.
  - `enum PagePlanner`:
    - konstanty `heroMinLongSidePX = 1800`, `heroMinScore = 0.6`, `heroPercentile = 0.85`, `windowSize = 6`
    - `static func heroCandidates(_ selected: [Photo], excluding: Set<PhotoID>) -> Set<PhotoID>`
    - `static func planDay(_ photos: [Photo], heroCandidates: Set<PhotoID>, opener: Bool, target: Int, weights: LayoutWeights) -> [PlannedPage]`

**Algoritmus `planDay`** (spec 4.2–4.3). Vstup je chronologický.

1. **Hrdinové dne.** Z kandidátů ve dni vezmi nejvýš `max(1, count/6)` s nejvyšším skóre (`rank`). Hrdina hned po jiném hrdinovi (žádná jiná fotka mezi nimi) se změní na běžnou fotku.
2. **Opener** (když `opener == true`). Z okna prvních 6 fotek (bez hrdinů) vyber opener rozložení stejným skóre jako v bodu 3 (`opener-portrait`, `opener-2l`, `opener-3`). Když žádné nejde naplnit, použij `opener-text` (0 fotek).
3. **Další stránky.**
   - Je-li první fotka fronty hrdina, stránka je `full`.
   - Jinak kandidáti = hutná rozložení, která jde naplnit takto: první fotka fronty plus nejranější další fotky z okna (bez hrdinů), které pasují do zbylých slotů.
   - Skóre = `weight × 1/(1+|n−target|)`, × 0,5, když by po stránce do příštího hrdiny nebo konce dne zbylo 1–3 fotek, které žádné jedno hutné ani řídké rozložení přesně nenaplní (ať nezůstane zbytek jen pro nepasující rámečky).
   - Rozložení stejné jako u předchozí stránky nebo stránky před ní je vyloučené, pokud zbude jiný kandidát.
   - Shoda: víc fotek, pak pořadí v katalogu.
   - Fotky ve stránce seřaď do slotů přes `TemplateLayout.assign` (převeď sloty na `FrameSlot`).
4. **Záchrana**, když žádný kandidát není:
   - 1 fotka ▭ / čtverec s delší stranou ≥ 1800 px → `full`;
   - 1 fotka ▭ menší → `framed-1`;
   - 1 fotka ▯ → `portrait-text`;
   - řídké rozložení, které jde z okna naplnit přesně (např. 2 ▭ → `landscape-2`);
   - jinak hutné rozložení s počtem fotek `min(zbývá v okně, 6)`, které má nejmíň nepasujících slotů (shoda: pořadí v katalogu).
5. **Lichý počet stránek.**
   - Stránku s nejvíc fotkami (ne opener, ne `full`) naplánuj znovu s `target = max(1, n/2)` tak, aby z ní vyšly 2 stránky (bez openeru).
   - Když to nejde, změň opener na `opener-text`; jeho fotky se naplánují jako běžné stránky před ostatními.
   - Opakuj, dokud počet není sudý. Den s 1 fotkou dá `opener-text` + záchranná stránka.

- [ ] **Step 1: Write the failing tests** (8×6, fotky z pomocníka `photo`; ▯ = `landscape: false`):
  - `twelveLandscapesEvenNoRepeatsNoMismatch`: 12 ▭ bez hrdinů, target 3. Ověř:
    - sudý počet stran;
    - první stránka je opener;
    - každá fotka je přesně jednou;
    - počet fotek stránky = `photoCount` rozložení;
    - žádné dvě sousední stránky nemají stejné rozložení;
    - ▭ fotka nikdy není v ▯ slotu.
  - `portraitsGoToPortraitSlots`: 3 ▯ a 5 ▭ střídavě. Žádná ▯ fotka není v ▭ slotu a sudý počet stran.
  - `threePortraitsOnly`: 3 ▯. Sudý počet stran, žádný prázdný slot, ▯ jen v ▯ slotech.
  - `heroKeepsChronologicalPlace`: 10 ▭, kde fotka s indexem 5 je jediný kandidát. Je na stránce `full`, každá fotka na stránkách před ní je dřív a každá fotka na stránkách po ní je později.
  - `heroCandidatesThresholds`: 20 fotek se skóre 0.1…0.95. Kandidáti jsou jen ▭ se skóre ≥ 0.6 a ≥ 85. percentil. Fotka 2048 px je kandidát, fotka 1024 px ne a fotka z `excluding` ne.
  - `singlePhotoDays`:
    - 1 ▭ 4000 px → `["opener-text", "full"]`;
    - 1 ▭ 1024 × 768 → `["opener-text", "framed-1"]`;
    - 1 ▯ → `["opener-text", "portrait-text"]`.
  - `likedLayoutWins`: 10 ▭, `opener: false`, target 3. Bez oblíbených je první stránka `grid-4` (skóre 0,5 proti `mosaic-6` 0,25). S `liked: ["mosaic-6"]` je první stránka `mosaic-6` (0,75).
  - `twoLandscapesLeftUseLandscapeTwo`: 6 ▭, `opener: false` → stránky `["grid-4", "landscape-2"]`.
  - `noOpenerWhenDisabled`: `opener: false` → žádné `opener-*`.
- [ ] **Step 2: Run test to verify it fails.** Spusť `make test`. Očekávané selhání je kompilace.
- [ ] **Step 3: Implement** `PagePlanner.swift` podle algoritmu výš. Percentil počítej z vybraných fotek jako hodnotu na indexu `floor(0.85 × (n − 1))` vzestupně seřazených skóre.
- [ ] **Step 4: Run tests.** Spusť `make test`. Projde.
- [ ] **Step 5: Commit.** `feat: page planner with heroes, orientation-aware dense pages and variety`

### Task 3: Návrh knihy po stránkách

**Files:**
- Modify: `Sources/LeporeloCore/Layout/AlbumDrafter.swift`, `Tests/LeporeloCoreTests/AlbumDrafterTests.swift`, `EndToEndTests.swift`, `WorkflowTests.swift`, `PreflightTests.swift` (jen očekávání, která počítají se šablonami `journal-*`/`gallery-*` z návrhu)

**Interfaces:**
- Consumes: `PagePlanner`, `PageSpread.compose`, `LayoutWeights`.
- Produces:
  - `DraftOptions(includeClosing: Bool = true, photosPerPage: Int = 3, layoutWeights: LayoutWeights = .init())`. `galleryPhotosPerSpread` zmizí a jeho použití uprav.
  - Interní `draft(…, galleryOnlyDays:)` zůstává. Den v `galleryOnlyDays` se plánuje s `opener: false`. Parametr `captionlessDays` zmizí (popisky jsou prázdné vždy).

**Pravidla** (spec 4.1–4.3):
- **Úvod, závěr a obálka** jako dnes. Jejich fotky jsou v `excluding` u `heroCandidates`.
- **Kandidáti na hrdiny** se počítají jednou z celého výběru.
- **Dny:** stránky dne se párují do dvoustran přes `PageSpread.compose`. První dvoustrana dne je `.journal`, když začíná openerem, jinak `.gallery`, další `.gallery`. Id dvoustran jsou jako dnes.
- **Texty openeru:**
  - `date` = `czechDate(day)`;
  - `title` = místa dne (nebo „Bez místa“);
  - `body` = "".
- **Maximum stran:** když je překročené, naplánuj všechny dny znovu s cílem 4, pak 5. Cíl začíná na `options.photosPerPage`.
- **Doplnění na minimum stran:**
  - Dokud chybí strany, vyber den s nejvyšším průměrem fotek na stránku (bez openeru a `full`; shoda → dřívější den).
  - Ten den naplánuj znovu s cílem `target − 1`, `target − 2`, … ≥ 1. Vezmi první plán s aspoň o 2 stránky víc.
  - Když to nejde u žádného dne, vlož dvoustranu `blank` před závěr jako dnes.

- [ ] **Step 1: Write the failing tests** (8×6):
  - `daySpreadsAreComposedPages`: každá dvoustrana dne má `templateID == "pages"` a `pageLayouts.count == 2`. První dvoustrana dne má vlevo `opener-*` a je `.journal`. Opener má `date` = `czechDate`.
  - `noEmptyFramesAndEveryPhotoPlaced`: 3 dny, 40 fotek (mix ▭/▯, různá skóre). Ověř:
    - žádný rámeček v nedvoustranách `blank` není prázdný;
    - každá vybraná fotka je ve dnech nejvýš jednou a aspoň jednou;
    - počet stran splňuje Canva min 20.
  - `introPhotoIsNotAHero`: fotka úvodu není v žádném `full` dne.
  - `overMaximumReplansDenser`: 400 fotek v 10 dnech. Stran je méně než při `photosPerPage: 3` bez limitu a fotky se neztrácí.
  - Uprav dosavadní testy, které počítají s `journal-N`/`gallery-N` z návrhu. Pravidla, která pořád platí (pořadí dnů, úvod, závěr, obálka, id, `excludedFromDays`), zachovej a přepiš na nové struktury. Žádný test jen nemaž bez náhrady.
- [ ] **Step 2: Run test to verify it fails.** Spusť `make test`.
- [ ] **Step 3: Implement.** Starý `planDay`/`pad` nahraď.
- [ ] **Step 4: Run tests.** Spusť `make test`, `make test-app`. Projde (aplikace jen kompiluje a dosavadní testy).
- [ ] **Step 5: Commit.** `feat: draft albums page by page from the page planner`

### Task 4: AlbumUpdater a dvoustrany po stránkách

**Files:**
- Modify: `Sources/LeporeloCore/Layout/AlbumUpdater.swift`, `Tests/LeporeloCoreTests/AlbumUpdaterTests.swift`

**Interfaces:**
- Consumes: Úkoly 1–3.
- Produces:
  - `photoSelected(_:in:geometry:weights: LayoutWeights = .init())`
  - `photoMoved(_:to:in:geometry:weights: LayoutWeights = .init())`
  - `redraft(album:days:profile:format:weights: LayoutWeights = .init())`

**Pravidla:**
- **`reinstantiated`, `changeFormat`, `settingMargin`** u dvoustrany s neprázdným `pageLayouts` postupují po stránkách:
  - Stránka s id se postaví znovu z katalogu (`PageSpread.pageItems`). Fotky, výřezy a texty se přenesou podle id.
  - Stránka `nil` drží své rámečky a texty (podle středu) a při změně formátu se úměrně přepočítají jako dnes ruční dvoustrany.
  - Nakonec projde celá dvoustrana `MarginRule.conform`.
  - `customLayout`, `manuallyEdited` a `pageLayouts` se nemění.
- **`slotOrientation`:** u dvoustrany po stránkách se orientace bere z `PageLayoutCatalog` (id bez prefixu, rozložení stránky), u stránky `nil` je `.any`.
- **`place`** (spec 4.5):
  1. prázdný rámeček dne s pasující orientací, pak jakýkoli;
  2. dvoustrany dne s `manuallyEdited == false` se naplánují znovu (`PagePlanner.planDay` s jejich fotkami + novou, opener jen pokud ho první z nich měla, kandidáti na hrdiny z celého výběru bez úvodu a závěru). Na jejich místo přijde výsledek: id se použijí znovu v pořadí, další dostanou volné id za poslední z nich;
  3. jinak nová dvoustrana za poslední dvoustranu dne: vlevo `framed-1` (▭) / `portrait-text` (▯) s fotkou, vpravo `empty`. U dne bez dvoustran `opener-text` + stránka s fotkou, umístění jako dnes.
- **`redraft`:**
  - dny s ponechanou ruční dvoustranou `.journal` → `galleryOnlyDays`;
  - `captionedDays` zmizí;
  - `weights` jde do `DraftOptions`.

- [ ] **Step 1: Write the failing tests:**
  - `marginChangeRebuildsPagesKeepsPhotos`: návrh 8×6, okraj 10 → 20 → 10. Rozložení stránek s id je stejné jako na začátku, fotky a výřezy zůstávají.
  - `formatChangeKeepsManualPage`: dvoustrana `["grid-4", nil]`, kde ruční stránka má posunutý rámeček. Po změně formátu na `landscape-a4` je levá stránka z katalogu pro A4 a pravá úměrně přepočítaná.
  - `selectingPhotoReplansAutomaticDay`: den bez prázdného rámečku, přidaná fotka. Je v knize právě jednou a den má sudý počet stran a žádný prázdný rámeček. Ruční dvoustrana dne zůstává beze změny.
  - `selectingPhotoAllManualAddsSpread`: všechny dvoustrany dne ruční → nová dvoustrana `[framed-1|portrait-text, empty]` za poslední dvoustranou dne.
  - Dosavadní testy `photoSelected`/`photoMoved`/`redraft` uprav na nové chování. Pravidla, která platí dál, zachovej.
- [ ] **Step 2: Run test to verify it fails.** Spusť `make test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests.** Spusť `make test`. Projde.
- [ ] **Step 5: Commit.** `feat: updater keeps page layouts through margin, format and new photos`

### Task 5: Operace nad jednou stránkou

**Files:**
- Create: `Sources/LeporeloCore/Layout/PageEditing.swift`, `Tests/LeporeloCoreTests/PageEditingTests.swift`

**Interfaces:**
- Produces `enum PageEditing`:
  - `static func photoIDs(on side: PageSide, of spread: Spread, geometry: PageGeometry) -> [PhotoID]`: fotky rámečků se středem na stránce, v pořadí rámečků.
  - `static func isOpenerPage(_ spread: Spread, side: PageSide, geometry: PageGeometry) -> Bool`: rozložení stránky má roli `.opener`. U stránky `nil` nebo staré dvoustrany to platí, když je na stránce text s rolí `.date` nebo `.title`.
  - `static func alternatives(for spread: Spread, side: PageSide, geometry: PageGeometry, photos: [PhotoID: Photo], weights: LayoutWeights) -> [String]`: rozložení se stejným počtem fotek, která jdou těmi fotkami naplnit s pasující orientací. U opener stránky jen `.opener`, jinak `.hero`/`.dense`/`.sparse`. Řazení je váha sestupně, pak katalog. Prázdné pro úvod, závěr, 0 fotek a stránku `empty`.
  - `static func nextLayout(for spread: Spread, side: PageSide, geometry: PageGeometry, photos: [PhotoID: Photo], weights: LayoutWeights) -> String?`:
    - prvek za aktuálním rozložením stránky (dokola);
    - když aktuální v seznamu není (ruční, stará), první prvek;
    - `nil`, když seznam neobsahuje nic jiného než aktuální.
  - `static func applying(_ layoutID: String, to spread: Spread, side: PageSide, geometry: PageGeometry, photos: [PhotoID: Photo], marginMM: Double) -> RetemplateResult`: pravidla `retemplate`, ale jen pro jednu stránku:
    - rámečky a texty se středem na stránce se nahradí `pageItems`;
    - fotky se přiřadí přes `assign`, výřezy se vynulují;
    - texty se přenesou podle role, nepoužité neprázdné jdou do `droppedTexts`;
    - fotky navíc jdou do `unplacedPhotoIDs`;
    - `manuallyEdited = true`, `customLayout = pageLayouts.contains(nil)`.
    - **Stará dvoustrana** (`pageLayouts == []`, `templateID != "blank"`, ne úvod nebo závěr): `templateID = "pages"`, druhá stránka `nil` a nechá si své rámečky a texty.
    - **`blank`:** `kind = .gallery`, druhá stránka `empty`, `templateID = "pages"`.
  - `static func markingCustom(_ spread: Spread, side: PageSide) -> Spread`: u dvoustrany po stránkách nastaví stránku na `nil`; vždy `customLayout = true`, `manuallyEdited = true`.

- [ ] **Step 1: Write the failing tests:**
  - `alternativesForTwoPortraits`: stránka `portraits-2` se 2 ▯ → `["portraits-2"]` plus případná další 2fotková rozložení pro ▯. `nextLayout` je `nil`, když jiné není.
  - `cyclesThroughThreeLandscapePageAlternatives`: stránka se 3 ▭ (`opener-3` na stránce opener). `nextLayout` opakovaně projde všechny alternativy a vrátí se na začátek.
  - `likedFirst`: `liked: ["portrait-right-2l"]` → ve výsledku je před `portrait-left-2l`.
  - `applyingKeepsOtherPage`: změna levé stránky nezmění rámečky ani texty pravé stránky (rovnost).
  - `applyingOnLegacyConverts`: dvoustrana z `TemplateCatalog` `gallery-3` s fotkami, levá stránka → `portraits-2`. Platí `templateID == "pages"`, `pageLayouts == ["portraits-2", nil]` a pravá stránka je beze změny. Fotky, které se nevešly, jsou v `unplacedPhotoIDs`.
  - `applyingOnBlankMakesGallery`.
  - `markingCustomSetsNil`.
- [ ] **Step 2: Run test to verify it fails.** Spusť `make test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests.** Spusť `make test`. Projde.
- [ ] **Step 5: Commit.** `feat: page-level layout alternatives and application`

### Task 6: Editor: aktuální stránka, „Zkusit jinak“, picker po stránkách

**Files:**
- Create: `App/Leporelo/Sources/Layouts/PageLayoutPreview.swift`
- Modify: `App/Leporelo/Sources/Editor/EditorModel.swift`, `EditorView.swift`, `SpreadCanvasView.swift`, `TemplatePicker.swift`, `EditorLogic.swift` (texty), `App/LeporeloTests/EditorModelTests.swift`, `App/project.yml` jen pokud nová složka vyžaduje zápis

**Interfaces:**
- Consumes: `PageEditing`, `PageSpread`, `PageLayoutCatalog`, `LayoutWeights`.
- Produces v `EditorModel`:
  - `var layoutWeights: () -> LayoutWeights` (výchozí `{ LayoutWeights() }`; Úkol 7 dosadí předvolby)
  - `var currentPageSide: PageSide?`:
    - nastavuje ho klik na plátno;
    - čtení vrací stranu vybraného rámečku nebo textu (podle středu), jinak posledně kliknutou stranu aktuální dvoustrany;
    - změna dvoustrany ho vynuluje.
  - `var tryAnotherAvailability: TryAnotherAvailability` s hodnotami `.available`, `.noPage` (nápověda „Klikni na stránku“), `.noAlternative` („Pro tyhle fotky jiné rozložení není“) a `.notApplicable` (úvod, závěr, obálka, `empty`).
  - `func tryAnotherLayout(confirmLayoutReplace: Bool = false) -> TemplateChangeOutcome`:
    - `PageEditing.nextLayout` a pak `applying`;
    - jeden krok „Zkusit jinak“;
    - u stránky `nil` nebo staré dvoustrany vrátí nejdřív `.needsLayoutReplaceConfirmation`;
    - fotky navíc nevzniknou, protože počet sedí.
  - `func availablePageLayouts() -> [PageLayout]`: celý katalog bez `.empty` pro aktuální stránku dvoustrany `journal`/`gallery`/`blank`; prázdné jinak.
  - `func changePageLayout(to id: String, confirmTextLoss: Bool = false, confirmLayoutReplace: Bool = false) -> TemplateChangeOutcome`: pravidla jako `changeTemplate`, přes `PageEditing.applying`.
  - `endLayoutChange`, `addFrame(on:)`, `addText(on:)` a `deleteItem` u dvoustrany po stránkách použijí `PageEditing.markingCustom` pro stranu položky.
  - `insertSpread`: Galerie = `compose(framed-1, framed-1)`, Deník = `compose(opener-2l, grid-4)`, Prázdná jako dnes.
  - `draftIfEmpty` a `redraft` předají `layoutWeights()` (`Workflow.draft` dostane `options`).
- Produces `PageLayoutPreview(layout: PageLayout, side: PageSide = .left)`:
  - SwiftUI náhled stránky 8×6 (z `PageSpread.pageItems` na geometrii `canva-photobook`/`landscape-8x6in`, okraj 10);
  - fotky jako barevné přechody (6 barev jako v mockupu) s ikonou ▭/▯ (`rectangle` / `rectangle.portrait`);
  - texty jako šedé ukázkové řádky („čtvrtek 18. června“, „Ravello“).

**UI:**
- **Tlačítko** v toolbaru `Label("Zkusit jinak", systemImage: "shuffle")`. Je neaktivní mimo `.available` a nápovědu (`.help`) má podle dostupnosti.
- **Potvrzení** je alert „Ruční rozložení se nahradí doporučeným.“ s tlačítky „Nahradit“ a „Zrušit“.
- **Plátno:**
  - klik na pozadí stránky nastaví `currentPageSide`;
  - aktuální stránka má obrys 2 pt v barvě akcentu, vsazený o 1 pt;
  - na obálce obrys není.
- **Picker** u dvoustrany po stránkách, staré `journal`/`gallery` dvoustrany a `blank`:
  - ukazuje „Doporučená rozložení“ pro aktuální stránku, seskupená podle počtu fotek (nadpis „1 fotka“, „2 fotky“, … přes `CzechPlural`);
  - každé rozložení má `PageLayoutPreview` a název;
  - bez aktuální stránky ukáže text „Klikni na stránku“;
  - úvod a závěr jako dnes.

- [ ] **Step 1: Write the failing tests** v `EditorModelTests` (pomocníci ze stávajících testů):
  - `tryAnotherThreeTimesUndoesStepwise`:
    - stránka `grid-4` (4 ▭);
    - 3 × `tryAnotherLayout` (tolik, kolik je alternativ);
    - 3 × `undo` vrátí přesně původní dvoustranu;
    - každý mezistav je jeden krok.
  - `tryAnotherNeedsPage`: bez kliknuté stránky a výběru → `.noPage`.
  - `tryAnotherAsksOnManualPage`: po posunu rámečku na levé stránce → `.needsLayoutReplaceConfirmation`. S potvrzením se stránka změní a pravá zůstane.
  - `movingFrameMarksOnlyItsPage`: `pageLayouts` po posunu = `[nil, "<původní pravé>"]`.
  - `insertGalleryComposesPages`.
  - `pickerAppliesToCurrentPage`.
- [ ] **Step 2: Run test to verify it fails.** Spusť `make test-app`.
- [ ] **Step 3: Implement** model, plátno, toolbar a picker.
- [ ] **Step 4: Run tests.** Spusť `make test-app` a pak `make build-app`. Projde.
- [ ] **Step 5: Commit.** `feat: try another layout and per-page recommended layouts in the editor`

### Task 7: Oblíbená rozložení

**Files:**
- Create: `App/Leporelo/Sources/Layouts/LayoutPreferences.swift`, `App/Leporelo/Sources/Layouts/FavoriteLayoutsView.swift`, `App/LeporeloTests/LayoutPreferencesTests.swift`
- Modify: `App/Leporelo/Sources/Start/CreateBookSheet.swift`, `App/Leporelo/Sources/LeporeloApp.swift`, místo, kde se vytváří `EditorModel` (dosazení `layoutWeights`), `docs/manual-verification.md`

**Interfaces:**
- Consumes: `PageLayoutPreview`, `PageLayoutCatalog.favouriteCandidates`, `EditorModel.layoutWeights`.
- Produces `struct LayoutPreferences`:
  - `init(defaults: UserDefaults = .standard)`
  - `var liked: Set<String>` (klíč `layouts.liked`, `[String]`)
  - `var asked: Bool` (klíč `layouts.asked`)
  - `var needsOnboarding: Bool { !asked }`
  - `func weights() -> LayoutWeights`
  - `mutating func finish(liked: Set<String>)`: uloží liked a `asked = true`, platí pro Hotovo i Přeskočit (Přeskočit předá prázdnou množinu).
- Produces `FavoriteLayoutsView(initial: Set<String>, onFinish: (Set<String>) -> Void)`:
  - nadpis „Která rozložení se ti líbí?“ a věta ze specu;
  - mřížka 3 sloupců z `favouriteCandidates` s `PageLayoutPreview`, názvem a srdíčkem (`heart` / `heart.fill`);
  - klik přepne zvýraznění rámečkem v barvě akcentu;
  - tlačítka „Přeskočit“ (předá prázdnou množinu) a „Hotovo“.

**Zapojení:**
- **`CreateBookSheet`** má dva kroky. Když `LayoutPreferences().needsOnboarding`, nejdřív `FavoriteLayoutsView` (šířka listu 640), po dokončení formulář jako dnes (šířka 500).
- **Menu:** `CommandGroup(after: .appSettings) { Button("Oblíbená rozložení…") { openWindow(id: "favorite-layouts") } }` a `Window("Oblíbená rozložení", id: "favorite-layouts")` s `FavoriteLayoutsView(initial: liked)`. Okno se zavře po „Hotovo“ nebo „Přeskočit“.
- **Editor:** `EditorModel.layoutWeights = { LayoutPreferences().weights() }` tam, kde aplikace model vytváří (v testech zůstává výchozí).
- **`docs/manual-verification.md`:**
  - nový oddíl s ručními kontrolami: první zakládání ukáže výběr; Přeskočit podruhé neukáže; menu otevře výběr; návrh knihy z Davidova alba; „Zkusit jinak“ na 3 stránkách; export a nahrání do Canvy;
  - oprav zastaralý řádek 73 o šipkách: šipky na okraji neuvíznou, platí řádek 75.

- [ ] **Step 1: Write the failing tests** v `LayoutPreferencesTests`. Každý test má vlastní `UserDefaults(suiteName: UUID().uuidString)!`.
  - `freshNeedsOnboardingEqualWeights`: `needsOnboarding == true`, `weights().weight("grid-4") == 1`.
  - `finishWithLikesWeighsThree`: po `finish(["mosaic-6"])` je `weight("mosaic-6") == 3`, `weight("grid-4") == 1` a `needsOnboarding == false`.
  - `skipStoresAskedNoLikes`: `finish([])` → `asked == true` a všechny váhy 1.
- [ ] **Step 2: Run test to verify it fails.** Spusť `make test-app`.
- [ ] **Step 3: Implement** předvolby, view, kroky listu, okno a menu, dosazení vah a dokumentaci.
- [ ] **Step 4: Run tests.** Spusť `make test-app`, `make test` a `make build-app`. Vše projde.
- [ ] **Step 5: Commit.** `feat: favourite layouts onboarding and menu`
