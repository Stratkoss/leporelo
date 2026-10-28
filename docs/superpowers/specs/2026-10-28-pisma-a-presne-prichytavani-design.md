# Leporelo: písmo u textu, přesné přichytávání, kontrola lišty

Doplněk k `2026-10-27-start-a-volne-rozlozeni-design.md`, 28. 10. 2026. Vznikl z připomínek Davida k editoru dvoustran. Kde se tento doplněk a dřívější návrhy liší, platí doplněk. **(moje volba)** označuje, co rozhodl autor; David řekl „pusť se do toho“ a tyto volby nechal na autorovi, může je změnit.

## 1. Co David chce a proč

1. **Projít nástrojovou lištu editoru a ověřit, že všechno funguje.**
2. **Písmo a velikost textu jako v profesionálním nástroji.** Klikne na jeden text a změní mu písmo a velikost, jen tomu jednomu, „jako v Canvě“. Dnes má každý text pevné písmo a velikost podle své role (`SpreadRenderer.font(for:)`) a nejde to změnit.
3. **Mřížka a přichytávání musí opravdu fungovat.** Dnes se fotka „připevní různě“. David táhne fotky a chce je mít v zákrytu s ostatními fotkami na dvoustraně, bez odskoku o 1–2 px. Musí se brát v potaz ostatní rozložení na stránce.
4. **Doporučené vzdálenosti jako v Canvě:** aplikace sama nabídne polohu se stejnými mezerami, aby to bylo symetrické, a rovnou ukáže číslo vzdálenosti. Značky jsou fialové, aby se nepletly s ostatním.

Proč se to dnes chytá „různě“ (rozbor kódu, `SnapEngine`): mřížka 5 mm, čáry stránky i hrany ostatních položek jsou v jednom seznamu cílů a vyhrává ten nejbližší. Dosah je 8 bodů, což při běžné velikosti okna dělá 3–4 mm. S mřížkou 5 mm je tak skoro každá poloha v dosahu nějaké čáry mřížky, a ta často přebije hranu sousední fotky, která je o kousek dál. Výsledek: fotka sedí na mřížce 1–2 mm vedle souseda.

## 2. Přichytávání **(moje volby, odsouhlasené Davidem v rozhovoru)**

### 2.1 Pořadí cílů

Cíle se hledají ve dvou patrech. Druhé patro se použije jen tehdy, když v prvním není nic v dosahu.

1. **Ostatní položky:** hrany a středy ostatních rámečků a textů na dvoustraně, stejné mezery (2.2), stejné rozměry (2.3).
2. **Stránka:** hrany stránky (ořez, hřbet), čáry okraje, střed stránky, mezera 4 mm od hran ostatních položek.
3. **Mřížka** (jen když je zapnutá „Mřížka“).

Patra se prohledávají v tomto pořadí a každé další se použije jen tehdy, když v předchozích nic v dosahu není. Uvnitř patra vyhrává nejbližší cíl. Při shodě vyhrává hrana položky před jejím středem, pak menší souřadnice **(moje volba)**. Takže když je hrana sousední fotky v dosahu, fotka se chytí na ni, i když je střed stránky, čára okraje nebo čára mřížky o kousek blíž. Nezáleží na tom, jestli David měl mřížku zapnutou (ve výchozím stavu je vypnutá a stejný odskok vzniká i tak, protože dnes čáry stránky přebíjejí sousedy).

Přepínač „Přichytávat“ zapíná první a druhé patro, „Mřížka“ třetí (a kreslí mřížku).

**Odskok o pixely (moje volba):** builder navíc ověří, že dvě položky se stejnou souřadnicí hrany se na plátně i v PDF kreslí na stejném pixelu (zaokrouhlení v `CanvasLayout.viewRect`, spadávka u hrany stránky). Pokud ne, opraví to. ⌘ při tažení přichytávání vypne jako dnes. ⇧ na rohu drží poměr stran a nepřichytává jako dnes.

Dosah zůstává 8 bodů na obrazovce. Pevná mezera 4 mm od hran ostatních položek (`SnapSettings.gapMM`) zůstává jako cíl prvního patra.

Přichycená poloha je přesně na cíli, bez zaokrouhlení. Pravidlo okraje (`MarginRule`) má dál poslední slovo: cíle v zakázaném pásu se vůbec nenabízejí (`allowedTargets`) a když pravidlo okraje položku posune, vodítko, na kterém už neleží, se nekreslí.

### 2.2 Stejné mezery

Při posouvání položky (rámečku nebo textu) se v každé ose hledají polohy, kde je mezera stejná jako jiná mezera:

- **Mezi dvěma sousedy:** položka leží mezi sousedem vlevo a vpravo (nebo nahoře a dole). Cíl je poloha, kde jsou obě mezery stejné.
- **Stejně jako jinde:** mezera k sousedovi je stejná jako mezera mezi dvěma jinými položkami, které spolu sousedí ve stejné ose (kdekoli na dvoustraně).

Soused v ose x je položka, která se s posouvanou položkou překrývá v ose y (a obráceně), a je nejbližší na dané straně. Mezery se počítají mezi uloženými obdélníky (bez spadávky) jen v rámci jedné stránky; hřbet stránky odděluje **(moje volba)**.

