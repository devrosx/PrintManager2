//
//  ExpandService.swift
//  PrintManager
//
//  Rozšíření okrajů dokumentu (PDF nebo obrázek) o zadaný počet mm na každou stranu.
//  Okraje jsou vyplněny opakováním krajního pixelu (po řádcích/sloupcích).
//
//  PDF strategie:
//    1. Stránka se rasterizuje na 300 DPI.
//    2. Raster se rozšíří o expandPx pixelů na každou stranu.
//    3. Nová stránka PDF: rozšířený raster jako pozadí + originální vektorová vrstva nahoře.
//

import Foundation
import CoreGraphics
import PDFKit
import AppKit
import ImageIO

// MARK: - Error

enum ExpandError: LocalizedError {
    case cannotLoadFile
    case cannotCreateContext
    case cannotCreateImage

    var errorDescription: String? {
        switch self {
        case .cannotLoadFile:      return "Nelze načíst soubor."
        case .cannotCreateContext: return "Nelze vytvořit grafický kontext."
        case .cannotCreateImage:   return "Nelze vytvořit výsledný obrázek."
        }
    }
}

// MARK: - Fill Mode

enum ExpandFillMode: String, CaseIterable {
    case edgeFill   = "Krajní pixel"
    case mirrorFill = "Zrcadlo"
}

// MARK: - Service

final class ExpandService {

    static let shared = ExpandService()
    private init() {}

    private let mmToPt: CGFloat = RenderingConstants.pointsPerMillimeter
    private let renderDPI: CGFloat = 300    // DPI pro rasterizaci PDF stránek

    // MARK: - Public entry point

    func expand(url: URL, expandMm: Double, fillMode: ExpandFillMode = .edgeFill) throws -> URL {
        let fileType = FileType.from(extension: url.pathExtension.lowercased())
        if fileType == .pdf {
            return try expandPDF(url: url, expandMm: expandMm, fillMode: fillMode)
        } else if fileType.isImage {
            return try expandImage(url: url, expandMm: expandMm, fillMode: fillMode)
        } else {
            throw ExpandError.cannotLoadFile
        }
    }

    // MARK: - Image Expand

    private func expandImage(url: URL, expandMm: Double, fillMode: ExpandFillMode) throws -> URL {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExpandError.cannotLoadFile
        }

        // Zjisti DPI z NSImage reprezentace
        let dpi: CGFloat = {
            guard let rep = nsImage.representations.first, rep.size.width > 0 else { return 72 }
            return CGFloat(rep.pixelsWide) / rep.size.width * 72
        }()

        let expandPx = max(1, Int((CGFloat(expandMm) / 25.4 * dpi).rounded()))
        let expanded = try expandCGImage(cgImage, expandPx: expandPx, fillMode: fillMode)

