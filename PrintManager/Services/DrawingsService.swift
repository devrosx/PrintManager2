//
//  DrawingsService.swift
//  PrintManager
//
//  Service for processing technical drawings with image manipulation pipeline
//

import CoreImage
import Vision
import PDFKit
import AppKit

// MARK: - DrawingsService

final class DrawingsService: @unchecked Sendable {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Process a file (image or PDF) with the specified settings
    /// - Parameters:
    ///   - url: URL of the file to process
    ///   - settings: Processing settings to apply
    func process(url: URL, settings: DrawingsSettings) async throws {
        if url.pathExtension.lowercased() == "pdf" {
            try await processPDF(url: url, settings: settings)
        } else {
            try await processImage(url: url, settings: settings)
        }
    }

    /// Generate a preview image with applied settings (full quality, downsampled at end)
    /// - Parameters:
    ///   - url: URL of the file to preview
    ///   - settings: Processing settings to apply
    ///   - maxSize: Maximum size for the final preview
    /// - Returns: Preview image with settings applied
    func previewImage(url: URL, settings: DrawingsSettings, maxSize: CGSize) async throws -> NSImage {
        let ext = url.pathExtension.lowercased()
        let ciImage: CIImage

        if ext == "pdf" {
            // Use unified PDF rendering service
            guard let rendered = await PDFRenderingService.shared.renderPageToCIImage(
                url: url,
                pageIndex: 0,
                quality: .preview
            ) else {
                throw DrawingsError.unsupportedFile
            }
            ciImage = rendered
        } else {
            // Use unified image loading service
            guard let cgImage = await ImageLoadingService.loadCGImage(from: url, respectOrientation: true) else {
                throw DrawingsError.unsupportedFile
            }
            ciImage = CIImage(cgImage: cgImage)
        }

        var workingImage = ciImage

        // Ořez provést PŘED threshold - na původním obrázku pro lepší detekci
        if settings.applyCrop && settings.cropMode == .autoDetect,
           let cg = Self.ciContext.createCGImage(workingImage, from: workingImage.extent) {
            let cropped = applyCropToCG(cg, settings: settings)
            workingImage = CIImage(cgImage: cropped)
        }

        var result = applySyncPipeline(ciImage: workingImage, settings: settings)

        // Ruční ořez (s margin) může zůstat na konci
        if settings.applyCrop && settings.cropMode == .manualMargins,
           let cg = Self.ciContext.createCGImage(result, from: result.extent) {
            let cropped = applyCropToCG(cg, settings: settings)
            result = CIImage(cgImage: cropped)
        }

        return try downsampleToNSImage(ciImage: result, maxSize: maxSize)
    }

    // MARK: - Image Processing Operations

    /// Apply threshold filter with brightness and contrast adjustments
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

    /// Detect document skew angle using Vision framework
    /// - Parameter cgImage: Image to analyze
    /// - Returns: Detected angle in degrees (negative = clockwise)
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

    /// Apply deskew transformation to straighten rotated documents
    /// - Parameters:
    ///   - ciImage: Image to deskew
    ///   - angle: Rotation angle in degrees
    ///   - withCrop: Whether to crop black corners after rotation
    /// - Returns: Deskewed image
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

    /// Rotate image by 90-degree increments
    /// - Parameters:
    ///   - ciImage: Image to rotate
    ///   - steps: Number of 90-degree clockwise rotations (negative for counter-clockwise)
    /// - Returns: Rotated image
    func rotate90(ciImage: CIImage, steps: Int) -> CIImage {
        var img = ciImage
        for _ in 0..<(((steps % 4) + 4) % 4) { img = rotateOnce90CW(img) }
        return img
    }

    /// Align image to specific paper format with fit or fill mode
    /// - Parameters:
    ///   - cgImage: Source image
    ///   - format: Target paper format
    ///   - mode: Fit (preserve entire image) or Fill (may crop)
    /// - Returns: Aligned image on white background
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

