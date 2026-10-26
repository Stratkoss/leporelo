# Album: mac aplikace na fotoknihu z dovolené

Návrhový dokument, 26. 10. 2026. Vznikl z rozhovoru s Davidem (uživatel a zadavatel). Co je označeno jako **(moje volba)**, rozhodl autor dokumentu, ne zadavatel, a zadavatel to může změnit.

## 1. Záměr a proč

David s partnerkou fotí na dovolené oba, hlavně na iPhone, fotky z fotoaparátu se nahrávají do Apple Photos. Z jedné dovolené (7 až 14 dní) zůstane kolem 3 000 nepromazaných fotek v Apple Photos, s 2 TB iCloudem, takže většina originálů není na disku, jen náhledy.

Chtějí z toho tištěnou fotoknihu. Existující editory (naposledy Saal Digital, dřív jiná aplikace) selhaly na dvou věcech: nedostaly se k fotkám v Apple Photos na macu, a byly pomalé a nepřehledné. "AI" funkce v nich nic reálného nedělaly. Výsledek: album nikdy nevzniklo, protože to bylo moc komplikované.

Cíl aplikace: dovést je od 3 000 fotek v Photos k objednanému, vytištěnému albu bez toho, aby to vzdali v půlce. Aplikace je primárně pro ně dva, ne produkt pro trh.

## 2. Cíle, ne-cíle, anti-cíle

### Cíle (verze 1)

1. Načíst fotky přímo z knihovny Apple Photos toho, kdo aplikaci spustí, včetně fotek, jejichž originál je jen v iCloudu.
2. Předtřídit fotky: rozdělit po dnech a místech, ohodnotit kvalitu, najít duplicity a série, a pro každý den doporučit balík fotek. Finální výběr dělá člověk.
3. Vygenerovat hrubý návrh celého alba ve stylu "deník + galerie" (viz 6), který uživatel ladí: přesouvá, mění fotky, přepisuje texty.
4. Exportovat tiskové PDF podle profilu dodavatele, v první verzi Canva Print (fotokniha), s kontrolou před exportem (rozlišení, spadávka, počet stran, chybějící originály). Saal Digital jako druhý profil.
5. Být rychlá: na 3 000 fotkách použitelná do půl minuty od otevření, bez čekání na stažení originálů.
6. Nikdy neztratit rozdělanou práci.

### Ne-cíle (verze 1)

- Scrapbook svět (polaroidy, pásky, samolepky). Struktura s ním počítá, implementace později.
- Mozaiková dvoustrana (typ D). Třetí typ dvoustrany, přijde po A a B.
- Sdílená knihovna iCloud, dvě knihovny, dohledávání originálů ze sdíleného alba. Verze 1 čte jednu knihovnu.
- Import ze složky na disku (fotky z foťáku bez Photos). Abstrakce zdroje fotek to má umožnit, UI ne.
- Další dodavatelé (Saal Digital, Blurb, MCLab, Bontia). Profily dodavatelů jsou data, přidají se později; Saal je první v pořadí.
- AI psaní textů. Aplikace doplní datum a místo, texty píše člověk.
- Objednání tisku z aplikace. Konec je hotové PDF, které uživatel nahraje sám.
- Distribuce přes App Store, podepisování, prodej. Build z Xcode pro vlastní mac stačí.
- Windows, Linux, web.

### Anti-cíle (co by znamenalo neúspěch, i kdyby to "fungovalo")

- **Ztracená práce.** Pád aplikace, zavření okna, vypnutý mac nebo chyba při exportu nesmí stát uživatele víc než pár sekund práce. Žádné "nezapomeň uložit".
- **Špatný tisk.** Vytištěná kniha, kde je fotka rozmazaná z nízkého rozlišení, oříznutý obličej na spadávce, text u hřbetu, nebo chybějící stránka. Všechno, co se dá zkontrolovat před exportem, se kontroluje před exportem a uživatel je zastaven, dokud to nevyřeší nebo výslovně nepřijme.
- **Čekání.** Modální "načítám" déle než pár sekund. Všechno těžké běží na pozadí a uživatel pracuje dál.
- **Nedostupné fotky.** Jakákoli fotka v knihovně Photos musí jít do alba, i když je originál v iCloudu.

## 3. Omezení

