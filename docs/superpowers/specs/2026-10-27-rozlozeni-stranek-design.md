# Leporelo: rozložení po stránkách, „Zkusit jinak“, oblíbená rozložení

Doplněk k `2026-10-26-album-app-design.md` a `2026-10-27-start-a-volne-rozlozeni-design.md`, 27. 10. 2026. Kde se liší, platí tento doplněk. **(moje volba)** = rozhodl autor, David řekl „pokračuj“ a nechal to na něm; může to změnit.

## 1. Proč

David vyzkoušel export do Canvy (funguje) a výsledek vypadá prázdně: malé fotky, hodně bílé, fotky na šířku naskládané v úzkém sloupci, fotka na výšku sama uprostřed stránky na šířku. Příčina: šablony jsou navržené jako dvoustrany (deník = textový sloupec + fotky na pravé stránce), ale Canva tiskne jednotlivé stránky 8×6 in na šířku (203,2 × 152,4 mm) a fotky z iPhonu mají poměr 4:3 / 3:4.

Co David chce (jeho slova shrnutá):
- víc roztáhnout, míň bílé, „úvodní fotka je nice, hezky celá“;
- kombinace na šířku a na výšku;
- kvalitní fotky samostatně přes celou stránku;
- různorodost („různorodost bude point“);
- styl: kombinace variant A „Velké fotky“ a B „Mozaika“ z mockupů (do kraje, úzké mezery, střídání celostránkových fotek a koláží);
- tlačítko nahoře, které danou stránku „zkusí jinak“;
- na začátku krátký výběr asi 10 rozložení s ukázkovými fotkami, kde uživatel označí, co se mu líbí. Učení z chování teď ne.

## 2. Cíle a ne-cíle

**Cíle**
- Automatický návrh skládá knihu po **stránkách** z katalogu jednostránkových rozložení (oddíl 3).
- Na stránkách s fotkami (kromě „S bílým okrajem“ a stránek s textem) pokrývají fotky ≥ 85 % plochy stránky.
- Fotka na výšku je v rámečku na výšku a fotka na šířku v rámečku na šířku, kdykoli to jde.
- Nejlepší fotky dostanou celou stránku (oddíl 4.2).
- Dvě sousední stránky nemají stejné rozložení, pokud existuje jiné vhodné.
- „Zkusit jinak“ u vybrané stránky (oddíl 5).
- Výběr oblíbených rozložení při prvním zakládání knihy a kdykoli z menu (oddíl 6); oblíbená se v návrhu používají častěji.

**Ne-cíle**
- Učení z toho, co uživatel přeskakuje nebo mění.
- Panoramata přes hřbet (fotka přes obě stránky). Canva tiskne jednotlivé stránky.
- Nový vzhled obálky, úvodu a závěru (zůstávají, úvodní dvoustrana se Davidovi líbí).
- Oblíbená rozložení zvlášť pro každou knihu (jsou pro celou aplikaci).
- Styly písma, barvy pozadí.

**Anti-cíle** (i kdyby to technicky fungovalo, je to špatně)
- Stránka, kde je fotka zmenšená uprostřed bílé plochy (kromě „S bílým okrajem“, kde je okraj záměr).
- Fotka na výšku oříznutá do širokého rámečku tak, že z ní zbude pruh.
- Kniha, kde se pořád opakuje jedno rozložení.

## 3. Katalog stránek

Rozložení jsou definovaná normalizovaně (0…1) vůči **jedné stránce**. Navržená jsou pro stránku na šířku 4:3; na ostatních formátech (A4 na šířku, čtverec, oba neověřené) se použijí stejně, jen s jiným ořezem. Všechny vnější hrany fotek jdou do spadávky (leží na hraně stránky), mezery mezi fotkami jsou **3 mm** **(moje volba)**. Texty a „S bílým okrajem“ dodržují okraj knihy (`marginMM`) podle pravidla okraje (`MarginRule`). Mezera 3 mm je uprostřed stránky, takže pravidlo okraje neporušuje.

Mřížky: „poloviny“ = stránka rozdělená na 2 sloupce (a 2 řádky) s mezerou 3 mm; „třetiny“ = 3 × 3 buňky s mezerami 3 mm (každá buňka má zhruba 4:3).

