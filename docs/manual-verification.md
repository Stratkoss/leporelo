# Ruční ověření před prvním tiskem

Kontrolní seznam toho, co se při stavbě nedalo ověřit: agenti nespouštěli aplikaci, neměli přístup do knihovny Photos ani účet Canva. Testy (`make test`, `make test-app`) tyto věci nepokrývají. Odškrtávej po jednom a nález, který nevyjde, si poznamenej s popisem, co se stalo.

Příprava: `make build-app`, pak `make run-app`. Chyby a diagnostika jdou do Konzole (subsystém `com.stratkoss.leporelo`). Pro kontroly bez Photos stačí album vytvořené příkazem `leporelo-cli draft` (viz README); otevři ho přes Soubor > Otevřít.

## A. První spuštění a oprávnění k Photos

- [ ] **Nejdřív:** spuštění aplikace (bez otevřených dokumentů k obnovení) ukáže úvodní okno „Leporelo“, žádný systémový panel Otevřít a žádné prázdné okno bez názvu. Potlačení panelu je postavené jen na registraci `NSShowAppCentricOpenPanelInsteadOfUntitledFile = false` v `LeporeloApp.init()` a na `applicationShouldOpenUntitledFile` = false v delegátu aplikace; při stavbě to ověřit nešlo. Když se panel Otevřít nebo prázdné okno přesto ukáže, zapiš co přesně. Zkus i spuštění s otevřenou knihou z minula (obnoví se kniha a k ní úvodní okno) a klik na ikonu v Docku, když nejsou otevřená žádná okna (zapiš, co se stane; prázdné okno bez názvu se objevit nesmí). Spusť aplikaci i dvojklikem na `.leporelo` ve Finderu a zapiš, jestli se vedle knihy ukáže i úvodní okno (`defaultLaunchBehavior(.presented)` ho ukazuje při každém spuštění).
- [ ] Úvodní okno při nerozhodnutém přístupu ukáže vpravo vysvětlení a tlačítko „Povolit přístup k Fotkám“. Po kliknutí se objeví systémový dotaz právě jednou. Očekávání: po povolení plného přístupu se vlevo objeví alba z Fotek a vpravo mřížka prvního alba.
- [ ] V Nastavení systému > Soukromí > Fotky přepni aplikaci na „Vybrané fotky“ (limited) a vrať se do úvodního okna. Očekávání: pravá strana ukáže vysvětlení omezeného přístupu a tlačítko „Otevřít Nastavení systému“ otevře správný panel. Volání nad knihovnou nesmí vrátit částečný seznam fotek.
- [ ] Totéž pro „Žádné“ (denied) a, pokud to jde nasimulovat, pro omezený přístup správcem (restricted). Očekávání: v restricted se tlačítko nastavení nezobrazuje.
- [ ] Odeber přístup za běhu u otevřeného, už zanalyzovaného alba. Očekávání: album dál funguje, banner ukáže chybějící přístup s tlačítkem „Otevřít Nastavení systému“. U nového alba bez náhledů se ukáže celookenní obrazovka s vysvětlením. Po vrácení přístupu a návratu do aplikace práce na pozadí znovu naběhne.

## B. Úvodní okno a založení knihy

- [ ] „Alba v iCloudu“ odpovídají Fotkám: stejná běžná i sdílená alba (i alba ve složkách), stejné názvy a počty fotek (bez videí). Sdílené album má ikonu dvou postav a po najetí myší ukáže upozornění na zmenšené fotky.
- [ ] Mřížka alba se scrolluje plynule i u alba kolem 3 000 fotek: náhledy se dotahují při scrollu, okno nezamrzá a výběr jiného alba během načítání ukáže fotky nově vybraného alba (ne předchozího). Když scroll drhne, zapiš to (náhrada je `NSCollectionView` jako v třídění).
- [ ] „Moje knihy“ ukazují naposledy otevřené knihy (bez přípony); klik knihu otevře a úvodní okno zavře. Kniha, která už je otevřená, se jen přenese dopředu.
- [ ] Šipkami v postranním panelu projdu knihy i alba, nic se neotevře; kliknutím na knihu se otevře. Kniha vybraná šipkami ukáže vpravo svůj název a tlačítko „Otevřít“; Return nebo dvojklik ji otevře taky.
- [ ] Dvojklik na knihu v „Moje knihy“ ji otevře jen jednou: jedno okno knihy, žádné druhé okno ani chybové hlášení (zkus i u knihy, která už je otevřená v pozadí).
- [ ] Zavři všechna okna (aplikace běží dál) a klikni na ikonu Leporela v Docku. Očekávání: otevře se úvodní okno „Leporelo“, ne prázdný dokument ani nic. Když je otevřené okno knihy, klik v Docku ho jen přenese dopředu a úvodní okno neotevře.
- [ ] `make test-app` při běhu neukáže v úvodním okně testovací aplikace alba z Fotek (okno zůstane prázdné) a nespustí dotaz na přístup k Fotkám.
- [ ] Soubor > Nové album… (Cmd-N) úvodní okno znovu otevře, i když je vepředu okno knihy; totéž tlačítko „Nové album…“ v liště knihy a Okno > Úvod. V nabídce Okno je „Úvod“ jen jednou (bez další položky „Leporelo“).
- [ ] „Jinak“ > „Podle data…“: výchozí rozmezí je od před 7 dny do dneška, „Od“ a „Do“ mění mřížku i počet. Rozmezí bez fotek ukáže „V tomto rozmezí nejsou žádné fotky“ a „Udělat z toho knihu“ je vypnuté.
- [ ] „Udělat z toho knihu“ u alba: list má název alba, formát „Na šířku 8 × 6 in (Canva)“ s poznámkou „Rozměry formátu nejsou ověřené u dodavatele.“ a po chvíli „Fotek ve zdroji: N“. U data je název „Nové album“. U sdíleného alba ukáže oranžovou poznámku o sdílených albech iCloudu (zmenšené fotky) a dovolí založení.
- [ ] „Založit“ nabídne uložení jako „<název>.leporelo“ (u data „Nové album.leporelo“). Ulož na plochu. Očekávání: okno alba se otevře do několika sekund, banner ukazuje „Analyzuji fotky 0 / N“ a počítá nahoru, okno zůstává plynulé, po skončení banner zmizí (nebo ukáže „Zjišťuji místa…“, dokud běží geocoding).
- [ ] Názvy míst se objeví později, ne hned; třídění po dnech je použitelné dřív. Fotky s GPS mají po dokončení v `album.json` (Zobrazit obsah balíku) pole `placeName`.
- [ ] Zavři okno uprostřed analýzy a balík znovu otevři. Očekávání: analýza pokračuje se zbývajícím počtem. Po dokončení má `album.json` vyplněné `analysis` a část fotek `isSelected: true`. Otevření dokončeného alba nezmění výběr a neukáže banner.
- [ ] V uložení vyber existující `.leporelo` a potvrď. Očekávání: panel zůstane otevřený a ukáže „Na tomto místě už album je. Zvolte jiný název.“; systémový dotaz „Nahradit?“ se neobjeví. Pokud se objeví (pořadí volání delegáta je jiné, než se předpokládalo), existující balík se přesto nesmí přepsat a ukáže se „Album s tímto názvem už existuje.“.
- [ ] Během „Zakládám album…“ jsou formulář i „Zrušit“ vypnuté. Po otevření knihy se list i úvodní okno zavřou.
- [ ] Smaž z `thumbs/` jeden soubor v hotovém albu a album otevři. Očekávání: krátce se ukáže „Analyzuji fotky 0 / 1“, soubor je zpět a výběr se nezměnil.

