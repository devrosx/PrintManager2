//
//  WatermarkService.swift
//  PrintManager
//
//  Přidání textového vodoznaku na všechny stránky PDF pomocí Core Graphics.
//

import Foundation
import PDFKit
import AppKit

// MARK: - WatermarkSettings

struct WatermarkSettings {
    var text: String = "DRAFT"
    var fontSize: CGFloat = 72
    var color: NSColor = NSColor.red.withAlphaComponent(0.25)
    var angle: Double = -45          // stupně
    var mode: WatermarkMode = .center
    var fontName: String = "Helvetica-Bold"
}

enum WatermarkMode: String, CaseIterable {
    case center = "Střed"
    case tiled  = "Dlaždicové"
}

// MARK: - WatermarkService

class WatermarkService {
    static let shared = WatermarkService()
    private init() {}

    /// Přidá vodoznak na všechny stránky PDF a uloží jako nový soubor vedle originálu.
    func addWatermark(to url: URL, settings: WatermarkSettings) throws -> URL {
        guard let doc = PDFDocument(url: url) else {
            throw WatermarkError.invalidPDF
        }

        let outputURL = url.deletingPathExtension()
            .appendingPathExtension("_watermark")
            .appendingPathExtension("pdf")

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            let stamp = WatermarkAnnotation(bounds: pageBounds, settings: settings)
            page.addAnnotation(stamp)
        }

        // PDFDocument.write nemusí správně embedovat custom anotace,
        // proto renderujeme každou stránku do nového PDF přes CGContext.
        guard let data = renderToPDF(doc: doc) else {
            throw WatermarkError.renderFailed
        }

        try data.write(to: outputURL)
        return outputURL
    }

    // MARK: - Private: render

    private func renderToPDF(doc: PDFDocument) -> Data? {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { return nil }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // fallback
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)

            let pageInfo: [String: Any] = [
                kCGPDFContextMediaBox as String: box
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)

            // Vykreslit originální stránku
            ctx.saveGState()
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            // Vykreslit vodoznak
            let settings = extractSettings(from: page)
            if let s = settings {
                drawWatermark(in: ctx, bounds: box, settings: s)
            }

            ctx.endPDFPage()
        }

        ctx.closePDF()
        return mutableData as Data
    }

    private func extractSettings(from page: PDFPage) -> WatermarkSettings? {
        // Vrátí settings z WatermarkAnnotation pokud existuje
        for ann in page.annotations {
            if let wa = ann as? WatermarkAnnotation {
                return wa.settings
            }
        }
        return nil
    }

    private func drawWatermark(in ctx: CGContext, bounds: CGRect, settings: WatermarkSettings) {
        let font = CTFontCreateWithName(settings.fontName as CFString, settings.fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: settings.color
        ]
        let attrString = NSAttributedString(string: settings.text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let lineHeight = settings.fontSize * 1.2

        ctx.saveGState()

        switch settings.mode {
        case .center:
            ctx.translateBy(x: bounds.midX, y: bounds.midY)
            ctx.rotate(by: CGFloat(settings.angle) * .pi / 180)
            ctx.textPosition = CGPoint(x: -lineWidth / 2, y: -lineHeight / 2)
            CTLineDraw(line, ctx)

        case .tiled:
            let spacing: CGFloat = max(lineWidth, lineHeight) * 1.5
            let cols = Int(ceil(bounds.width  / spacing)) + 2
            let rows = Int(ceil(bounds.height / spacing)) + 2
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = bounds.minX + CGFloat(col) * spacing - spacing / 2
                    let y = bounds.minY + CGFloat(row) * spacing - spacing / 2
                    ctx.saveGState()
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: CGFloat(settings.angle) * .pi / 180)
                    ctx.textPosition = CGPoint(x: -lineWidth / 2, y: -lineHeight / 2)
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
            }
        }

        ctx.restoreGState()
    }
}

// MARK: - WatermarkAnnotation (nosič settings pro render)

private class WatermarkAnnotation: PDFAnnotation {
    let settings: WatermarkSettings

    init(bounds: CGRect, settings: WatermarkSettings) {
        self.settings = settings
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.shouldDisplay = false  // nechceme vizuální anotaci v PDFView
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - WatermarkError

enum WatermarkError: LocalizedError {
    case invalidPDF
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidPDF:    return "Nelze otevřít PDF soubor."
        case .renderFailed:  return "Renderování PDF s vodoznakem selhalo."
        }
    }
}