| id | název (česky v UI) | fotky | rozložení |
|---|---|---|---|
| `full` | Celá stránka | 1 ▭ | celá stránka (jako úvod) |
| `framed-1` | S bílým okrajem | 1 ▭ | fotka 4:3 uvnitř okraje, nahoře na střed; pod ní popisek |
| `portrait-text` | Na výšku + popisek | 1 ▯ | ▯ levá polovina; popisek v pravé polovině (uvnitř okraje, svisle na střed) |
| `portraits-2` | Dvě na výšku | 2 ▯ | levá a pravá polovina |
| `portrait-left-2l` | Na výšku + dvě | 1 ▯ + 2 ▭ | ▯ levá polovina; ▭ ▭ nad sebou v pravé |
| `portrait-right-2l` | Dvě + na výšku | 2 ▭ + 1 ▯ | zrcadlově |
| `landscape-2` | Velká + malá | 2 ▭ | třetiny: velká ▭ 2 × 2 buňky vlevo nahoře, malá ▭ v buňce vpravo dole; popisek v buňkách vlevo dole; zbytek bílý |
| `grid-4` | Čtyři | 4 ▭ | poloviny 2 × 2 |
| `mosaic-5` | Mozaika 5 | 4 ▭ + 1 ▯ | třetiny: velká ▭ 2 × 2 vlevo nahoře, ▯ 1 × 2 vpravo nahoře, spodní řada 3 × ▭ |
| `mosaic-6` | Mozaika 6 | 6 ▭ | třetiny: velká ▭ 2 × 2 vlevo nahoře, 2 malé vpravo nad sebou, spodní řada 3 × ▭ |
| `opener-portrait` | Začátek dne: na výšku | 1 ▯ | texty dne v levé polovině (uvnitř okraje); ▯ pravá polovina |
| `opener-2l` | Začátek dne: dvě | 2 ▭ | texty v levé polovině; ▭ ▭ nad sebou v pravé |
| `opener-3` | Začátek dne: velká + dvě | 3 ▭ | třetiny: texty v levém sloupci; velká ▭ 2 × 2 vpravo nahoře; 2 malé ▭ vpravo dole |
| `opener-text` | Začátek dne: jen text | 0 | texty dne větší, uvnitř okraje, svisle na střed |
| `empty` | Prázdná stránka | 0 | nic |

Texty dne na „opener“ stránkách mají role jako dnešní deník: `date`, `title`, `body` (zástupné texty „Datum“, „Titulek“, „Co jsme dnes dělali“). Popisky mají roli `caption`.

Rámeček ▭ přijme fotku na šířku nebo čtvercovou, ▯ fotku na výšku nebo čtvercovou **(moje volba;** dnes čtvercová fotka nepasuje nikam).

Náhled katalogu (mockup, poměry orientační): `.superpowers/brainstorm/…/content/layout-catalog.html`.

## 4. Automatický návrh

### 4.1 Struktura knihy

- Obálka, úvod (`intro-1`) a závěr (`closing-1`) zůstávají jako dnes, včetně výběru fotek.
- Každý den začíná na nové dvoustraně a zabírá celé dvoustrany (sudý počet stránek), jako dnes **(moje volba;** model drží jeden den na dvoustranu a navazuje na to přidávání fotek, přesuny mezi dny a „Navrhnout znovu“).
- První stránka dne (vždy levá) je „opener“ s datem a místem, jako dnešní deník. První dvoustrana dne je druhu `journal`, další `gallery`.
- Při „Navrhnout znovu“ u dne, který už má ručně upravenou dvoustranu s hlavičkou dne, se opener nevkládá (jako dnes `galleryOnlyDays`).

### 4.2 Celostránkové fotky („hrdinové“)

Fotka je kandidát na celou stránku, když:
- je na šířku (nebo čtvercová);
- delší strana má ≥ 1800 px (≈ 225 dpi na 8 in);
- `PhotoScore.score` ≥ 0,6 a zároveň ≥ 85. percentil skóre všech vybraných fotek knihy.

Fotka úvodu a fotka závěru hrdiny nejsou (jinak by stejná fotka byla dvakrát přes celou stránku hned za sebou); ve dnech se objeví jen jako běžná fotka koláže, jako dnes **(moje volba)**.