## C. Fakta o PhotoKit k potvrzení

Dosud nikdo neprošel PhotoKit proti skutečné knihovně. Nejjednodušší je dočasné tlačítko v `App/Leporelo/Sources/AlbumWindow.swift`, které zavolá `PhotoKitAuthorization.request()`, `PhotoKitSource().photos(matching: .dateRange(start:end:))`, `albums()`, u první fotky `thumbnail(for:maxPixel: 512)`, `original(for:)` a `isLocallyAvailable(identifier:)` a vypíše výsledky (potom tlačítko odstraň). Většinu lze vyčíst i z chování v oddílech B, D a F.

- [ ] Rozměry z `PHAsset` jsou upright. U portrétní fotky z iPhonu je `pixelWidth < pixelHeight`, náhled je na výšku s delší stranou 512 px a původní HEIC v Náhledu stojí správně. Když vyjdou otočené, musí se opravit zdroj (zbytek aplikace počítá s upright rozměry).
- [ ] Upravená nebo ořezaná fotka (úprava ve Photos) vrátí upravenou verzi a rozměry jí odpovídají.
- [ ] Sdílená alba iCloudu se vypíšou s nenulovým počtem, mají zhruba 2 048 px na delší straně a dotaz na album vrací fotky. Když vrátí 0, je potřeba upravit dotaz (`includeAssetSourceTypes`, případně načtení kolekce bez voleb).
- [ ] Náhled má přesně požadovaný pixelový rozměr (512 px na delší straně), ne dvojnásobek bodů.
- [ ] Volba zdroje originálu a přípona: iPhone fotka dá příponu `heic`, upravená fotka dá upravenou verzi, RAW dá velký soubor (dng), Live Photo dá fotku.
- [ ] Fotka jen v iCloudu (Optimalizovat úložiště): před stažením je `isLocallyAvailable` `false`, po stažení `true`.
- [ ] Cena `isLocallyAvailable` (čte celý lokální soubor): s několika sty vybranými fotkami otevření alba a změna stavu stahování nezpomalí okno.
- [ ] Počet za posledních 7 dní odpovídá Photos a načtení trvá výrazně méně než 5 s. Videa se nenačtou vůbec, v mřížce nejsou ani prázdné buňky, a počet alba ve výběru Photos počítá jen fotky.

## D. Třídění

