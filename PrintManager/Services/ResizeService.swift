//
//  ResizeService.swift
//  PrintManager
//
//  Změna velikosti obrázků (Core Image, Lanczos) a PDF stránek (Core Graphics).
//

import Foundation
import AppKit
import CoreImage
import PDFKit
import ImageIO

// MARK: - Enums

enum ResizeUnit: String, CaseIterable, Identifiable {
    case pixels      = "px"
    case millimeters = "mm"
    case centimeters = "cm"
    case inches      = "in"
    case percent     = "%"
    var id: String { rawValue }
}

enum ResizeInterpolation: String, CaseIterable, Identifiable {
    case none    = "Žádná"
    case linear  = "Lineární"
    case lanczos = "Lanczos"
    var id: String { rawValue }
}

// MARK: - Preset

struct ResizePreset: Identifiable {
    let id     = UUID()
    let name:    String
    let widthMM: Double   // 0 = px preset
    let heightMM: Double
    let widthPx: Int      // 0 = mm preset
    let heightPx: Int

    var isPxPreset: Bool { widthPx > 0 }

    static func mm(_ name: String, _ w: Double, _ h: Double) -> ResizePreset {
        ResizePreset(name: name, widthMM: w, heightMM: h, widthPx: 0, heightPx: 0)
    }
    static func px(_ name: String, _ w: Int, _ h: Int) -> ResizePreset {
        ResizePreset(name: name, widthMM: 0, heightMM: 0, widthPx: w, heightPx: h)
    }
    static func mmL(_ name: String, _ w: Double, _ h: Double) -> ResizePreset {
        ResizePreset(name: name + " L", widthMM: h, heightMM: w, widthPx: 0, heightPx: 0)
    }

    static let paperPresets: [ResizePreset] = [
        .mm("A3",     297, 420), .mmL("A3",     297, 420),
        .mm("A4",     210, 297), .mmL("A4",     210, 297),
        .mm("A5",     148, 210), .mmL("A5",     148, 210),
        .mm("Letter", 215.9, 279.4),
    ]
    static let screenPresets: [ResizePreset] = [
        .px("4K",   3840, 2160),
        .px("2K",   2560, 1440),
        .px("FHD",  1920, 1080),
        .px("HD",   1280, 720),
        .px("XGA",  1024, 768),
        .px("SVGA", 800,  600),
        .px("512",  512,  512),
    ]
}

// MARK: - File Info

struct ResizeFileInfo {
    let url:       URL
    let name:      String
    let isPDF:     Bool
    let widthPx:   Int
    let heightPx:  Int
    let dpi:       Double   // detected or 72
    let widthPt:   CGFloat
    let heightPt:  CGFloat

    var widthMM:  Double { isPDF ? Double(widthPt)  * 25.4 / 72 : Double(widthPx)  * 25.4 / dpi }
    var heightMM: Double { isPDF ? Double(heightPt) * 25.4 / 72 : Double(heightPx) * 25.4 / dpi }

    /// Poměr stran h/w (v přirozených jednotkách)
    var aspectRatio: Double {
        let w = isPDF ? Double(widthPt)  : Double(widthPx)
        let h = isPDF ? Double(heightPt) : Double(heightPx)
        return w > 0 ? h / w : 1.0
    }

    var sizeLabel: String {
        if isPDF {
            return String(format: "%.0f × %.0f mm  (%.0f × %.0f pt)", widthMM, heightMM, widthPt, heightPt)
        } else {
            return String(format: "%d × %d px  (%.0f × %.0f mm @ %.0f DPI)",
                          widthPx, heightPx, widthMM, heightMM, dpi)
        }
    }
}

// MARK: - Service

final class ResizeService {
    static let shared = ResizeService()
    private init() {}

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - File info