- Jen mac, nejnovější macOS. Vývojový i cílový stroj je macOS 26 (Darwin 25). **(moje volba)** minimální verze macOS 15, aby šlo použít Vision aesthetics scoring; builder může zvednout na 26, pokud to něco usnadní.
- Fotky jsou v Apple Photos s "Optimalizovat úložiště", originály se stahují z iCloudu na vyžádání. Stažení všech 3 000 originálů (kolem 15 GB) není přijatelné.
- Canva Print: zadavatel ověřil ve svém účtu, že Canva tiskne fotoknihy s doručením do Česka. Cesta: hotové PDF se naimportuje do Canvy jako fotokniha (jedna strana PDF = jedna strana knihy), případně se doladí, a objedná. Přesné formáty, spadávku a bezpečnou zónu musí builder vzít z Canvy: založit v Canvě fotoknihu ve zvoleném formátu a odečíst rozměry stránky a tiskové vodítka (Canva je ukazuje v návrhu a v exportu "PDF pro tisk"). Hřbet obálky Canva řeší sama; obálka se v Canvě navrhne z exportované přední strany. Protože Canva při importu PDF stránky převádí, exportovat tak, aby fotky nebyly dál komprimovány (viz pasti v 10).
- Saal Digital (druhý profil) nebere soubor z jiného editoru, jen hotové PDF nebo JPG strany v režimu "PDF Upload": vnitřní strany jako dvoustrany, obálka zvlášť (zadní strana, hřbet, přední strana, šířka hřbetu podle počtu stran), sRGB, maximální kvalita JPEG, PSD šablony s vyznačenou spadávkou pro každý formát za přihlášením (https://www.saal-digital.com/photo-book/professional-zone/). Přesné rozměry z nich, ne odhadem.
- Fotky partnerky: pro první reálné album je pošle v originálech (AirDrop nebo sdílená knihovna iCloud) do knihovny zadavatele. Aplikace čte jednu knihovnu.
- Dva uživatelé v budoucnu, ale v jednu chvíli pracuje jeden. Žádná souběžná editace.

## 4. Co rozhodl zadavatel

- Nativní mac aplikace, ne web.
- Zdroj fotek pro verzi 1: vlastní knihovna Apple Photos.
- AI předtřídí a doporučí, člověk vybírá. AI nemá dělat "ideální album" sama.
- Aplikace předpřipraví hrubý návrh celého alba, uživatel ladí (ne prázdná stránka).
- Vzhled: jeden "svět" na album, v něm typy dvoustran. Výchozí svět je kombinace "deník" (B) a "galerie" (A), kde deník otevírá den nebo místo a galerie za ním pokračují. Mozaika (D) až potom, scrapbook (C) jako samostatný svět později.
- Při ladění dvoustrany aplikace nabízí fotky z toho dne a sousedních dní, ne celou knihovnu.
- První cílový dodavatel: Canva Print (ověřená dostupnost v Česku), druhý Saal Digital.
- Fotky partnerky přijdou do knihovny zadavatele v originálech, aplikace to neřeší.
- Nejhorší selhání: ztracená rozdělaná práce a špatný tisk.

## 5. Co rozhodl autor dokumentu (moje volby)

- **Swift 6, SwiftUI, AppKit tam, kde SwiftUI nestačí (velké mřížky, drag and drop, přesné vykreslování).** Důvod: knihovna Photos s iCloud originály jde číst jen přes PhotoKit, hodnocení fotek dává Vision framework zdarma a offline, PDF dělá Core Graphics. Rust by to všechno musel přemosťovat a multiplatformnost nikdo nepotřebuje.
- **Hodnocení fotek lokálně, bez cloudu.** Vision: estetické skóre (`VNCalculateImageAestheticsScoresRequest`, dává i "utility" příznak pro screenshoty a účtenky), feature print pro podobnost a duplicity, detekce obličejů a landmarks pro zavřené oči, vlastní měření ostrosti (variance Laplaciánu nad náhledem). Žádné API klíče, žádné náklady, 3 000 fotek v rozumném čase na Apple Silicon.
- **Třídění nad náhledy, originály jen pro vybrané.** Analýza běží nad náhledy kolem 1024 px, které PhotoKit vydá rychle a lokálně. Originál se stáhne z iCloudu až když fotka přistane v albu, na pozadí, s viditelným stavem. Export odmítne pokračovat, dokud nemá všechny originály.
- **Projekt je balík (package) na disku, samostatný.** Obsahuje JSON s albem, cache náhledů a kopie originálů všech umístěných fotek. Důvod: export nesmí záviset na tom, jestli je iCloud zrovna dostupný nebo jestli fotku někdo mezitím smazal z Photos. Velikost v řádu 1 až 2 GB je přijatelná. Fotky se odkazují i identifikátorem z Photos, aby šlo originál znovu dohledat.
- **Autosave + verze.** Standardní macOS dokumentový model (autosave, Versions, undo/redo přes celý model). Každá změna je uložená do sekund. Žádné tlačítko Uložit v hlavním toku.
- **Jeden vykreslovač pro obrazovku i PDF.** Dvoustrana je datový model, který jeden renderer nad Core Graphics kreslí do okna i do PDF. To, co uživatel vidí, je to, co se tiskne. Náhled v aplikaci ukazuje ořez, spadávku a bezpečnou zónu.
- **Výchozí formát: fotokniha Canva na šířku v největším formátu, který Canva pro Česko nabízí v tvrdé vazbě, druhý čtverec.** Přesné hodnoty z Canvy (viz 3). Formát se volí při založení alba a lze ho změnit, rozložení se přepočítá.
- **Profily dodavatelů jsou data, ne kód.** Rozměr strany, spadávka, bezpečná zóna, strany vs. dvoustrany, obálka zvlášť a výpočet hřbetu, pravidla počtu stran, barevný profil, pojmenování souborů. Verze 1 má jen profil Canva; Saal se přidá jako druhý bez změny aplikace. Model dvoustrany musí od začátku umět obě varianty: jednotlivé strany (Canva) i spojené dvoustrany (Saal), a samostatnou první a poslední stranu, pokud to profil vyžaduje.
- **Přegenerování vs. ruční úpravy (otázka stavitele).** Album se generuje jednou krokem "Navrhnout album". Potom se změny výběru promítají přírůstkově: nově vybraná fotka přibude do zásobníku dne a na konec jeho galerijních dvoustran (nová dvoustrana, když je plno), vyhozená fotka vyprázdní rámeček a označí ho. Dvoustrany a rámečky mají příznak "upraveno ručně". Explicitní "Navrhnout znovu" přepíše jen dvoustrany bez tohoto příznaku, a před tím řekne, kolik ručně upravených zachová. Nikdy se ruční práce nepřepíše bez potvrzení. Totéž pro změnu formátu: rozložení se přepočítá, obsah (fotky, texty, pořadí) zůstává.
- **Zdroj fotek je snímek v okamžiku založení, s ručním "Načíst nové fotky" (otázka stavitele).** Projekt si pamatuje dotaz (rozmezí dat nebo album). Akce "Načíst nové fotky" ho spustí znovu, nové fotky přidá do dnů jako nevybrané a spustí pro ně analýzu, smazané fotky v Photos označí (originál v projektu zůstává, takže album drží). Žádné živé sledování knihovny.
- **Fotky bez GPS nebo s cizím časem, typicky z foťáku (otázka stavitele).** Časová zóna a místo se u fotky bez GPS odvodí z nejbližší fotky s GPS v čase (obvykle iPhone). Nástroj "posunout čas fotek z tohoto zařízení" není ve verzi 1; pokud se den rozpadne, uživatel fotku přetáhne do správného dne ručně, což třídění musí umožnit.
- **Písma:** dvě open source rodiny s licencí OFL přibalené v aplikaci, serif pro titulky deníku a grotesk pro popisky. V mockupu byly Fraunces a Schibsted Grotesk; builder může zvolit jiné s podobným charakterem. Písma se do PDF vkládají.
- **Jazyk UI: čeština.** Datum a místo v albu česky ("Čtvrtek 18. června 2026").

## 6. Jak se s aplikací pracuje

Pět kroků v jednom okně, uživatel se mezi nimi volně vrací.

### 6.1 Založení alba

Nové album: název (např. "Amalfi 2026"), formát (ze seznamu podle profilu dodavatele), zdroj fotek. Zdroj v verzi 1: rozmezí dat v knihovně Photos, nebo existující album/sdílené album v Photos (u sdíleného alba aplikace upozorní, že fotky jsou zmenšené a pro tisk nemusí stačit). Po potvrzení aplikace okamžitě ukáže fotky (náhledy) a na pozadí spustí analýzu s viditelným průběhem.

### 6.2 Třídění

Fotky rozdělené po dnech, uvnitř dne po místech (reverse geocoding z GPS, cache, offline fallback na souřadnice nebo "bez místa"). Den je podle místního času místa pořízení, ne podle času macu (viz pasti v 10).

Každá fotka má: skóre kvality, příznaky (rozmazaná, zavřené oči, duplicita, screenshot/účtenka, video), příslušnost do série (burst, podobné fotky za sebou). U každého dne aplikace předvybere doporučené fotky: nejlepší z každé série, bez vadných, s rozumným počtem na den podle toho, kolik fotek den má (builder navrhne heuristiku, např. 8 až 20 na den, víc pro dny s víc místy).

Uživatel prochází den po dni: vidí doporučené, zbytek zašedlý, jedním klikem přidává nebo vyhazuje, série se dají rozbalit. Vidí počet vybraných a odhad počtu stran. Výběr je stav fotky, ne kopie, takže se dá kdykoli vrátit.

Od okamžiku, kdy je fotka vybraná, se na pozadí stahuje její originál a ukládá do projektu.

### 6.3 Návrh alba

Jedním krokem aplikace vygeneruje album z vybraných fotek:

- Úvodní dvoustrana: název, rozmezí dat, seznam míst, jedna velká fotka.
- Pro každý den (nebo místo, pokud má den víc výrazných míst): deníková dvoustrana (B) s datem, předvyplněným titulkem z místa ("Ravello, Minori"), prázdným textem a 3 až 5 fotkami, následovaná 0 až N galerijními dvoustranami (A) s 1 až 2 fotkami na stranu podle počtu vybraných fotek dne.
- Závěrečná dvoustrana (volitelně).
- Obálka: přední strana s názvem a jednou fotkou, zadní prázdná nebo s malou fotkou.

Pořadí fotek je chronologické. Výběr fotek do rámečků respektuje orientaci (na výšku do rámečků na výšku) a skóre (nejlepší fotka dne na velký rámeček). Počet stran se dorovná na pravidla dodavatele (sudý počet, minimum, násobky).

Výsledek nemusí být dobrý, musí být rozumný výchozí bod, který uživatel ladí.

### 6.4 Ladění

Hlavní pohled: pruh dvoustran vlevo nebo dole (přehled a přeskládání tažením), velká dvoustrana uprostřed, vpravo zásobník fotek z aktuálního dne a sousedních dní (vybrané i nevybrané, s možností přepnout na celý výběr).

Na dvoustraně: táhnout fotku ze zásobníku do rámečku (vymění), prohodit dvě fotky tažením, posunout nebo přiblížit fotku v rámečku, upravit text přímo na místě, změnit šablonu dvoustrany (jiné rozložení stejného typu, nebo změna typu A na B a zpět), přidat nebo smazat dvoustranu, rozdělit den na dvě.

Vždy viditelné: hranice ořezu, spadávka, bezpečná zóna, hřbet. Varování přímo na dvoustraně: nízké rozlišení fotky pro daný rámeček, text v nebezpečné zóně, originál ještě nestažen.

Undo/redo na všechno.

### 6.5 Export

Tlačítko "Exportovat pro Canva" (název podle profilu). Nejdřív kontrola před exportem (preflight), seznam problémů s odkazem na dvoustranu:

- chyba (blokuje): chybějící originál, fotka pod 150 DPI při umístěné velikosti, nesplněná pravidla počtu stran, prázdný rámeček;
- varování (lze přijmout): fotka pod 220 DPI, text nebo obličej v zóně spadávky či blízko hřbetu, prázdný text v deníkové dvoustraně.

Pak se vytvoří výstup podle profilu: PDF (nebo sada JPG stran, co profil chce) vnitřních stran nebo dvoustran v pořadí, obálka podle profilu (Canva: přední strana jako samostatný soubor; Saal: zadní + hřbet + přední s hřbetem spočítaným z počtu stran), sRGB, fotky převzorkované na 300 DPI při umístěné velikosti, JPEG kvalita blízko maximu, písma vložená. Vedle toho krátký textový soubor "co nahrát kam" s názvem formátu, počtem stran a kroky v uploadu dodavatele.

Export do složky, kterou uživatel vybere. Po exportu aplikace nabídne otevření složky.

## 7. Datový model (hrubě)

- Album: název, profil dodavatele, formát, svět (verze 1: "deník + galerie"), seznam dvoustran, obálka, zdroj fotek, stav analýzy.
- Fotka: identifikátor z Photos, datum a čas pořízení s časovou zónou, GPS, orientace, rozměry originálu, skóre a příznaky, série, den, místo, stav výběru, stav originálu (chybí / stahuje se / v projektu), cesta k originálu v projektu, cesta k náhledu.
- Dvoustrana: typ (úvod, deník, galerie, závěr), šablona, rámečky s fotkou a jejím posunem/zvětšením, textová pole s obsahem, přiřazený den.
- Profil dodavatele (JSON v bundlu): viz 5.

Všechno serializovatelné do JSON v balíku projektu, s verzí formátu kvůli budoucím migracím.

## 8. Rychlost a práce na pozadí

Cíle na macu s Apple Silicon a 3 000 fotkách:

- do 5 s od výběru zdroje vidí uživatel mřížku náhledů a může listovat;
- do 30 s je hotové rozdělení po dnech a místech (metadata, bez analýzy obrazu);
- analýza obrazu (skóre, duplicity, obličeje) běží na pozadí, průběžně se promítá do UI, hotová řádově v jednotkách minut; uživatel může třídit dřív a doporučení se doplňují;
- stahování originálů na pozadí, souběžně, s omezením počtu; stav vidět u fotky a souhrnně;
- listování dvoustranami a tažení fotek plynulé (náhledy z cache, originál se kreslí až pro export a zoom).

Všechno, co se spočítalo, se ukládá do projektu, aby se po restartu nepočítalo znovu.

## 9. Co se nechává na builderovi

- Přesná architektura (moduly, MVVM nebo jiné), jak oddělit zdroj fotek za protokol tak, aby šel později přidat import ze složky a sdílená knihovna.
- Konkrétní heuristiky: kolik fotek na den doporučit, prahy pro "rozmazaná", jak slučovat série, kdy rozdělit den na víc míst, kolik galerijních dvoustran na den.
- Konkrétní sada šablon pro dvoustrany A a B (řádově 3 až 5 variant každé) a pravidla, jak se do nich fotky vybírají podle orientace.
- Jak vyřešit, že SwiftUI nemusí utáhnout mřížku 3 000 fotek (pravděpodobně NSCollectionView).
- Formát balíku projektu, verzování, strategie cache.
- Testy: layout engine, seskupování, preflight a profil dodavatele jsou čistá logika a mají mít unit testy; renderer má mít snapshot testy dvoustran; PhotoKit se schová za protokol s falešnou implementací nad složkou fotek pro testy.
- Jak vložit JPEG do PDF bez překódování a jak řídit kvalitu.

## 10. Známé pasti

- **Sdílená alba iCloud zmenšují fotky** na zhruba 2 048 px na delší straně. Pro tisk přes celou stranu nestačí. Aplikace to musí poznat (rozměry originálu) a varovat už při výběru zdroje.
- **Časová zóna.** PHAsset dává datum pořízení v UTC; den dovolené se má počítat v místním čase místa pořízení. Bez správné zóny se noční fotky přelévají do jiného dne. Zónu odvodit z GPS (nebo z EXIF přes content editing input), s fallbackem.
- **Živé fotky, videa, RAW+JPEG páry, HEIC.** Videa se do alba nedávají (ale ukazují se zašedlé). RAW se nemusí řešit, pokud Photos vydá renderovaný JPEG/HEIC. HEIC se při exportu překóduje do JPEG.
- **Oprávnění k Photos.** Aplikace potřebuje Photos usage description a žádá o plný přístup. Bez něj nic nefunguje, UI to musí vysvětlit.
- **Reverse geocoding** vyžaduje síť a má limity. Cache výsledků, dávkování, a nic nesmí na geocodingu čekat.
- **Barevný prostor.** Fotky z iPhonu jsou Display P3, Saal chce sRGB. Převod při exportu, ne při zobrazení.
- **Šířka hřbetu** (profil Saal) závisí na počtu stran a typu papíru. Vzít z šablon Saalu pro daný formát; pokud šablony dávají jen pár hodnot, interpolovat a varovat.
- **Import PDF do Canvy.** Canva stránky PDF převádí na své objekty a fotky může překomprimovat nebo rozložit. Builder má v rámci profilu Canva ověřit na zkušebním PDF, jak Canva fotky importuje, a podle toho zvolit mezi PDF a sadou JPG/PNG stran v plném rozlišení (Canva umí nahrát obrázky a vložit je jako stránky). Ověřit před stavbou exportu, ne po.

## 11. Otevřené otázky pro zadavatele

Žádné blokující. Věci, které se rozhodnou při stavbě nebo po první verzi:

- Jestli má album mít i závěrečnou dvoustranu a co na ní.
- Jaký konkrétní formát a papír v Canvě nakonec objednají (ovlivní jen profil, ne aplikaci).
- Kdy přidat profil Saal a zda stáhnout jeho šablony (vyžaduje účet zadavatele).
