//
//  GalleryInDesignService.swift
//  PrintManager
//
//  Vytvoří InDesign dokument se stejným rozložením galerie jako GalleryService.
//  Každý obrázek je umístěn jako samostatný objekt (obrázkový rámeček) 1 : 1.
//

import Foundation
import AppKit
import SwiftUI

class GalleryInDesignService {

    static let shared = GalleryInDesignService()
    private init() {}

    // MARK: - Public API

    func createGallery(
        images: [GalleryImageState],
        settings: GallerySettings,
        outputName: String
    ) async throws {
        // Zajisti, že InDesign běží
        if InDesignService().runningAppName() == nil {
            guard let appURL = findInstalledInDesign() else {
                throw GalleryInDesignError.notInstalled
            }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if InDesignService().runningAppName() != nil { break }
            }
        }
        guard let appName = InDesignService().runningAppName() else {
            throw GalleryInDesignError.notRunning
        }

        let jsx = buildJSX(images: images, settings: settings, outputName: outputName)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintManager_Gallery.jsx")
        try jsx.write(to: tmpURL, atomically: true, encoding: .utf8)
        try await runAppleScript(jsxPath: tmpURL.path, appName: appName)
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // MARK: - JSX builder

    private func buildJSX(
        images: [GalleryImageState],
        settings: GallerySettings,
        outputName: String
    ) -> String {

        let paper = settings.effectivePaperMM
        let paperW = paper.width, paperH = paper.height
        let mT = settings.marginTop, mB = settings.marginBottom
        let mL = settings.marginLeft, mR = settings.marginRight
        let gH = settings.gutterH, gV = settings.gutterV
        let usableW = paperW - mL - mR
        let usableH = paperH - mT - mB

        // Layout (totožný výpočet s GalleryService/GalleryLayout)
        let (cols, rows, frameW, frameH): (Int, Int, Double, Double)
        if settings.fillPageEvenly && !images.isEmpty {
            let (c, r, fw, fh) = GalleryLayout.fillLayout(
                count: images.count, usableW: usableW, usableH: usableH, gH: gH, gV: gV)
            (cols, rows, frameW, frameH) = (c, r, fw, fh)
        } else if let fmm = settings.effectiveFrameMM {
            let c = max(1, Int((usableW + gH) / (Double(fmm.width)  + gH)))
            let r = max(1, Int((usableH + gV) / (Double(fmm.height) + gV)))
            (cols, rows, frameW, frameH) = (c, r, Double(fmm.width), Double(fmm.height))
        } else {
            (cols, rows, frameW, frameH) = (1, 1, usableW, usableH)
        }
        let perPage   = cols * rows
        let pageCount = max(1, Int(ceil(Double(images.count) / Double(perPage))))

        let docName = js(outputName + "_gallery")

        // ── Pole obrázků (JSON-like) ────────────────────────────────────────
        var imgArray = "[\n"
        for (i, state) in images.enumerated() {
            // Auto-rotace: respektuje stejnou logiku jako preview
            let px = state.pixelSize
            let imgIsLandscape  = px.width > px.height && px != .zero
            let cellIsLandscape = frameW > frameH
            let autoRot = (imgIsLandscape != cellIsLandscape && px != .zero) ? 90 : 0
            let totalRot = (autoRot + state.extraRotation) % 360

            let (bgC, bgM, bgY, bgK) = cmyk(state.fitBackground)
            let label = state.displayLabel
            let sep = i < images.count - 1 ? "," : ""
            imgArray += "  {path:\(js(state.url.path)),fit:\(state.fitMode ? "true" : "false"),rot:\(totalRot),bgC:\(f(bgC)),bgM:\(f(bgM)),bgY:\(f(bgY)),bgK:\(f(bgK)),label:\(js(label))}\(sep)\n"
        }
        imgArray += "]"

        // Ořezové značky (jen obrysy, v mm)
        let cropMarkJS: String
        if settings.addCropMarks {
            let len = settings.cropMarkLength, off = settings.cropMarkOffset
            // strokeWeight v InDesignu (při measurementUnit=mm) bere mm, ne pt
            let lw  = settings.cropMarkWidth / 2.834645669
            cropMarkJS = """
            // Ořezové značky
            try {
                var cmLen = \(f(len)), cmOff = \(f(off)), cmLW = \(f(lw));
                var cmStroke = doc.swatches.itemByName("Black");
                function drawMark(pg, x1, y1, x2, y2) {
                    var ln = pg.graphicLines.add();
                    ln.paths[0].pathPoints[0].anchor = [y1+\"mm\", x1+\"mm\"];
                    ln.paths[0].pathPoints[1].anchor = [y2+\"mm\", x2+\"mm\"];
                    ln.strokeColor = cmStroke; ln.strokeWeight = cmLW;
                }
                function cropCorner(pg, cx, cy, dx, dy) {
                    drawMark(pg, cx+dx*cmOff,       cy,             cx+dx*(cmOff+cmLen), cy);
                    drawMark(pg, cx,                cy+dy*cmOff,    cx,                  cy+dy*(cmOff+cmLen));
                }
            } catch(e) {}
"""
        } else {
            cropMarkJS = ""
        }

        let addCropMarksInLoop = settings.addCropMarks ? """
                    // Ořezové značky pro tento rámeček
                    try {
                        cropCorner(page, fx,      fy,       -1, -1);
                        cropCorner(page, fx+\(f(frameW)), fy,       +1, -1);
                        cropCorner(page, fx,      fy+\(f(frameH)), -1, +1);
                        cropCorner(page, fx+\(f(frameW)), fy+\(f(frameH)), +1, +1);
                    } catch(e) {}
""" : ""

        // frameBorderWidth je v pt; InDesign s mm-jednotkami bere strokeWeight v mm
        let borderWidthMM = settings.frameBorderWidth / 2.834645669
        let addBorderInLoop = settings.addFrameBorder ? """
                    frame.strokeColor = doc.swatches.itemByName("Black");
                    frame.strokeWeight = \(f(borderWidthMM));
""" : """
                    frame.strokeColor = doc.swatches.itemByName("None");
                    frame.strokeWeight = 0;
"""

        // Popisek – textový rámeček pod obrázkem
        let labelH      = settings.effectiveLabelHeightMM   // 0 pokud inside
        let labelAreaH  = settings.labelAreaHeightMM        // vždy fyzická výška
        let (lblC, lblM, lblY, lblK) = cmyk(settings.labelColor)
        let (bgLC, bgLM, bgLY, bgLK) = cmyk(settings.labelBackground)
        let addLabelInLoop: String
        if settings.showImageLabel {
            let fontSizeMM    = settings.labelFontSize / 2.834645669
            let justification = settings.labelAlignment.indesignJustification
            // Poloha: inside = spodní pruh obrázku, outside = pod obrázkem
            let topExpr    = settings.labelInside
                ? "(fy+FRAME_H-\(f(labelAreaH)))"
                : "(fy+FRAME_H)"
            let bottomExpr = settings.labelInside
                ? "(fy+FRAME_H)"
                : "(fy+FRAME_H+\(f(labelAreaH)))"
            addLabelInLoop = """
                    // Popisek \(settings.labelInside ? "uvnitř obrázku" : "pod obrázkem")
                    try {
                        var lf = page.textFrames.add();
                        lf.geometricBounds = [\(topExpr)+"mm", fx+"mm", \(bottomExpr)+"mm", (fx+FRAME_W)+"mm"];
                        lf.contents = img.label;
                        var lblPara = lf.paragraphs[0];
                        lblPara.justification = \(justification);
                        lblPara.pointSize     = \(f(fontSizeMM));
                        try { lblPara.appliedFont = \(js(settings.labelFontName)); } catch(e) {}
                        var lblColor = doc.colors.add();
                        lblColor.model = ColorModel.PROCESS;
                        lblColor.colorValue = [\(f(lblC)), \(f(lblM)), \(f(lblY)), \(f(lblK))];
                        lblPara.fillColor = lblColor;
                        var bgLSwatch = doc.colors.add();
                        bgLSwatch.model = ColorModel.PROCESS;
                        bgLSwatch.colorValue = [\(f(bgLC)), \(f(bgLM)), \(f(bgLY)), \(f(bgLK))];
                        lf.fillColor = bgLSwatch;
                        lf.strokeColor = doc.swatches.itemByName("None");
                        // Vertikální zarovnání na střed
                        lf.textFramePreferences.verticalJustification = VerticalJustification.CENTER_ALIGN;
                    } catch(e) {}
"""
        } else {
            addLabelInLoop = ""
        }

        // Řádkový krok = FRAME_H + labelH (pro správné fy)
        let cellH = frameH + labelH

        return """
// PrintManager — InDesign Gallery (\(outputName))
app.scriptPreferences.userInteractionLevel = UserInteractionLevels.INTERACT_WITH_ALERTS;
app.scriptPreferences.measurementUnit      = MeasurementUnits.MILLIMETERS;

var COLS    = \(cols),  ROWS    = \(rows);
var FRAME_W = \(f(frameW)), FRAME_H = \(f(frameH));
var LABEL_H = \(f(labelH)), CELL_H  = \(f(cellH));
var ML = \(f(mL)), MT = \(f(mT)), GH = \(f(gH)), GV = \(f(gV));
var PER_PAGE = \(perPage), NUM_PAGES = \(pageCount);
var PAPER_W  = \(f(paperW)), PAPER_H = \(f(paperH));
var IMAGES   = \(imgArray);

// Vytvoření dokumentu
var doc = app.documents.add(true);
var dp  = doc.documentPreferences;
dp.pageWidth   = PAPER_W + "mm";
dp.pageHeight  = PAPER_H + "mm";
dp.facingPages = false;
try { doc.name = \(docName); } catch(e) {}

\(cropMarkJS)

var imgIdx = 0;
for (var pg = 0; pg < NUM_PAGES; pg++) {
    var page;
    if (pg === 0) {
        page = doc.pages[0];
    } else {
        doc.pages.add(LocationOptions.AT_END);
        page = doc.pages[doc.pages.length - 1];
    }

    for (var row = 0; row < ROWS && imgIdx < IMAGES.length; row++) {
        for (var col = 0; col < COLS && imgIdx < IMAGES.length; col++) {
            var img = IMAGES[imgIdx];
            var fx  = ML + col * (FRAME_W + GH);
            var fy  = MT + row * (CELL_H  + GV);

            // Rámeček [top, left, bottom, right]
            var frame = page.rectangles.add();
            frame.geometricBounds = [fy+"mm", fx+"mm", (fy+FRAME_H)+"mm", (fx+FRAME_W)+"mm"];

            // Barva pozadí (viditelná jen v fit módu)
            if (img.fit) {
                try {
                    var bgSwatch = doc.colors.add();
                    bgSwatch.model      = ColorModel.PROCESS;
                    bgSwatch.colorValue = [img.bgC, img.bgM, img.bgY, img.bgK];
                    frame.fillColor = bgSwatch;
                } catch(e) { frame.fillColor = doc.swatches.itemByName("Paper"); }
            } else {
                try { frame.fillColor = doc.swatches.itemByName("None"); } catch(e) {}
            }

            // Umístění obrázku
            var f = new File(img.path);
            if (f.exists) {
                try { frame.place(f); } catch(e) { imgIdx++; continue; }

                // Fitování
                if (img.fit) {
                    try { frame.fit(FitOptions.PROPORTIONALLY);  } catch(e) {}
                    try { frame.fit(FitOptions.CENTER_CONTENT);  } catch(e) {}
                } else {
                    try { frame.fit(FitOptions.FILL_PROPORTIONALLY); } catch(e) {}
                }

                // Rotace obsahu (auto + manuální)
                if (img.rot !== 0) {
                    try {
                        // InDesign: kladný úhel = CCW; negujeme aby odpovídal CW náhledu
                        frame.graphics[0].rotationAngle = -img.rot;
                        if (img.fit) {
                            try { frame.fit(FitOptions.PROPORTIONALLY); } catch(e) {}
                            try { frame.fit(FitOptions.CENTER_CONTENT); } catch(e) {}
                        } else {
                            try { frame.fit(FitOptions.FILL_PROPORTIONALLY); } catch(e) {}
                        }
                    } catch(e) {}
                }
            }

\(addBorderInLoop)
\(addCropMarksInLoop)
\(addLabelInLoop)
            imgIdx++;
        }
    }
}

app.activeDocument = doc;
app.scriptPreferences.userInteractionLevel = UserInteractionLevels.INTERACT_WITH_ALL;
"""
    }

