# Leporelo: úvodní obrazovka, duplicitní fotky, volné rozložení

Doplněk k `2026-10-26-album-app-design.md`, 27. 10. 2026. Vznikl z připomínek Davida po prvním vyzkoušení aplikace. Kde se tento doplněk a původní návrh liší, platí doplněk. **(moje volba)** označuje, co rozhodl autor; David řekl „pusť se do toho“ a tyto volby nechal na autorovi, může je změnit.

## 1. Co David chce a proč

1. **Na začátku menu pro fotky s alby z iCloudu.** Dnešní dialog „Nové album“ s přepínačem „Rozmezí dat / Album z Fotek“ a rozbalovacím seznamem je nepřehledný. Chce začínat od svých alb jako ve Fotkách. Z mockupů vybral variantu A „Jako aplikace Fotky“.
2. **Fotka, která už v albu je, má vyvolat upozornění,** ne se potichu odebrat z jiné dvoustrany. Dnes `dropPhoto` fotku z jiné dvoustrany deníku/galerie přesune a tam nechá prázdný rámeček; David to vnímal jako ztrátu práce.
3. **Šablony jen jako doporučené rozložení.** Rámečky se dají posouvat, měnit jim velikost, s mřížkou a přichytáváním (snap).
4. **Okraj.** Fotka přes celou stranu do spadávky je v pořádku. Ale když se nastaví okraj, musí být dodržen: nic nesmí trčet do pásu mezi ořezem a okrajem.

## 2. Úvodní obrazovka (varianta A)

Po spuštění aplikace se otevře okno „Leporelo“ ve stylu Fotek (místo dnešního okna „Nové album“ a místo systémového panelu Otevřít).

- **Levý panel:**
  - „Moje knihy“: naposledy otevřené knihy (`.leporelo`), klik knihu otevře.
  - „Alba v iCloudu“: alba z Fotek (běžná i sdílená, pořadí a názvy jako dnes `PhotoKitSource.albums()`), u sdíleného ikona a upozornění na zmenšené fotky.
  - „Jinak“: „Podle data…“.
- **Vpravo** u vybraného alba: název, počet fotek, tlačítko „Udělat z toho knihu“ a mřížka náhledů fotek alba (jen k prohlížení, výběr fotek je dál v třídění). U „Podle data…“: dva výběry data, počet a mřížka fotek rozmezí.
- **„Udělat z toho knihu“** otevře list: název (předvyplněný názvem alba **(moje volba)**; u data „Nové album“), dodavatel (jen když je víc profilů), formát, upozornění (sdílené album, zmenšené fotky, neověřený formát). „Založit“ se zeptá na místo uložení a dál jako dnes (`NewAlbumModel.createAlbum`), knihu otevře a úvodní okno zavře **(moje volba)**.
- Bez přístupu k Fotkám ukáže pravá strana dnešní výzvu k povolení přístupu.
- Soubor > „Nové album…“ (⌘N) otevře úvodní okno. Okno > „Úvod“ taky **(moje volba)**.

## 3. Fotka, která už v knize je **(moje volby)**

- Přetažení fotky do rámečku, když už je v jiném rámečku na JINÉ dvoustraně nebo na obálce: dialog „Tahle fotka už v knize je (dvoustrana 5).“ s tlačítky „Dát i sem“, „Přesunout sem“, „Zrušit“. „Přesunout sem“ ji odebere ze všech ostatních rámečků (jako dnes), „Dát i sem“ ji nechá na obou místech. Číslo je pořadí dvoustrany v pruhu od 1; obálka se jmenuje „obálka“.
- Ve stejné dvoustraně zůstává dnešní prohození (nic se neztrácí).
- Kontrola před tiskem: fotka ve dvou a více rámečcích dvoustran deníku/galerie = **varování** „Fotka je v knize víckrát“ (u každého výskytu kromě prvního). Úvod, závěr a obálka se nepočítají, protože tam titulní fotka opakuje fotku dne záměrně.
- Zásobník už fotky v knize označuje, to zůstává.

## 4. Volné rozložení **(moje volby)**

