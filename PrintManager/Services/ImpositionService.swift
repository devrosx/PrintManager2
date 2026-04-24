//
//  ImpositionService.swift
//  PrintManager
//
//  PDF Imposition service – N-up, Step-Repeat, Booklet, Cut Stacks
//  Uses PDFKit + Core Graphics (macOS native, no UIKit)
//

import Foundation
import CoreGraphics
import PDFKit
import AppKit

// MARK: - Error

enum ImpositionError: LocalizedError {
    case cannotLoadPDF
    case noPages

    var errorDescription: String? {
        switch self {
        case .cannotLoadPDF: return "Nelze načíst PDF soubor."
        case .noPages:       return "PDF neobsahuje žádné stránky."
        }
    }
}

// MARK: - Service

final class ImpositionService {

    static let shared = ImpositionService()
    private init() {}

    let mmToPt: CGFloat = RenderingConstants.pointsPerMillimeter

    // MARK: - Public entry point

    func createImposition(from sourceURL: URL, settings: ImpositionSettings) throws -> ImpositionResult {
        guard let pdfDoc = PDFDocument(url: sourceURL) else {
            throw ImpositionError.cannotLoadPDF
        }
        guard pdfDoc.pageCount > 0 else {
            throw ImpositionError.noPages
        }

        let sheetSize = computeSheetSize(settings: settings)
        let outURL    = outputURL(for: sourceURL)

        switch settings.mode {
        case .nUp:
            return try performNUp(pdfDoc: pdfDoc, settings: settings, sheetSize: sheetSize, outputURL: outURL)
        case .stepRepeat:
            return try performStepRepeat(pdfDoc: pdfDoc, settings: settings, sheetSize: sheetSize, outputURL: outURL)
        case .booklet:
            return try performBooklet(pdfDoc: pdfDoc, settings: settings, outputURL: outURL)
        case .cutStacks:
            return try performCutStacks(pdfDoc: pdfDoc, settings: settings, sheetSize: sheetSize, outputURL: outURL)
        }
    }

    // MARK: - Sheet size

    func computeSheetSize(settings: ImpositionSettings) -> CGSize {
        let base: CGSize = settings.paperSize == .custom
            ? CGSize(width: CGFloat(settings.customWidth)  * mmToPt,
                     height: CGFloat(settings.customHeight) * mmToPt)
            : settings.paperSize.size
        switch settings.orientation {
        case .portrait:
            return base
        case .landscape:
            return CGSize(width: base.height, height: base.width)
        case .auto:
            // Booklet always landscape; N-up: landscape when cols ≥ rows
            if settings.mode == .booklet { return CGSize(width: base.height, height: base.width) }
            if settings.columns >= settings.rows { return CGSize(width: base.height, height: base.width) }
            return base
        }
    }

    // MARK: - Sheet count (for UI preview)

    func sheetCount(pageCount: Int, settings: ImpositionSettings) -> Int {
        guard pageCount > 0 else { return 0 }
        switch settings.mode {
        case .nUp:
            let perSheet = max(1, settings.columns * settings.rows)
            return (pageCount + perSheet - 1) / perSheet
        case .stepRepeat:
            return 1
        case .cutStacks:
            return pageCount
        case .booklet:
            let padded = pageCount + ((4 - pageCount % 4) % 4)
            return padded / 2  // total output pages (each = one printed side)
        }
    }

    // MARK: - Cell rect helper

