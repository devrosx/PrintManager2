//
//  DrawingsService.swift
//  PrintManager
//

import CoreImage
import Vision
import PDFKit
import AppKit

// MARK: - Modely nastavení

struct DrawingsSettings: Equatable {
    var applyThreshold: Bool = true
    var thresholdMode: ThresholdMode = .auto
    var thresholdValue: Double = 0.5
    var brightnessBoost: Double = 0.1
    var contrastBoost: Double = 0.3

    var applyCrop: Bool = false
    var cropMode: CropMode = .autoDetect
    var cropTopMargin: Double = 0.02
    var cropBottomMargin: Double = 0.02
    var cropLeftMargin: Double = 0.02
    var cropRightMargin: Double = 0.02

    var applyDeskew: Bool = false
    var deskewWithCrop: Bool = true

    var applyRotation: Bool = false
    var rotationSteps: Int = 1

    var applyAlignment: Bool = false
    var alignmentFormat: PaperFormat = .a4
    var alignmentMode: AlignmentMode = .fit

    var applyColorConversion: Bool = false
    var colorMode: ColorMode = .grayscale

    var applyNoiseReduction: Bool = false
    var noiseLevel: Double = 0.02
    var noiseSharpness: Double = 0.40

    // OCR region (top-left origin, 0-1 normalized)
    var applyOCR: Bool = false
    var ocrUseCustomRegion: Bool = false
    var ocrRegionLeft: Double = 0.75
    var ocrRegionTop: Double = 0.75
    var ocrRegionWidth: Double = 0.25
    var ocrRegionHeight: Double = 0.25
}

enum ThresholdMode: Equatable { case auto, manual }
enum PaperFormat: String, CaseIterable, Equatable {
    case a5 = "A5"; case a4 = "A4"; case a3 = "A3"
    case a2 = "A2"; case letter = "Letter"
    var sizeAt300DPI: CGSize {
        switch self {
        case .a5:     return CGSize(width: 1748,  height: 2480)
        case .a4:     return CGSize(width: 2480,  height: 3508)
        case .a3:     return CGSize(width: 3508,  height: 4961)
        case .a2:     return CGSize(width: 4961,  height: 7016)
        case .letter: return CGSize(width: 2550,  height: 3300)
        }
    }
}
enum AlignmentMode: String, CaseIterable, Equatable { case fit = "Fit", fill = "Fill" }
enum ColorMode: String, CaseIterable, Equatable {
    case bitmap = "Bitmapa"; case grayscale = "Stupně šedi"; case color = "Barevné"
}
enum CropMode: String, CaseIterable, Equatable {
    case autoDetect    = "Automaticky"
    case manualMargins = "Ručně"
}

// MARK: - DrawingsService

