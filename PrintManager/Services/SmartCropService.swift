//
//  SmartCropService.swift
//  PrintManager
//
//  Detekuje bílé okraje ze všech 4 stran a ořeže je.
//  Funguje pro PDF (stránky se rastrují před detekcí) i obrázky.
//  Výstup: originální_název_sc.ext
//

import Foundation
import AppKit
import PDFKit

class SmartCropService {

    /// Pixel světlejší nebo rovný tomuto prahu se považuje za bílý okraj (0–255).
    /// 245 pokryje běžné "bílé" pozadí včetně #f8f8f8 (248) či #f5f5f5 (245).
    private let whiteThreshold: UInt8 = 245
    /// Krok vzorkování — každý druhý pixel pro rychlost.
    private let step = 2

    // MARK: - Public API

    func smartCropFiles(urls: [URL]) async throws -> [URL] {
        var result: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                result.append(try await smartCropPDF(url: url))
            } else if ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif"].contains(ext) {
                result.append(try await smartCropImage(url: url))
            } else {
                throw SmartCropError.unsupportedFormat
            }
        }
        return result
    }

    // MARK: - PDF

    private func smartCropPDF(url: URL) async throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw SmartCropError.invalidPDF }
        let outputURL = outputPath(for: url)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            guard mediaBox.width > 0, mediaBox.height > 0 else { continue }

            // thumbnail() spolehlivě rastruje všechny typy PDF obsahu.
            // Renderujeme ve 2× rozlišení pro přesnější detekci okrajů.
            let nsImage = page.thumbnail(
                of: CGSize(width: mediaBox.width * 2, height: mediaBox.height * 2),
                for: .mediaBox
            )
            guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            // Použijeme skutečné pixelové rozměry — na Retina může být @2×, ale
            // výpočet scale faktorů přes cgImage.width/height to automaticky koriguje.
            let imgW = CGFloat(cgImage.width)
            let imgH = CGFloat(cgImage.height)
            let scaleX = mediaBox.width  / imgW
            let scaleY = mediaBox.height / imgH

            guard let m = detectMargins(in: cgImage) else { continue }

            // CGImage z thumbnail(): y=0 nahoře = vizuální vršek stránky
            // PDF souřadnice:       y=0 dole   = vizuální spodek stránky
            //
            // m.top    = bílé řádky od vrchu CGImage = bílý okraj nahoře stránky
            // m.bottom = bílé řádky od spodu CGImage = bílý okraj dole stránky
            //
            // CropBox spodní hrana (PDF y): origin.y + m.bottom * scaleY
            // CropBox levá hrana:           origin.x + m.left   * scaleX
            let cropBox = CGRect(
                x:      mediaBox.origin.x + CGFloat(m.left)          * scaleX,
                y:      mediaBox.origin.y + CGFloat(m.bottom)         * scaleY,
                width:  CGFloat(m.contentW) * scaleX,
                height: CGFloat(m.contentH) * scaleY
            )
            guard cropBox.width > 0, cropBox.height > 0 else { continue }
            // Nastavíme MediaBox — změní se skutečné rozměry stránky.
            // CropBox resetujeme na nový MediaBox (relativní souřadnice od nového originu).
            page.setBounds(cropBox, for: .mediaBox)
            page.setBounds(CGRect(origin: .zero, size: cropBox.size), for: .cropBox)
        }

        doc.write(to: outputURL)
        return outputURL
    }

    // MARK: - Obrázek

    private func smartCropImage(url: URL) async throws -> URL {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw SmartCropError.invalidImage }

        guard let m = detectMargins(in: cgImage) else {
            throw SmartCropError.cropDetectionFailed
        }

        // CGImage cropping: x=left, y=top (y=0 nahoře)
        let cropRect = CGRect(x: m.left, y: m.top, width: m.contentW, height: m.contentH)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            throw SmartCropError.cropFailed
        }

        let output = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        let outputURL = outputPath(for: url)
        try saveImage(output, to: outputURL, ext: url.pathExtension)
        return outputURL
    }

    // MARK: - Detekce bílých okrajů

    private struct Margins {
        let top: Int    // bílé řádky od vrchu (y=0)
        let bottom: Int // bílé řádky od spodu
        let left: Int
        let right: Int
        let w: Int
        let h: Int
        var contentW: Int { w - left - right }
        var contentH: Int { h - top  - bottom }
    }

    /// Detekuje bílé okraje v CGImage (y=0 nahoře).
    /// Vrátí počet bílých řádků/sloupců od každé strany.
    private func detectMargins(in cgImage: CGImage) -> Margins? {
        guard let gray = toGrayscale(cgImage) else { return nil }
        let w = gray.width, h = gray.height
        guard w > 0, h > 0,
              let dp  = gray.dataProvider?.data,
              let ptr = CFDataGetBytePtr(dp) else { return nil }
        let len = CFDataGetLength(dp)
        let t   = whiteThreshold

        func px(_ x: Int, _ y: Int) -> UInt8 {
            let i = y * w + x
            return (i >= 0 && i < len) ? ptr[i] : 255
        }

        // ── Horní okraj: první řádek (od y=0) s nebílým pixelem ──
        var top = 0
        topScan: while top < h {
            for x in stride(from: 0, to: w, by: step) {
                if px(x, top) < t { break topScan }
            }
            top += step
        }
        if top >= h { return nil }  // celý obrázek je bílý

        // ── Dolní okraj: první řádek od spodu s nebílým pixelem ──
        var botRow = h - 1
        botScan: while botRow > top {
            for x in stride(from: 0, to: w, by: step) {
                if px(x, botRow) < t { break botScan }
            }
            botRow -= step
        }
        let bottom = h - 1 - botRow

        // ── Levý okraj ──
        var lft = 0
        lftScan: while lft < w {
            for y in stride(from: top, through: botRow, by: step) {
                if px(lft, y) < t { break lftScan }
            }
            lft += step
        }

        // ── Pravý okraj ──
        var rgtRow = w - 1
        rgtScan: while rgtRow > lft {
            for y in stride(from: top, through: botRow, by: step) {
                if px(rgtRow, y) < t { break rgtScan }
            }
            rgtRow -= step
        }
        let right = w - 1 - rgtRow

        let cw = w - lft - right
        let ch = h - top  - bottom
        guard cw > 0, ch > 0 else { return nil }
        return Margins(top: top, bottom: bottom, left: lft, right: right, w: w, h: h)
    }

    // MARK: - Helpers

    private func toGrayscale(_ src: CGImage) -> CGImage? {
        let w = src.width, h = src.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func outputPath(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_sc")
            .appendingPathExtension(url.pathExtension)
    }

    private func saveImage(_ image: NSImage, to url: URL, ext: String) throws {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { throw SmartCropError.saveFailed }
        let type: NSBitmapImageRep.FileType
        switch ext.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "tiff", "tif": type = .tiff
        case "bmp":         type = .bmp
        default:            type = .png
        }
        guard let data = rep.representation(using: type, properties: [:]) else {
            throw SmartCropError.saveFailed
        }
        try data.write(to: url)
    }
}

// MARK: - Errors

enum SmartCropError: LocalizedError {
    case invalidPDF, invalidImage, unsupportedFormat, cropDetectionFailed, cropFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidPDF:           return "Invalid PDF file"
        case .invalidImage:         return "Invalid image file"
        case .unsupportedFormat:    return "Unsupported file format for smart crop"
        case .cropDetectionFailed:  return "Failed to detect crop boundaries"
        case .cropFailed:           return "Failed to crop image"
        case .saveFailed:           return "Failed to save cropped file"
        }
    }
}