Při změně velikosti za úchyt se stejné mezery hledají jen pro taženou hranu.

### 2.3 Stejné rozměry

Při změně velikosti za úchyt je cílem i šířka nebo výška rovná šířce nebo výšce jiné položky na dvoustraně: tažená hrana se posune tak, aby rozměr seděl.

### 2.4 Co se kreslí (fialově)

Barva: fialová, jedna pro všechna vodítka přichytávání (například sRGB #A020F0 nebo systémová fialová), na papíře i v tmavém režimu stejná **(moje volba)**. Modrá (barva zvýraznění) zůstává pro výběr, aktuální stránku a úpravu výřezu.

Během tažení položky:

- **Zarovnávací čáry:** fialová čára 1 bod přes celou dvoustranu jako dnes, jen fialová.
- **Vzdálenosti:** od tažené položky k nejbližšímu sousedovi vlevo, vpravo, nahoře a dole fialová úsečka s krátkými zarážkami na koncích a štítkem s číslem uprostřed. Když na některé straně soused není, úsečka vede k hraně stránky (ořez nebo hřbet). Štítek: bílý text na fialovém zaobleném obdélníku, číslo v milimetrech s jedním desetinným místem a desetinnou čárkou, např. „12,5 mm“.
- **Stejné mezery:** když je položka přichycená na stejnou mezeru (2.2), ukážou se fialově všechny mezery, které jsou stejné (ta její i ta, ke které se rovná), každá se štítkem.
- **Stejný rozměr:** když je přichycená na stejný rozměr (2.3), dostane fialový štítek s rozměrem (např. „85,0 mm“) a stejný štítek se ukáže u položky, ke které se rovná.
- Když přichytávání neplatí (⌘), nekreslí se nic.

Po puštění myši značky zmizí. Při posunu šipkami se vzdálenosti ukážou taky a zmizí krátce po puštění klávesy **(moje volba)**; šipky dál posouvají o 1 mm (⇧ 5 mm) a nepřichytávají.

Jednotky jsou milimetry, ne pixely. David to odsouhlasil: kniha se tiskne a okraje i mezery už v aplikaci v mm jsou.

## 3. Písmo jednoho textu

### 3.1 Co jde nastavit

U každého textu zvlášť:

- **písmo** (rodina),
- **velikost** v bodech (pt) jako v tisku, 6–200 pt, krok 1 pt (políčko se šipkami a nabídka obvyklých velikostí 8, 9, 10, 11, 12, 14, 18, 24, 28, 36, 48, 72),
- **tučně** a **kurzíva**,
- **zarovnání** vlevo / na střed / vpravo,
- **barva textu**.

**Kurzíva u písem knihy (moje volba):** přibalená `Fraunces.ttf` a `SchibstedGrotesk.ttf` kurzívu nemají (jen osu váhy). Přibalí se k nim kurzivní řezy z téže rodiny (Fraunces Italic a Schibsted Grotesk Italic, obě pod licencí OFL, proměnné TTF z Google Fonts), registrují se v `FontRegistry` a kurzíva písem knihy pak funguje stejně jako u písem z Macu. Žádná umělá kurzíva (zkosení).

**(moje volby)** Nastavení platí pro celý text v rámečku, ne pro jednotlivá slova. Text, kterému nic nastaveno nebylo, vypadá dál podle své role jako dnes (včetně čísla stránky zarovnaného vpravo na pravé stránce). Nové texty a navržené stránky dostávají dnešní výchozí vzhled.

### 3.2 Pruh s nástroji

**(moje volby)**

- Když je vybraný text, nebo když se text právě upravuje (dvojklik), objeví se nad dvoustranou pruh s nástroji pro text. Jinak pruh zmizí a plátno se nehýbe víc, než je nutné.
- Zleva: písmo, velikost, tučně, kurzíva, zarovnání (tři tlačítka), barva.
- **Písmo:** nabídka; nahoře dvě písma knihy (Fraunces, Schibsted Grotesk), oddělovač, pod tím všechny rodiny písma nainstalované v Macu abecedně. Každé jméno je napsané svým písmem. U dlouhého seznamu musí jít psát na hledání (vyhledávací pole v nabídce nebo v rozbalovacím okně); jak přesně, je na builderovi.
- **Tučně / kurzíva:** vypnuté (šedé), když daná rodina tučný nebo kurzivní řez nemá.
- **Barva:** pár připravených barev (téměř černá jako dnes, bílá, tmavě šedá, a 3–4 tlumené barvy, které ladí s knihou) a „Jiná…“ přes systémový výběr barvy.
- Tlačítko „Výchozí“ vrátí text na vzhled podle role.
- Na obálce je pruh vypnutý (obálka je jen ke čtení).
- Klávesy ⌘B a ⌘I přepnou tučné písmo a kurzívu u vybraného textu.

### 3.3 Chování

- Každá změna je jeden krok zpět (⌘Z). Šipky u velikosti a psaní do políčka: změna se projeví hned a celé jedno klepání nebo potvrzení políčka je jeden krok.
- Plátno, úprava textu (dvojklik) i export do PDF ukazují text stejně: písmo, velikost, řez, zarovnání a barvu. Překryvný editor textu proto musí používat stejný styl.
- Když se text po změně do rámečku nevejde, kontrola před tiskem upozorní jako dnes („Text se nevejde do rámečku“); kontrola počítá s novým písmem a velikostí.
- Písmo se do PDF vkládá (podmnožina znaků), jak to Core Graphics dělá dnes.
- **Chybějící písmo (moje volba):** když se kniha otevře v Macu, kde zvolené písmo není, text se vykreslí výchozím písmem své role a kontrola před tiskem ukáže varování „Písmo „X“ v tomto Macu chybí“. Uložená volba se nemaže.
- **Změna rozložení (moje volba):** když „Zkusit jinak“, výběr doporučeného rozložení nebo „Navrhnout znovu“ přenáší text do nového rámečku, přenese se i jeho vzhled. Vzhled patří k textu, ne k rámečku.
- Starší knihy (bez uloženého vzhledu) se otevřou beze změny; uložená kniha s vzhledem musí jít načíst. Pole vzhledu je volitelné.

## 4. Kontrola lišty

**Jak (moje volba):** builder aplikaci sestaví a spustí a ovládá ji přes computer use. Kde to nejde, napíše UI test nebo projde kód a položku zapíše do kontrolního seznamu pro Davida v `docs/manual-verification.md` (s poznámkou, že ji neověřil v aplikaci). Kontrola lišty se dělá jako první, takže její opravy jsou samostatné úkoly plánu.

Builder v běžící aplikaci projde každou položku lišty editoru a ověří ji na knize s několika dvoustranami (deník, galerie, úvod, závěr) i na obálce. Co nefunguje, opraví, a výsledek zapíše do `docs/manual-verification.md` (položka, co se čekalo, co se stalo, oprava).

| Položka | Má dělat |
|---|---|
| Zkusit jinak | jiné doporučené rozložení aktuální stránky; u ručně upravené se nejdřív zeptá; vypnuté s vysvětlením v nápovědě, když nejde |
| Přidat rámeček | prázdný rámeček na aktuální stránce (jinak na pravé), vybraný; vypnuté na obálce |
| Přidat text | textové pole na aktuální stránce, vybrané; vypnuté na obálce |
| Mřížka | zobrazí mřížku 5 mm a přichytává k ní (druhé patro, 2.1); pamatuje se |
| Přichytávat | přichytávání k rozložení (první patro, 2.1); pamatuje se |
| Okraj | krok 1 mm v rozsahu bezpečná zóna–30 mm; všechny dvoustrany se upraví jedním krokem zpět |
| Zpět do třídění | uloží rozpracované a přepne do třídění |
| Navrhnout znovu | dialog s počtem zachovaných ručních dvoustran, pak nový návrh |
| Formát | nabídka formátů profilu s fajfkou u aktuálního, změna s potvrzením |
| Exportovat… | otevře list exportu; vypnuté bez dvoustran |
| Třídění / Dvoustrany | přepínání pohledu v okně |

Každá položka lišty musí mít čitelný popisek (i když je lišta zúžená do přetékající nabídky) a nápovědu.

## 5. Ne-cíle

- Různé písmo nebo velikost pro jednotlivá slova uvnitř jednoho textu.
- Společný styl pro všechny nadpisy knihy najednou.
- Řádkování, prostrkání, stín, obrys textu.
- Přichytávání k mřížce a vodítkům při posunu šipkami.
- Pixely jako jednotka.
- Vodítka, která si uživatel sám natáhne z pravítka; pravítka.

## 6. Proti-cíle (to by byla chyba, i kdyby to technicky fungovalo)

- Fotka přichycená na mřížku 1–2 mm vedle hrany sousední fotky, která byla v dosahu.
- Fialová značka, která ukazuje zarovnání nebo mezeru, kterou položka po pravidle okraje ve skutečnosti nemá.
- Text, který na plátně vypadá jinak než v PDF.
- Kniha, která po uložení nejde otevřít ve starší nebo novější verzi kvůli novému poli.

## 7. Na builderovi

- Datový tvar vzhledu textu (kandidát: volitelná struktura u `TextBox` s rodinou, velikostí v pt, tučně, kurzíva, zarovnání, barva v sRGB; nová úprava `AlbumEdit` s inverzí `restoreSpread`).
- Jak sestavit konkrétní font z rodiny a řezu, včetně proměnných písem knihy (Fraunces a Schibsted Grotesk mají osu váhy, tučný řez se dělá nastavením osy `wght`, ne výběrem souboru).
- Přesný výpočet sousedů a stejných mezer, a jak se 2.2 a 2.3 skládají s pravidlem okraje.
- Vzhled pruhu s nástroji a štítků (velikost, zaoblení, odsazení), přesný odstín fialové a sada připravených barev.
- Kde žije logika: čistý výpočet (cíle, stejné mezery, vzdálenosti ke kreslení) patří do `LeporeloCore` (`SnapEngine`) s testy; kreslení do `SpreadCanvasNSView`.
