# Leporelo

Leporelo je nativní mac aplikace, která z fotek z dovolené v Apple Photos připraví fotoknihu k tisku. Fotky roztřídí po dnech a místech, doporučí výběr (ostrost, zavřené oči, duplicity a série, estetické skóre z Vision, vše lokálně), navrhne hrubé album ve stylu „deník + galerie“, nechá ho doladit v editoru dvoustran, zkontroluje ho před tiskem (rozlišení, bezpečná zóna, počet stran, chybějící originály) a vyexportuje PDF pro Canva Print. Aplikace je určena pro dva uživatele, ne jako produkt pro trh. Uživatelské rozhraní je česky.

## Požadavky

- macOS 15 nebo novější (vývoj probíhal na macOS 26).
- Xcode v `/Applications/Xcode.app`. Příkaz `xcode-select` na tomto stroji ukazuje na Command Line Tools, kterým chybí modul Testing, proto všechny cíle v `Makefile` nastavují `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Systémové nastavení se nemění.
- XcodeGen přes Homebrew (`brew install xcodegen`; cíl `make xcodegen` ho nainstaluje, když chybí). Projekt `App/Leporelo.xcodeproj` se generuje z `App/project.yml` a není v gitu.
- Swift 6 (jazykový režim Swift 6 je zapnutý v `Package.swift` i v `project.yml`).

## Sestavení, spuštění, testy

Všechny příkazy se spouštějí v kořeni repozitáře. `make help` vypíše přehled cílů.

| Příkaz | Co dělá |
| --- | --- |
| `make test` | testy balíčku `LeporeloCore` (`swift test`) |
| `make cli` | sestaví `leporelo-cli` do `.build/debug/leporelo-cli` |
| `make build-app` | vygeneruje projekt a sestaví aplikaci (Debug) do `App/DerivedData` |
| `make test-app` | vygeneruje projekt a spustí testy aplikace |
| `make run-app` | otevře `App/DerivedData/Build/Products/Debug/Leporelo.app` (nejdřív `make build-app`) |
| `make all` | `test`, `test-app`, `build-app` za sebou |

Aplikace není podepsaná (ad hoc, bez týmu). O přístup k Fotkám systém požádá až po kliknutí na „Povolit přístup k Fotkám“ v úvodním okně (ne při spuštění); potřebný je plný přístup.

### Příkazový řádek

`leporelo-cli` projde celý postup bez aplikace a bez Photos: složka s fotkami, projekt, návrh alba, kontrola před tiskem, PDF.

```
make cli
.build/debug/leporelo-cli draft --folder ~/Pictures/dovolena --title "Řecko 2026" --out ~/Desktop/leporelo-out
```

Vznikne `<out>/<název>.leporelo` a `<out>/export/` (`pages.pdf`, `cover.pdf`, `co-nahrat-kam.txt`). Volby `--profile <id>` (výchozí `canva-photobook`) a `--format <id>` jsou nepovinné; `--help` vypíše celou nápovědu. Existující projekt se nepřepíše. CLI potřebuje vedle sebe adresář `Leporelo_LeporeloCore.bundle` (písma a profily), takže ho spouštěj přímo z `.build/debug/`, nekopíruj samotný binární soubor jinam.

Návratové kódy: `0` hotovo, `1` kontrola před tiskem našla chyby (PDF se nevytvořilo), `2` jiná chyba, `64` špatné argumenty.

## Struktura repozitáře

- `Sources/LeporeloCore/`: model, třídění, analýza, návrh alba, vykreslování, preflight, export, balík projektu, profily dodavatelů, zdroje fotek. Nezávisí na UI.
- `Sources/leporelo-cli/`: tenký příkazový řádek nad `Workflow`.
- `App/`: mac aplikace (SwiftUI, AppKit pro mřížku a plátno editoru, PhotoKit). `App/project.yml` je vstup pro XcodeGen, `App/Leporelo/Sources` zdroje, `App/LeporeloTests` testy.
- `Tests/LeporeloCoreTests/`: testy jádra.
- `docs/superpowers/specs/`: návrhový dokument ([2026-10-26-album-app-design.md](docs/superpowers/specs/2026-10-26-album-app-design.md)).
- `docs/superpowers/plans/`: implementační plán ([2026-10-26-leporelo-v1.md](docs/superpowers/plans/2026-10-26-leporelo-v1.md)).
- `docs/manual-verification.md`: kontrolní seznam toho, co nešlo ověřit bez spuštěné aplikace, knihovny Photos a účtu Canva.

## Úvodní okno

Po spuštění se místo systémového panelu Otevřít ukáže okno „Leporelo“ ve stylu Fotek. Vlevo jsou „Moje knihy“ (naposledy otevřené knihy, klik knihu otevře), „Alba v iCloudu“ (běžná i sdílená alba z Fotek s počtem fotek; sdílené má ikonu dvou postav a upozornění na zmenšené fotky) a „Jinak“ > „Podle data…“. Vpravo je název, počet a mřížka fotek vybraného alba nebo rozmezí dat (jen k prohlížení, výběr fotek je až v třídění). „Udělat z toho knihu“ otevře list s názvem (předvyplněný názvem alba, u data „Nové album“), dodavatelem (jen když je jich víc), formátem a upozorněními; „Založit“ se zeptá na místo uložení, knihu založí a otevře a úvodní okno zavře. Bez přístupu k Fotkám ukáže pravá strana výzvu k povolení. Okno znovu otevře Soubor > Nové album… (Cmd-N), tlačítko „Nové album…“ v liště alba a Okno > Úvod.

## Editor dvoustran

Šablona dvoustrany je jen doporučené rozložení. Rámečky a texty jde na plátně přímo posouvat a za rohy či strany měnit jejich velikost (Shift drží poměr stran, Cmd vypne přichytávání). Přichytávají se k okrajům a středům stránek, k okrajové čáře, k hranám a středům ostatních rámečků i k mezeře 4 mm; zapnutá „Mřížka“ v liště přidá čáry po 5 mm. Okraj knihy („Okraj“ v liště, výchozí 6 mm, od bezpečné zóny profilu do 30 mm) platí pro všechny úpravy: každá hrana rámečku leží aspoň na okrajové čáře, žádná fotka zatím nesahá ke kraji stránky ani ke hřbetu (ani na obálce), a text zůstává uvnitř okraje. Starou knihu s fotkami ke kraji opraví nastavení okraje, i na stejnou hodnotu. Dvojklik na fotku zapne režim výřezu, ve kterém tažení posouvá fotku v rámečku (Escape ho ukončí). „Přidat rámeček“ a „Přidat text“ jsou v liště i v kontextové nabídce plátna; v té je u položky pod ukazatelem také „Smazat“, „Odebrat fotku“, „Upravit výřez“ a „Obnovit výřez“. Každá úprava je jeden krok zpět. Obálka se zatím jen zobrazuje.

## Jak aplikace ukládá projekt

Projekt je balík `<název>.leporelo` (standardní dokument macOS s automatickým ukládáním a Verzemi):

- `album.json`: celé album (dny, fotky, dvoustrany, texty, výřezy). Kóduje se společným kodérem z jádra (ISO 8601 s milisekundami).
- `originals/`: kopie originálů fotek, které jsou v albu. Stahují se z Fotek na pozadí; u vybraných fotek mřížka ukazuje odznak mraku, dokud originál není uložený (při chybě s vykřičníkem), nevybrané fotky odznak nemají. Banner ukazuje průběh a export nezačne, dokud nejsou originály všech fotek v albu uložené. Výpadek iCloudu nebo sítě se zkouší znovu (automaticky jednou, pak „Stáhnout znovu“); trvale nedostupná je jen fotka, která ve Fotkách už není. Díky kopiím export nezávisí na iCloudu ani na tom, jestli fotku někdo mezitím smazal z Fotek. Když originál v balíku chybí nebo nejde přečíst, export skončí chybou a nic nezapíše (nikdy nevytiskne náhled nebo šedý rámeček).
- `thumbs/`: náhledy, nad kterými běží třídění a analýza.

Zápisy na pozadí (náhledy, originály) jdou přes `NSFileCoordinator` a dokument, aby je automatické ukládání nepřepsalo. Fotky v projektu mají i identifikátor z Fotek, aby šlo originál znovu dohledat a aby fungovalo „Načíst nové fotky ze zdroje“.

**Pozor na Verze:** Soubor > Vrátit se k > Poslední otevřená verze i „Procházet všechny verze…“ > Obnovit nahradí celý balík včetně složky `originals/`. Originály stažené po té verzi se tím smažou z disku, a pokud fotka mezitím zmizela z Fotek, byla to její jediná kopie. Nevracejte projekt ke starší verzi, pokud jste mezitím stáhli originály z Fotek.

## Jak přidat profil dodavatele

Profil je data, ne kód. `ProfileCatalog.all()` načte každý soubor `*.json` ze složky `Sources/LeporeloCore/Resources/Profiles` (řazeno podle názvu souboru), takže stačí přidat nový soubor a znovu sestavit; `Package.swift` kopíruje celou složku `Resources`. Nový profil se pak nabídne v listu „Udělat z toho knihu“ úvodního okna a jde zadat v CLI přes `--profile <id>`. Soubor se dekóduje do `SupplierProfile` (`Sources/LeporeloCore/Supplier/SupplierProfile.swift`); chybějící nebo špatné pole dekódování shodí, nevalidují se ale věcné hodnoty (například `multipleOf: 0` nebo prázdné `formats`), na to si dej pozor sám.

Pole profilu:

| Pole | Význam |
| --- | --- |
| `id` | stabilní identifikátor (ukládá se do alba); musí být unikátní |
| `name` | název v UI; první slovo se používá jako krátké jméno dodavatele v textech exportu |
| `formats[]` | `id`, `name`, `pageWidthMM`, `pageHeightMM` (rozměr jedné strany bez spadávky) |
| `pageMode` | `singlePages` (jedna strana = jedna strana PDF, Canva) nebo `spreads` (spojené dvoustrany, bez spadávky u hřbetu) |
| `coverMode` | `frontOnly`, `wrapWithSpine` nebo `none` |
| `pageCount` | `min`, `max` (smí chybět), `multipleOf` |
| `bleedMM`, `safeMM` | spadávka a bezpečná zóna v mm |
| `output` | `fileType`, `dpi`, `jpegQuality` (0 až 1), `separateCover` |
| `verified` | `true` jen když rozměry někdo ověřil u dodavatele; `false` aplikace ukazuje jako „neověřené“ |
| `sourceURL` | odkud jsou údaje |
| `uploadSteps[]` | kroky nahrání, které se zapíšou do `co-nahrat-kam.txt` |

Zkrácený příklad (`canva-photobook.json`):

```json
{
  "id": "canva-photobook",
  "name": "Canva Print – fotokniha",
  "formats": [
    { "id": "landscape-8x6in", "name": "Na šířku 8 × 6 in (Canva)", "pageWidthMM": 203.2, "pageHeightMM": 152.4 },
    { "id": "landscape-a4", "name": "Na šířku 297 × 210 mm (záloha, neověřeno u Canvy)", "pageWidthMM": 297, "pageHeightMM": 210 }
  ],
  "pageMode": "singlePages",
  "coverMode": "frontOnly",
  "pageCount": { "min": 20, "max": 98, "multipleOf": 2 },
  "bleedMM": 3,
  "safeMM": 6,
  "output": { "fileType": "pdf", "dpi": 300, "jpegQuality": 0.92, "separateCover": true },
  "verified": false,
  "sourceURL": "https://www.canva.com/photo-books/",
  "uploadSteps": [ "Otevři Canvu a vytvoř novou fotoknihu ve stejném formátu a orientaci.", "..." ]
}
```

Co profil sám nepokryje a co je v kódu:

- Z krytí obálky je ve verzi 1 implementovaný jen `frontOnly` (přední strana jako samostatné `cover.pdf`) a `none`. `wrapWithSpine` (Saal: zadní strana, hřbet a přední strana v jednom, šířka hřbetu podle počtu stran a papíru) exportér odmítne chybou `ExportError.unsupportedCoverMode`. Pro Saal je nutné doplnit výpočet hřbetu a vykreslení obálky v `Sources/LeporeloCore/Export/PDFExporter.swift`.
- Režim `spreads` je v geometrii (`PageGeometry`) a v preflightu podporovaný, ale na skutečném profilu ho nikdo nevyzkoušel; stejně tak šablony dvoustran pro něj nikdo neověřil.
- Text v `co-nahrat-kam.txt` a v UI říká „Canva“ podle prvního slova z `name`; při druhém dodavateli bude čistší přidat do profilu pole `shortName`.
- Hodnoty, které nejsou ověřené u dodavatele, nech s `"verified": false` a vždy je doplň z jeho šablon nebo editoru, ne odhadem.

## Známé limity verze 1

- Aplikace čte jednu knihovnu Photos (knihovnu přihlášeného uživatele). Fotky partnerky musí být v téže knihovně, ideálně v originálech.
- Jediný profil je Canva Print a jeho rozměry (formáty, spadávka, bezpečná zóna, 98 stran) jsou označené jako neověřené u dodavatele. Profil Saal Digital zatím není.
- Videa se nepodporují a z knihovny se nenačítají. Starší projekt, který videa už obsahuje, je v aplikaci nezobrazuje ani nepočítá; v souboru alba zůstávají beze změny.
- Jen svět „deník + galerie“. Scrapbook a mozaika nejsou.
- Není „rozdělit den na dvě“. Ručně jde použít „Vložit dvoustranu za“ a přetahování fotek.
- Plátno editoru nemá položky přístupnosti pro jednotlivé rámečky (VoiceOver vidí plátno jako jednu skupinu). Mřížka, pás dvoustran a zásobník fotek popisky mají.
- Import ze složky je jen v CLI; v aplikaci se album zakládá z rozmezí dat nebo z alba ve Photos.
- AI nepíše texty. Doporučuje výběr fotek, texty píše člověk.
- Není nástroj „posunout čas fotek z fotoaparátu“. Fotka z jiného zařízení s nesprávným časem se přetáhne do správného dne ručně.
- Názvy míst se určují přes síťový reverzní geocoding (CLGeocoder) s odstupem 1 požadavek za sekundu, takže se objevují později; třídění a návrh na nich nečekají.
- Obálka se v editoru jen zobrazuje, nejde na ní upravovat fotku ani text.
- Systémové nabídky macOS jsou anglicky (aplikace nemá lokalizační balík).
- Není ověřeno, zda Canva při importu PDF nepřekomprimuje fotky; postup zkoušky je v `docs/manual-verification.md`.
- Návrh alba dává do galerie 2 fotky na dvoustranu; když by album přesáhlo maximum stran dodavatele (Canva 98), navrhne 3 fotky na dvoustranu. Dlouhou cestu s velkým výběrem to nemusí stačit zkrátit: třídění pak ukáže „Přesahuje maximum 98 stran“ a export je zablokovaný, dokud se výběr nezmenší.
- Vrácení ke starší verzi (Soubor > Vrátit se k, Verze) obnoví i složku `originals/` a smaže originály stažené později (viz výše).
- Balík alba smazaný z disku, zatímco je otevřený (například `rm -rf` v Terminálu), už nejde uložit; práce od posledního uložení se ztratí.
- Prázdný dokument bez názvu aplikace nezakládá (ani při spuštění, ani po kliknutí na ikonu v Docku bez otevřených oken); kniha vzniká jen z úvodního okna.
- Text delší než jeho rámeček se do tisku nevejde a konec se ořízne. Editor ho ukáže (překryv při psaní roluje, na plátně je u textu varování) a kontrola před exportem varuje „Text se nevejde do rámečku“; zkrátit ho musí člověk.

## Licence a písma

V aplikaci jsou přibalená písma Fraunces (serif, titulky deníku) a Schibsted Grotesk (popisky) pod licencí SIL Open Font License 1.1. Texty licencí jsou v `Sources/LeporeloCore/Resources/Fonts/Fraunces-OFL.txt` a `Sources/LeporeloCore/Resources/Fonts/SchibstedGrotesk-OFL.txt`. Písma se vkládají do exportovaného PDF. Samotný kód repozitáře zatím licenci nemá.