Za den nejvýš `max(1, počet fotek dne / 6)` hrdinů (zaokrouhleno dolů), vybírají se od nejvyššího skóre. Hrdina zůstává na svém místě v čase: stránky před ním a za ním se skládají z ostatních fotek. Hrdina nikdy není na opener stránce a dvě celé stránky nejsou hned za sebou, pokud to jde **(moje volby,** čísla jsou laditelná konstanty).

Fotky na výšku celou stránku nedostanou (ořez by z nich nechal polovinu). Nejlepší fotka na výšku dne dostane přednost na `portraits-2`, `portrait-text` nebo v polovině `portrait-*-2l` (velký rámeček s prioritou 0 bere nejlepší fotku, jako dnes `TemplateLayout.assign`).

### 4.3 Skládání stránek dne

Fotky dne jdou chronologicky. Opener: vybere se opener rozložení podle prvních fotek dne (jako ostatní stránky níže, jen z rozložení `opener-*`). Pak se stránky skládají jedna po druhé:

1. Je-li první fotka fronty hrdina, stránka je `full`.
2. Jinak: stránka bere první fotku fronty a další do počtu z **okna** prvních 6 fotek fronty (nejdřív nejranější, které pasují orientací). Hrdinové v okně se nepočítají. V rámci okna se tedy pořadí může mírně přeházet, aby orientace seděly.
3. Kandidáti = **hutná rozložení** (`portraits-2`, `portrait-left-2l`, `portrait-right-2l`, `grid-4`, `mosaic-5`, `mosaic-6`), která jde z okna naplnit. Skóre = váha rozložení (oddíl 6) × `1 / (1 + |počet fotek − cíl|)`. Vyloučené je rozložení předchozí stránky a stránky před ní, pokud zbude jiný kandidát. Shoda → víc fotek, pak pořadí v katalogu. **Řídká rozložení** (`framed-1`, `portrait-text`, `landscape-2`) automatický návrh nepoužívá, jen jako záchranu (bod 5 a den s 1 fotkou); uživatel je má v pickeru a v „Zkusit jinak“ **(moje volba;** jinak by kniha zase byla bílá).
4. Cíl hustoty je **3 fotky na stránku** **(moje volba)**. Když návrh přesáhne maximum stran dodavatele, plánuje se znovu s cílem 4, pak 5 (dnes obdobně 3 fotky na galerii). Pořád moc stran → nic se nemaže, kontrola před tiskem to nahlásí (jako dnes).
5. Když fotky dne nejde žádným hutným rozložením naplnit tak, aby orientace seděly (např. zbyde 1 fotka), použije se: jedna fotka na šířku s delší stranou ≥ 1800 px → `full`, jinak `framed-1`; jedna fotka na výšku → `portrait-text`; jinak hutné rozložení s nejmenším počtem nepasujících rámečků. Prázdný rámeček nikdy nevznikne.

Popisky (`caption`) nechává návrh prázdné (datum a místo jsou na openeru); v editoru je vidět zástupný text „Popisek“. Proto jsou řídká rozložení jen záchrana.

**Sudý počet stránek dne:** když vyjde lichý, rozdělí se stránka dne s nejvíc fotkami (ne opener, ne `full`) na dvě (její fotky se znovu rozloží s polovičním cílem). Nejde-li to (den má jen opener a nanejvýš jednu stránku s 1 fotkou), opener se změní na `opener-text` a fotky jdou na samostatnou stránku. Den s 1 fotkou = `opener-text` + `full`/`framed-1`/`portrait-text`.

**Doplnění na minimum stran dodavatele** (Canva 20): dokud je stran málo, dostane den s nejvíc fotkami na stránku (bez openeru a `full`) jednu dvoustranu navíc: jeho stránky (bez openeru a hrdinů) se poskládají znovu tak, aby jich vyšlo o 2 víc. Když už to nejde u žádného dne (všechny stránky mají 1 fotku), vloží se prázdná dvoustrana před závěr jako dnes.

### 4.4 Rozložení dvoustrany v modelu **(moje volba)**

