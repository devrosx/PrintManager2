# PrintManager

A powerful macOS print management application built with SwiftUI, designed for print shops, designers, and anyone who regularly works with PDF and image files.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Version](https://img.shields.io/badge/version-2.0-green)

---

## Features

### File Management
- Drag & drop files directly into the app or onto the dock icon
- Supports PDF, images (JPEG, PNG, TIFF, HEIC), and Office documents
- File list with sortable columns: name, format, size, pages, color info
- Batch selection, reordering, and batch rename with custom patterns
- Dock icon badge showing the current file count

### Printing
- Fast printing via system `lp` command
- Printer selection with per-printer preset support
- Print settings: copies, two-sided, collate, fit to page, landscape, paper size
- Save and load printer presets
- Auto-detect and highlight default printer on startup

### PDF Operations
- **Merge** — combine multiple PDFs into one
- **Split** — extract selected pages into separate files
- **Compress** — reduce file size with adjustable quality and image downsampling
- **Crop** — crop PDF pages with precise mm/pt controls and visual preview
- **Watermark** — add text or image watermarks with opacity, position, and font control
- **Imposition** — N-up, booklet, step-and-repeat, and cut-stack layouts
- **Tile PDF** — split a large page into multiple printable sheets
- **Expand (Bleed)** — add bleed margins to a PDF canvas
- **Flatten transparency** — rasterize transparent layers
- **Apply PDF Box** — trim/crop/bleed/art/media box management
- **Color page detection** — identify and select color vs. B&W pages using Ghostscript

### Image Operations
- **Resize** — resize with DPI-aware scaling
- **Crop** — interactive crop with handles in the preview
- **Stitch** — join multiple images using Apple Vision for overlap detection
- **Watermark** — overlay text or image watermarks
- **Image adjustments** — brightness, contrast, threshold, deskew, background removal
- **Drawings processor** — specialized pipeline for scanned technical drawings (deskew, crop, threshold, OCR)
- **Invert colors**, **convert to grayscale**, **convert to PDF**
- **Sub-image extraction** — detect and extract photos embedded within a scan

### Office Document Conversion
Convert `.docx`, `.xlsx`, `.pptx` and other Office formats to PDF via:
- **LibreOffice / OpenOffice** — local, fast, no internet required
- **CloudConvert** — cloud API, requires account
- **Google Drive** — upload → export as PDF → delete, requires OAuth 2.0
- **iLovePDF** — cloud API, free tier available

### Gallery & InDesign
- Create PDF galleries from a set of images with configurable grid layout and captions
- Import files directly into Adobe InDesign as a placed-image document
- Generate InDesign gallery layouts via JSX scripting

### Print Pricing Calculator
- Per-page pricing for A4/A3 in B&W and color with tiered volume discounts
- Large-format (plotter) pricing per cm of print length, by roll width (297–914 mm)
- Drawing folding surcharge
- "All B&W" override toggle — recalculates color pages as B&W
- All prices configurable in Settings

### Preview & Inspection
- Inline Quick Look with page-by-page navigation
- PDF metadata viewer (page count, dimensions, color info, PDF boxes)
- Thumbnail strip with configurable size
- Page color analysis per page with colored indicators

---

## Requirements

- macOS 13.0 or later
- Xcode 15+ (to build)
- **Optional:** Ghostscript (`gs`) for color page detection
- **Optional:** LibreOffice for local Office → PDF conversion

---

## Installation

Clone and open in Xcode:

```bash
git clone https://github.com/yourname/PrintManager.git
open PrintManager.xcodeproj
```

Build and run with **⌘R**.

---

## Localization

The app supports **Czech** (default) and **English**. The language follows the system preference — set English as the first language in *System Settings → General → Language & Region* to use the English UI.

---

## Architecture

| Layer | Details |
|-------|---------|
| UI | SwiftUI, AppKit where needed |
| State | `AppState` — central `ObservableObject` |
| Services | Stateless service classes per feature area |
| Persistence | `UserDefaults` / `@AppStorage` |
| Async | Swift Concurrency (`async/await`, `Task`) |
| PDF | PDFKit, CoreGraphics, Ghostscript |
| Vision | Apple Vision framework for stitch and deskew |
| Conversion | CloudConvert API, Google Drive API, iLovePDF API |

---

## License

MIT
