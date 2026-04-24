//
//  TilePDFService.swift
//  PrintManager
//
//  Skládání PDF stránek vedle sebe nebo pod sebe (tiling).
//
//  Single mode:  jeden PDF → každá stránka se zobrazí N×krát vedle/pod sebe
//  Multiple mode: N PDF → stránky se skládají (doc1_pg1 | doc2_pg1 | ...)
//
//  Poznámka k rotaci:
//    page.bounds(for: .mediaBox) vrátí FYZICKÉ rozměry stránky.
//    PDF s /Rotate 90 nebo 270 má vizuální šířku/výšku prohozenu.
//    Funkce visualSize(for:) provede swap — geometrie výstupu pak odpovídá
//    tomu, co uživatel vidí. PDFKit při page.draw() rotaci aplikuje
//    automaticky, takže translation zůstává nezměněno.
//

import Foundation
import CoreGraphics
import PDFKit
import AppKit

// MARK: - Direction

enum TileDirection: String, CaseIterable {
    case horizontal = "Vedle sebe"
    case vertical   = "Pod sebe"

    var icon: String {
        switch self {
        case .horizontal: return "rectangle.split.2x1"
        case .vertical:   return "rectangle.split.1x2"
        }
    }
}

// MARK: - Options

struct TilePDFOptions {
    var count: Int = 2
    var direction: TileDirection = .horizontal
    var spacingMm: Double = 0
    var showLine: Bool = false
    var lineWidthPt: Double = 0.5
}

// MARK: - Service

final class TilePDFService {

    static let shared = TilePDFService()
    private init() {}

    private let mmToPt: CGFloat = RenderingConstants.pointsPerMillimeter

    // MARK: - Public API

    func tileSingle(url: URL, options: TilePDFOptions) throws -> URL {
        switch options.direction {
        case .horizontal: return try tileSingleH(url: url, options: options)
        case .vertical:   return try tileSingleV(url: url, options: options)
        }
    }

    func tileMultiple(urls: [URL], options: TilePDFOptions) throws -> URL {
        switch options.direction {
        case .horizontal: return try tileMultipleH(urls: urls, options: options)
        case .vertical:   return try tileMultipleV(urls: urls, options: options)
        }
    }

    // MARK: - Single — Horizontal