- Dvoustrana dál drží rámečky a texty v souřadnicích dvoustrany (vykreslování, export, kontrola před tiskem, editor se nemění).
- Nové pole `Spread.pageLayouts: [String?]` (prázdné u úvodu, závěru, obálky a dvoustran ze starých šablon; jinak 2 prvky: levá a pravá stránka). `nil` = stránka upravená ručně. `templateID` je u takových dvoustran `"pages"`. Starší soubory se pole naučí jako prázdné.
- Id rámečků a textů dostanou prefix stránky: `L.photo1`, `R.date` atd., takže jsou stabilní napříč formáty.
- Ruční úprava rozložení (posun, změna velikosti, přidání, smazání) nastaví u stránky, které se týká, `nil` a jako dnes `customLayout = true`. Rámeček přes hřbet patří stránce, na které leží jeho střed.
- Změna formátu a změna okraje: stránky s id rozložení se postaví znovu z katalogu (fotky, výřezy a texty podle id), ruční stránky se úměrně přepočítají (jako dnes ruční dvoustrany).
- Staré šablony dvoustran (`journal-*`, `gallery-*`) zůstávají v kódu, aby staré knihy šly otevřít, upravit a exportovat, ale nový návrh je nepoužívá a v nabídce rozložení nejsou.

### 4.5 Přidání fotky po návrhu (`photoSelected`, `photoMoved`)

1. Prázdný rámeček ve dvoustranách dne s pasující orientací, pak jakýkoli prázdný (jako dnes).
2. Jinak se znovu poskládají dvoustrany dne, které nejsou ručně upravené (`manuallyEdited == false`), i s novou fotkou; jejich id zůstanou, nové dostanou volná id. Ruční dvoustrany zůstávají, jak jsou **(moje volba;** jedno Zpět to vrátí).
3. Jsou-li všechny dvoustrany dne ruční, za poslední dvoustranu dne přijde nová: levá stránka `framed-1` / `portrait-text` podle orientace s fotkou, pravá `empty`. U dne bez dvoustran: `opener-text` + stránka s fotkou na místě dne jako dnes.

## 5. „Zkusit jinak“

- **Aktuální stránka:** klik do stránky ji vybere (jemný obrys stránky). Vybraný rámeček nebo text určuje stránku podle svého středu. Bez vybrané stránky je tlačítko neaktivní s nápovědou „Klikni na stránku“.
- **Tlačítko** v nástrojové liště editoru, „Zkusit jinak“ (ikona `shuffle`). U úvodu, závěru, obálky a prázdné stránky (`empty`) je neaktivní.
- **Co udělá:** stejné fotky stránky (počet se nemění) rozloží do dalšího rozložení ze seznamu alternativ. Alternativy = rozložení katalogu se stejným počtem fotek, jejichž rámečky jdou těmi fotkami naplnit s pasující orientací; u opener stránky jen `opener-*`, u ostatních ne `opener-*`. Seřazené podle váhy (oddíl 6), pak podle katalogu; klikání jimi dokola cykluje, zpět na původní. Fotky do rámečků přiřadí `assign` (nejlepší do hlavního rámečku), výřezy se vynulují, texty se přenesou podle role.
- **Není alternativa:** tlačítko je neaktivní s nápovědou „Pro tyhle fotky jiné rozložení není“.
- **Ručně upravená stránka** (`nil`) a stránka staré dvoustrany: nejdřív potvrzení „Ruční rozložení se nahradí doporučeným.“ (jako dnes u šablon). U staré dvoustrany se tím dvoustrana převede: vybraná stránka dostane rozložení z katalogu, druhá stránka se stane ruční (`nil`) a zůstane, jak je.
- Každý klik = jeden krok Zpět. Dvoustrana se označí `manuallyEdited` (aby ji „Navrhnout znovu“ nepřepsalo), ale `customLayout` zůstává podle stránek.

**Doporučená rozložení (picker):** dnes nabízí šablony dvoustrany. Nově u dvoustrany po stránkách nabízí rozložení katalogu **pro aktuální stránku** (všechna, i s jiným počtem fotek, seskupená podle počtu fotek, s náhledy jako v oddílu 6). Volba má dnešní pravidla `retemplate`, jen pro jednu stránku: fotky navíc zůstanou mimo knihu (kontrola před tiskem je ohlásí), rámečky navíc zůstanou prázdné, texty bez místa se nejdřív potvrdí. U prázdné dvoustrany (`blank`) volba rozložení pro stránku udělá z dvoustrany galerii po stránkách (druhá stránka `empty`). Úvod a závěr nabízí jako dnes své šablony.