        let outputURL = makeOutputURL(for: url)
        let utType    = uniformTypeID(for: url.pathExtension) as CFString
        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, utType, 1, nil) else {
            throw ExpandError.cannotCreateContext
        }
        let props: [String: Any] = [
            kCGImagePropertyDPIWidth  as String: dpi,
            kCGImagePropertyDPIHeight as String: dpi
        ]
        CGImageDestinationAddImage(dest, expanded, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExpandError.cannotCreateImage }
        return outputURL
    }

    // MARK: - PDF Expand

    private func expandPDF(url: URL, expandMm: Double, fillMode: ExpandFillMode) throws -> URL {
        guard let pdfDoc = PDFDocument(url: url), pdfDoc.pageCount > 0 else {
            throw ExpandError.cannotLoadFile
        }

        let expandPt = CGFloat(expandMm) * mmToPt
        let pdfToPx  = renderDPI / 72   // body → pixely pro rasterizaci

        // Výstupní PDF kontext
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw ExpandError.cannotCreateContext
        }

        // Inicializuj s první stránkou (per-page size se nastaví v beginPDFPage)
        let firstPage    = pdfDoc.page(at: 0)!
        let firstOrig    = firstPage.bounds(for: .mediaBox)
        var initMediaBox = CGRect(x: 0, y: 0,
                                  width:  firstOrig.width  + 2 * expandPt,
                                  height: firstOrig.height + 2 * expandPt)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initMediaBox, nil) else {
            throw ExpandError.cannotCreateContext
        }

        for pageIdx in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIdx) else { continue }
            let origRect = page.bounds(for: .mediaBox)
            let newW     = origRect.width  + 2 * expandPt
            let newH     = origRect.height + 2 * expandPt

            // Rasterizuj stránku na 300 DPI (bílé pozadí)
            let rasterW  = max(1, Int((origRect.width  * pdfToPx).rounded()))
            let rasterH  = max(1, Int((origRect.height * pdfToPx).rounded()))
            guard let rasterCtx = CGContext(
                data: nil, width: rasterW, height: rasterH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }

            rasterCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            rasterCtx.fill(CGRect(x: 0, y: 0, width: CGFloat(rasterW), height: CGFloat(rasterH)))
            rasterCtx.scaleBy(x: pdfToPx, y: pdfToPx)
            rasterCtx.translateBy(x: -origRect.minX, y: -origRect.minY)
            page.draw(with: .mediaBox, to: rasterCtx)
            guard let rasterImg = rasterCtx.makeImage() else { continue }

            // Rozšíř raster o expandPx pixelů na každou stranu
            let expandPx    = max(1, Int((expandPt * pdfToPx).rounded()))
            let expandedImg = try expandCGImage(rasterImg, expandPx: expandPx, fillMode: fillMode)

            // Začni novou stránku s upravenou media box
            var newMediaBox = CGRect(x: 0, y: 0, width: newW, height: newH)
            let mboxData    = Data(bytes: &newMediaBox, count: MemoryLayout<CGRect>.size) as CFData
            let pageInfo    = [kCGPDFContextMediaBox: mboxData] as CFDictionary
            ctx.beginPDFPage(pageInfo)

            // 1. Pozadí — rozšířený raster přes celou novou stránku
            ctx.draw(expandedImg, in: CGRect(x: 0, y: 0, width: newW, height: newH))

            // 2. Vektorová grafika — posunutá o expandPt (kompenzujeme také origin media boxu)
            ctx.saveGState()
            ctx.translateBy(x: expandPt - origRect.minX, y: expandPt - origRect.minY)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            ctx.endPDFPage()
        }

        ctx.closePDF()
        let outputURL = makeOutputURL(for: url)
        try (pdfData as Data).write(to: outputURL)
        return outputURL
    }

    // MARK: - Core: expand CGImage

    private func expandCGImage(_ image: CGImage, expandPx: Int, fillMode: ExpandFillMode) throws -> CGImage {
        switch fillMode {
        case .edgeFill:   return try expandCGImageEdge(image, expandPx: expandPx)
        case .mirrorFill: return try expandCGImageMirror(image, expandPx: expandPx)
        }
    }

    // MARK: Edge-fill (opakování krajního pixelu)

    /// Rozšíří obrázek o `expandPx` pixelů na každou stranu vyplněním krajními barvami.
    private func expandCGImageEdge(_ image: CGImage, expandPx: Int) throws -> CGImage {
        let origW = image.width
        let origH = image.height
        let newW  = origW + 2 * expandPx
        let newH  = origH + 2 * expandPx

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        // Použij premultipliedLast — bezpečné pro obrázky s i bez alfa
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ExpandError.cannotCreateContext
        }

        // Bez interpolace — přesná barva krajního pixelu, bez přechodu
        ctx.interpolationQuality = .none

        let ex = CGFloat(expandPx)
        let ow = CGFloat(origW)
        let oh = CGFloat(origH)

        // CGImage má souřadnicový systém vlevo-nahoře: y=0 je PRVNÍ (horní) řádek.
        // CGContext má y=0 dole → ctx.draw() obrázek vertikálně překlopí.
        // Proto:
        //   horní okraj výsledku  → bereme y=0        z CGImage (horní řádek obrázku)
        //   dolní okraj výsledku  → bereme y=origH-1  z CGImage (dolní řádek obrázku)

        // Rohy: 1×1 pixel natažený na celý rohový čtverec
        func drawCorner(srcX: Int, srcY: Int, dstX: CGFloat, dstY: CGFloat) {
            guard let crop = image.cropping(to: CGRect(x: srcX, y: srcY, width: 1, height: 1)) else { return }
            ctx.draw(crop, in: CGRect(x: dstX, y: dstY, width: ex, height: ex))
        }
        // dstY=0 = dolní část kontextu → srcY = dolní řádek obrázku (origH-1)
        // dstY=oh+ex = horní část kontextu → srcY = horní řádek obrázku (0)
        drawCorner(srcX: 0,       srcY: origH-1, dstX: 0,       dstY: 0)       // dole-vlevo
        drawCorner(srcX: origW-1, srcY: origH-1, dstX: ow+ex,   dstY: 0)       // dole-vpravo
        drawCorner(srcX: 0,       srcY: 0,       dstX: 0,       dstY: oh+ex)   // nahoře-vlevo
        drawCorner(srcX: origW-1, srcY: 0,       dstX: ow+ex,   dstY: oh+ex)   // nahoře-vpravo

        // Okrajové pruhy: 1px sloupec/řádek natažený přes celé rozšíření
        // Levý/pravý: bereme celý sloupec (y: 0, height: origH) — ctx.draw ho správně překlopí
        if let s = image.cropping(to: CGRect(x: 0,       y: 0, width: 1,     height: origH)) {
            ctx.draw(s, in: CGRect(x: 0,     y: ex, width: ex, height: oh))    // vlevo
        }
        if let s = image.cropping(to: CGRect(x: origW-1, y: 0, width: 1,     height: origH)) {
            ctx.draw(s, in: CGRect(x: ow+ex, y: ex, width: ex, height: oh))    // vpravo
        }
        // Dolní pruh → dolní řádek obrázku = y: origH-1 v CGImage
        if let s = image.cropping(to: CGRect(x: 0, y: origH-1, width: origW, height: 1)) {
            ctx.draw(s, in: CGRect(x: ex, y: 0,     width: ow, height: ex))    // dole
        }
        // Horní pruh → horní řádek obrázku = y: 0 v CGImage
        if let s = image.cropping(to: CGRect(x: 0, y: 0,       width: origW, height: 1)) {
            ctx.draw(s, in: CGRect(x: ex, y: oh+ex, width: ow, height: ex))    // nahoře
        }

        // Originální obrázek do středu
        ctx.draw(image, in: CGRect(x: ex, y: ex, width: ow, height: oh))

        guard let result = ctx.makeImage() else { throw ExpandError.cannotCreateImage }
        return result
    }

    // MARK: Mirror-fill (zrcadlové opakování okraje)

    /// Rozšíří obrázek zrcadlovým odrazem obsahu od každé hrany.
    /// Pruh šířky min(expandPx, origW/H) se překlopí a vloží do okraje.
    private func expandCGImageMirror(_ image: CGImage, expandPx: Int) throws -> CGImage {
        let origW = image.width
        let origH = image.height
        let newW  = origW + 2 * expandPx
        let newH  = origH + 2 * expandPx

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ExpandError.cannotCreateContext
        }
        ctx.interpolationQuality = .high

        let ex  = CGFloat(expandPx)
        let ow  = CGFloat(origW)
        let oh  = CGFloat(origH)

        // Šířka zrcadleného pruhu nesmí přesáhnout rozměry originálního obrázku
        let mirrorW = min(expandPx, origW)
        let mirrorH = min(expandPx, origH)
        let mw = CGFloat(mirrorW)
        let mh = CGFloat(mirrorH)

        // Pomocná closure: vykreslí cropped výřez s volitelným horizontálním/vertikálním překlopením
        func drawMirrored(crop: CGImage, in destRect: CGRect, flipH: Bool, flipV: Bool) {
            ctx.saveGState()
            // Přesuň počátek do středu destRect, aplikuj zrcadlení, vrať zpět
            let cx = destRect.midX
            let cy = destRect.midY
            ctx.translateBy(x: cx, y: cy)
            ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
            ctx.translateBy(x: -cx, y: -cy)
            ctx.draw(crop, in: destRect)
            ctx.restoreGState()
        }

        // ── Levý pruh: první mirrorW sloupců obrázku, zrcadleno horizontálně ──
        // CGImage y=0 je NAHOŘE → celý sloupec = (x:0, y:0, w:mirrorW, h:origH)
        if let leftStrip = image.cropping(to: CGRect(x: 0, y: 0, width: mirrorW, height: origH)) {
            // Levý pruh v kontextu: x=0, y=ex, w=ex, h=oh  (ale my máme jen mw wide crop)
            // Natáhneme na plnou šířku ex a překlopíme horizontálně
            drawMirrored(crop: leftStrip,
                         in: CGRect(x: 0, y: ex, width: ex, height: oh),
                         flipH: true, flipV: false)
        }

        // ── Pravý pruh: posledních mirrorW sloupců, zrcadleno horizontálně ──
        if let rightStrip = image.cropping(to: CGRect(x: origW - mirrorW, y: 0, width: mirrorW, height: origH)) {
            drawMirrored(crop: rightStrip,
                         in: CGRect(x: ow + ex, y: ex, width: ex, height: oh),
                         flipH: true, flipV: false)
        }

        // ── Dolní pruh: poslední mirrorH řádků obrázku (CGImage y=0 je nahoře → dolní řádky = y: origH-mirrorH)
        //    V kontextu y=0 je dole → dolní okraj = y: 0..ex; zrcadlíme vertikálně ──
        if let bottomStrip = image.cropping(to: CGRect(x: 0, y: origH - mirrorH, width: origW, height: mirrorH)) {
            drawMirrored(crop: bottomStrip,
                         in: CGRect(x: ex, y: 0, width: ow, height: ex),
                         flipH: false, flipV: true)
        }

        // ── Horní pruh: první mirrorH řádků obrázku (CGImage y=0..mirrorH)
        //    V kontextu horní okraj = y: oh+ex..(oh+2*ex); zrcadlíme vertikálně ──
        if let topStrip = image.cropping(to: CGRect(x: 0, y: 0, width: origW, height: mirrorH)) {
            drawMirrored(crop: topStrip,
                         in: CGRect(x: ex, y: oh + ex, width: ow, height: ex),
                         flipH: false, flipV: true)
        }

        // ── Rohové čtverce ──
        // Rohy bereme z rohových čtverců (mirrorW × mirrorH) a zrcadlíme v obou osách

        // Levý dolní roh kontextu → levý dolní roh obrázku (CGImage: x=0, y=origH-mirrorH)
        if let c = image.cropping(to: CGRect(x: 0, y: origH - mirrorH, width: mirrorW, height: mirrorH)) {
            drawMirrored(crop: c, in: CGRect(x: 0, y: 0, width: ex, height: ex),
                         flipH: true, flipV: true)
        }
        // Pravý dolní roh kontextu → pravý dolní roh obrázku (CGImage: x=origW-mirrorW, y=origH-mirrorH)
        if let c = image.cropping(to: CGRect(x: origW - mirrorW, y: origH - mirrorH, width: mirrorW, height: mirrorH)) {
            drawMirrored(crop: c, in: CGRect(x: ow + ex, y: 0, width: ex, height: ex),
                         flipH: true, flipV: true)
        }
        // Levý horní roh kontextu → levý horní roh obrázku (CGImage: x=0, y=0)
        if let c = image.cropping(to: CGRect(x: 0, y: 0, width: mirrorW, height: mirrorH)) {
            drawMirrored(crop: c, in: CGRect(x: 0, y: oh + ex, width: ex, height: ex),
                         flipH: true, flipV: true)
        }
        // Pravý horní roh kontextu → pravý horní roh obrázku (CGImage: x=origW-mirrorW, y=0)
        if let c = image.cropping(to: CGRect(x: origW - mirrorW, y: 0, width: mirrorW, height: mirrorH)) {
            drawMirrored(crop: c, in: CGRect(x: ow + ex, y: oh + ex, width: ex, height: ex),
                         flipH: true, flipV: true)
        }

        // ── Originální obrázek do středu ──
        ctx.draw(image, in: CGRect(x: ex, y: ex, width: ow, height: oh))

        guard let result = ctx.makeImage() else { throw ExpandError.cannotCreateImage }
        return result
    }

    // MARK: - Helpers

    private func makeOutputURL(for url: URL) -> URL {
        let dir  = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        return dir.appendingPathComponent("\(base)\(OutputSuffix.expanded).\(ext)")
    }

    private func uniformTypeID(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "public.jpeg"
        case "png":         return "public.png"
        case "tif", "tiff": return "public.tiff"
        case "bmp":         return "com.microsoft.bmp"
        default:            return "public.png"
        }
    }
}
