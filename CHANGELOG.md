# Changelog

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