**Vložení dvoustrany** (dnes Galerie / Deník / Prázdná): Galerie = `framed-1` + `framed-1`, Deník = `opener-2l` + `grid-4`, s prázdnými rámečky jako dnes **(moje volba)**.

## 6. Oblíbená rozložení (onboarding)

- **Kdy:** při prvním „Udělat z toho knihu“, dokud uživatel výběr ani jednou nedokončil ani nepřeskočil, se v listu „Udělat z toho knihu“ nejdřív ukáže krok „Která rozložení se ti líbí?“ a pak teprve dnešní formulář. Kdykoli později z menu Leporelo > „Oblíbená rozložení…“ (samostatné okno se stejným obsahem).
- **Obsah:** nadpis, věta „Nejlepší fotky dostanou celou stránku vždycky. Vyber, co se ti líbí dál – návrh je bude používat častěji.“, mřížka 9 rozložení, ze kterých návrh vybírá (hutná rozložení a `opener-portrait`, `opener-2l`, `opener-3`), jako náhledy stránky s ukázkovými fotkami. Ukázkové fotky jsou barevné přechody s malou ikonou orientace, texty jsou ukázkové („čtvrtek 18. června“, „Ravello“) **(moje volba;** David řekl „mock fotky“). Klik na náhled ho označí / odznačí (srdíčko a zvýraznění).
- **Tlačítka:** „Přeskočit“ a „Hotovo“ (i bez označení). Obojí uloží, že se už ptát nemá.
- **Uložení:** pro celou aplikaci v `UserDefaults`: `layouts.liked` (seznam id) a `layouts.asked` (Bool).
- **Váhy:** nic neoznačeno → všechna rozložení váha 1. Něco označeno → označená 3, ostatní 1 **(moje volba;** neoznačená se pořád používají, když jinak orientace nesedí nebo by se opakovala).
- Váhy čte návrh knihy, „Navrhnout znovu“, přidání fotky (oddíl 4.5) i pořadí v „Zkusit jinak“. Existující stránky knih se změnou oblíbených nemění.
- Jádro (`LeporeloCore`) dostane váhy jako parametr (`DraftOptions`), o `UserDefaults` neví.

## 7. Kontrola před tiskem

Beze změny, jen:
- varování „Text deníkové dvoustrany je prázdný“ se týká opener stránky (dvoustrana `journal`) jako dnes;
- duplicitní fotky se počítají přes dvoustrany `journal` i `gallery` jako dnes.

## 8. Ověření

- Na vzorku 40 fotek (mix ▭/▯, různá skóre, 3 dny) v testu jádra: žádné prázdné rámečky; každý den sudý počet stran; žádné dvě sousední stránky se stejným rozložením tam, kde existovala alternativa; fotky na výšku jen v ▯ rámečcích (kromě případu 4.3 bod 5); hrdinové jsou `full`; pokrytí fotek ≥ 85 % plochy u stránek, kde to oddíl 2 vyžaduje.
- Ručně: Davidova kniha z Canvy vygenerovaná znovu a nahraná do Canvy; „Zkusit jinak“ na několika stránkách; onboarding při prvním zakládání.

## 9. Na builderovi

- Přeskládání dne (4.5 bod 2), když mezi automatickými dvoustranami leží ruční: nové dvoustrany přijdou za poslední automatickou dvoustranu dne **(moje volba)**.
- „Zkusit jinak“ na ruční stránce cykluje jen rozloženími katalogu; ruční rozložení vrací Zpět **(moje volba)**.

- Přesné souřadnice rozložení z mřížek v oddílu 3 (poloviny, třetiny, mezera 3 mm) a umístění textů; vzhled náhledů v onboardingu a v pickeru.
- Jak se v editoru kreslí obrys vybrané stránky a jak se vybírá stránka bez rámečku pod kurzorem.
- Volné id při dělení stránek a přeskládání dne.