- [ ] Rychlost mřížky: album s kolem 3 000 fotek (nebo den s několika sty). Rychlé rolování je plynulé bez sekání, placeholdery se rychle mění na náhledy, paměť zůstává rozumná.
- [ ] Při analýze nového alba přibývají náhledy a odznaky (rozmazaná, zavřené oči, série ×N) postupně, bez blikání a bez skoku nahoru.
- [ ] Jedno kliknutí na fotku ji vybere nebo zruší (zešedne nebo se vrátí, objeví se zatržení).
- [ ] Přetažení fotky na jiný den v levém seznamu ji přesune a řádek dne se při tažení orámuje. Tažení fotku nesmí zároveň přepnout výběr. Upuštění na „Bez data“ nedělá nic. Pokud tažení přepíná výběr, je chyba v obsluze mouseDown v `PhotoGridView`.
- [ ] Chip série „×4“ rozbalí a sbalí sérii na místě, klik na chip nepřepne vedoucí fotku. S vybranými členy chip ukazuje „2 z 4“.
- [ ] Klávesnice: šipky nahoru a dolů v seznamu dnů mění den; v mřížce šipky posouvají fokus a mezerník přepíná výběr.
- [ ] Undo: po přepnutí výběru nebo přesunu říká položka nabídky „Odvolat: Vybrat fotku“ nebo „Odvolat: Přesunout fotku do dne“ a Cmd-Z stav vrátí.
- [ ] VoiceOver čte buňky jako „Fotka, vybraná, …“ (zatržítko) a VO-mezerník přepíná výběr.
- [ ] Vzhled: nevybrané fotky jsou ztlumené, odznaky jsou čitelné na světlých i tmavých fotkách ve světlém i tmavém režimu, tlačítko „Navrhnout album“ je při nedostupnosti vypnuté s popiskem (ověř, že se popisek u vypnutého tlačítka vůbec zobrazí).
- [ ] Když album už má dvoustrany, přesun vybrané fotky na jiný den přesune i její umístění v rozložení (jedno Cmd-Z to vrátí).
- [ ] Dlouhá cesta (kolem 3 000 fotek za 10 dní, výběr přes 200 fotek): patička třídění ukáže vedle počtu stran oranžové „Přesahuje maximum 98 stran“, když odhad přesáhne maximum profilu. „Navrhnout album“ pak dává do galerie 3 fotky na dvoustranu; počet stran klesne, ale může zůstat nad maximem (export to pak zablokuje).
- [ ] Analýza fotek po návrhu: album s dvoustranami, ve kterém část fotek ještě nemá analýzu (například po „Načíst nové fotky ze zdroje“ nebo po zavření okna uprostřed analýzy a „Navrhnout album“). Po doběhnutí analýzy se výběr nezmění: žádná fotka v rámečku nezešedne jako nevybraná.

## E. Editor

Otevři album s fotkami, které ještě nemá dvoustrany (nebo jeho kopii). Fotky z Photos nejsou potřeba.

