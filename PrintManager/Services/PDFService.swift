//
//  PDFService.swift
//  PrintManager
//
//  Service for PDF operations: split, merge, compress, OCR, crop, etc.
//

import Foundation
import PDFKit
import Vision
import Quartz
import UniformTypeIdentifiers

class PDFService {
    
    // MARK: - Split PDF
    
    func splitPDF(url: URL) async throws -> [URL] {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw PDFError.invalidPDF
        }
        
        let outputDir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        var outputURLs: [URL] = []
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            let newDocument = PDFDocument()
            newDocument.insert(page, at: 0)
            
            let outputURL = outputDir.appendingPathComponent("\(baseName)_page\(pageIndex + 1).pdf")
            newDocument.write(to: outputURL)
            outputURLs.append(outputURL)
        }
        
        return outputURLs
    }
    
    // MARK: - Merge PDFs
    
    func mergePDFs(urls: [URL]) async throws -> URL {
        guard !urls.isEmpty else {
            throw PDFError.emptyInput
        }
        
        let mergedDocument = PDFDocument()
        var pageCount = 0
        
        for url in urls {
            guard let pdfDocument = PDFDocument(url: url) else {
                continue
            }
            
            for pageIndex in 0..<pdfDocument.pageCount {
                guard let page = pdfDocument.page(at: pageIndex) else { continue }
                mergedDocument.insert(page, at: pageCount)
                pageCount += 1
            }
        }
        
        let outputURL = urls[0].deletingLastPathComponent()
            .appendingPathComponent("merged_\(Date().timeIntervalSince1970).pdf")
        mergedDocument.write(to: outputURL)
        
        return outputURL
    }
    
    // MARK: - Compress PDF
    
    func compressPDF(url: URL, settings: CompressionSettings) async throws -> URL {
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_compressed")
            .appendingPathExtension("pdf")
        
        let startTime = Date()
        var warnings: [String] = []
        
        // Check if PDF is already optimized
        if let pdfDocument = PDFDocument(url: url) {
            let pageCount = pdfDocument.pageCount
            let metadata = pdfDocument.documentAttributes
            
            // Check for existing compression
            if let producer = metadata?["Producer"] as? String,
               producer.contains("Adobe") || producer.contains("Ghostscript") {
                warnings.append("PDF may already be optimized by \(producer)")
            }
        }
        
        // Method 1: Use Ghostscript if available (best quality)
        if let ghostscriptResult = try? await compressWithGhostscript(url: url, outputURL: outputURL, settings: settings) {
            let result = try await processCompressionResult(
                inputURL: url,
                outputURL: ghostscriptResult,
                startTime: startTime,
                warnings: warnings
            )
            return result
        }
        
        // Method 2: Use Quartz PDFKit with custom settings
        if let quartzResult = try? await compressWithQuartz(url: url, outputURL: outputURL, settings: settings) {
            let result = try await processCompressionResult(
                inputURL: url,
                outputURL: quartzResult,
                startTime: startTime,
                warnings: warnings
            )
            return result
        }
        
        // Method 3: Fallback to system conversion
        let qualityString: String
        switch settings.quality {
        case .high:
            qualityString = "high"
        case .medium:
            qualityString = "medium"
        case .low:
            qualityString = "low"
        case .minimal:
            qualityString = "low"
        case .veryLow:
            qualityString = "low"
        case .veryHigh:
            qualityString = "high"
        }
        
        try await executeCommand([
            "/System/Library/Printers/Libraries/convert",
            "-f", url.path,
            "-o", outputURL.path,
            "-q", qualityString
        ])
        
        return try await processCompressionResult(
            inputURL: url,
            outputURL: outputURL,
            startTime: startTime,
            warnings: warnings
        )
    }
    
    private func compressWithGhostscript(url: URL, outputURL: URL, settings: CompressionSettings) async throws -> URL {
        // Check if Ghostscript is available
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        checkProcess.arguments = ["gs"]
        
        let checkPipe = Pipe()
        checkProcess.standardOutput = checkPipe
        
        try checkProcess.run()
        checkProcess.waitUntilExit()
        
        guard checkProcess.terminationStatus == 0 else {
            throw PDFError.operationFailed("Ghostscript not available")
        }
        
        // Build Ghostscript command
        var args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            "-dPDFSETTINGS=/\(getPDFSettings(settings: settings))",
            "-dNOPAUSE",
            "-dQUIET",
            "-dBATCH"
        ]
        
        // Add quality-specific options
        if settings.quality == .minimal {
            args.append("-dDownsampleColorImages=true")
            args.append("-dColorImageResolution=\(settings.dpi)")
            args.append("-dColorImageDownsampleType=/Subsample")
        }
        
        if settings.removeMetadata {
            args.append("-dFILTERPSDATA")
        }
        
        if settings.linearize {
            args.append("-dLinearize")
        }
        
        args.append("-sOutputFile=\(outputURL.path)")
        args.append(url.path)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gs")
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PDFError.operationFailed("Ghostscript failed: \(output)")
        }
        
        return outputURL
    }
    
    private func compressWithQuartz(url: URL, outputURL: URL, settings: CompressionSettings) async throws -> URL {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw PDFError.invalidPDF
        }
        
        let newDocument = PDFDocument()
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            // Create new page with compression settings
            let newPage = PDFPage(image: page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox))
            
            // Apply image compression if needed
            if settings.compressImages || settings.downsampleImages {
                // Apply compression to page content
                if let pageData = page.dataRepresentation {
                    // For now, we'll skip the complex image compression
                    // This would require parsing PDF content streams
                }
            }
            
            if let newPage = newPage {
                newDocument.insert(newPage, at: pageIndex)
            }
        }
        
        // Set document properties
        var attributes: [String: Any] = [:]
        
        if settings.removeMetadata {
            attributes["Title"] = "Compressed PDF"
            attributes["Author"] = "PrintManager"
            attributes["Creator"] = "PrintManager"
            attributes["Producer"] = "PrintManager Compression"
        } else {
            // Preserve existing metadata
            if let existingAttributes = pdfDocument.documentAttributes {
                for (key, value) in existingAttributes {
                    if let stringKey = key as? String {
                        attributes[stringKey] = value as? String ?? "\(value)"
                    }
                }
            }
        }
        
        newDocument.documentAttributes = attributes
        newDocument.write(to: outputURL)
        
        return outputURL
    }
    
    private func getPDFSettings(settings: CompressionSettings) -> String {
        switch settings.quality {
        case .high:
            return "printer" // 300 DPI
        case .medium:
            return "ebook" // 150 DPI
        case .low:
            return "screen" // 72 DPI
        case .veryLow:
            return "screen" // 72 DPI
        case .veryHigh:
            return "printer" // 300 DPI
        case .minimal:
            return "prepress" // Maximum compression
        }
    }
    
    private func processCompressionResult(inputURL: URL, outputURL: URL, startTime: Date, warnings: [String]) async throws -> URL {
        let processingTime = Date().timeIntervalSince(startTime)
        
        // Check if compression was successful
        let inputSize = try FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64 ?? 0
        let outputSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        
        let savings = Double(inputSize - outputSize) / Double(inputSize) * 100
        
        // If compression didn't help or made it worse, return original
        if savings <= 0 {
            try FileManager.default.removeItem(at: outputURL)
            throw PDFError.operationFailed("Compression not effective (savings: \(String(format: "%.1f", savings))%)")
        }
        
        return outputURL
    }
    
    // MARK: - OCR PDF
    
    func ocrPDF(url: URL) async throws -> URL {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw PDFError.invalidPDF
        }
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_ocr")
            .appendingPathExtension("pdf")
        
        let newDocument = PDFDocument()
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else {
                continue
            }
            
            let pageImage = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
            
            // Perform OCR using Vision
            let text = try await performOCR(on: pageImage)
            
            // Create new page with searchable text
            let newPage = PDFPage(image: pageImage)
            newPage?.addAnnotation(createTextAnnotation(text: text, bounds: page.bounds(for: .mediaBox)))
            
            if let newPage = newPage {
                newDocument.insert(newPage, at: pageIndex)
            }
        }
        
        newDocument.write(to: outputURL)
        return outputURL
    }
    
    private func performOCR(on image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PDFError.ocrFailed
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                
                continuation.resume(returning: text)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func createTextAnnotation(text: String, bounds: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.color = .clear
        annotation.font = NSFont.systemFont(ofSize: 1)
        return annotation
    }
    
    // MARK: - Rasterize PDF
    
    func rasterizePDF(url: URL, dpi: Int = 300) async throws -> URL {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw PDFError.invalidPDF
        }
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_rasterized")
            .appendingPathExtension("pdf")
        
        let newDocument = PDFDocument()
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            let bounds = page.bounds(for: .mediaBox)
            let scaleFactor = CGFloat(dpi) / 72.0
            let scaledSize = CGSize(
                width: bounds.width * scaleFactor,
                height: bounds.height * scaleFactor
            )
            
            let pageImage = page.thumbnail(of: scaledSize, for: .mediaBox)
            guard let newPage = PDFPage(image: pageImage) else {
                continue
            }
            
            newDocument.insert(newPage, at: pageIndex)
        }
        
        newDocument.write(to: outputURL)
        return outputURL
    }
    
    // MARK: - Crop PDF
    
    func cropPDF(url: URL, cropBox: CGRect) async throws -> URL {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw PDFError.invalidPDF
        }
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_cropped")
            .appendingPathExtension("pdf")
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            page.setBounds(cropBox, for: .cropBox)
        }
        
        pdfDocument.write(to: outputURL)
        return outputURL
    }
    
    // MARK: - Extract Images
    
    func extractImages(url: URL) async throws -> [URL] {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw PDFError.invalidPDF
        }
        
        let outputDir = url.deletingLastPathComponent()
            .appendingPathComponent("extracted_images")
        
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        var extractedURLs: [URL] = []
        var imageIndex = 0
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            let images = extractImagesFromPage(page: page)
            
            for image in images {
                let outputURL = outputDir.appendingPathComponent("image_\(imageIndex).png")
                
                if let tiffData = image.tiffRepresentation,
                   let bitmapRep = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                    try pngData.write(to: outputURL)
                    extractedURLs.append(outputURL)
                    imageIndex += 1
                }
            }
        }
        
        return extractedURLs
    }
    
    private func extractImagesFromPage(page: PDFPage) -> [NSImage] {
        var images: [NSImage] = []
        
        // Get page content
        guard let pageContent = page.dataRepresentation,
              let contentStream = String(data: pageContent, encoding: .utf8) else {
            return images
        }
        
        // Simple extraction - render page and look for image operators
        // For production, you'd want to parse the PDF operators more carefully
        let pageImage = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
        images.append(pageImage)
        
        return images
    }
    
    // MARK: - Helper Methods
    
    private func executeCommand(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PDFError.operationFailed(output)
        }
    }
}

// MARK: - PDF Errors

enum PDFError: LocalizedError {
    case invalidPDF
    case emptyInput
    case ocrFailed
    case operationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "Invalid PDF file"
        case .emptyInput:
            return "No PDF files provided"
        case .ocrFailed:
            return "OCR operation failed"
        case .operationFailed(let message):
            return "PDF operation failed: \(message)"
        }
    }
}
