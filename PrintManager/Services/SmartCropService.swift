//
//  SmartCropService.swift
//  PrintManager
//
//  Service for smart cropping: detect white borders and crop images and PDFs automatically
//

import Foundation
import AppKit
import CoreImage
import PDFKit
import Vision

class SmartCropService {
    
    // MARK: - Smart Crop Main Function
    
    func smartCropFiles(urls: [URL]) async throws -> [URL] {
        var outputURLs: [URL] = []
        
        for url in urls {
            let outputURL: URL
            
            if url.pathExtension.lowercased() == "pdf" {
                outputURL = try await smartCropPDF(url: url)
            } else if isImageFile(url: url) {
                outputURL = try await smartCropImage(url: url)
            } else {
                throw SmartCropError.unsupportedFormat
            }
            
            outputURLs.append(outputURL)
        }
        
        return outputURLs
    }
    
    // MARK: - Smart Crop PDF
    
    private func smartCropPDF(url: URL) async throws -> URL {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw SmartCropError.invalidPDF
        }
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_smart_cropped")
            .appendingPathExtension("pdf")
        
        // Create temporary directory for image processing
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintManager_SmartCrop_\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Process each page
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            // Convert page to image for analysis
            let imageSize = CGSize(width: 1200, height: 1600) // High enough resolution for accurate detection
            let pageImage = page.thumbnail(of: imageSize, for: .mediaBox)
            
            // Analyze image to find crop bounds
            guard let cropBounds = detectCropBounds(image: pageImage) else {
                continue // Skip if detection fails
            }
            
            // Convert crop bounds back to PDF coordinates
            let pageBounds = page.bounds(for: .mediaBox)
            let scaleFactorX = pageBounds.width / imageSize.width
            let scaleFactorY = pageBounds.height / imageSize.height
            
            let pdfCropRect = CGRect(
                x: cropBounds.origin.x * scaleFactorX,
                y: pageBounds.height - (cropBounds.origin.y + cropBounds.height) * scaleFactorY,
                width: cropBounds.width * scaleFactorX,
                height: cropBounds.height * scaleFactorY
            )
            
