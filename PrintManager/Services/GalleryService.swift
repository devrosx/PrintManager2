//
//  GalleryService.swift
//  PrintManager
//
//  Renderuje galerii obrázků do PDF. Každý obrázek se proporčně vloží do
//  předdefinovaného rámečku; obrázky na výšku/šířku se automaticky otáčí.
//  Podporuje ořezové značky, linku okolo obrázku a převzorkování.
//

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import SwiftUI

class GalleryService {

    static let shared = GalleryService()
    private init() {}

    // MARK: - pt konverze

    private let mmToPt: Double = RenderingConstants.pointsPerMillimeter
    private let ciCtx  = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Vygeneruje PDF galerii a vrátí URL výsledného souboru.
    func createGallery(
        images: [GalleryImageState],
        settings: GallerySettings,
        outputName: String,
        progress: @escaping (Double) -> Void
    ) throws -> URL {

        let pt  = mmToPt
        let paper = settings.effectivePaperMM
        let paperW = paper.width  * pt
        let paperH = paper.height * pt

        // Okraje v pt
        let mT = settings.marginTop    * pt
        let mB = settings.marginBottom * pt
        let mL = settings.marginLeft   * pt
        let mR = settings.marginRight  * pt
        let gH = settings.gutterH      * pt
        let gV = settings.gutterV      * pt

        // Při centrování ignorujeme okraje pro výpočet počtu sloupců/řádků
        let usableW = settings.centerOnPage ? paperW : paperW - mL - mR
        let usableH = settings.centerOnPage ? paperH : paperH - mT - mB

        // Výpočet layoutu (počet sloupců a řádků)
        let (cols, rows, frameW, frameH) = computeLayout(
            settings: settings, usableW: usableW, usableH: usableH,
            gutterH: gH, gutterV: gV, pt: pt, imageCount: images.count
        )
        let perPage = cols * rows

        // Efektivní okraje: nastaven nebo vystředění mřížky na stránce
        let effectiveMLeft: Double
        let effectiveMTop:  Double
        if settings.centerOnPage {
            let labelH_pt = settings.effectiveLabelHeightMM * pt
            let gridW = Double(cols) * frameW + Double(max(0, cols - 1)) * gH
            let gridH = Double(rows) * (frameH + labelH_pt) + Double(max(0, rows - 1)) * gV
            effectiveMLeft = (paperW - gridW) / 2
            effectiveMTop  = (paperH - gridH) / 2
        } else {
            effectiveMLeft = mL
            effectiveMTop  = mT
        }

        // Výstupní soubor do temp složky
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(outputName).pdf")

        // PDF kontext
        var mediaRect = CGRect(x: 0, y: 0, width: paperW, height: paperH)
        guard let ctx = CGContext(outURL as CFURL, mediaBox: &mediaRect, nil) else {
            throw GalleryError.cannotCreateContext
        }

        let total = images.count
        var done  = 0

        var idx = 0
        while idx < images.count {
            let batch = Array(images[idx..<min(idx + perPage, images.count)])

            ctx.beginPDFPage(nil)

            // Barva pozadí stránky
            let bgNS = NSColor(settings.pageBackgroundColor)
            if bgNS != NSColor.white && bgNS.alphaComponent > 0.01 {
                ctx.saveGState()
                ctx.setFillColor(bgNS.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: paperW, height: paperH))
                ctx.restoreGState()
            }

            // Nastavíme souřadnicový systém: (0,0) = levý dolní roh
            // CoreGraphics má (0,0) vlevo dole, takže mapujeme y = paperH - y_top

            let labelH_pt = settings.effectiveLabelHeightMM * pt
            let cellH_pt  = frameH + labelH_pt

            for (i, imgState) in batch.enumerated() {
                let col = i % cols
                let row = i / cols

                let cellX = effectiveMLeft + Double(col) * (frameW + gH)
                // Dno celé buňky (obrázek + popisek); v CG PDF Y roste nahoru
                let cellBottomY = paperH - effectiveMTop - Double(row + 1) * cellH_pt - Double(row) * gV
                // Obrázek je vizuálně nahoře → v Y-up coords nad popiskem
                let imageY  = cellBottomY + labelH_pt
                let imageRect = CGRect(x: cellX, y: imageY, width: frameW, height: frameH)
                let labelRect = CGRect(x: cellX, y: cellBottomY, width: frameW, height: labelH_pt)

                // Stín za rámečkem (kreslíme před obrázkem – painter's model)
                if settings.addFrameShadow {
                    let alpha = settings.shadowOpacity / 100.0
                    if let shadowNS = NSColor(settings.shadowColor).usingColorSpace(.sRGB) {
                        let shadowCG = shadowNS.withAlphaComponent(alpha).cgColor
                        ctx.saveGState()
                        ctx.setShadow(
                            offset: CGSize(width:  settings.shadowOffsetX * pt,
                                           height: -settings.shadowOffsetY * pt),
                            blur: settings.shadowBlur * pt,
                            color: shadowCG
                        )
                        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                        if settings.roundCorners && settings.cornerRadius > 0 {
                            let rad = settings.cornerRadius * pt
                            let path = CGPath(roundedRect: imageRect, cornerWidth: rad, cornerHeight: rad, transform: nil)
                            ctx.addPath(path)
                            ctx.fillPath()
                        } else {
                            ctx.fill(imageRect)
                        }
                        ctx.restoreGState()
                    }
                }

                renderImage(imgState, into: imageRect, settings: settings, ctx: ctx)

                if settings.showImageLabel {
                    if settings.labelInside {
                        // Popisek uvnitř: pruh přes spodní část imageRect (v Y-up: dole = nižší Y)
                        let lh = settings.labelAreaHeightMM * pt
                        let insideRect = CGRect(x: imageRect.minX, y: imageRect.minY,
                                                width: imageRect.width, height: lh)
                        drawLabel(for: imgState, in: insideRect, settings: settings, ctx: ctx)
                    } else if labelH_pt > 0 {
                        drawLabel(for: imgState, in: labelRect, settings: settings, ctx: ctx)
                    }
                }

                done += 1
                progress(Double(done) / Double(total))
            }

            ctx.endPDFPage()
            idx += perPage
        }