    /// Returns the CGRect (in PDF coordinates, Y-up) for the cell at (col, row)
    /// Row 0 = top-most row visually.
    func cellRect(col: Int, row: Int, cols: Int, rows: Int,
                  in sheetSize: CGSize,
                  margins: ImpositionMargins,
                  gutterH: Double, gutterV: Double,
                  cellSizeOverride: CGSize? = nil) -> CGRect {
        let topPt    = CGFloat(margins.top)    * mmToPt
        let bottomPt = CGFloat(margins.bottom) * mmToPt
        let leftPt   = CGFloat(margins.left)   * mmToPt
        let rightPt  = CGFloat(margins.right)  * mmToPt
        let gHPt     = CGFloat(gutterH) * mmToPt
        let gVPt     = CGFloat(gutterV) * mmToPt

        let cellW: CGFloat
        let cellH: CGFloat
        if let ov = cellSizeOverride {
            cellW = ov.width
            cellH = ov.height
        } else {
            let usableW = sheetSize.width  - leftPt - rightPt  - CGFloat(cols - 1) * gHPt
            let usableH = sheetSize.height - topPt  - bottomPt - CGFloat(rows - 1) * gVPt
            cellW = max(1, usableW / CGFloat(cols))
            cellH = max(1, usableH / CGFloat(rows))
        }

        let x = leftPt + CGFloat(col) * (cellW + gHPt)
        // PDF Y-up: row 0 (top visual) anchored at topPt from sheet top
        let y = sheetSize.height - topPt - cellH - CGFloat(row) * (cellH + gVPt)

        return CGRect(x: x, y: y, width: cellW, height: cellH)
    }

    /// Effective frame/cell size in points (respects manual override and natural 1:1 mode).
    /// V 1:1 režimu vrací trim size (sourcePageSize − 2×ořez).
    func effectiveCellSize(settings: ImpositionSettings, sheetSize: CGSize) -> CGSize {
        if settings.useManualFrameSize {
            return CGSize(width:  CGFloat(settings.manualFrameWidth)  * mmToPt,
                          height: CGFloat(settings.manualFrameHeight) * mmToPt)
        }
        if !settings.fitToPage, let pageSize = settings.sourcePageSizePt {
            let crop = CGFloat(settings.cropInsetMM) * mmToPt * 2
            return CGSize(width:  max(1, pageSize.width  - crop),
                          height: max(1, pageSize.height - crop))
        }
        return cellRect(col: 0, row: 0, cols: settings.columns, rows: settings.rows,
                        in: sheetSize, margins: settings.margins,
                        gutterH: settings.gutterH, gutterV: settings.gutterV).size
    }

    // MARK: - Draw one PDF page into a cell rect

    private func drawPage(_ page: PDFPage, into rect: CGRect, scale: Double,
                          autoRotate: Bool = false,
                          fitToPage:  Bool = true,
                          pdfBox: PDFDisplayBox = .mediaBox,
                          cropInset: CGSize = .zero,
                          in ctx: CGContext) {
        let pageRect = page.bounds(for: pdfBox)
        let pageW = pageRect.width
        let pageH = pageRect.height
        guard pageW > 0, pageH > 0 else { return }

        // Determine whether rotating 90° CCW gives a better fill
        let fitNormal  = min(rect.width / pageW, rect.height / pageH)
        let fitRotated = min(rect.width / pageH, rect.height / pageW)
        let rotate = autoRotate && (fitRotated > fitNormal)

        let drawW = rotate ? pageH : pageW  // display dimensions after optional rotation
        let drawH = rotate ? pageW : pageH
        let scaleFactor = CGFloat(scale / 100.0)

        ctx.saveGState()

        // Záporná mezera: ořez centrovaně dovnitř
        if cropInset.width > 0 || cropInset.height > 0 {
            ctx.clip(to: rect.insetBy(dx: cropInset.width, dy: cropInset.height))
        }

        if fitToPage {
            // Scale page to fill the cell, then apply extra scale%
            let fitScale = min(rect.width / drawW, rect.height / drawH) * scaleFactor
            let scaledW  = drawW * fitScale
            let scaledH  = drawH * fitScale
            let xOff = rect.minX + (rect.width  - scaledW) / 2
            let yOff = rect.minY + (rect.height - scaledH) / 2
            if rotate {
                ctx.translateBy(x: xOff + scaledW, y: yOff)
                ctx.rotate(by: .pi / 2)
                ctx.scaleBy(x: fitScale, y: fitScale)
            } else {
                ctx.translateBy(x: xOff, y: yOff)
                ctx.scaleBy(x: fitScale, y: fitScale)
            }
        } else {
            // Natural size: 100% = 1 pt per pt; clip to cell so pages larger than cell don't overflow
            let naturalScale = scaleFactor
            let scaledW = drawW * naturalScale
            let scaledH = drawH * naturalScale
            let xOff = rect.minX + (rect.width  - scaledW) / 2
            let yOff = rect.minY + (rect.height - scaledH) / 2
            ctx.clip(to: rect)
            if rotate {
                ctx.translateBy(x: xOff + scaledW, y: yOff)
                ctx.rotate(by: .pi / 2)
                ctx.scaleBy(x: naturalScale, y: naturalScale)
            } else {
                ctx.translateBy(x: xOff, y: yOff)
                ctx.scaleBy(x: naturalScale, y: naturalScale)
            }
        }

        page.draw(with: pdfBox, to: ctx)
        ctx.restoreGState()
    }