    func fileInfo(for url: URL) -> ResizeFileInfo? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return pdfInfo(url: url)
        } else {
            return imageInfo(url: url)
        }
    }

    private func imageInfo(url: URL) -> ResizeFileInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth]  as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { return nil }
        let dpiX = (props[kCGImagePropertyDPIWidth] as? Double)
                ?? (props[kCGImagePropertyDPIHeight] as? Double)
                ?? 72.0
        return ResizeFileInfo(url: url, name: url.lastPathComponent, isPDF: false,
                              widthPx: w, heightPx: h, dpi: max(1, dpiX),
                              widthPt: 0, heightPt: 0)
    }

    private func pdfInfo(url: URL) -> ResizeFileInfo? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        return ResizeFileInfo(url: url, name: url.lastPathComponent, isPDF: true,
                              widthPx: 0, heightPx: 0, dpi: 72,
                              widthPt: box.width, heightPt: box.height)
    }

    // MARK: - Resize image

    func resizeImage(url: URL, toPixelWidth tw: Int, height th: Int,
                     interpolation: ResizeInterpolation,
                     overwrite: Bool) throws -> URL {
        guard let ci = CIImage(contentsOf: url) else {
            throw Err.load(url.lastPathComponent)
        }
        let src    = ci.extent
        let scaleX = CGFloat(tw) / src.width
        let scaleY = CGFloat(th) / src.height

        let resized: CIImage
        switch interpolation {
        case .lanczos:
            if let f = CIFilter(name: "CILanczosScaleTransform") {
                f.setValue(ci,               forKey: kCIInputImageKey)
                f.setValue(Float(scaleY),    forKey: kCIInputScaleKey)
                f.setValue(Float(scaleX / scaleY), forKey: kCIInputAspectRatioKey)
                resized = f.outputImage ?? ci.transformed(by: .init(scaleX: scaleX, y: scaleY))
            } else {
                resized = ci.transformed(by: .init(scaleX: scaleX, y: scaleY))
            }
        case .linear, .none:
            resized = ci.transformed(by: .init(scaleX: scaleX, y: scaleY))
        }

        let outURL = overwrite ? url : outputURL(for: url, suffix: OutputSuffix.resized)
        let ext    = url.pathExtension.lowercased()
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { throw Err.render }

        if ext == "png" {
            guard let data = ciContext.pngRepresentation(of: resized, format: .RGBA8, colorSpace: cs) else {
                throw Err.render
            }
            try data.write(to: outURL)
        } else {
            let opts: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92
            ]
            guard let data = ciContext.jpegRepresentation(of: resized, colorSpace: cs, options: opts) else {
                throw Err.render
            }
            try data.write(to: outURL)
        }
        return outURL
    }

    // MARK: - Resize PDF

    /// Přeformátuje každou stránku PDF na nové rozměry (v bodech).
    /// `stretch = false` → scale-to-fit se zarovnáním na střed.
    func resizePDF(url: URL, toPointWidth w: CGFloat, height h: CGFloat,
                   stretch: Bool = false,
                   overwrite: Bool = false) throws -> URL {
        guard let doc = PDFDocument(url: url) else {
            throw Err.load(url.lastPathComponent)
        }
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData) else { throw Err.render }
        var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                  nil as CFDictionary?) else { throw Err.render }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let ref = page.pageRef else { continue }
            let src = page.bounds(for: .mediaBox)
            ctx.beginPDFPage(nil as CFDictionary?)
            if stretch {
                ctx.scaleBy(x: w / src.width, y: h / src.height)
            } else {
                let scale  = min(w / src.width, h / src.height)
                let ox     = (w - src.width  * scale) / 2
                let oy     = (h - src.height * scale) / 2
                ctx.translateBy(x: ox, y: oy)
                ctx.scaleBy(x: scale, y: scale)
            }
            ctx.drawPDFPage(ref)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let outURL = overwrite ? url : outputURL(for: url, suffix: OutputSuffix.resized)
        try (mutableData as Data).write(to: outURL)
        return outURL
    }

    // MARK: - Helpers

    private func outputURL(for url: URL, suffix: String) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)\(suffix).\(ext)")
    }

    enum Err: LocalizedError {
        case load(String), render
        var errorDescription: String? {
            switch self {
            case .load(let n): return "Nelze načíst: \(n)"
            case .render:      return "Renderování selhalo."
            }
        }
    }
}

// MARK: - Unit conversion helpers (global, sdíleno s VM)

func rsToMM(_ v: Double, unit: ResizeUnit, base: Double, dpi: Double) -> Double {
    switch unit {
    case .pixels:      return v / dpi * 25.4
    case .millimeters: return v
    case .centimeters: return v * 10
    case .inches:      return v * 25.4
    case .percent:     return base * v / 100.0
    }
}

func rsFromMM(_ mm: Double, to unit: ResizeUnit, base: Double, dpi: Double) -> String {
    switch unit {
    case .pixels:      return String(format: "%.0f", (mm / 25.4 * dpi).rounded())
    case .millimeters: return String(format: "%.2f", mm)
    case .centimeters: return String(format: "%.3f", mm / 10)
    case .inches:      return String(format: "%.4f", mm / 25.4)
    case .percent:     return String(format: "%.1f", base > 0 ? mm / base * 100 : 100)
    }
}