            // Apply crop to page
            page.setBounds(pdfCropRect, for: .cropBox)
        }
        
        pdfDocument.write(to: outputURL)
        return outputURL
    }
    
    // MARK: - Smart Crop Image
    
    private func smartCropImage(url: URL) async throws -> URL {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SmartCropError.invalidImage
        }
        
        // Analyze image to find crop bounds
        let imageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let cropBounds = detectCropBounds(cgImage: cgImage, imageSize: imageSize)
        
        guard let cropRect = cropBounds else {
            throw SmartCropError.cropDetectionFailed
        }
        
        // Crop the image
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            throw SmartCropError.cropFailed
        }
        
        let croppedImage = NSImage(
            cgImage: croppedCGImage,
            size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height)
        )
        
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_smart_cropped")
            .appendingPathExtension(url.pathExtension)
        
        try saveImage(croppedImage, to: outputURL)
        return outputURL
    }
    
    // MARK: - Crop Bounds Detection
    
    private func detectCropBounds(image: NSImage) -> CGRect? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let imageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        return detectCropBounds(cgImage: cgImage, imageSize: imageSize)
    }
    
    private func detectCropBounds(cgImage: CGImage, imageSize: CGSize) -> CGRect? {
        // Convert to grayscale for faster processing
        guard let grayImage = convertToGrayscale(cgImage: cgImage) else {
            return nil
        }
        
        // Analyze edges to find content boundaries
        let top = findContentEdge(image: grayImage, direction: .top, imageSize: imageSize)
        let bottom = findContentEdge(image: grayImage, direction: .bottom, imageSize: imageSize)
        let left = findContentEdge(image: grayImage, direction: .left, imageSize: imageSize)
        let right = findContentEdge(image: grayImage, direction: .right, imageSize: imageSize)
        
        // Validate that we found reasonable bounds
        guard top < bottom && left < right else {
            return nil
        }
        
        // Add small padding to avoid cutting off content
        let padding: CGFloat = 2.0
        let cropRect = CGRect(
            x: max(0, left - padding),
            y: max(0, top - padding),
            width: min(imageSize.width - left - padding, right - left + padding * 2),
            height: min(imageSize.height - top - padding, bottom - top + padding * 2)
        )
        
        return cropRect
    }
    
    // MARK: - Edge Detection
    
    private enum Direction {
        case top, bottom, left, right
    }
    
    private func findContentEdge(image: CGImage, direction: Direction, imageSize: CGSize) -> CGFloat {
        let width = image.width
        let height = image.height
        
        // Sample every few pixels to speed up processing
        let sampleStep: Int = 4
        let threshold: UInt8 = 240 // White threshold (0-255)
        
        switch direction {
        case .top:
            return findEdgeFromTop(image: image, width: width, height: height, sampleStep: sampleStep, threshold: threshold)
        case .bottom:
            return findEdgeFromBottom(image: image, width: width, height: height, sampleStep: sampleStep, threshold: threshold)
        case .left:
            return findEdgeFromLeft(image: image, width: width, height: height, sampleStep: sampleStep, threshold: threshold)
        case .right:
            return findEdgeFromRight(image: image, width: width, height: height, sampleStep: sampleStep, threshold: threshold)
        }
    }
    
    private func findEdgeFromTop(image: CGImage, width: Int, height: Int, sampleStep: Int, threshold: UInt8) -> CGFloat {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return 0
        }
        
        let bytesPerPixel = 1 // Grayscale
        let bytesPerRow = width * bytesPerPixel
        let bytes = CFDataGetBytePtr(data)!
        
        // Start from top and move down
        for y in stride(from: 0, to: height, by: sampleStep) {
            let rowOffset = y * bytesPerRow
            
            // Check if this row has non-white content
            for x in stride(from: 0, to: width, by: sampleStep) {
                let pixelOffset = rowOffset + x * bytesPerPixel
                let pixelValue = bytes[pixelOffset]
                
                if pixelValue < threshold {
                    return CGFloat(y)
                }
            }
        }
        
        return 0 // No content found, keep original
    }
    
    private func findEdgeFromBottom(image: CGImage, width: Int, height: Int, sampleStep: Int, threshold: UInt8) -> CGFloat {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return CGFloat(height)
        }
        
        let bytesPerPixel = 1 // Grayscale
        let bytesPerRow = width * bytesPerPixel
        let bytes = CFDataGetBytePtr(data)!
        
        // Start from bottom and move up
        for y in stride(from: height - 1, to: 0, by: -sampleStep) {
            let rowOffset = y * bytesPerRow
            
            // Check if this row has non-white content
            for x in stride(from: 0, to: width, by: sampleStep) {
                let pixelOffset = rowOffset + x * bytesPerPixel
                let pixelValue = bytes[pixelOffset]
                
                if pixelValue < threshold {
                    return CGFloat(y + 1)
                }
            }
        }
        
        return CGFloat(height) // No content found, keep original
    }
    
    private func findEdgeFromLeft(image: CGImage, width: Int, height: Int, sampleStep: Int, threshold: UInt8) -> CGFloat {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return 0
        }
        
        let bytesPerPixel = 1 // Grayscale
        let bytesPerRow = width * bytesPerPixel
        let bytes = CFDataGetBytePtr(data)!
        
        // Start from left and move right
        for x in stride(from: 0, to: width, by: sampleStep) {
            // Check if this column has non-white content
            for y in stride(from: 0, to: height, by: sampleStep) {
                let pixelOffset = y * bytesPerRow + x * bytesPerPixel
                let pixelValue = bytes[pixelOffset]
                
                if pixelValue < threshold {
                    return CGFloat(x)
                }
            }
        }
        
        return 0 // No content found, keep original
    }
    
    private func findEdgeFromRight(image: CGImage, width: Int, height: Int, sampleStep: Int, threshold: UInt8) -> CGFloat {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return CGFloat(width)
        }
        
        let bytesPerPixel = 1 // Grayscale
        let bytesPerRow = width * bytesPerPixel
        let bytes = CFDataGetBytePtr(data)!
        
        // Start from right and move left
        for x in stride(from: width - 1, to: 0, by: -sampleStep) {
            // Check if this column has non-white content
            for y in stride(from: 0, to: height, by: sampleStep) {
                let pixelOffset = y * bytesPerRow + x * bytesPerPixel
                let pixelValue = bytes[pixelOffset]
                
                if pixelValue < threshold {
                    return CGFloat(x + 1)
                }
            }
        }
        
        return CGFloat(width) // No content found, keep original
    }
    
    // MARK: - Image Processing Helpers
    
    private func convertToGrayscale(cgImage: CGImage) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width,
            space: colorSpace,
            bitmapInfo: 0
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context?.makeImage()
    }
    
    private func saveImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            throw SmartCropError.saveFailed
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
            throw SmartCropError.saveFailed
        }
        
        try data.write(to: url)
    }
    
    private func isImageFile(url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif"]
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
}

// MARK: - Smart Crop Errors

enum SmartCropError: LocalizedError {
    case invalidPDF
    case invalidImage
    case unsupportedFormat
    case cropDetectionFailed
    case cropFailed
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "Invalid PDF file"
        case .invalidImage:
            return "Invalid image file"
        case .unsupportedFormat:
            return "Unsupported file format for smart crop"
        case .cropDetectionFailed:
            return "Failed to detect crop boundaries"
        case .cropFailed:
            return "Failed to crop image"
        case .saveFailed:
            return "Failed to save cropped file"
        }
    }
}