    // MARK: - Ořezové značky

    /// Kreslí ořezové značky **pouze po vnějším obvodu** celé kompozice.
    ///
    /// Algoritmus (jednoduchý a robustní):
    ///   1. Sesbírej všechny unikátní X a Y pozice hranic rámečků.
    ///   2. Vnější X = nejmenší a největší X (levý a pravý okraj kompozice).
    ///   3. Vnější Y = nejmenší a největší Y (dolní a horní okraj).
    ///   4. Na levém/pravém vnějším X nakresli vodorovné čáry ven pro každou Y pozici.
    ///   5. Na dolním/horním vnějším Y nakresli svislé čáry ven pro každou X pozici.
    ///
    /// Výsledek: L-tvar v rozích, jednoduchá čára v mezilehlých bodech obvodu, nic uvnitř.
    private func drawCropMarks(for rects: [CGRect], settings: ImpositionSettings,
                               sheetSize: CGSize, in ctx: CGContext) {
        guard !rects.isEmpty else { return }

        let len    = CGFloat(settings.cropMarkLength) * mmToPt
        let offset = CGFloat(settings.cropMarkOffset) * mmToPt

        // ── 1. Unikátní X a Y pozice všech hranic rámečků ──────────────────────
        var xs = Set<CGFloat>()
        var ys = Set<CGFloat>()
        for r in rects {
            xs.insert(r.minX); xs.insert(r.maxX)
            ys.insert(r.minY); ys.insert(r.maxY)
        }
        let xSorted = xs.sorted()
        let ySorted = ys.sorted()

        let xLeft  = xSorted.first!
        let xRight = xSorted.last!
        let yBot   = ySorted.first!
        let yTop   = ySorted.last!

        ctx.saveGState()
        ctx.beginPath()

        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(CGFloat(settings.cropMarkLineWidth))

        let lenL = min(len, max(0, xLeft  - offset))
        let lenR = min(len, max(0, sheetSize.width  - xRight - offset))
        let lenB = min(len, max(0, yBot   - offset))
        let lenT = min(len, max(0, sheetSize.height - yTop   - offset))

        // Levá strana – vodorovné čáry jdoucí doleva pro každou Y pozici
        if lenL > 0 {
            for y in ySorted {
                ctx.move(to:    CGPoint(x: xLeft - offset,        y: y))
                ctx.addLine(to: CGPoint(x: xLeft - offset - lenL, y: y))
            }
        }
        // Pravá strana – vodorovné čáry jdoucí doprava pro každou Y pozici
        if lenR > 0 {
            for y in ySorted {
                ctx.move(to:    CGPoint(x: xRight + offset,        y: y))
                ctx.addLine(to: CGPoint(x: xRight + offset + lenR, y: y))
            }
        }
        // Dolní strana – svislé čáry jdoucí dolů pro každou X pozici
        if lenB > 0 {
            for x in xSorted {
                ctx.move(to:    CGPoint(x: x, y: yBot - offset))
                ctx.addLine(to: CGPoint(x: x, y: yBot - offset - lenB))
            }
        }
        // Horní strana – svislé čáry jdoucí nahoru pro každou X pozici
        if lenT > 0 {
            for x in xSorted {
                ctx.move(to:    CGPoint(x: x, y: yTop + offset))
                ctx.addLine(to: CGPoint(x: x, y: yTop + offset + lenT))
            }
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    private func addCropMark(ctx: CGContext, corner: CGPoint,
                             hDir: CGFloat, vDir: CGFloat,
                             hLen: CGFloat, vLen: CGFloat, offset: CGFloat) {
        if hLen > 0 {
            ctx.move(to:    CGPoint(x: corner.x + hDir * offset,          y: corner.y))
            ctx.addLine(to: CGPoint(x: corner.x + hDir * (offset + hLen), y: corner.y))
        }
        if vLen > 0 {
            ctx.move(to:    CGPoint(x: corner.x, y: corner.y + vDir * offset))
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + vDir * (offset + vLen)))
        }
    }