    private func tileSingleH(url: URL, options: TilePDFOptions) throws -> URL {
        let (doc, sp, count) = try loadSingle(url: url, options: options)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw TilePDFError.cannotCreateContext
        }
        let firstVS = visualSize(for: doc.page(at: 0)!)
        var initBox = CGRect(x: 0, y: 0,
                             width:  firstVS.width * CGFloat(count) + sp * CGFloat(count - 1),
                             height: firstVS.height)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initBox, nil) else {
            throw TilePDFError.cannotCreateContext
        }

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx) else { continue }
            let b  = page.bounds(for: .mediaBox)
            let vs = visualSize(for: page)
            var mediaBox = CGRect(x: 0, y: 0,
                                  width:  vs.width * CGFloat(count) + sp * CGFloat(count - 1),
                                  height: vs.height)
            ctx.beginPDFPage(pdfPageInfo(&mediaBox))

            for i in 0..<count {
                let xOff = CGFloat(i) * (vs.width + sp)   // ← vizuální šířka
                ctx.saveGState()
                ctx.translateBy(x: xOff - b.minX, y: -b.minY)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }
            drawHSeparators(ctx: ctx, count: count,
                            slotW: vs.width, pageH: vs.height,
                            spacingPt: sp, options: options)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let out = singleOutputURL(for: url, count: count)
        try (pdfData as Data).write(to: out)
        return out
    }

    // MARK: - Single — Vertical

    private func tileSingleV(url: URL, options: TilePDFOptions) throws -> URL {
        let (doc, sp, count) = try loadSingle(url: url, options: options)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw TilePDFError.cannotCreateContext
        }
        let firstVS = visualSize(for: doc.page(at: 0)!)
        var initBox = CGRect(x: 0, y: 0,
                             width:  firstVS.width,
                             height: firstVS.height * CGFloat(count) + sp * CGFloat(count - 1))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initBox, nil) else {
            throw TilePDFError.cannotCreateContext
        }

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx) else { continue }
            let b  = page.bounds(for: .mediaBox)
            let vs = visualSize(for: page)
            var mediaBox = CGRect(x: 0, y: 0,
                                  width:  vs.width,
                                  height: vs.height * CGFloat(count) + sp * CGFloat(count - 1))
            ctx.beginPDFPage(pdfPageInfo(&mediaBox))

            for i in 0..<count {
                // i=0 nahoře → nejvyšší y; vizuální výška určuje rozestupy
                let yOff = CGFloat(count - 1 - i) * (vs.height + sp)  // ← vizuální výška
                ctx.saveGState()
                ctx.translateBy(x: -b.minX, y: yOff - b.minY)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }
            drawVSeparators(ctx: ctx, count: count,
                            slotH: vs.height, pageW: vs.width,
                            spacingPt: sp, options: options)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let out = singleOutputURL(for: url, count: count)
        try (pdfData as Data).write(to: out)
        return out
    }

    // MARK: - Multiple — Horizontal

    private func tileMultipleH(urls: [URL], options: TilePDFOptions) throws -> URL {
        let (docs, sp, count) = try loadMultiple(urls: urls, options: options)
        // Referenční vizuální rozměr = první stránka každého dokumentu
        let refVS = docs.map { d -> CGSize in
            guard let p = d.page(at: 0) else { return .zero }
            return visualSize(for: p)
        }
        let maxPages = docs.map(\.pageCount).max() ?? 1

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw TilePDFError.cannotCreateContext
        }
        let initW = refVS.map(\.width).reduce(0, +) + CGFloat(count - 1) * sp
        let initH = refVS.map(\.height).max() ?? 0
        var initBox = CGRect(x: 0, y: 0, width: initW, height: initH)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initBox, nil) else {
            throw TilePDFError.cannotCreateContext
        }

        for pageIdx in 0..<maxPages {
            let pages: [PDFPage?] = docs.map { d in pageIdx < d.pageCount ? d.page(at: pageIdx) : nil }
            // Pro každý slot: vizuální šířka/výška
            let widths  = zip(pages, refVS).map { pg, ref in
                pg.map { visualSize(for: $0).width  } ?? ref.width
            }
            let heights = zip(pages, refVS).map { pg, ref in
                pg.map { visualSize(for: $0).height } ?? ref.height
            }
            let outW = widths.reduce(0, +) + CGFloat(count - 1) * sp
            let outH = heights.max() ?? initH

            var mediaBox = CGRect(x: 0, y: 0, width: outW, height: outH)
            ctx.beginPDFPage(pdfPageInfo(&mediaBox))

            var xCursor: CGFloat = 0
            for (i, page) in pages.enumerated() {
                if let p = page {
                    let b = p.bounds(for: .mediaBox)
                    ctx.saveGState()
                    ctx.translateBy(x: xCursor - b.minX, y: -b.minY)
                    p.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                }
                if i < count - 1 {
                    drawHSingleSep(ctx: ctx, x: xCursor + widths[i],
                                   height: outH, spacingPt: sp, options: options)
                }
                xCursor += widths[i] + sp
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let out = multipleOutputURL(referenceURL: urls[0], count: count)
        try (pdfData as Data).write(to: out)
        return out
    }

    // MARK: - Multiple — Vertical

    private func tileMultipleV(urls: [URL], options: TilePDFOptions) throws -> URL {
        let (docs, sp, count) = try loadMultiple(urls: urls, options: options)
        let refVS = docs.map { d -> CGSize in
            guard let p = d.page(at: 0) else { return .zero }
            return visualSize(for: p)
        }
        let maxPages = docs.map(\.pageCount).max() ?? 1

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw TilePDFError.cannotCreateContext
        }
        let initW = refVS.map(\.width).max() ?? 0
        let initH = refVS.map(\.height).reduce(0, +) + CGFloat(count - 1) * sp
        var initBox = CGRect(x: 0, y: 0, width: initW, height: initH)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initBox, nil) else {
            throw TilePDFError.cannotCreateContext
        }

        for pageIdx in 0..<maxPages {
            let pages: [PDFPage?] = docs.map { d in pageIdx < d.pageCount ? d.page(at: pageIdx) : nil }
            let widths  = zip(pages, refVS).map { pg, ref in
                pg.map { visualSize(for: $0).width  } ?? ref.width
            }
            let heights = zip(pages, refVS).map { pg, ref in
                pg.map { visualSize(for: $0).height } ?? ref.height
            }
            let outW = widths.max() ?? initW
            let outH = heights.reduce(0, +) + CGFloat(count - 1) * sp

            var mediaBox = CGRect(x: 0, y: 0, width: outW, height: outH)
            ctx.beginPDFPage(pdfPageInfo(&mediaBox))

            var yCursor: CGFloat = outH     // začínáme nahoře, jdeme dolů
            for (i, page) in pages.enumerated() {
                let slotH = heights[i]
                yCursor -= slotH
                if let p = page {
                    let b = p.bounds(for: .mediaBox)
                    ctx.saveGState()
                    ctx.translateBy(x: -b.minX, y: yCursor - b.minY)
                    p.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                }
                if i < count - 1 {
                    drawVSingleSep(ctx: ctx, y: yCursor - sp,
                                   width: outW, spacingPt: sp, options: options)
                    yCursor -= sp
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let out = multipleOutputURL(referenceURL: urls[0], count: count)
        try (pdfData as Data).write(to: out)
        return out
    }

    // MARK: - Rotation helper

    /// Vizuální šířka a výška stránky — u /Rotate 90 nebo 270 jsou fyzické
    /// rozměry prohozeny oproti tomu, co uživatel vidí.
    private func visualSize(for page: PDFPage) -> CGSize {
        let b   = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: b.height, height: b.width)
        }
        return CGSize(width: b.width, height: b.height)
    }

    // MARK: - Separators

    private func drawHSeparators(ctx: CGContext, count: Int,
                                  slotW: CGFloat, pageH: CGFloat,
                                  spacingPt: CGFloat, options: TilePDFOptions) {
        for i in 0..<(count - 1) {
            let x = CGFloat(i + 1) * slotW + CGFloat(i) * spacingPt
            drawHSingleSep(ctx: ctx, x: x, height: pageH, spacingPt: spacingPt, options: options)
        }
    }

    private func drawHSingleSep(ctx: CGContext, x: CGFloat, height: CGFloat,
                                  spacingPt: CGFloat, options: TilePDFOptions) {
        guard options.showLine else { return }
        let lineX = spacingPt > 0 ? x + spacingPt / 2 : x
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(CGFloat(options.lineWidthPt))
        ctx.move(to: CGPoint(x: lineX, y: 0))
        ctx.addLine(to: CGPoint(x: lineX, y: height))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawVSeparators(ctx: CGContext, count: Int,
                                  slotH: CGFloat, pageW: CGFloat,
                                  spacingPt: CGFloat, options: TilePDFOptions) {
        for i in 0..<(count - 1) {
            let y = CGFloat(i) * (slotH + spacingPt)
            drawVSingleSep(ctx: ctx, y: y, width: pageW, spacingPt: spacingPt, options: options)
        }
    }

    private func drawVSingleSep(ctx: CGContext, y: CGFloat, width: CGFloat,
                                  spacingPt: CGFloat, options: TilePDFOptions) {
        guard options.showLine else { return }
        let lineY = spacingPt > 0 ? y + spacingPt / 2 : y
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(CGFloat(options.lineWidthPt))
        ctx.move(to: CGPoint(x: 0, y: lineY))
        ctx.addLine(to: CGPoint(x: width, y: lineY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - PDF helpers

    private func pdfPageInfo(_ rect: inout CGRect) -> CFDictionary {
        let data = Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
        return [kCGPDFContextMediaBox: data] as CFDictionary
    }

    // MARK: - Load helpers

    private func loadSingle(url: URL, options: TilePDFOptions) throws -> (PDFDocument, CGFloat, Int) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw TilePDFError.cannotLoadPDF(url.lastPathComponent)
        }
        return (doc, CGFloat(options.spacingMm) * mmToPt, max(2, options.count))
    }

    private func loadMultiple(urls: [URL], options: TilePDFOptions) throws -> ([PDFDocument], CGFloat, Int) {
        guard !urls.isEmpty else { throw TilePDFError.noPDFsProvided }
        let docs: [PDFDocument] = try urls.map { url in
            guard let d = PDFDocument(url: url) else { throw TilePDFError.cannotLoadPDF(url.lastPathComponent) }
            return d
        }
        return (docs, CGFloat(options.spacingMm) * mmToPt, docs.count)
    }

    // MARK: - Output URLs

    private func singleOutputURL(for url: URL, count: Int) -> URL {
        let dir  = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base)_tile\(count)x.pdf")
    }

    private func multipleOutputURL(referenceURL: URL, count: Int) -> URL {
        referenceURL.deletingLastPathComponent()
                    .appendingPathComponent("tiled_\(count)x.pdf")
    }
}

// MARK: - Errors

enum TilePDFError: LocalizedError {
    case cannotLoadPDF(String)
    case cannotCreateContext
    case noPDFsProvided

    var errorDescription: String? {
        switch self {
        case .cannotLoadPDF(let n): return "Nelze načíst PDF: \(n)"
        case .cannotCreateContext:  return "Nelze vytvořit PDF kontext."
        case .noPDFsProvided:       return "Nebyly vybrány žádné PDF soubory."
        }
    }
}
