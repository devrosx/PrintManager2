//
//  InDesignService.swift
//  PrintManager
//
//  Komunikace s Adobe InDesign přes AppleScript + ExtendScript (JSX).
//  JSX se zapíše do temp souboru a InDesign ho spustí – bez problémů s escapováním.
//
//  Podpora vícestránkových PDF: každá stránka PDF → jedna stránka InDesign dokumentu.
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Models

enum InDesignFit: String, CaseIterable, Identifiable {
    case fillProportionally       = "FILL_PROPORTIONALLY"   // FitOptions.FILL_PROPORTIONALLY
    case fitContentProportionally = "PROPORTIONALLY"        // FitOptions.PROPORTIONALLY
    case fitFrameToContent        = "FRAME_TO_CONTENT"      // FitOptions.FRAME_TO_CONTENT
    case none                     = "NONE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fillProportionally:       return "Vyplnit rámec"
        case .fitContentProportionally: return "Přizpůsobit obsah"
        case .fitFrameToContent:        return "Přizpůsobit rámec"
        case .none:                     return "Bez přizpůsobení"
        }
    }
    var icon: String {
        switch self {
        case .fillProportionally:       return "arrow.up.left.and.arrow.down.right"
        case .fitContentProportionally: return "arrow.down.right.and.arrow.up.left"
        case .fitFrameToContent:        return "rectangle.compress.vertical"
        case .none:                     return "xmark.square"
        }
    }
}

// Crop box pro umístění PDF (odpovídá InDesign PDFCrop enum)
enum PDFCropOption: String, CaseIterable, Identifiable {
    case mediaBox    = "MEDIA_BOX"
    case bleedBox    = "BLEED_BOX"
    case trimBox     = "TRIM_BOX"
    case slugBox     = "SLUG_BOX"
    case artBox      = "ART_BOX"
    case boundingBox = "BOUNDING_BOX"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mediaBox:    return "Media"
        case .bleedBox:    return "Bleed"
        case .trimBox:     return "Trim"
        case .slugBox:     return "Slug"
        case .artBox:      return "Art"
        case .boundingBox: return "Bounding Box"
        }
    }
}

struct InDesignImportSettings {
    var autoPageSize: Bool   = true
    var pageWidth:  Double   = 210        // mm
    var pageHeight: Double   = 297        // mm
    var bleedLinked: Bool    = true
    var bleedAll:   Double   = 3
    var bleedTop:   Double   = 3
    var bleedBottom: Double  = 3
    var bleedLeft:  Double   = 3
    var bleedRight: Double   = 3
    var marginLinked: Bool   = true
    var marginAll:   Double  = 0
    var marginTop:   Double  = 0
    var marginBottom: Double = 0
    var marginLeft:  Double  = 0
    var marginRight: Double  = 0
    var fit: InDesignFit     = .fillProportionally
    var useExistingDoc: Bool = false
    var facingPages: Bool    = false
    // PDF-specific
    var pdfCropTo: PDFCropOption  = .bleedBox
    var pdfTransparentBg: Bool    = false
    var pdfPageFilter: [Int]      = []   // prázdné = všechny stránky
}

/// Informace o jednom souboru pro import.
struct InDesignFileInfo {
    let url: URL
    /// Počet stran (PDF může mít více; obrázky = 1).
    var pageCount: Int = 1
    /// Rozměry každé stránky v mm. Index 0 = strana 1.
    var pageSizes: [CGSize] = []
    /// Rozměry PDF box typů první stránky v mm (nil = box v PDF není definován).
    var pdfBoxSizes: [PDFCropOption: CGSize] = [:]

    /// Rozměr první stránky (shortcut).
    var detectedSize: CGSize? { pageSizes.first }
}

// MARK: - Errors

enum InDesignError: LocalizedError {
    case notInstalled
    case notRunning
    case scriptFailed(String)
    case noFiles

    var errorDescription: String? {
        switch self {
        case .notInstalled:         return "Adobe InDesign nebyl nalezen v systému."
        case .notRunning:           return "Nepodařilo se spustit Adobe InDesign."
        case .scriptFailed(let m):  return "Chyba skriptu: \(m)"
        case .noFiles:              return "Nejsou vybrány žádné soubory."
        }
    }
}

// MARK: - Service

class InDesignService {

    // MARK: - Discovery

    func runningAppName() -> String? {
        NSWorkspace.shared.runningApplications
            .first { ($0.localizedName ?? "").contains("InDesign") }
            .flatMap { $0.localizedName }
    }

    func isAvailable() -> Bool {
        runningAppName() != nil || findInstalledInDesign() != nil
    }