    // MARK: - Frame border

    /// Tenkā šedá linka 0,5 pt (50 % šedá) okolo každého rámečku objektu.
    private func drawFrameBorders(for rects: [CGRect], in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1.0))
        ctx.setLineWidth(0.5)
        for rect in rects { ctx.stroke(rect) }
        ctx.restoreGState()
    }

    // MARK: - Crop inset helpers

    /// Vrátí CGSize crop inset pro kreslení / crop marks.
    /// V 1:1 režimu je ořez zahrnut ve velikosti rámečku (bleed) → .zero.
    /// V ostatních režimech (fitToPage, manual) ořezujeme viditelnou plochu dovnitř.
    func negativeMezeraCropInset(_ settings: ImpositionSettings) -> CGSize {
        guard settings.cropInsetMM > 0 else { return .zero }
        if !settings.fitToPage && !settings.useManualFrameSize { return .zero }
        let c = CGFloat(settings.cropInsetMM) * mmToPt
        return CGSize(width: c, height: c)
    }

    /// Insetuje pole rektů o cropInset (pro crop marks / frame borders).
    /// Pokud cropInset == .zero, vrátí rects beze změny.
    private func insetRects(_ rects: [CGRect], by inset: CGSize) -> [CGRect] {
        guard inset.width > 0 || inset.height > 0 else { return rects }
        return rects.map { $0.insetBy(dx: inset.width, dy: inset.height) }
    }

    // MARK: - CGContext / PDF context factory

    private func makeContext(sheetSize: CGSize) -> (CGContext, NSMutableData) {
        let pdfData = NSMutableData()
        let consumer = CGDataConsumer(data: pdfData as CFMutableData)!
        var mediaBox = CGRect(origin: .zero, size: sheetSize)
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        return (ctx, pdfData)
    }

    // MARK: - N-up

    private func performNUp(pdfDoc: PDFDocument, settings: ImpositionSettings,
                            sheetSize: CGSize, outputURL: URL) throws -> ImpositionResult {
        let perSheet   = max(1, settings.columns * settings.rows)
        let pageCount  = pdfDoc.pageCount
        let sheetCount = (pageCount + perSheet - 1) / perSheet
        let frameOv    = frameOverride(settings)
        let cropInset  = negativeMezeraCropInset(settings)

        let (ctx, pdfData) = makeContext(sheetSize: sheetSize)

        for sheetIdx in 0..<sheetCount {
            ctx.beginPDFPage(nil)
            fillWhite(ctx: ctx, size: sheetSize)

            var cellRects: [CGRect] = []

            for posInSheet in 0..<perSheet {
                let pageIndex = sheetIdx * perSheet + posInSheet
                guard pageIndex < pageCount, let page = pdfDoc.page(at: pageIndex) else { break }

                let row  = posInSheet / settings.columns
                let col  = posInSheet % settings.columns
                let rect = cellRect(col: col, row: row, cols: settings.columns, rows: settings.rows,
                                    in: sheetSize, margins: settings.margins,
                                    gutterH: settings.gutterH, gutterV: settings.gutterV,
                                    cellSizeOverride: frameOv)
                cellRects.append(rect)
                drawPage(page, into: rect, scale: settings.scale, autoRotate: settings.autoRotate,
                         fitToPage: settings.fitToPage, pdfBox: settings.pdfBox.pdfKitBox,
                         cropInset: cropInset, in: ctx)
            }

            let markRects = insetRects(cellRects, by: cropInset)
            if settings.addCropMarks  { drawCropMarks(for: markRects, settings: settings, sheetSize: sheetSize, in: ctx) }
            if settings.addFrameBorder { drawFrameBorders(for: markRects, in: ctx) }
            ctx.endPDFPage()
        }

        ctx.closePDF()
        try (pdfData as Data).write(to: outputURL)
        return ImpositionResult(outputURL: outputURL, sheetCount: sheetCount, pagesPerSheet: perSheet)
    }

    // MARK: - Step-Repeat

    private func performStepRepeat(pdfDoc: PDFDocument, settings: ImpositionSettings,
                                   sheetSize: CGSize, outputURL: URL) throws -> ImpositionResult {
        guard let firstPage = pdfDoc.page(at: 0) else { throw ImpositionError.noPages }

        let perSheet  = max(1, settings.columns * settings.rows)
        let frameOv   = frameOverride(settings)
        let cropInset = negativeMezeraCropInset(settings)
        let (ctx, pdfData) = makeContext(sheetSize: sheetSize)

        ctx.beginPDFPage(nil)
        fillWhite(ctx: ctx, size: sheetSize)

        var cellRects: [CGRect] = []
        for row in 0..<settings.rows {
            for col in 0..<settings.columns {
                let rect = cellRect(col: col, row: row, cols: settings.columns, rows: settings.rows,
                                    in: sheetSize, margins: settings.margins,
                                    gutterH: settings.gutterH, gutterV: settings.gutterV,
                                    cellSizeOverride: frameOv)
                cellRects.append(rect)
                drawPage(firstPage, into: rect, scale: settings.scale, autoRotate: settings.autoRotate,
                         fitToPage: settings.fitToPage, pdfBox: settings.pdfBox.pdfKitBox,
                         cropInset: cropInset, in: ctx)
            }
        }

        let markRects = insetRects(cellRects, by: cropInset)
        if settings.addCropMarks  { drawCropMarks(for: markRects, settings: settings, sheetSize: sheetSize, in: ctx) }
        if settings.addFrameBorder { drawFrameBorders(for: markRects, in: ctx) }
        ctx.endPDFPage()
        ctx.closePDF()
        try (pdfData as Data).write(to: outputURL)
        return ImpositionResult(outputURL: outputURL, sheetCount: 1, pagesPerSheet: perSheet)
    }

    // MARK: - Cut Stacks

    private func performCutStacks(pdfDoc: PDFDocument, settings: ImpositionSettings,
                                  sheetSize: CGSize, outputURL: URL) throws -> ImpositionResult {
        let pageCount = pdfDoc.pageCount
        let perSheet  = max(1, settings.columns * settings.rows)
        let frameOv   = frameOverride(settings)
        let cropInset = negativeMezeraCropInset(settings)
        let (ctx, pdfData) = makeContext(sheetSize: sheetSize)

        for pageIndex in 0..<pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }

            ctx.beginPDFPage(nil)
            fillWhite(ctx: ctx, size: sheetSize)

            var cellRects: [CGRect] = []
            for row in 0..<settings.rows {
                for col in 0..<settings.columns {
                    let rect = cellRect(col: col, row: row, cols: settings.columns, rows: settings.rows,
                                        in: sheetSize, margins: settings.margins,
                                        gutterH: settings.gutterH, gutterV: settings.gutterV,
                                        cellSizeOverride: frameOv)
                    cellRects.append(rect)
                    drawPage(page, into: rect, scale: settings.scale, autoRotate: settings.autoRotate,
                             fitToPage: settings.fitToPage, pdfBox: settings.pdfBox.pdfKitBox,
                             cropInset: cropInset, in: ctx)
                }
            }

            let markRects = insetRects(cellRects, by: cropInset)
            if settings.addCropMarks  { drawCropMarks(for: markRects, settings: settings, sheetSize: sheetSize, in: ctx) }
            if settings.addFrameBorder { drawFrameBorders(for: markRects, in: ctx) }
            ctx.endPDFPage()
        }

        ctx.closePDF()
        try (pdfData as Data).write(to: outputURL)
        return ImpositionResult(outputURL: outputURL, sheetCount: pageCount, pagesPerSheet: perSheet)
    }

    // MARK: - Booklet (saddle-stitch)

    private func performBooklet(pdfDoc: PDFDocument, settings: ImpositionSettings,
                                outputURL: URL) throws -> ImpositionResult {
        let srcCount   = pdfDoc.pageCount
        // Pad to multiple of 4
        let pageCount  = srcCount + ((4 - srcCount % 4) % 4)
        let base       = settings.paperSize.size
        let sheetSize  = CGSize(width: base.height, height: base.width) // always landscape

        // Total output pages = pageCount / 2 (each output page = one physical side)
        let totalOutputPages = pageCount / 2
        let (ctx, pdfData)   = makeContext(sheetSize: sheetSize)

        for outIdx in 0..<totalOutputPages {
            let leftIdx: Int
            let rightIdx: Int
            if outIdx % 2 == 0 {
                // Front side of a sheet
                leftIdx  = pageCount - 1 - outIdx
                rightIdx = outIdx
            } else {
                // Back side of a sheet
                leftIdx  = outIdx
                rightIdx = pageCount - 1 - outIdx
            }

            ctx.beginPDFPage(nil)
            fillWhite(ctx: ctx, size: sheetSize)

            var cellRects: [CGRect] = []
            let cropInset = negativeMezeraCropInset(settings)

            let leftRect = cellRect(col: 0, row: 0, cols: 2, rows: 1,
                                    in: sheetSize, margins: settings.margins,
                                    gutterH: settings.gutterH, gutterV: settings.gutterV)
            cellRects.append(leftRect)
            if leftIdx < srcCount, let page = pdfDoc.page(at: leftIdx) {
                drawPage(page, into: leftRect, scale: settings.scale, autoRotate: settings.autoRotate,
                         fitToPage: settings.fitToPage, pdfBox: settings.pdfBox.pdfKitBox,
                         cropInset: cropInset, in: ctx)
            }

            let rightRect = cellRect(col: 1, row: 0, cols: 2, rows: 1,
                                     in: sheetSize, margins: settings.margins,
                                     gutterH: settings.gutterH, gutterV: settings.gutterV)
            cellRects.append(rightRect)
            if rightIdx < srcCount, let page = pdfDoc.page(at: rightIdx) {
                drawPage(page, into: rightRect, scale: settings.scale, autoRotate: settings.autoRotate,
                         fitToPage: settings.fitToPage, pdfBox: settings.pdfBox.pdfKitBox,
                         cropInset: cropInset, in: ctx)
            }

            let markRects = insetRects(cellRects, by: cropInset)
            if settings.addCropMarks  { drawCropMarks(for: markRects, settings: settings, sheetSize: sheetSize, in: ctx) }
            if settings.addFrameBorder { drawFrameBorders(for: markRects, in: ctx) }
            ctx.endPDFPage()
        }

        ctx.closePDF()
        try (pdfData as Data).write(to: outputURL)
        return ImpositionResult(outputURL: outputURL, sheetCount: totalOutputPages / 2, pagesPerSheet: 2)
    }

    // MARK: - Helpers

    private func frameOverride(_ settings: ImpositionSettings) -> CGSize? {
        if settings.useManualFrameSize {
            return CGSize(width:  CGFloat(settings.manualFrameWidth)  * mmToPt,
                          height: CGFloat(settings.manualFrameHeight) * mmToPt)
        }
        // 1:1 režim: rámeček = trim size (přirozená velikost − 2×ořez)
        // PDF přeteče za okraj buňky jako bleed a bude oříznut při kreslení.
        if !settings.fitToPage, let pageSize = settings.sourcePageSizePt {
            let crop = CGFloat(settings.cropInsetMM) * mmToPt * 2
            return CGSize(width:  max(1, pageSize.width  - crop),
                          height: max(1, pageSize.height - crop))
        }
        return nil
    }

    private func fillWhite(ctx: CGContext, size: CGSize) {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    private func outputURL(for sourceURL: URL) -> URL {
        let dir      = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(baseName)\(OutputSuffix.imposed).pdf")
    }
}