    /// Apply noise reduction filter
    /// - Parameters:
    ///   - ciImage: Source image
    ///   - level: Noise reduction intensity
    ///   - sharpness: Sharpness preservation level
    /// - Returns: Noise-reduced image
    func reduceNoise(ciImage: CIImage, level: Double, sharpness: Double) -> CIImage {
        guard let f = CIFilter(name: "CINoiseReduction") else { return ciImage }
        f.setValue(ciImage, forKey: kCIInputImageKey)
        f.setValue(level,     forKey: "inputNoiseLevel")
        f.setValue(sharpness, forKey: "inputSharpness")
        return f.outputImage ?? ciImage
    }

    /// Perform OCR text recognition on specified region
    /// - Parameters:
    ///   - cgImage: Image to analyze
    ///   - regionOfInterest: Region in top-left coordinates (0-1 normalized). Nil = default bottom-right corner
    /// - Returns: Recognized text
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
                // Convert from top-left (UI) to bottom-left (Vision) coordinates
                req.regionOfInterest = CGRect(x: roi.minX, y: 1 - roi.maxY,
                                              width: roi.width, height: roi.height)
            } else {
                // Default: bottom-right corner
                req.regionOfInterest = CGRect(x: 0.75, y: 0.0, width: 0.25, height: 0.25)
            }
            let h = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try h.perform([req]) } catch { cont.resume(throwing: error) }
        }
    }

    /// Detect document rectangle using Vision framework
    /// - Parameter cgImage: Image to analyze
    /// - Returns: Normalized rectangle in top-left coordinates (0-1), or nil if not detected
    func detectDocumentRect(cgImage: CGImage) -> CGRect? {
        let req = VNDetectRectanglesRequest()
        req.minimumSize = 0.3; req.minimumConfidence = 0.5; req.maximumObservations = 1
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
        guard let r = req.results?.first else { return nil }
        // Vision uses bottom-left origin → convert to top-left
        return CGRect(x: r.boundingBox.minX, y: 1 - r.boundingBox.maxY,
                      width: r.boundingBox.width, height: r.boundingBox.height)
    }

    // MARK: - Cropping

    /// Apply crop to CGImage using either auto-detect or manual margins
    func applyCropToCG(_ cgImage: CGImage, settings: DrawingsSettings) -> CGImage {
        switch settings.cropMode {
        case .autoDetect:   return autoCropCGImage(cgImage, sensitivity: settings.cropSensitivity) ?? cgImage
        case .manualMargins: return manualCropCGImage(cgImage, settings: settings)
        }
    }

    /// Automatically crop image by detecting content edges
    private func autoCropCGImage(_ cg: CGImage, sensitivity: Double) -> CGImage? {
        let w = cg.width
        let h = cg.height

        guard w > RenderingConstants.AutoCrop.minimumDimension,
              h > RenderingConstants.AutoCrop.minimumDimension else {
            return nil
        }

        guard let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = cg.bitsPerPixel / 8
        let bytesPerRow = cg.bytesPerRow

        // Zjisti průměrnou jasnost - pro určení jestli je pozadí světlé nebo tmavé
        var totalBrightness: CGFloat = 0
        var sampleCount = 0

        // Sample at regular intervals for speed
        for y in stride(from: 0, to: h, by: RenderingConstants.AutoCrop.sampleInterval) {
            for x in stride(from: 0, to: w, by: RenderingConstants.AutoCrop.sampleInterval) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = CGFloat(bytes[offset]) / 255.0
                let g = CGFloat(bytes[offset + 1]) / 255.0
                let b = CGFloat(bytes[offset + 2]) / 255.0
                totalBrightness += (r + g + b) / 3.0
                sampleCount += 1
            }
        }

        let avgBrightness = totalBrightness / CGFloat(sampleCount)
        let isDarkBackground = avgBrightness < 0.5

        // Threshold based on sensitivity (0-1)
        // sensitivity 0 = stricter (requires stronger contrast)
        // sensitivity 1 = looser (detects weaker content)
        let threshold: CGFloat = 0.3 + CGFloat(1.0 - sensitivity) * 0.4

        // Find any content that differs significantly from average
        var minX = w, maxX = 0
        var minY = h, maxY = 0
        var foundContent = false

        for y in stride(from: 0, to: h, by: RenderingConstants.AutoCrop.contentSampleInterval) {
            for x in stride(from: 0, to: w, by: RenderingConstants.AutoCrop.contentSampleInterval) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = CGFloat(bytes[offset]) / 255.0
                let g = CGFloat(bytes[offset + 1]) / 255.0
                let b = CGFloat(bytes[offset + 2]) / 255.0
                let brightness = (r + g + b) / 3.0

                // Find pixels that differ enough from average brightness
                let diff = abs(brightness - avgBrightness)

                if diff > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    foundContent = true
                }
            }
        }

        guard foundContent else { return nil }

        let cropWidth = maxX - minX
        let cropHeight = maxY - minY

        // Validation - crop must be smaller than original but large enough
        guard cropWidth > RenderingConstants.AutoCrop.minimumCropDimension,
              cropHeight > RenderingConstants.AutoCrop.minimumCropDimension else {
            return nil
        }
        guard cropWidth < w - RenderingConstants.AutoCrop.detectionMargin,
              cropHeight < h - RenderingConstants.AutoCrop.detectionMargin else {
            return nil
        }

        // Add small margin around detected content
        let margin = RenderingConstants.AutoCrop.detectionMargin
        minX = max(0, minX - margin)
        minY = max(0, minY - margin)
        maxX = min(w, maxX + margin)
        maxY = min(h, maxY + margin)

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return cg.cropping(to: cropRect)
    }

    /// Apply manual crop using specified margins
    private func manualCropCGImage(_ cg: CGImage, settings: DrawingsSettings) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let x = settings.cropLeftMargin * w, y = settings.cropTopMargin * h
        let cw = w * (1 - settings.cropLeftMargin - settings.cropRightMargin)
        let ch = h * (1 - settings.cropTopMargin  - settings.cropBottomMargin)
        guard cw > 0, ch > 0 else { return cg }
        return cg.cropping(to: CGRect(x: x, y: y, width: cw, height: ch)) ?? cg
    }

    // MARK: - Processing Pipeline

    /// Apply synchronous image processing pipeline (threshold, color, rotation)
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

    /// Convert image color mode (grayscale, bitmap, or keep color)
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

    /// Rotate image 90 degrees clockwise
    private func rotateOnce90CW(_ img: CIImage) -> CIImage {
        let r = img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        let e = r.extent
        return r.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    /// Calculate optimal threshold using Otsu's method
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

    // MARK: - File Processing

    /// Process single image file with all enabled settings
    private func processImage(url: URL, settings: DrawingsSettings) async throws {
        // Use unified image loading service
        guard let cg = await ImageLoadingService.loadCGImage(from: url, respectOrientation: true) else {
            throw DrawingsError.unsupportedFile
        }
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

    /// Process multi-page PDF document with settings applied to each page
    private func processPDF(url: URL, settings: DrawingsSettings) async throws {
        guard let doc = PDFDocument(url: url) else { throw DrawingsError.unsupportedFile }
        let newDoc = PDFDocument()

        for i in 0..<doc.pageCount {
            // Use unified PDF rendering service for high quality
            guard let cg = await PDFRenderingService.shared.renderPageToCGImage(
                url: url,
                pageIndex: i,
                quality: .high
            ) else {
                continue
            }

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

    // MARK: - Helper Methods

    /// Save CGImage to file with appropriate format
    private func saveImage(cgImage: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let t: CFString = ext == "png" ? "public.png" as CFString
                        : (ext == "tif" || ext == "tiff") ? "public.tiff" as CFString
                        : "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, t, 1, nil) else {
            throw DrawingsError.processingFailed("Cíl souboru")
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: RenderingConstants.Compression.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DrawingsError.processingFailed("Uložení selhalo") }
    }

    /// Downsample CIImage to NSImage with maximum size constraint
    /// Uses high-quality Lanczos scaling when downsampling is needed
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
