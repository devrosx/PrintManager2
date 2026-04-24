# Changelog

## 2026-04-25

### Hromadné přejmenování — změna přípony
- Nová sekce "Přípona" v dialogu Rename Selected
- Toggle pro změnu přípony + textové pole (předvyplní se aktuální příponou)
- Náhled okamžitě zobrazuje novou příponu
- Po přejmenování se aktualizuje i `fileType` v seznamu

### Choose Color Pages — více souborů najednou
- Funkce zpracuje všechna vybraná PDF za sebou v jednom dialogu
- Progress badge "1 / 3" v záhlaví při více souborech
- Tlačítko "Potvrdit a pokračovat →" přechází na další soubor bez zavření dialogu
- Změna generace thumbnailů zabraňuje smíchání miniatur při rychlém přepínání

### Detail stránek (Inline QuickLook) — nové funkce
- Drag stránek na Apps panel: otevře stránky v dané aplikaci
- Drag stránek na tiskárnu: vytiskne vybrané stránky (stejně jako Print Selected)
- Dvojklik na šedou plochu (mimo stránky) zavře detail a vrátí seznam souborů
- Drag a drop na tiskárnu nyní funguje i ze základního seznamu souborů

### Opravy drag & drop na tiskárny a Apps
- Drop handlery přijímají `.pdf` i `.fileURL` typy — aktivují se pro drag z detailu i Finderu
- `loadItem` správně extrahuje URL z `NSURL`, `URL` i `Data` (předtím tiše selhal)
- `printFiles(urls:toPrinter:)` tiskne i soubory mimo seznam (temp PDF ze stránek)
- Dvojklik na řádek v seznamu funguje spolehlivě — odstraněna podmíněná aplikace `.onDrag` která měnila strukturu view a přerušovala rozpoznání dvojkliku

## 2026-04-08

### Export PDF to Images
- Nová funkce v PDF menu (toolbar i kontextové menu): "Export to Images…"
- Převede všechny stránky PDF do obrázků (JPEG / PNG / TIFF)
- Výběr rozlišení: 72, 96, 150, 200, 300, 400, 600 DPI
- Slider kvality pro JPEG (50–100 %)
- Podporuje hromadné zpracování více PDF najednou
- Stránky se ukládají do podsložky `<název>_images/` jako `page_0001.jpg` atd.
- Exportované soubory se automaticky přidají do seznamu

## 2026-03-26

### PDF Portfolio import
- Automatická detekce PDF portfolií (packages) při importu
- Extrakce vložených souborů z portfolia do dočasného adresáře
- Soubory z portfolia mají oranžovou ikonku složky s badge typu souboru
- Tooltip na ikoně zobrazuje název zdrojového portfolia

### Double-click otevření ve vybrané aplikaci
- Dvojklik na soubor v seznamu otevře soubor ve vybrané aplikaci z panelu Apps
- Pokud není vybraná žádná aplikace: PDF otevře inline QuickLook, ostatní default app

## 2026-03-09

### Gallery
- Image effects: duotone, feather edges, rounded corners, center on page
- Drop shadow, border color, page background, settings presets
- Opravy menu/UX a file list click

### Opravy
- Race condition fix
- InDesign filename fix
- ICC profil fix

## 2026-03-07

### Preview
- Klik na preview image otevře inline QuickLook (thumbnail mřížka stránek)

## 2026-03-05

### CUPS
- Fix detekce stavu tiskárny přes localhost:631
- Přidán tab Printing settings s CUPS management
