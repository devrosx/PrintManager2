//
//  ImageService.swift
//  PrintManager
//
//  Service for image operations: convert, resize, rotate, invert, detect sub-images
//

import Foundation
import AppKit
import CoreImage
import Vision
import PDFKit

class ImageService {

    // Sdílený CIContext — alokuje GPU zdroje pouze jednou
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Convert to PDF

    func convertToPDF(urls: [URL]) async throws -> URL {
        guard !urls.isEmpty else { throw ImageError.invalidImage }

        let pdfDocument = PDFDocument()

        for url in urls {
            // CGImageSource okamžitě dekóduje pixel data — spolehlivější než NSImage(contentsOf:)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                continue
            }
            let nsImage = NSImage(cgImage: cgImage,
                                  size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let page = PDFPage(image: nsImage) else { continue }
            // Vždy append (pageCount roste s každou vloženou stránkou)
            pdfDocument.insert(page, at: pdfDocument.pageCount)
        }

        guard pdfDocument.pageCount > 0 else { throw ImageError.processingFailed }

        let outputURL = urls[0].deletingLastPathComponent()
            .appendingPathComponent("converted_\(Int(Date().timeIntervalSince1970)).pdf")

        guard pdfDocument.write(to: outputURL) else {
            throw ImageError.saveFailed
        }
        return outputURL
    }

    // MARK: - Resize Image
    
    func resizeImage(url: URL, width: Int, height: Int) async throws -> URL {
        guard let image = NSImage(contentsOf: url) else {
            throw ImageError.invalidImage
        }
        
        let newSize = NSSize(width: width, height: height)
        let resizedImage = image.resized(to: newSize)
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_resized")
            .appendingPathExtension(url.pathExtension)

        try saveImage(resizedImage, to: outputURL)
        return outputURL
    }

    func resizeImageProportional(url: URL, maxDimension: Int) async throws -> URL {
        guard let image = NSImage(contentsOf: url) else {
            throw ImageError.invalidImage
        }
        
        let currentSize = image.size
        let aspectRatio = currentSize.width / currentSize.height
        
        var newSize: NSSize
        if currentSize.width > currentSize.height {
            newSize = NSSize(width: maxDimension, height: Int(Double(maxDimension) / aspectRatio))
        } else {
            newSize = NSSize(width: Int(Double(maxDimension) * aspectRatio), height: maxDimension)
        }
        
        let resizedImage = image.resized(to: newSize)
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_resized")
            .appendingPathExtension(url.pathExtension)

        try saveImage(resizedImage, to: outputURL)
        return outputURL
    }

    // MARK: - Rotate Image
    
    func rotateImage(url: URL, degrees: Double) async throws -> URL {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageError.invalidImage
        }
        