- [ ] Tok režimů: „Navrhnout album“ navrhne a přepne na „Dvoustrany“; Cmd-Z hned potom návrh vrátí a okno se vrátí do třídění. Album s dvoustranami se otevře rovnou v „Dvoustranách“. Přepínač v liště funguje oběma směry; „Dvoustrany“ bez vybraných fotek zůstanou v třídění.
- [ ] Plátno: dvoustrana vyplňuje střed, je vidět červená ořezová čára, světle červený pás spadávky, modré obdélníky bezpečné zóny a šedá linka hřbetu. Fotky naskočí po chvíli (do té doby šedé), rolování pásu nesekne. Velikost a poloha textů odpovídá exportu.
- [ ] Výběr: klik na rámeček nebo text ho orámuje a ukáže 8 čtverečků (úchytů) v barvě akcentu; klik na pozadí a Escape výběr zruší. Na obálce se nic nevybírá a úchyty nejsou.
- [ ] Posun a změna velikosti bez mřížky: tažení uvnitř rámečku (i prázdného) nebo textu ho posouvá, tažení za úchyt mění velikost jen na dané straně, protější strana stojí. Roh se Shiftem drží poměr stran. Rámeček nejde zmenšit pod 1 cm. Jedno Cmd-Z vrátí celé tažení („Odvolat: Upravit rozložení“). Fotka v rámečku zůstává oříznutá na rámeček.
- [ ] Přichytávání a vodítka (zapnuté „Přichytávat“, mřížka vypnutá): při tažení blízko okraje stránky, okrajové čáry, středu stránky, hřbetu nebo hrany či středu jiného rámečku (i mezery 4 mm) se rámeček přichytí a přes celou dvoustranu se ukáže tenká čára v barvě akcentu; po puštění zmizí. S podrženým Cmd se nepřichytává a čára se neukáže. S vypnutým „Přichytávat“ se nepřichytává k ničemu.
- [ ] Mřížka: „Mřížka“ v liště nakreslí jemné čáry po 5 mm v ořezu každé stránky (pod úchyty a vodítky, čitelné i v tmavém režimu) a rámečky se k nim přichytávají. Nastavení „Mřížka“ a „Přichytávat“ zůstane po novém spuštění aplikace.
- [ ] Okraj: „Okraj: 10 mm“ v liště, krok na 20 mm. Rámečky a texty, které ležely v pásu nového okraje, se odsunou (nebo zarovnají ke spadávce); jedno Cmd-Z vše vrátí na 10 mm. Stepper nejde pod bezpečnou zónu profilu ani nad 30 mm.
- [ ] Spadávka: rámeček přetažený k hraně stránky se přichytí na hranu a fotka pokryje i spadávku (červený pás). Rámeček nejde nechat v pásu okraje: po puštění stojí buď na hraně stránky, nebo na okrajové čáře. Šipka ven z okrajové čáry ho neuvězní, ale přesune na hranu stránky (viz kontrola šipek u kraje stránky níže); tažením se dostane až ke spadávce.
- [ ] Šipky s vybraným rámečkem nebo textem ho posouvají o 1 mm (Shift = 5 mm), držení klávesy je jeden krok zpět. Šipky vlevo a vpravo bez výběru přepínají dvoustrany.
- [ ] Šipky u kraje stránky: rámeček na čáře okraje se šipkou ven (i o 1 mm) přesune na hranu stránky do spadávky a šipkou dovnitř se z hrany vrátí na čáru okraje; Shift+šipka od pravé čáry okraje dojede na hřbet. Rámeček přes celou stranu se šipkou → odsune o šířku okraje (přes hřbet), nahoru ani dolů se nehne (nemá kam).
- [ ] Režim výřezu: dvojklik na fotku ho zapne (čárkovaný okraj v barvě akcentu, bez úchytů). Tažení pak posouvá fotku pod ukazatelem a zastaví se na krajích; jedno Cmd-Z vrátí celé tažení („Odvolat: Posunout fotku“). Šipky posouvají fotku (Shift = 5 mm). Escape, Return nebo klik mimo rámeček režim ukončí (klik na jiný rámeček ho rovnou vybere). Dvouprstové rolování a pinch zoomují 1× až 4× jen v režimu výřezu a jen nad tou fotkou, jedno Cmd-Z na gesto; mimo režim výřezu fotku nepřiblíží.
- [ ] Kontextová nabídka (pravé tlačítko): na pozadí jen „Přidat rámeček“ a „Přidat text“ (přidají se na stránku pod ukazatelem a vyberou se); na fotce navíc „Upravit výřez“, „Obnovit výřez“ (jen když je výřez posunutý nebo přiblížený), „Odebrat fotku“ a „Smazat“; na prázdném rámečku a textu „Smazat“. Každá akce je jeden krok zpět. Na obálce se nabídka neukáže.
- [ ] Lišta: „Přidat rámeček“ a „Přidat text“ přidají na aktuální stránku (stránka vybraného rámečku nebo textu, jinak naposledy kliknutá); bez aktuální stránky na pravou. Když je zobrazená obálka, jsou neaktivní. Delete na prázdném rámečku nebo textu ho smaže.
- [ ] Podržená klávesa Delete na rámečku s fotkou jen odebere fotku, rámeček zůstane.
- [ ] Cmd-Z uprostřed tažení rámečku (myš drží): tažení pokračuje, po puštění jedno Cmd-Z vrátí zbytek tažení, žádný řetěz drobných kroků.
- [ ] Klasická myš s kolečkem (bez plynulého rolování): kolečko nad fotkou v režimu výřezu zoomuje rozumnými kroky (ne skokem na 4×), po chvíli bez otáčení se gesto uzavře a jedno Cmd-Z ho vrátí.
- [ ] Cmd-Z uprostřed tažení výřezu (myš drží): potom jedno Cmd-Z vrátí zbytek tažení, žádný řetěz drobných kroků.
- [ ] Přetažení fotky ze zásobníku na rámeček: rámeček se při tažení zvýrazní, fotka nahradí původní a tečka v zásobníku se přesune. Upuštění na text nebo pozadí nedělá nic. Pokud SwiftUI zásobník a AppKit plátno nespolupracují, je chyba v přenosu (prostý text s identifikátorem fotky).
- [ ] ⌥-tažení fotky na jiný rámeček téže dvoustrany obě fotky prohodí i s výřezy. Vzhled tažení: pod ukazatelem jde rozumný obrázek fotky (výřez z plátna), cílový rámeček se zvýrazní, po puštění nezůstane nic viset.
- [ ] Pás dvoustran: klik zobrazí dvoustranu a zásobník sleduje její den. Přetažení položky přeřadí s vloženou svislou čárou; úvod a závěr nejdou tahat a nic nejde před úvod ani za závěr. Kontextová nabídka: „Doporučené rozložení…“, „Vložit dvoustranu za“ (Galerie, Deník, Prázdná), „Smazat dvoustranu“ (ptá se jen když má obsah). Náhledy se po úpravách aktualizují. Přední a zadní obálka jsou na začátku a jen ke čtení.
- [ ] Delete na vybraném rámečku ho vyprázdní, objeví se červený odznak „Rámeček je prázdný…“ a v záhlaví pásu „1 vybraná fotka není v albu“; popover ji vypíše a klik na ni přeskočí zásobník a na 2 s ji orámuje.
- [ ] Text: dvojklik na textové pole otevře překryv se stejným písmem a velikostí; porovnej s vytištěným/exportovaným textem (PNG nebo `pages.pdf` v Náhledu), že zalamování a velikost sedí. Zadej text a klikni jinam: uloží se a jedno Cmd-Z vrátí celé psaní.
- [ ] Cmd-Z při psaní: překryv ukáže předchozí text a zůstane otevřený; další psaní funguje a Cmd-Shift-Z se chová rozumně. Return ukončí titulek nebo popisek, v těle deníku dělá nový řádek, Escape editaci ukončí a text zachová.
- [ ] Přepnutí do jiné aplikace (Cmd-Tab) uprostřed psaní textu a návrat: napsaný text zůstal uložený (jedno Cmd-Z ho vrátí) a nic se neztratilo.
- [ ] Dlouhý text: do popisku nebo těla deníku napiš víc textu, než se vejde do rámečku. Překryv se dá rolovat (objeví se svislý posuvník) a konec textu jde vidět i upravit. Po ukončení psaní je u textu na plátně oranžová ikona s popiskem „Text se nevejde do rámečku, konec se nevytiskne“ a kontrola v exportu ukáže stejné varování. V exportovaném PDF je text uříznutý na hranici rámečku.
- [ ] Zrušení překryvu: otevři překryv bez psaní a klikni na fotku. Překryv zmizí a nabídka Úpravy už neříká „Odvolat: Upravit text“.
- [ ] Změna šablony, která zahodí text: potvrzení „Tyto texty by se ztratily: …“ se ukáže uvnitř výběru rozložení pod otázkou „Použít doporučené rozložení?“; „Použít“ změnu provede (Odvolat: „Použít doporučené rozložení“) a výběr zavře. Nesmí se objevit druhý dialog po zavření sheetu.
- [ ] Ručně upravená dvoustrana (posunutý rámeček) a výběr TÉŽE šablony v „Doporučená rozložení“: zeptá se „Ruční rozložení se nahradí doporučeným.“ a po potvrzení vrátí doporučené rozložení (jedno Cmd-Z ho zase vrátí na ruční).
- [ ] Ručně upravená dvoustrana s textem a výběr šablony, která by text zahodila: jedno společné potvrzení „Ruční rozložení se nahradí doporučeným.“ obsahuje i „Tyto texty by se ztratily: …“; „Nahradit“ změnu provede a nepřijde druhý dialog za ním.
- [ ] Fotka, která už v knize je, přetažená ze zásobníku na rámeček: sheet „Tahle fotka už v knize je“ s „Je na: …“ a tlačítky „Dát i sem“, „Přesunout sem“, „Zrušit“ se ukáže správně (sheet se otevírá zevnitř upuštění, nesmí se zaseknout ani zmizet) a každá volba udělá, co říká.
- [ ] Nabídka Úpravy: titulky „Odvolat: …“ a „Znovu: …“ se po každé změně hned obnoví. Položka se záměrně nikdy nevypíná: když není co odvolat, říká jen „Odvolat“ a Cmd-Z nic neudělá. V listu „Udělat z toho knihu“ Cmd-Z v poli názvu pořád vrací psaní.
- [ ] Cmd-Z v listu „Udělat z toho knihu“ úvodního okna otevřeného z okna alba (Cmd-N, když je album vepředu): napiš do pole názvu pár znaků a stiskni Cmd-Z. Očekávání: vrátí se psaní v poli, album se nezmění (třeba výběr fotky nebo text zůstanou). Totéž v sheetu exportu, ve výběru šablony a v potvrzovacích dialozích.
- [ ] Cmd-W nebo Cmd-Q do 0,5 s po posledním písmenu psaného textu a následné otevření: poslední znaky mohou chybět (ověř a zapiš; zaručené je jen uložení po 0,5 s nečinnosti).
- [ ] Varování: nízké DPI, chybějící originál a text mimo bezpečnou zónu mají oranžové nebo červené ikony u rámečku či rohu textu s popiskem; prázdné tělo deníku dá pruh „1 problém na této dvoustraně“ s popoverem; chyba počtu stran je v záhlaví pásu („N problémů alba“).
- [ ] Panel nástrojů: „Navrhnout znovu“ ukáže „Zachovám N ručně upravených dvoustran. Pokračovat?“ se správným N; „Formát“ vypíše formáty se zatržením a změna ukáže „Rozložení se přepočítá, obsah zůstane.“ a přepočítá.
- [ ] VoiceOver: položky pásu čtou „Dvoustrana 3, Deník, čtvrtek 18. června 2026, 2 problémy“, buňky zásobníku „Fotka čt 18. 6. · 9:05, vybraná, v albu“.
- [ ] Výkon: psaní textu ve velkém albu (stovky dvoustran) nesekne (miniatury v pásu se při změně přepočítávají).

