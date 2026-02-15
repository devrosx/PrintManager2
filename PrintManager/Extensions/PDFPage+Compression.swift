//
//  PDFPage+Compression.swift
//  PrintManager
//
//  Extension to add image compression capabilities to PDFPage
//

import PDFKit
import AppKit

extension PDFPage {
    /// Apply image compression settings to the page
    func applyImageCompression(settings: CompressionSettings) {
        // This is a simplified implementation
        // In a full implementation, you would:
        // 1. Extract all images from the page
        // 2. Compress them according to settings
        // 3. Replace them in the page
        
        // For now, we'll just set some basic compression hints
        if settings.compressImages {
            // Set compression quality hint
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.clear,
                .font: NSFont.systemFont(ofSize: 1)
            ]
            
            // This is a placeholder - actual implementation would require
            // low-level PDF manipulation or using a library like PDFKit's
            // advanced features
        }
    }
    
    /// Extract all images from the page
    func extractImages() -> [NSImage] {
        var images: [NSImage] = []
        
        // Create a temporary PDF document with just this page
        let tempDocument = PDFDocument()
        tempDocument.insert(self, at: 0)
        
        // Render the page to get a composite image
        let pageImage = self.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
        images.append(pageImage)
        
        return images
    }
    
    /// Replace images in the page with compressed versions
    func replaceImages(with compressedImages: [NSImage], settings: CompressionSettings) {
        // This would require advanced PDF manipulation
        // For now, this is a placeholder for future implementation
    }
}

// MARK: - Image Compression Utilities

extension NSImage {
    /// Compress image to specified quality
    func compressedImage(quality: Double) -> NSImage? {
        guard let tiffData = self.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        let compressionFactor = max(0.1, min(1.0, quality))
        let properties: [NSBitmapImageRep.PropertyKey: Any] = [
            .compressionFactor: compressionFactor
        ]
        
        guard let compressedData = bitmapRep.representation(using: .jpeg, properties: properties),
              let compressedImage = NSImage(data: compressedData) else {
            return nil
        }
        
        return compressedImage
    }
    
    /// Downsample image to specified DPI
    func downsampledImage(dpi: Int) -> NSImage? {
        let scaleFactor = CGFloat(dpi) / 72.0
        let newSize = NSSize(
            width: size.width / scaleFactor,
            height: size.height / scaleFactor
        )
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}