        let ciImage = CIImage(cgImage: cgImage)
        let rotatedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: degrees * .pi / 180))
        guard let outputCGImage = ImageService.ciContext.createCGImage(rotatedImage, from: rotatedImage.extent) else {
            throw ImageError.processingFailed
        }
        
        let outputImage = NSImage(cgImage: outputCGImage, size: NSSize(width: outputCGImage.width, height: outputCGImage.height))
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_rotated")
            .appendingPathExtension(url.pathExtension)
        
        try saveImage(outputImage, to: outputURL)
        return outputURL
    }
    
    // MARK: - Invert Image
    
    func invertImage(url: URL) async throws -> URL {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageError.invalidImage
        }
        
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let filter = CIFilter(name: "CIColorInvert") else {
            throw ImageError.processingFailed
        }
        
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        
        guard let outputImage = filter.outputImage else {
            throw ImageError.processingFailed
        }
        guard let outputCGImage = ImageService.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw ImageError.processingFailed
        }
        let finalImage = NSImage(cgImage: outputCGImage, size: NSSize(width: outputCGImage.width, height: outputCGImage.height))
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_inverted")
            .appendingPathExtension(url.pathExtension)
        
        try saveImage(finalImage, to: outputURL)
        return outputURL
    }
    
    // MARK: - Detect and Extract Sub-Images
    
    func detectAndExtractImages(url: URL) async throws -> [URL] {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageError.invalidImage
        }
        
        let outputDir = url.deletingLastPathComponent()
            .appendingPathComponent("extracted_subimages")
        
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        // Use Vision framework to detect rectangles (potential images)
        let rectangles = try await detectRectangles(in: cgImage)
        
        var extractedURLs: [URL] = []
        
        for (index, rect) in rectangles.enumerated() {
            // Převod normalizovaných souřadnic Vision (počátek vlevo dole) na
            // pixelové souřadnice CGImage (počátek vlevo nahoře) — nutný flip osy Y
            let imageRect = CGRect(
                x: rect.origin.x * CGFloat(cgImage.width),
                y: (1.0 - rect.origin.y - rect.size.height) * CGFloat(cgImage.height),
                width: rect.size.width * CGFloat(cgImage.width),
                height: rect.size.height * CGFloat(cgImage.height)
            )
            
            // Crop the image
            if let croppedCGImage = cgImage.cropping(to: imageRect) {
                let croppedImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height))
                
                let outputURL = outputDir.appendingPathComponent("subimage_\(index).png")
                try saveImage(croppedImage, to: outputURL)
                extractedURLs.append(outputURL)
            }
        }
        
        return extractedURLs
    }
    
    private func detectRectangles(in cgImage: CGImage) async throws -> [CGRect] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Filter and convert to CGRect
                let rectangles = observations
                    .filter { $0.confidence > 0.5 }
                    .map { observation -> CGRect in
                        let boundingBox = observation.boundingBox
                        return CGRect(
                            x: boundingBox.origin.x,
                            y: boundingBox.origin.y,
                            width: boundingBox.size.width,
                            height: boundingBox.size.height
                        )
                    }
                
                continuation.resume(returning: rectangles)
            }
            
            request.minimumAspectRatio = 0.3
            request.maximumAspectRatio = 1.0
            request.minimumSize = 0.1
            request.maximumObservations = 10
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - OCR on Image
    
    func ocrImage(url: URL) async throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageError.invalidImage
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
    
    // MARK: - Apply Filters
    
    func applyGrayscale(url: URL) async throws -> URL {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageError.invalidImage
        }
        
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let filter = CIFilter(name: "CIPhotoEffectNoir") else {
            throw ImageError.processingFailed
        }
        
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        
        guard let outputImage = filter.outputImage else {
            throw ImageError.processingFailed
        }
        guard let outputCGImage = ImageService.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw ImageError.processingFailed
        }
        let finalImage = NSImage(cgImage: outputCGImage, size: NSSize(width: outputCGImage.width, height: outputCGImage.height))
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_grayscale")
            .appendingPathExtension(url.pathExtension)
        
        try saveImage(finalImage, to: outputURL)
        return outputURL
    }
    
    // MARK: - Helper Methods
    
    private func saveImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            throw ImageError.saveFailed
        }
        
        let fileType: NSBitmapImageRep.FileType
        switch url.pathExtension.lowercased() {
        case "png":
            fileType = .png
        case "jpg", "jpeg":
            fileType = .jpeg
        case "tiff", "tif":
            fileType = .tiff
        case "bmp":
            fileType = .bmp
        default:
            fileType = .png
        }
        
        guard let data = bitmapRep.representation(using: fileType, properties: [:]) else {
            throw ImageError.saveFailed
        }
        
        try data.write(to: url)
    }
}

// MARK: - NSImage Extension

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

// MARK: - Image Errors

enum ImageError: LocalizedError {
    case invalidImage
    case processingFailed
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid image file"
        case .processingFailed:
            return "Image processing failed"
        case .saveFailed:
            return "Failed to save image"
        }
    }
}