        ctx.closePDF()
        return outURL
    }

    // MARK: - Layout výpočet

    private func computeLayout(
        settings: GallerySettings,
        usableW: Double, usableH: Double,
        gutterH: Double, gutterV: Double,
        pt: Double,
        imageCount: Int = 0
    ) -> (cols: Int, rows: Int, frameW: Double, frameH: Double) {

        let labelH = settings.effectiveLabelHeightMM * pt  // pt

        if settings.fillPageEvenly && imageCount > 0 {
            let usableW_mm = usableW / pt, usableH_mm = usableH / pt
            let gH_mm = gutterH / pt, gV_mm = gutterV / pt
            let lH_mm = settings.effectiveLabelHeightMM
            let (c, r, fw_mm, fh_mm) = GalleryLayout.fillLayout(
                count: imageCount, usableW: usableW_mm, usableH: usableH_mm,
                gH: gH_mm, gV: gV_mm, labelH: lH_mm)
            return (c, r, fw_mm * pt, fh_mm * pt)
        } else if let frameMM = settings.effectiveFrameMM {
            let fw = frameMM.width  * pt
            let fh = frameMM.height * pt
            let cols = max(1, Int((usableW + gutterH) / (fw + gutterH)))
            let rows = max(1, Int((usableH + gutterV) / (fh + labelH + gutterV)))
            return (cols, rows, fw, fh)
        } else {
            return (1, 1, usableW, max(pt, usableH - labelH))
        }
    }

    // MARK: - Renderování jednoho obrázku do buňky

    private func renderImage(
        _ state: GalleryImageState,
        into cell: CGRect,
        settings: GallerySettings,
        ctx: CGContext
    ) {
        guard var cgImg = loadCGImage(url: state.url) else { return }
        cgImg = applyEffect(settings, to: cgImg)

        let imgW = Double(cgImg.width)
        let imgH = Double(cgImg.height)

        // Celková rotace: auto (orientace) + manuální kroky
        let cellIsLandscape = cell.width > cell.height
        let imgIsLandscape  = imgW > imgH
        let autoRot  = (cellIsLandscape != imgIsLandscape) ? 90 : 0
        let totalDeg = (autoRot + state.extraRotation) % 360
        let totalRad = Double(totalDeg) * .pi / 180.0

        // Efektivní rozměry v souřadnicích buňky (90° / 270° prohodí osy)
        let swapsDims = (totalDeg == 90 || totalDeg == 270)
        let effW = swapsDims ? imgH : imgW
        let effH = swapsDims ? imgW : imgH

        // Měřítko: fit = celý obrázek viditelný, fill = pokryje celou buňku; aplikujeme zoom
        let baseScaleVal: Double = state.fitMode
            ? min(cell.width / effW, cell.height / effH)
            : max(cell.width / effW, cell.height / effH)
        let scale = baseScaleVal * state.zoom

        let drawW = imgW * scale
        let drawH = imgH * scale

        // Pan offset: model ukládá normalizovanou frakci (±1) → převod na PDF body.
        // fRendW/H = vizuální rozměry obrázku v souřadnicích rámečku (po rotaci)
        let fRendW = swapsDims ? drawH : drawW
        let fRendH = swapsDims ? drawW : drawH
        let maxPanX = max(0, (fRendW - cell.width)  / 2)
        let maxPanY = max(0, (fRendH - cell.height) / 2)
        // SwiftUI: +height = dolů; CoreGraphics PDF: +y = nahoru → negujeme Y
        let panX = state.fitMode ? 0.0 :  state.panOffset.width  * maxPanX
        let panY = state.fitMode ? 0.0 : -(state.panOffset.height * maxPanY)

        ctx.saveGState()
        if settings.roundCorners && settings.cornerRadius > 0 {
            let rad = settings.cornerRadius * mmToPt
            let path = CGPath(roundedRect: cell, cornerWidth: rad, cornerHeight: rad, transform: nil)
            ctx.addPath(path)
            ctx.clip()
        } else {
            ctx.clip(to: cell)
        }

        // V fit módu vyplníme pozadí zvolenou barvou (bílé místo)
        if state.fitMode {
            let bgColor = NSColor(state.fitBackground).cgColor
            ctx.setFillColor(bgColor)
            ctx.fill(cell)
        }

        // Přesun do středu buňky + pan (v souřadnicích buňky), otočení, kreslení
        ctx.translateBy(x: cell.midX + panX, y: cell.midY + panY)
        // CoreGraphics má Y nahoru → kladný úhel = CCW; negujeme aby odpovídal CW náhledu
        ctx.rotate(by: -totalRad)
        ctx.draw(cgImg, in: CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH))

        ctx.restoreGState()

        // Linka okolo rámečku
        if settings.addFrameBorder {
            ctx.saveGState()
            ctx.setLineWidth(settings.frameBorderWidth)
            ctx.setStrokeColor(NSColor(settings.frameBorderColor).cgColor)
            if settings.roundCorners && settings.cornerRadius > 0 {
                let rad = settings.cornerRadius * mmToPt
                let path = CGPath(roundedRect: cell, cornerWidth: rad, cornerHeight: rad, transform: nil)
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                ctx.stroke(cell)
            }
            ctx.restoreGState()
        }

        // Prolnutí krajů (kreslíme po obrázku, přes něj)
        if settings.featherEdges && settings.featherAmount > 0 {
            drawFeather(cell: cell, settings: settings, ctx: ctx)
        }

        // Ořezové značky
        if settings.addCropMarks {
            drawCropMarks(for: cell, settings: settings, ctx: ctx)
        }
    }

    // MARK: - Image Effect (Core Image)

    private func applyEffect(_ settings: GallerySettings, to cgImg: CGImage) -> CGImage {
        let effect = settings.imageEffect
        guard effect != .none else { return cgImg }
        var ci = CIImage(cgImage: cgImg)

        switch effect {
        case .none:
            break
        case .vivid:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.6,
                kCIInputContrastKey:   1.1
            ])
            ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4])
        case .grayscale:
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        case .sepia:
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            ci = ci.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        case .oldPhoto:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey:   0.9,
                kCIInputBrightnessKey: -0.03
            ])
            ci = ci.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.70])
            ci = ci.applyingFilter("CIVignette", parameters: [
                kCIInputRadiusKey:    1.8,
                kCIInputIntensityKey: 0.55
            ])
        case .faded:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.65,
                kCIInputContrastKey:   0.82,
                kCIInputBrightnessKey: 0.05
            ])
            ci = ci.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: 0.07, y: 0.07, z: 0.07, w: 0)
            ])
        case .coolTone:
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: 8500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        case .duotone:
            // Desaturace → CIFalseColor přemapuje luminanci na gradient shadow→highlight
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            let shadowNS    = NSColor(settings.duotoneShadowColor).usingColorSpace(.sRGB)
                              ?? NSColor(red: 0.04, green: 0.18, blue: 0.42, alpha: 1)
            let highlightNS = NSColor(settings.duotoneHighlightColor).usingColorSpace(.sRGB)
                              ?? NSColor(red: 1.00, green: 0.60, blue: 0.15, alpha: 1)
            ci = ci.applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(cgColor: shadowNS.cgColor),
                "inputColor1": CIColor(cgColor: highlightNS.cgColor)
            ])
        }

        return ciCtx.createCGImage(ci, from: ci.extent) ?? cgImg
    }

    // MARK: - Prolnutí krajů do ztracena

    private func drawFeather(cell: CGRect, settings: GallerySettings, ctx: CGContext) {
        let f   = CGFloat(settings.featherAmount / 100.0)
        let dx  = cell.width  * f
        let dy  = cell.height * f

        // Barva pozadí stránky jako cílová barva prolnutí
        let bgNS = NSColor(settings.pageBackgroundColor).usingColorSpace(.sRGB)
                   ?? NSColor.white
        let bgCG   = bgNS.cgColor
        guard let transparent = bgCG.copy(alpha: 0),
              let colorSpace  = bgCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        else { return }

        ctx.saveGState()
        // Clip na rámeček (zakulacený nebo rovný)
        if settings.roundCorners && settings.cornerRadius > 0 {
            let rad  = settings.cornerRadius * mmToPt
            let path = CGPath(roundedRect: cell, cornerWidth: rad, cornerHeight: rad, transform: nil)
            ctx.addPath(path)
            ctx.clip()
        } else {
            ctx.clip(to: cell)
        }

        let sides: [(CGPoint, CGPoint, [CGColor])] = [
            // levý okraj: bgCG → transparent (zleva doprava)
            (CGPoint(x: cell.minX,      y: cell.midY),
             CGPoint(x: cell.minX + dx, y: cell.midY),
             [bgCG, transparent]),
            // pravý okraj: transparent → bgCG (zleva doprava)
            (CGPoint(x: cell.maxX - dx, y: cell.midY),
             CGPoint(x: cell.maxX,      y: cell.midY),
             [transparent, bgCG]),
            // horní okraj: transparent → bgCG (v PDF Y roste nahoru → maxY je nahoře)
            (CGPoint(x: cell.midX, y: cell.maxY - dy),
             CGPoint(x: cell.midX, y: cell.maxY),
             [transparent, bgCG]),
            // dolní okraj: bgCG → transparent
            (CGPoint(x: cell.midX, y: cell.minY),
             CGPoint(x: cell.midX, y: cell.minY + dy),
             [bgCG, transparent]),
        ]

        for (start, end, colors) in sides {
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors as CFArray,
                locations: [0, 1]
            ) else { continue }
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        }

        ctx.restoreGState()
    }

    // MARK: - Ořezové značky

    private func drawCropMarks(for rect: CGRect, settings: GallerySettings, ctx: CGContext) {
        let len = settings.cropMarkLength * mmToPt
        let off = settings.cropMarkOffset * mmToPt
        let lw  = settings.cropMarkWidth

        ctx.saveGState()
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))

        let corners: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            // Levý horní
            (CGPoint(x: rect.minX, y: rect.maxY),
             CGPoint(x: rect.minX - off - len, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.maxY + off),
             CGPoint(x: rect.minX, y: rect.maxY + off + len)),
            // Pravý horní
            (CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.maxX + off + len, y: rect.maxY),
             CGPoint(x: rect.maxX, y: rect.maxY + off),
             CGPoint(x: rect.maxX, y: rect.maxY + off + len)),
            // Levý dolní
            (CGPoint(x: rect.minX, y: rect.minY),
             CGPoint(x: rect.minX - off - len, y: rect.minY),
             CGPoint(x: rect.minX, y: rect.minY - off),
             CGPoint(x: rect.minX, y: rect.minY - off - len)),
            // Pravý dolní
            (CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX + off + len, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY - off),
             CGPoint(x: rect.maxX, y: rect.minY - off - len)),
        ]

        for (_, h1, _, v1) in corners {
            // Vodorovná čára
            ctx.move(to: h1)
            if h1.x < rect.minX {
                ctx.addLine(to: CGPoint(x: rect.minX - off, y: h1.y))
            } else {
                ctx.addLine(to: CGPoint(x: rect.maxX + off, y: h1.y))
            }
            // Svislá čára
            ctx.move(to: v1)
            if v1.y > rect.maxY {
                ctx.addLine(to: CGPoint(x: v1.x, y: rect.maxY + off))
            } else {
                ctx.addLine(to: CGPoint(x: v1.x, y: rect.minY - off))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Popisek pod obrázkem

    /// Odstraní číslo na konci názvu (např. "Felix Slováček 2" → "Felix Slováček").
    static func stripTrailingNumber(_ s: String) -> String {
        guard let range = s.range(of: #"\s+\d+$"#, options: .regularExpression) else { return s }
        return String(s[..<range.lowerBound])
    }

    private func drawLabel(
        for state: GalleryImageState,
        in rect: CGRect,
        settings: GallerySettings,
        ctx: CGContext
    ) {
        var filename = state.displayLabel
        if settings.labelStripNumbers {
            filename = GalleryService.stripTrailingNumber(filename)
        }

        // Pozadí popisku (pokud není průhledné)
        let bgNS = NSColor(settings.labelBackground)
        if bgNS.alphaComponent > 0.01 {
            ctx.saveGState()
            ctx.setFillColor(bgNS.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        }

        // Atributy textu
        let font = NSFont(name: settings.labelFontName, size: CGFloat(settings.labelFontSize))
                   ?? NSFont.systemFont(ofSize: CGFloat(settings.labelFontSize))
        let para = NSMutableParagraphStyle()
        para.alignment = settings.labelAlignment.nsAlignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(settings.labelColor),
            .paragraphStyle: para
        ]
        let str = NSAttributedString(string: filename, attributes: attrs)

        // Odsazení textu (padding) – konverze z mm na pt
        let padTop    = settings.labelPadTop    * mmToPt
        let padBottom = settings.labelPadBottom * mmToPt
        let padLeft   = settings.labelPadLeft   * mmToPt
        let padRight  = settings.labelPadRight  * mmToPt

        // Textová oblast s paddingem (Y-up souřadnice: padTop zmenšuje maxY, padBottom zmenšuje minY)
        let textRect = CGRect(
            x:      rect.minX + padLeft,
            y:      rect.minY + padBottom,
            width:  max(1, rect.width  - padLeft - padRight),
            height: max(1, rect.height - padTop  - padBottom)
        )

        // Vertikálně vystředit text v oblasti s paddingem
        let textH = str.size().height
        let textY = textRect.minY + (textRect.height - textH) / 2

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        str.draw(in: CGRect(x: textRect.minX, y: textY,
                            width: textRect.width, height: textH))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Načtení CGImage (s volitelným převzorkováním)

    private func loadCGImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Vrátí rozměry obrázku v px a DPI.
    func imageInfo(url: URL) -> (pixelSize: CGSize, dpi: Double) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return (.zero, 72)
        }
        let pw = (props[kCGImagePropertyPixelWidth]  as? Int).map(Double.init) ?? 0
        let ph = (props[kCGImagePropertyPixelHeight] as? Int).map(Double.init) ?? 0
        var dpi: Double = 72
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let x = tiff[kCGImagePropertyTIFFXResolution] as? Double, x > 0 {
            dpi = x
        } else if let x = props[kCGImagePropertyDPIWidth] as? Double, x > 0 {
            dpi = x
        }
        return (CGSize(width: pw, height: ph), dpi)
    }
}

// MARK: - Errors

enum GalleryError: LocalizedError {
    case cannotCreateContext
    case noImages

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext: return "Nelze vytvořit PDF kontext."
        case .noImages:            return "Nejsou vybrány žádné obrázky."
        }
    }
}