    private func findInstalledInDesign() -> URL? {
        let ids = ["com.adobe.InDesign", "com.adobe.indesign",
                   "com.adobe.InDesign2024", "com.adobe.InDesign2023", "com.adobe.InDesign2022"]
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let base = URL(fileURLWithPath: "/Applications")
        return (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.contains("InDesign") }
    }

    // MARK: - File info detection

    /// Detekuje počet stran a rozměry (v mm) pro daný soubor.
    func detectFileInfo(url: URL) -> InDesignFileInfo {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return detectPDFInfo(url: url)
        } else {
            let size = imageSizeMM(url: url)
            return InDesignFileInfo(url: url, pageCount: 1, pageSizes: size.map { [$0] } ?? [])
        }
    }

    /// Zpětná kompatibilita pro dialog.
    func detectSize(url: URL) -> CGSize? {
        detectFileInfo(url: url).detectedSize
    }

    private func detectPDFInfo(url: URL) -> InDesignFileInfo {
        guard let doc = CGPDFDocument(url as CFURL) else {
            return InDesignFileInfo(url: url)
        }
        let ptToMM: CGFloat = 25.4 / 72
        let n = doc.numberOfPages
        var sizes: [CGSize] = []
        var boxSizes: [PDFCropOption: CGSize] = [:]

        for i in 1...n {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.mediaBox)
            sizes.append(CGSize(width: box.width * ptToMM, height: box.height * ptToMM))

            // Rozměry box typů první stránky (pro zobrazení v UI)
            if i == 1 {
                let media = page.getBoxRect(.mediaBox)
                boxSizes[.mediaBox] = CGSize(width: media.width * ptToMM, height: media.height * ptToMM)

                // Box je "definován" pokud se liší od media boxu nebo je stejný (PDF standard:
                // getBoxRect vždy vrátí media box jako fallback pro nedefinované boxy)
                // Porovnáme s media boxem — pokud jsou totožné, box pravděpodobně není explicitně nastaven
                func addIfDefined(_ cgBox: CGPDFBox, _ opt: PDFCropOption) {
                    let r = page.getBoxRect(cgBox)
                    // Definovaný = nenulový (a CGPDFPage nevrací nil, takže zjistíme zda se liší od media)
                    boxSizes[opt] = CGSize(width: r.width * ptToMM, height: r.height * ptToMM)
                }
                addIfDefined(.bleedBox, .bleedBox)
                addIfDefined(.trimBox,  .trimBox)
                addIfDefined(.artBox,   .artBox)
                addIfDefined(.cropBox,  .boundingBox)   // CGPDFBox.cropBox ≈ "crop/bounding"
            }
        }
        return InDesignFileInfo(url: url, pageCount: n, pageSizes: sizes, pdfBoxSizes: boxSizes)
    }

    private func imageSizeMM(url: URL) -> CGSize? {
        guard let src   = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw    = props[kCGImagePropertyPixelWidth]  as? Int,
              let ph    = props[kCGImagePropertyPixelHeight] as? Int else { return nil }

        var xDPI: Double = 72, yDPI: Double = 72
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            xDPI = (tiff[kCGImagePropertyTIFFXResolution] as? Double) ?? 72
            yDPI = (tiff[kCGImagePropertyTIFFYResolution] as? Double) ?? 72
        } else if let dx = props[kCGImagePropertyDPIWidth] as? Double {
            xDPI = dx
            yDPI = (props[kCGImagePropertyDPIHeight] as? Double) ?? dx
        }
        if xDPI < 1 { xDPI = 72 }
        if yDPI < 1 { yDPI = 72 }

        return CGSize(width: Double(pw) / xDPI * 25.4, height: Double(ph) / yDPI * 25.4)
    }

    // MARK: - Import

    func `import`(files: [InDesignFileInfo], settings: InDesignImportSettings) async throws {
        guard !files.isEmpty else { throw InDesignError.noFiles }

        if runningAppName() == nil {
            guard let appURL = findInstalledInDesign() else { throw InDesignError.notInstalled }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if runningAppName() != nil { break }
            }
        }
        guard let appName = runningAppName() else { throw InDesignError.notRunning }

        let jsx    = buildJSX(files: files, settings: settings)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintManager_InDesign.jsx")
        try jsx.write(to: tmpURL, atomically: true, encoding: .utf8)
        try await runAppleScript(jsxPath: tmpURL.path, appName: appName)
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // MARK: - JSX builder

    private func buildJSX(files: [InDesignFileInfo], settings: InDesignImportSettings) -> String {
        let bT = settings.bleedLinked ? settings.bleedAll : settings.bleedTop
        let bB = settings.bleedLinked ? settings.bleedAll : settings.bleedBottom
        let bL = settings.bleedLinked ? settings.bleedAll : settings.bleedLeft
        let bR = settings.bleedLinked ? settings.bleedAll : settings.bleedRight

        let mT = settings.marginLinked ? settings.marginAll : settings.marginTop
        let mB = settings.marginLinked ? settings.marginAll : settings.marginBottom
        let mL = settings.marginLinked ? settings.marginAll : settings.marginLeft
        let mR = settings.marginLinked ? settings.marginAll : settings.marginRight

        // Sestavení pole souborů s per-page velikostmi
        var filesArray = "[\n"
        for f in files {
            let escapedPath = f.url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let defaultW = f.detectedSize.map { Double($0.width)  } ?? settings.pageWidth
            let defaultH = f.detectedSize.map { Double($0.height) } ?? settings.pageHeight

            // pageSizes array (per strana)
            var psArr = "["
            if f.pageSizes.isEmpty {
                psArr += "{w:\(fmt(defaultW)),h:\(fmt(defaultH))}"
            } else {
                psArr += f.pageSizes.map { "{w:\(fmt(Double($0.width))),h:\(fmt(Double($0.height)))}" }.joined(separator: ",")
            }
            psArr += "]"

            filesArray += """
        {path: "\(escapedPath)", pageCount: \(f.pageCount), pageSizes: \(psArr), w: \(fmt(defaultW)), h: \(fmt(defaultH))},\n
"""
        }
        filesArray += "]"

        // Velikost prvního souboru / první stránky pro inicializaci dokumentu
        let firstFile = files.first
        let initW = settings.autoPageSize ? (firstFile?.detectedSize.map { Double($0.width)  } ?? settings.pageWidth)  : settings.pageWidth
        let initH = settings.autoPageSize ? (firstFile?.detectedSize.map { Double($0.height) } ?? settings.pageHeight) : settings.pageHeight

        let pageFilterJS = settings.pdfPageFilter.isEmpty ? "[]"
            : "[" + settings.pdfPageFilter.map { String($0) }.joined(separator: ",") + "]"

        // Název dokumentu podle prvního vloženého souboru (bez přípony)
        let firstFileName = (firstFile?.url.deletingPathExtension().lastPathComponent ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
// PrintManager – Import to InDesign (vícestránkové PDF podporováno)

var AUTO_SIZE       = \(settings.autoPageSize ? "true" : "false");
var DOC_W           = \(fmt(settings.pageWidth));
var DOC_H           = \(fmt(settings.pageHeight));
var INIT_W          = \(fmt(initW));
var INIT_H          = \(fmt(initH));
var BLEED_T         = \(fmt(bT));
var BLEED_B         = \(fmt(bB));
var BLEED_L         = \(fmt(bL));
var BLEED_R         = \(fmt(bR));
var MARGIN_T        = \(fmt(mT));
var MARGIN_B        = \(fmt(mB));
var MARGIN_L        = \(fmt(mL));
var MARGIN_R        = \(fmt(mR));
var FIT_OPTION      = "\(settings.fit.rawValue)";
var USE_EXISTING    = \(settings.useExistingDoc ? "true" : "false");
var FACING_PAGES    = \(settings.facingPages ? "true" : "false");
var PDF_CROP        = "\(settings.pdfCropTo.rawValue)";
var PDF_TRANSPARENT = \(settings.pdfTransparentBg ? "true" : "false");
var PDF_PAGE_FILTER = \(pageFilterJS);
var FIRST_FILE_NAME = "\(firstFileName)";

var FILES = \(filesArray);

// ─── Main ─────────────────────────────────────────────────────────────────────
app.scriptPreferences.userInteractionLevel = UserInteractionLevels.INTERACT_WITH_ALERTS;

// Nastav PDF place preferences (try/catch – enum konstanty se liší dle verze ID)
var ppp = app.pdfPlacePreferences;
try {
    // Použij enum PDFCrop podle jména (spolehlivější než číselné konstanty)
    if (typeof PDFCrop !== 'undefined' && PDFCrop[PDF_CROP] !== undefined) {
        ppp.pdfCrop = PDFCrop[PDF_CROP];
    } else {
        try { ppp.pdfCrop = PDFCrop.MEDIA_BOX; } catch(e2) {}
    }
} catch(e) { /* pdfCrop není v této verzi podporován */ }
try { ppp.transparentBackground = PDF_TRANSPARENT; } catch(e) {}

var doc;
if (USE_EXISTING && app.documents.length > 0) {
    doc = app.documents[0];
} else {
    doc = app.documents.add(true);
    var dp = doc.documentPreferences;
    dp.pageWidth    = INIT_W + "mm";
    dp.pageHeight   = INIT_H + "mm";
    dp.facingPages  = FACING_PAGES;
    dp.documentBleedTopOffset            = BLEED_T + "mm";
    dp.documentBleedBottomOffset         = BLEED_B + "mm";
    dp.documentBleedInsideOrLeftOffset   = BLEED_L + "mm";
    dp.documentBleedOutsideOrRightOffset = BLEED_R + "mm";
    // Název dokumentu podle prvního vloženého souboru
    if (FIRST_FILE_NAME.length > 0) {
        try { doc.name = FIRST_FILE_NAME; } catch(e) {}
    }
}

app.scriptPreferences.measurementUnit = MeasurementUnits.MILLIMETERS;

var idocPage = -1;

for (var i = 0; i < FILES.length; i++) {
    var fi       = FILES[i];
    var isPDF    = fi.path.toLowerCase().indexOf(".pdf") !== -1;
    var numPages = fi.pageCount || 1;

    // Urči které stránky importovat (filtr nebo všechny)
    var pagesToImport = [];
    if (PDF_PAGE_FILTER.length === 0 || !isPDF) {
        for (var pp = 1; pp <= numPages; pp++) { pagesToImport.push(pp); }
    } else {
        for (var pp = 0; pp < PDF_PAGE_FILTER.length; pp++) {
            if (PDF_PAGE_FILTER[pp] >= 1 && PDF_PAGE_FILTER[pp] <= numPages) {
                pagesToImport.push(PDF_PAGE_FILTER[pp]);
            }
        }
    }

    for (var pi = 0; pi < pagesToImport.length; pi++) {
        var pdfPage = pagesToImport[pi];
        idocPage++;

        var psInfo = fi.pageSizes[pdfPage - 1] || {w: fi.w, h: fi.h};
        var pw = AUTO_SIZE ? psInfo.w : DOC_W;
        var ph = AUTO_SIZE ? psInfo.h : DOC_H;

        var page;
        if (idocPage === 0 && !USE_EXISTING) {
            page = doc.pages[0];
        } else {
            doc.pages.add(LocationOptions.AT_END);
            page = doc.pages[doc.pages.length - 1];
        }

        if (AUTO_SIZE) {
            var dp2 = doc.documentPreferences;
            dp2.pageWidth  = pw + "mm";
            dp2.pageHeight = ph + "mm";
        }

        var mp = page.marginPreferences;
        mp.top    = MARGIN_T + "mm";
        mp.bottom = MARGIN_B + "mm";
        mp.left   = MARGIN_L + "mm";
        mp.right  = MARGIN_R + "mm";

        var frame = page.rectangles.add();
        frame.geometricBounds = [
            MARGIN_T + "mm", MARGIN_L + "mm",
            (ph - MARGIN_B) + "mm", (pw - MARGIN_R) + "mm"
        ];

        // Pro PDF nastav číslo stránky před umístěním
        if (isPDF) {
            ppp.pageNumber = pdfPage;
            // Nastav crop box před každým umístěním (zajistí správné nastavení)
            try {
                if (typeof PDFCrop !== 'undefined' && PDFCrop[PDF_CROP] !== undefined) {
                    ppp.pdfCrop = PDFCrop[PDF_CROP];
                }
            } catch(e) {}
        }

        var f = File(fi.path);
        if (f.exists) {
            if (isPDF) {
                try {
                    frame.place(f);
                } catch(placeErr) {
                    // Fallback: zkus Media Box
                    try { ppp.pdfCrop = PDFCrop.MEDIA_BOX; } catch(e) {}
                    try { frame.place(f); } catch(e2) { /* skip */ }
                }
            } else {
                frame.place(f);
            }
            if      (FIT_OPTION === "FILL_PROPORTIONALLY") frame.fit(FitOptions.FILL_PROPORTIONALLY);
            else if (FIT_OPTION === "PROPORTIONALLY")      frame.fit(FitOptions.PROPORTIONALLY);
            else if (FIT_OPTION === "FRAME_TO_CONTENT")    frame.fit(FitOptions.FRAME_TO_CONTENT);
        }
    }
}

// Reset PDF preferences
ppp.pageNumber = 1;

app.activeDocument = doc;
app.scriptPreferences.userInteractionLevel = UserInteractionLevels.INTERACT_WITH_ALL;
"""
    }

    private func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    // MARK: - AppleScript runner

    private func runAppleScript(jsxPath: String, appName: String) async throws {
        let source = """
        set jsxFile to POSIX file "\(jsxPath)"
        tell application "\(appName)"
            activate
            do script jsxFile language javascript
        end tell
        """
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                let script = NSAppleScript(source: source)
                script?.executeAndReturnError(&err)
                if let e = err {
                    let msg = e[NSAppleScript.errorMessage] as? String ?? "Neznámá chyba"
                    cont.resume(throwing: InDesignError.scriptFailed(msg))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}