- Šablona je výchozí rozložení. Rámečky a textová pole jdou posouvat a měnit jim velikost; rámečky jde přidávat a mazat, textová pole taky.
- **Myš a klávesnice v editoru:**
  - Klik vybere rámeček nebo text, vybraný má 8 úchytů.
  - Tažení uvnitř rámečku nebo textu ho posune, tažení úchytu mění velikost (⇧ drží poměr stran).
  - Dvojklik na fotku zapne „úpravu výřezu“: tažení posouvá fotku v rámečku, Esc, Return nebo klik vedle ji ukončí. Kolečko a sevření zoomují výřez jako dnes.
  - ⌥ + tažení přesune fotku do jiného rámečku jako dnes. Dvojklik na text ho upraví jako dnes.
  - Šipky posouvají vybraný rámeček nebo text o 1 mm, s ⇧ o 5 mm. V úpravě výřezu posouvají výřez jako dnes.
  - Delete u rámečku s fotkou odebere fotku, u prázdného rámečku nebo textového pole ho smaže.
  - Kontextové menu: Přidat rámeček, Přidat text, Smazat, Odebrat fotku, Upravit výřez, Obnovit výřez.
- **Přichytávání:** k mřížce (5 mm, počítaná od levého horního rohu každé stránky), k okrajům (ořez, čára okraje), ke středu stránky, ke hřbetu, k hranám a středům ostatních rámečků a textů a k mezeře 4 mm od jejich hran. Práh 8 bodů na obrazovce. Při přichycení se ukáže vodicí čára. ⌘ během tažení přichytávání dočasně vypne.
- **Přepínače v nástrojové liště:** „Mřížka“ (zobrazit a přichytávat k mřížce), „Přichytávat“ (k objektům a vodítkům) a „Okraj: N mm“. Mřížka a přichytávání se pamatují pro aplikaci, okraj pro knihu.
- **Okraj stránky** je vlastnost knihy, výchozí 10 mm, nejméně bezpečná zóna profilu (6 mm), nejvíc 30 mm. Pravidlo pro každou hranu rámečku: buď leží na hraně stránky (ořez nebo hřbet; taková hrana jde do spadávky jako dnes), nebo je aspoň okraj daleko od hrany stránky. Hrana v zakázaném pásu se přichytí k bližší z obou možností. Textová pole musí být celá uvnitř okraje. Pravidlo platí při tažení (nelze ho porušit), při vytvoření dvoustrany ze šablony, při změně formátu i při změně okraje (všechny dvoustrany se upraví jedním krokem zpět).
- **Šablony v pickeru** se jmenují „Doporučená rozložení“. Volba šablony u dvoustrany s ručně upraveným rozložením se nejdřív zeptá: „Ruční rozložení se nahradí doporučeným.“
- **Změna formátu** u dvoustrany s ručním rozložením rozložení zachová a přepočítá úměrně novému rozměru (a pak uplatní pravidlo okraje). Ostatní dvoustrany se přepočítají ze šablony jako dnes.
- „Navrhnout znovu“ ruční dvoustrany zachová jako dnes, protože úprava rozložení dvoustranu označí jako ručně upravenou.
- Fotka se kreslí vždy jen uvnitř svého rámečku (spadávka u hrany stránky jako dnes).

## 5. Ne-cíle

- Pořadí vrstev (dopředu/dozadu), otáčení rámečků, rámečky jiného tvaru než obdélník, vlastní velikost písma.
- Uložené vlastní šablony.
- Složky alb ve Fotkách jako strom (seznam zůstává plochý jako dnes).
- Výběr fotek už na úvodní obrazovce.

## 6. Na builderovi

- Jak potlačit systémový panel Otevřít při spuštění u `DocumentGroup` (kandidát: `UserDefaults` klíč `NSShowAppCentricOpenPanelInsteadOfUntitledFile` = false registrovaný v `init` aplikace); ověřit ručně.
- Mřížka náhledů na úvodní obrazovce: `LazyVGrid` s náhledy z `PhotoSource.thumbnail`; pokud u alba s 3 000 fotkami drhne, `NSCollectionView` jako v třídění.
- Vzhled úchytů, vodítek a mřížky.