    // MARK: - Helpers

    /// Formátování čísla pro JSX
    private func f(_ v: Double) -> String { String(format: "%.3f", v) }

    /// Escapování stringu pro JSX string literal (uvozovky, lomítka)
    private func js(_ s: String) -> String {
        let esc = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(esc)\""
    }

    /// Převod SwiftUI Color → CMYK (0–100)
    private func cmyk(_ color: Color) -> (c: Double, m: Double, y: Double, k: Double) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        let r = Double(ns.redComponent), g = Double(ns.greenComponent), b = Double(ns.blueComponent)
        let k = 1.0 - max(r, g, b)
        if k >= 1.0 { return (0, 0, 0, 100) }
        let d = 1.0 - k
        return ((1-r-k)/d * 100, (1-g-k)/d * 100, (1-b-k)/d * 100, k * 100)
    }

    // MARK: - InDesign discovery (zrcadlí InDesignService)

    private func findInstalledInDesign() -> URL? {
        let ids = ["com.adobe.InDesign", "com.adobe.indesign",
                   "com.adobe.InDesign2025", "com.adobe.InDesign2024",
                   "com.adobe.InDesign2023", "com.adobe.InDesign2022"]
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil
        ))?.first { $0.lastPathComponent.contains("InDesign") }
    }

    // MARK: - AppleScript runner

    private func runAppleScript(jsxPath: String, appName: String) async throws {
        let source = """
        set jsxFile to POSIX file "\(jsxPath)"
        tell application "\(appName)"
            activate
            do script jsxFile language javascript
        end tell
        """
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&err)
                if let e = err {
                    let msg = e[NSAppleScript.errorMessage] as? String ?? "Neznámá chyba"
                    cont.resume(throwing: GalleryInDesignError.scriptFailed(msg))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}

// MARK: - Errors

enum GalleryInDesignError: LocalizedError {
    case notInstalled, notRunning, scriptFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled:       return "Adobe InDesign nebyl nalezen v systému."
        case .notRunning:         return "Nepodařilo se spustit Adobe InDesign."
        case .scriptFailed(let m): return "Chyba InDesign skriptu: \(m)"
        }
    }
}