## E2. Rozložení stránek a oblíbená rozložení

Potřebuješ album s dvoustranami (ideálně Davidovo z Canvy) a čistý stav oblíbených: `defaults delete com.stratkoss.leporelo layouts.liked` a totéž pro `layouts.asked`.

- [ ] První „Udělat z toho knihu“ ukáže nejdřív „Která rozložení se ti líbí?“: 9 náhledů v mřížce 3 sloupců s názvem a srdíčkem, list široký 640. Klik na náhled ho orámuje barvou akcentu a změní srdíčko na plné, druhý klik označení zruší. Po „Hotovo“ nebo „Přeskočit“ se objeví obvyklý formulář (užší list, 500).
- [ ] Přeskočit: po „Přeskočit“ a dalším „Udělat z toho knihu“ se výběr už neukáže. Totéž po „Hotovo“ bez označení. Escape na listu s výběrem list zavře, ale nic neuloží, takže se výběr ukáže znovu.
- [ ] Menu Leporelo > „Oblíbená rozložení…“ otevře samostatné okno se stejným obsahem, s předvyplněnými dřívějšími oblíbenými. „Hotovo“ i „Přeskočit“ okno zavřou; „Hotovo“ uloží označená, „Přeskočit“ uložená oblíbená nezmění (srdíčka označená a nepotvrzená se zahodí). Okno otevřené podruhé ukáže uložený stav, ne srdíčka z minulého otevření.
- [ ] Náhledy v obou místech: ukázkové fotky jsou barevné přechody s ikonou ▭ / ▯, texty „čtvrtek 18. června“ a „Ravello“ jsou čitelné; v tmavém režimu zůstává stránka bílá a rámeček výběru i srdíčko jsou vidět.
- [ ] Návrh knihy z Davidova alba z Canvy: pokud označíš například `mosaic-6` a `opener-3`, „Navrhnout album“ je používá častěji než bez označení; nejlepší fotky mají celou stránku bez ohledu na výběr. Žádné prázdné rámečky, každý den má sudý počet stran. Změna oblíbených se projeví při dalším „Navrhnout znovu“ nebo přidání fotky; existující stránky se nemění.
- [ ] Aktuální stránka: klik na stránku dvoustrany ji orámuje (2 pt v barvě akcentu, odsazeno o 1 pt dovnitř); na obálce rámeček není. Výběr rámečku nebo textu určí aktuální stránku podle jeho středu.
- [ ] „Zkusit jinak“ (lišta): bez aktuální stránky je neaktivní s nápovědou po najetí „Klikni na stránku“; na stránce, pro kterou jiné rozložení neexistuje, je neaktivní s nápovědou „Pro tyhle fotky jiné rozložení není“. Jinak změní rozložení jen té stránky.
- [ ] „Zkusit jinak“ na 3 různých stránkách: každé kliknutí je jeden krok zpět („Odvolat: Zkusit jinak“); třikrát Cmd-Z vrátí stránku krok po kroku do původního stavu. Fotky zůstávají ve správných rámečcích (▯ nikdy v ▭), žádný prázdný rámeček.
- [ ] Ruční rozložení: na stránce, kterou jsi předtím upravil ručně (posun nebo změna velikosti rámečku), „Zkusit jinak“ i výběr z „Doporučené rozložení…“ nejdřív ukážou „Ruční rozložení se nahradí doporučeným.“ s tlačítkem „Nahradit“; když by se tím ztratil text, následuje ještě otázka na ztrátu textu. Cmd-Z vrátí ruční rozložení.
- [ ] Výběr rozložení stránky („Doporučené rozložení…“ na dvoustraně s aktuální stránkou): rozložení jsou seskupená podle počtu fotek („1 fotka“, „2 fotky“ …, „Bez fotek“ nakonec), u každého je náhled stránky a název; náhledy jsou čitelné i v tmavém režimu. Bez aktuální stránky nabídka ukáže jen „Klikni na stránku“.
- [ ] Stará kniha se dvoustranami `journal-*` / `gallery-*`: otevře se, jde změnit formát i okraj; „Zkusit jinak“ nejdřív potvrdí a pak převede jen vybranou stránku.
- [ ] Export nové knihy (PDF) a nahrání do Canvy: stránky vypadají jako v editoru, fotky na výšku jsou ve svislých rámečcích, žádný text nezmizel, nic není mimo bezpečnou zónu ani označené jako nízké rozlišení.