actor DrawingsService {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: Veřejné API

    func process(url: URL, settings: DrawingsSettings) async throws {
        if url.pathExtension.lowercased() == "pdf" {
            try await processPDF(url: url, settings: settings)
        } else {
            try await processImage(url: url, settings: settings)
        }
    }

    /// Preview — renderuje v plné kvalitě, ořízne na `maxSize` až na konci.
    func previewImage(url: URL, settings: DrawingsSettings, maxSize: CGSize) async throws -> NSImage {
        let ext = url.pathExtension.lowercased()
        let ciImage: CIImage

        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
                throw DrawingsError.unsupportedFile
            }
            // Renderujeme ve vysokém rozlišení (min 150 DPI)
            let pdfPts = page.bounds(for: .mediaBox).size
            let targetH: CGFloat = max(maxSize.height, 1600)
            let scale = min(targetH / pdfPts.height, 300 / 72)
            let rSize = CGSize(width: pdfPts.width * scale, height: pdfPts.height * scale)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: Int(rSize.width), height: Int(rSize.height),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw DrawingsError.processingFailed("PDF render context")
            }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: rSize))
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rSize.height)
            ctx.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            guard let cg = ctx.makeImage() else { throw DrawingsError.processingFailed("PDF render") }
            ciImage = CIImage(cgImage: cg)
        } else {
            guard let cg = loadCGImage(from: url) else { throw DrawingsError.unsupportedFile }
            ciImage = CIImage(cgImage: cg)
        }

        var result = applySyncPipeline(ciImage: ciImage, settings: settings)

        if settings.applyCrop,
           let cg = Self.ciContext.createCGImage(result, from: result.extent) {
            let cropped = applyCropToCG(cg, settings: settings)
            result = CIImage(cgImage: cropped)
        }

        return try downsampleToNSImage(ciImage: result, maxSize: maxSize)
    }

    // MARK: Dílčí operace

    func applyThreshold(ciImage: CIImage, settings: DrawingsSettings) -> CIImage {
        var img = ciImage
        if settings.brightnessBoost != 0 || settings.contrastBoost != 0,
           let f = CIFilter(name: "CIColorControls") {
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(settings.brightnessBoost, forKey: kCIInputBrightnessKey)
            f.setValue(1.0 + settings.contrastBoost, forKey: kCIInputContrastKey)
            if let out = f.outputImage { img = out }
        }
        let thr = settings.thresholdMode == .auto ? analyzeOtsuThreshold(img) : settings.thresholdValue
        if let f = CIFilter(name: "CIColorThreshold") {
            f.setValue(img, forKey: kCIInputImageKey); f.setValue(thr, forKey: "inputThreshold")
            if let out = f.outputImage { return out }
        }
        return img
    }

    func detectDeskewAngle(cgImage: CGImage) async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectRectanglesRequest { r, e in
                if let e = e { cont.resume(throwing: e); return }
                guard let rect = r.results?.first as? VNRectangleObservation else { cont.resume(returning: 0.0); return }
                let dx = rect.bottomRight.x - rect.bottomLeft.x
                let dy = rect.bottomRight.y - rect.bottomLeft.y
                cont.resume(returning: atan2(Double(dy), Double(dx)) * 180 / .pi)
            }
            req.minimumSize = 0.4; req.minimumConfidence = 0.6; req.maximumObservations = 1
            let h = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try h.perform([req]) } catch { cont.resume(throwing: error) }
        }
    }

    func deskew(ciImage: CIImage, angle: Double, withCrop: Bool) -> CIImage {
        guard abs(angle) > 0.05 else { return ciImage }
        var img = ciImage.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-angle * .pi / 180)))
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
        guard withCrop else { return img }
        let w = img.extent.width, h = img.extent.height, rad = abs(angle * .pi / 180)
        let cw = w * cos(rad) - h * abs(sin(rad)), ch = h * cos(rad) - w * abs(sin(rad))
        guard cw > 10, ch > 10 else { return img }
        return img.cropped(to: CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch))
    }

    func rotate90(ciImage: CIImage, steps: Int) -> CIImage {
        var img = ciImage
        for _ in 0..<(((steps % 4) + 4) % 4) { img = rotateOnce90CW(img) }
        return img
    }

    func alignToFormat(cgImage: CGImage, format: PaperFormat, mode: AlignmentMode) -> CGImage {
        let t = format.sizeAt300DPI
        let s = mode == .fit
            ? min(t.width / CGFloat(cgImage.width), t.height / CGFloat(cgImage.height))
            : max(t.width / CGFloat(cgImage.width), t.height / CGFloat(cgImage.height))
        let sw = CGFloat(cgImage.width) * s, sh = CGFloat(cgImage.height) * s
        let ctx = CGContext(data: nil, width: Int(t.width), height: Int(t.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: t))
        ctx.draw(cgImage, in: CGRect(x: (t.width - sw) / 2, y: (t.height - sh) / 2, width: sw, height: sh))
        return ctx.makeImage()!
    }

    func reduceNoise(ciImage: CIImage, level: Double, sharpness: Double) -> CIImage {
        guard let f = CIFilter(name: "CINoiseReduction") else { return ciImage }
        f.setValue(ciImage, forKey: kCIInputImageKey)
        f.setValue(level,     forKey: "inputNoiseLevel")
        f.setValue(sharpness, forKey: "inputSharpness")
        return f.outputImage ?? ciImage
    }

    /// OCR — `regionOfInterest` v top-left origin (0-1). Nil = výchozí pravý dolní roh.
    func ocrBottomRight(cgImage: CGImage, regionOfInterest: CGRect? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { r, e in
                if let e = e { cont.resume(throwing: e); return }
                let texts = (r.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: texts.joined(separator: "\n"))
            }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["cs", "sk", "en"]
            req.usesLanguageCorrection = true
            if let roi = regionOfInterest {
                // Konverze z top-left (UI) do bottom-left (Vision)
                req.regionOfInterest = CGRect(x: roi.minX, y: 1 - roi.maxY,
                                              width: roi.width, height: roi.height)
            } else {
                req.regionOfInterest = CGRect(x: 0.75, y: 0.0, width: 0.25, height: 0.25)
            }
            let h = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try h.perform([req]) } catch { cont.resume(throwing: error) }
        }
    }

    /// Detekuje obdélník dokumentu; vrací normalized rect v top-left souřadnicích.
    func detectDocumentRect(cgImage: CGImage) -> CGRect? {
        let req = VNDetectRectanglesRequest()
        req.minimumSize = 0.3; req.minimumConfidence = 0.5; req.maximumObservations = 1
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
        guard let r = req.results?.first else { return nil }
        // Vision: y=0 dole → převod na y=0 nahoře
        return CGRect(x: r.boundingBox.minX, y: 1 - r.boundingBox.maxY,
                      width: r.boundingBox.width, height: r.boundingBox.height)
    }

    // MARK: Ořez

    func applyCropToCG(_ cgImage: CGImage, settings: DrawingsSettings) -> CGImage {
        switch settings.cropMode {
        case .autoDetect:   return autoCropCGImage(cgImage) ?? cgImage
        case .manualMargins: return manualCropCGImage(cgImage, settings: settings)
        }
    }

    private func autoCropCGImage(_ cg: CGImage) -> CGImage? {
        let req = VNDetectRectanglesRequest()
        req.minimumSize = 0.3; req.minimumConfidence = 0.5; req.maximumObservations = 1
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        guard let r = req.results?.first else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let cr = CGRect(x: r.boundingBox.minX * w,
                        y: (1 - r.boundingBox.maxY) * h,
                        width: r.boundingBox.width * w,
                        height: r.boundingBox.height * h)
        return cg.cropping(to: cr)
    }

    private func manualCropCGImage(_ cg: CGImage, settings: DrawingsSettings) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let x = settings.cropLeftMargin * w, y = settings.cropTopMargin * h
        let cw = w * (1 - settings.cropLeftMargin - settings.cropRightMargin)
        let ch = h * (1 - settings.cropTopMargin  - settings.cropBottomMargin)
        guard cw > 0, ch > 0 else { return cg }
        return cg.cropping(to: CGRect(x: x, y: y, width: cw, height: ch)) ?? cg
    }

    // MARK: Privátní pipeline

    private func applySyncPipeline(ciImage: CIImage, settings: DrawingsSettings) -> CIImage {
        var img = ciImage
        if settings.applyNoiseReduction {
            img = reduceNoise(ciImage: img, level: settings.noiseLevel, sharpness: settings.noiseSharpness)
        }
        if settings.applyThreshold  { img = applyThreshold(ciImage: img, settings: settings) }
        if settings.applyColorConversion { img = convertColor(img, mode: settings.colorMode) }
        if settings.applyRotation   { img = rotate90(ciImage: img, steps: settings.rotationSteps) }
        return img
    }

    private func convertColor(_ img: CIImage, mode: ColorMode) -> CIImage {
        switch mode {
        case .grayscale:
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(img, forKey: kCIInputImageKey); f.setValue(0.0, forKey: kCIInputSaturationKey)
                return f.outputImage ?? img
            }
        case .bitmap:
            var g = img
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(img, forKey: kCIInputImageKey); f.setValue(0.0, forKey: kCIInputSaturationKey)
                if let o = f.outputImage { g = o }
            }
            if let f = CIFilter(name: "CIColorThreshold") {
                f.setValue(g, forKey: kCIInputImageKey); f.setValue(0.5, forKey: "inputThreshold")
                return f.outputImage ?? g
            }
            return g
        case .color: break
        }
        return img
    }

    private func rotateOnce90CW(_ img: CIImage) -> CIImage {
        let r = img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        let e = r.extent
        return r.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    private func analyzeOtsuThreshold(_ img: CIImage) -> Double {
        guard let cg = Self.ciContext.createCGImage(img, from: img.extent) else { return 0.5 }
        let w = min(cg.width, 64), h = min(cg.height, 64)
        var px = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hist = [Int](repeating: 0, count: 256)
        for p in px { hist[Int(p)] += 1 }
        let total = w * h
        var sum = 0; for (i, c) in hist.enumerated() { sum += i * c }
        var sumB = 0, wB = 0, maxVar = 0.0, thr = 128
        for t in 0..<256 {
            wB += hist[t]; let wF = total - wB
            if wB == 0 || wF == 0 { continue }
            sumB += t * hist[t]
            let mB = Double(sumB)/Double(wB), mF = Double(sum-sumB)/Double(wF)
            let v = Double(wB)*Double(wF)*(mB-mF)*(mB-mF)
            if v > maxVar { maxVar = v; thr = t }
        }
        return Double(thr)/255.0
    }

    // MARK: Zpracování souborů

    private func processImage(url: URL, settings: DrawingsSettings) async throws {
        guard let cg = loadCGImage(from: url) else { throw DrawingsError.unsupportedFile }
        var ci = applySyncPipeline(ciImage: CIImage(cgImage: cg), settings: settings)
        if settings.applyDeskew, let tmp = Self.ciContext.createCGImage(ci, from: ci.extent) {
            let angle = (try? await detectDeskewAngle(cgImage: tmp)) ?? 0.0
            if abs(angle) > 0.1, let dCG = Self.ciContext.createCGImage(
                deskew(ciImage: CIImage(cgImage: tmp), angle: angle, withCrop: settings.deskewWithCrop),
                from: deskew(ciImage: CIImage(cgImage: tmp), angle: angle, withCrop: settings.deskewWithCrop).extent
            ) { ci = CIImage(cgImage: dCG) }
        }
        guard let base = Self.ciContext.createCGImage(ci, from: ci.extent) else {
            throw DrawingsError.processingFailed("Render selhal")
        }
        var out = settings.applyCrop ? applyCropToCG(base, settings: settings) : base
        if settings.applyAlignment { out = alignToFormat(cgImage: out, format: settings.alignmentFormat, mode: settings.alignmentMode) }
        try saveImage(cgImage: out, to: url)
    }

    private func processPDF(url: URL, settings: DrawingsSettings) async throws {
        guard let doc = PDFDocument(url: url) else { throw DrawingsError.unsupportedFile }
        let newDoc = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pdfPts = page.bounds(for: .mediaBox).size
            let scale: CGFloat = 300 / 72.0
            let rSize = CGSize(width: pdfPts.width * scale, height: pdfPts.height * scale)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: Int(rSize.width), height: Int(rSize.height),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = { ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1))
                              ctx.fill(CGRect(origin:.zero,size:rSize))
                              ctx.saveGState(); ctx.translateBy(x:0,y:rSize.height)
                              ctx.scaleBy(x:scale,y:-scale); page.draw(with:.mediaBox,to:ctx)
                              ctx.restoreGState(); return ctx.makeImage() }()
            else { continue }

            var ci = CIImage(cgImage: cg)
            ci = applySyncPipeline(ciImage: ci, settings: settings)
            if settings.applyDeskew, let tmp = Self.ciContext.createCGImage(ci, from: ci.extent) {
                let angle = (try? await detectDeskewAngle(cgImage: tmp)) ?? 0.0
                if abs(angle) > 0.1 {
                    let d = deskew(ciImage: CIImage(cgImage: tmp), angle: angle, withCrop: settings.deskewWithCrop)
                    if let dCG = Self.ciContext.createCGImage(d, from: d.extent) { ci = CIImage(cgImage: dCG) }
                }
            }
            guard var finalCG = Self.ciContext.createCGImage(ci, from: ci.extent) else { continue }
            if settings.applyCrop { finalCG = applyCropToCG(finalCG, settings: settings) }
            if settings.applyAlignment { finalCG = alignToFormat(cgImage: finalCG, format: settings.alignmentFormat, mode: settings.alignmentMode) }
            if let pg = PDFPage(image: NSImage(cgImage: finalCG, size: .zero)) { newDoc.insert(pg, at: newDoc.pageCount) }
        }
        newDoc.write(to: url)
    }

    // MARK: Pomocné

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func saveImage(cgImage: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let t: CFString = ext == "png" ? "public.png" as CFString
                        : (ext == "tif" || ext == "tiff") ? "public.tiff" as CFString
                        : "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, t, 1, nil) else {
            throw DrawingsError.processingFailed("Cíl souboru")
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DrawingsError.processingFailed("Uložení selhalo") }
    }

    private func downsampleToNSImage(ciImage: CIImage, maxSize: CGSize) throws -> NSImage {
        let e = ciImage.extent
        let scale = min(maxSize.width / e.width, maxSize.height / e.height, 1.0)
        let scaled: CIImage
        if scale < 1.0, let f = CIFilter(name: "CILanczosScaleTransform") {
            f.setValue(ciImage, forKey: kCIInputImageKey)
            f.setValue(scale,   forKey: kCIInputScaleKey)
            f.setValue(1.0,     forKey: kCIInputAspectRatioKey)
            scaled = f.outputImage ?? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = ciImage
        }
        guard let cg = Self.ciContext.createCGImage(scaled, from: scaled.extent) else {
            throw DrawingsError.processingFailed("Render náhledu selhal")
        }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

enum DrawingsError: LocalizedError {
    case unsupportedFile, processingFailed(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedFile:         return "Nepodporovaný formát souboru"
        case .processingFailed(let m): return "Zpracování selhalo: \(m)"
        }
    }
}