## E3. Lišta editoru, přichytávání a písmo (28. 10. 2026)

Nic z tohoto oddílu se při stavbě nedalo ověřit v běžící aplikaci (ovládání obrazovky nebylo k dispozici). Každá akce lišty má test na úrovni modelu (přidat rámeček a text, okraj, Navrhnout znovu, Formát, Zkusit jinak) a všechny testy prochází (core 432, aplikace 313). Ověřené mimo aplikaci: PDF s textem ve Fraunces tučné kurzívě, Schibsted Grotesk kurzívě a Helvetice tučné v barvě má ta písma vložená (podmnožiny Fraunces-BoldItalic, SchibstedGrotesk-Italic, Helvetica-Bold) a stránka vypadá správně.

**Lišta (spec 4).** U každé položky zapiš OK, nebo co se stalo.
- [ ] Zkusit jinak: jiné doporučené rozložení aktuální stránky; u ručně upravené se nejdřív zeptá; na obálce vypnuté s nápovědou.
- [ ] Přidat rámeček / Přidat text: na aktuální stránce (jinak na pravé), nová položka je vybraná; na obálce vypnuté.
- [ ] Vodítka: ve výchozím stavu vypnutá a stránka končí ořezem (bez spadávky a čar), takže je vidět bílá kolem fotek jako v tisku. Zapnutá ukážou ořez, bezpečnou zónu, hřbet a spadávku; po restartu zůstanou, jak byla. Tenká šedá čára ohybu (hřbet) je vidět vždy, i s vypnutými vodítky.
- [ ] Textová pole: každé (prázdné i vyplněné) má světle modrý podklad a modrý čárkovaný rámeček, i v tmavém režimu; v exportu nejsou.
- [ ] Mřížka: ukáže mřížku 5 mm a přichytává k ní; po restartu aplikace zůstane, jak byla.
- [ ] Přichytávat: vypnuté = fotka se chytá jen k mřížce (je-li zapnutá); po restartu zůstane.
- [ ] Okraj: šipky mění po 1 mm od bezpečné zóny profilu (u Canvy 6 mm) do 30 mm; všechny dvoustrany se upraví a jedno ⌘Z to vrátí.
- [ ] Žádná fotka se nedotkne kraje stránky ani hřbetu, všude je aspoň okraj (výchozí 6 mm), i na obálce. U staré knihy se nad plátnem ukáže „Některé fotky sahají až ke kraji stránky“ a „Srovnat do okraje“ ji opraví (jedno ⌘Z vrátí); pak lišta zmizí.
- [ ] Zúžené okno: položky, které se nevejdou, jsou v nabídce » s čitelným názvem. Hlavně zkus „Okraj“: dá se z přetékající nabídky vůbec změnit? (Podezření z kódu: krokovač v nabídce nefunguje.)
- [ ] Zpět do třídění, Navrhnout znovu (dialog s počtem zachovaných dvoustran), Formát (fajfka u aktuálního, změna s potvrzením), Exportovat… (vypnuté bez dvoustran), Třídění / Dvoustrany.

**Přichytávání (spec 2).**
- [ ] Táhni fotku k hraně sousední fotky se zapnutou i vypnutou mřížkou: sedne přesně na hranu, ne 1–2 mm vedle, i když je poblíž čára mřížky, okraje nebo střed stránky.
- [ ] Dvě fotky v zákrytu přiblíž (snímek obrazovky zvětši): mezi lícujícími hranami není světlá spára 1 px.
- [ ] Fotka mezi dvěma jinými v řadě: cvakne doprostřed, obě mezery mají fialový štítek se stejným číslem („12,5 mm“).
- [ ] Mezera stejná jako jinde na stránce: fotka cvakne a fialově se ukáže i ta druhá stejná mezera.
- [ ] Změna velikosti za úchyt: šířka nebo výška cvakne na rozměr sousední fotky a obě dostanou štítek s rozměrem.
- [ ] Fialové vzdálenosti k sousedům (a k hraně stránky, když soused chybí) se ukazují při tažení; se stisknutým ⌘ nic; po puštění myši zmizí. Štítky se nepřekrývají tak, aby nešly přečíst (zapiš, kde ano).
- [ ] Šipky: vzdálenosti se ukážou a chvíli po puštění klávesy zmizí; šipky nepřichytávají.
- [ ] U okraje: fialová čára se neukáže tam, kam fotka kvůli okraji nesmí.

**Písmo u textu (spec 3).**
- [ ] Klik na text: nad dvoustranou je pruh (písmo, velikost, tučně, kurzíva, zarovnání, barva, Výchozí). Bez vybraného textu je místo prázdné a plátno neposkočí. Na obálce pruh není.
- [ ] Písmo: nahoře Fraunces a Schibsted Grotesk, pod čarou písma Macu, každé svým písmem; hledání funguje (i bez diakritiky); seznam se neseká.
- [ ] Velikost: psaní čísla + Return, šipky, nabídka velikostí; 500 se omezí na 200 (zapiš, jestli políčko pak ukazuje 200, nebo pořád 500).
- [ ] Tučně / kurzíva: tlačítka i ⌘B / ⌘I; u písma bez tučného nebo kurzivního řezu jsou šedá. Zkus ⌘B i během psaní v textu (dvojklik).
- [ ] Zarovnání vlevo / na střed / vpravo; barvy z nabídky i „Jiná…“ (tažení v panelu barev = jeden krok zpět).
- [ ] Klik na „Téměř černá“ u textu bez vlastní barvy: zapiš, jestli to přidá krok zpět bez viditelné změny.
- [ ] Výchozí vrátí text na původní vzhled; každá změna jde vrátit jedním ⌘Z.
- [ ] Dvojklik na stylovaný text: editor ukazuje stejné písmo, velikost, zarovnání a barvu jako plátno; změna v pruhu během psaní se projeví hned a napsaný text zůstane.
- [ ] Po skončení úprav zůstane text vybraný (Esc ho nechá vybraný; šipky ho posunou, Delete smaže) — zapiš, jestli ti to vadí.
- [ ] Zkusit jinak / jiné rozložení u stránky se stylovaným textem: text si vzhled ponese.
- [ ] Export: PDF ukazuje texty stejně jako plátno.
- [ ] Kniha se stylovaným textem otevřená na Macu bez daného písma (nebo písmo dočasně vypni v Knihovně písem): text se ukáže výchozím písmem a kontrola před tiskem hlásí „Písmo „X“ v tomto Macu chybí“.

## F. Originály a automatické ukládání

- [ ] Vyber fotku, která je jen v iCloudu. V buňce se ukáže spinner, banner říká „Stahuji originály 1 / 1“ a potom je soubor v `<album>.leporelo/originals/`.
- [ ] Velké stahování (100 a více originálů): nech album otevřené několik minut, aby proběhlo automatické ukládání. Zavři a znovu otevři: všechny stažené fotky jsou uložené (bez ikony mraku) a jejich soubory existují.
- [ ] Zavři okno uprostřed stahování a znovu otevři. Očekávání: už stažené se nestahují znovu, banner pokračuje se zbytkem.
- [ ] Smaž ve Photos fotku, jejíž originál je už stažený, ještě než se album uloží, a album znovu otevři. Očekávání: originál se použije dál a fotka je označená jako smazaná ve zdroji.
- [ ] Během stahování a ukládání se nikdy neobjeví hlášení „dokument byl změněn jinou aplikací“ a dokument se sám nenačte znovu.
- [ ] Soubor > Vrátit (Revert) nebo obnovení z Verzí a po něm úprava alba: změna se uloží (zavři a otevři). Práce na pozadí po návratu pokračuje.
- [ ] Verze a originály: vyber fotky, nech stáhnout jejich originály, pak Soubor > Vrátit se k > Poslední otevřená verze (nebo „Procházet všechny verze…“ > Obnovit starší verzi). Zjisti a zapiš, co se stane se složkou `originals/`. Očekávané (a proto varování v README): obnovení nahradí celý balík včetně `originals/`, originály stažené po té verzi z disku zmizí a znovu se stáhnou; když fotka mezitím zmizela z Fotek, její jediná kopie je pryč.
- [ ] Automatické ukládání při první analýze velkého alba (kolem 3 000 fotek): během analýzy sleduj plynulost okna (rolování mřížky). Zapiš, jestli okno zhruba každých 10 s na chvíli (asi 1 s) zamrzne kvůli uložení; při analýze se ukládá s odstupem 10 s, ne 3 s.
- [ ] Balík smazaný, zatímco je otevřený, nejde uložit (známé omezení). Jen zjisti, jak se aplikace chová, a zapiš to.

## G. Načíst nové fotky ze zdroje

- [ ] Přidej do Photos 2 fotky v období alba a jednu už vybranou smaž. Soubor > „Načíst nové fotky ze zdroje“. Očekávání: hlášení se správným součtem, nové fotky jsou v příslušných dnech jako nevybrané, smazaná má značku ve třídění i v zásobníku.
- [ ] Přejmenuj nebo smaž album ve Photos, ze kterého bylo vytvořené, a spusť načtení. Očekávání: hlášení „Zdroj nevrátil žádné fotky“ a žádná fotka se neoznačí jako smazaná.
- [ ] S omezeným přístupem (Vybrané fotky) je položka „Načíst nové fotky ze zdroje“ vypnutá a žádná fotka se neoznačí.
- [ ] Položky nabídky „Načíst nové fotky ze zdroje“ a „Stáhnout znovu“ jsou správně zapnuté a vypnuté. Při vypnuté síti se originál zkusí stáhnout, po neúspěchu ještě jednou automaticky a pak zůstane jako nestažený (ne „nedostupný“); po zapnutí sítě ho „Stáhnout znovu“ stáhne.

## H. Export

- [ ] Soubor > Exportovat… (Shift-Cmd-E) a tlačítko v liště editoru otevřou sheet; z třídění přepne do editoru; bez dvoustran je vypnuté.
- [ ] Seznam problémů: chyby červeně, varování žlutě. Klik na „Dvoustrana N“ zavře sheet, ukáže dvoustranu a vybere rámeček. „Rozumím varováním“ zapne tlačítko. Úprava alba při otevřeném sheetu seznam obnoví a nové varování zaškrtnutí zruší.
- [ ] Skok z exportu při zobrazené obálce: v pásu klikni na přední obálku, otevři export s problémem na některé dvoustraně a klikni na „Dvoustrana N“. Očekávání: plátno ukáže tu dvoustranu (ne obálku).
- [ ] Smazaný originál: u hotového alba smaž v Finderu (Zobrazit obsah balíku) jeden soubor z `originals/`, jehož fotka je v albu, a otevři export (album nezavírej). Očekávání: kontrola ukáže chybu „Soubor originálu chybí v projektu“ s nápovědou a export nejde spustit. Pokud by se export přesto spustil (soubor smazaný až během exportu), skončí chybou „Originál 1 fotky v projektu chybí nebo nejde přečíst, export se nezapsal…“ a ve složce exportu nevznikne nic nového.
- [ ] Při stahování originálů tlačítko říká „Čekám na originály (N)“ a N klesá.
- [ ] „Exportovat“ otevře výběr složky připojený k sheetu (modálně): dokud je otevřený, tlačítka a Esc sheetu nedělají nic a okno nejde zavřít. Složka uvnitř balíku `.leporelo` nebo samotný balík ukáže českou chybu. Složka s dřívějším exportem ukáže hlášení o přepsání se jmény souborů.
- [ ] Průběh se plynule posouvá, „Zrušit“ ho zastaví s hláškou „Export byl zrušen“ a nezůstane složka `.leporelo-export-*`. Během exportu sheet nejde zavřít (Esc = Zrušit).
- [ ] Cmd-W a Cmd-Q v průběhu exportu: zapiš, co se stane (okno s připojeným sheetem se nemá zavřít, ukončení export zruší).
- [ ] Po úspěchu: „Zobrazit ve Finderu“ vybere tři soubory (`pages.pdf`, `cover.pdf`, `co-nahrat-kam.txt`), „Otevřít složku“ otevře složku. `cover.pdf` je přední obálka.
- [ ] Otevři `pages.pdf` v Náhledu (Nástroje > Zobrazit inspektora, Cmd-I). Velikost stránky pro formát 297 × 210 mm se spadávkou 3 mm je 303 × 216 mm (pro 8 × 6 in 209,2 × 158,4 mm); počet stran odpovídá albu.
- [ ] Písma jsou vložená: v Náhledu Soubor > Vlastnosti nebo v terminálu `pdffonts pages.pdf` (pokud je nainstalovaný poppler). Fraunces a Schibsted Grotesk jsou uvedené jako vložené.
- [ ] Zkouška importu do Canvy (spec, oddíl 10; dosud neprovedena): vyexportuj PDF z alba s několika fotkami v plném rozlišení, nahraj ho do Canvy (nová fotokniha ve stejném formátu, Nahrát soubory) a prohlédni fotky zblízka: ostrost, artefakty JPEG, rozlišení. Očekávání: Canva fotky viditelně nepřekomprimuje a jedna strana PDF je jedna strana knihy. Když překomprimuje nebo rozloží: přejít na JPG strany v plném rozlišení (Canva umí nahrát obrázky a vložit je jako stránky); to vyžaduje změnu exportu, ne jen profilu, a je třeba ji zadat jako novou práci.
- [ ] Kontrola Canvy po nahrání: nic nesmí být označené jako nízké rozlišení tam, kde preflight Leporela mlčel, a nic důležitého nesmí vyjít mimo bezpečnou zónu.
- [ ] Pokud Canva uvádí jiné rozměry stránky, spadávku, bezpečnou zónu nebo maximum stran než profil (`Sources/LeporeloCore/Resources/Profiles/canva-photobook.json`), oprav hodnoty, nastav `verified` na `true` a u formátů smaž „neověřeno u Canvy“ z názvu.

## I. Rozhodnutí pro Davida

- [ ] Jaký formát a papír v Canvě nakonec objednat (ovlivní jen profil `canva-photobook.json`, ne aplikaci). Spec, oddíl 11.
- [ ] Zda a kdy přidat profil Saal Digital (vyžaduje účet a šablony za přihlášením; kód navíc potřebuje obálku `wrapWithSpine` a výpočet hřbetu).
- [ ] Zda má album mít závěrečnou dvoustranu a co na ní (návrh dnes vytváří dvoustranu „closing“; ověř, že to tak chceš). Spec, oddíl 11.
- [ ] Zda dodělat položky z limitů verze 1: rozdělit den na dvě, přístupnost rámečků, import ze složky v aplikaci, posun času fotek z foťáku.
