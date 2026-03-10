//
//  PDFRenderingService.swift
//  PrintManager
//
//  Unified service for PDF rendering operations
//

import Foundation
import PDFKit
import CoreImage
import AppKit

/// Actor-based service for thread-safe PDF rendering operations
actor PDFRenderingService {
    static let shared = PDFRenderingService()

    private init() {}

    // MARK: - Public API

    /// Render a PDF page to NSImage with specified quality
    /// - Parameters:
    ///   - url: URL of the PDF file
    ///   - pageIndex: Index of the page to render (0-based)
    ///   - quality: Rendering quality (determines DPI)
    /// - Returns: Rendered NSImage or nil if rendering failed
    func renderPage(url: URL, pageIndex: Int = 0, quality: RenderQuality) async -> NSImage? {
        guard let cgImage = await renderPageToCGImage(url: url, pageIndex: pageIndex, quality: quality) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Render a PDF page to CGImage with specified quality
    /// - Parameters:
    ///   - url: URL of the PDF file
    ///   - pageIndex: Index of the page to render (0-based)
    ///   - quality: Rendering quality (determines DPI)
    /// - Returns: Rendered CGImage or nil if rendering failed
    func renderPageToCGImage(url: URL, pageIndex: Int = 0, quality: RenderQuality) async -> CGImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else {
            return nil
        }

        let mediaBox = page.bounds(for: .mediaBox)
        let scale = quality.dpi / RenderingConstants.DPI.pointsToPixels
        let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Fill with white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        // Draw PDF page (CGContext and PDF both use bottom-left origin, just scale)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    /// Render a PDF page to CIImage with specified quality
    /// - Parameters:
    ///   - url: URL of the PDF file
    ///   - pageIndex: Index of the page to render (0-based)
    ///   - quality: Rendering quality (determines DPI)
    /// - Returns: Rendered CIImage or nil if rendering failed
    func renderPageToCIImage(url: URL, pageIndex: Int = 0, quality: RenderQuality) async -> CIImage? {
        guard let cgImage = await renderPageToCGImage(url: url, pageIndex: pageIndex, quality: quality) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    /// Render a PDF page as a thumbnail using PDFKit's optimized method
    /// - Parameters:
    ///   - url: URL of the PDF file
    ///   - pageIndex: Index of the page to render (0-based)
    ///   - size: Maximum size for the thumbnail
    /// - Returns: Thumbnail NSImage or nil if rendering failed
    func renderThumbnail(url: URL, pageIndex: Int = 0, size: CGSize) async -> NSImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else {
            return nil
        }
        return page.thumbnail(of: size, for: .mediaBox)
    }

    // MARK: - Quality Enum

    /// PDF rendering quality levels
    enum RenderQuality {
        case thumbnail  // 72 DPI - for small previews
        case preview    // 150 DPI - for medium previews
        case high       // 300 DPI - for processing and export

        var dpi: CGFloat {
            switch self {
            case .thumbnail: return RenderingConstants.DPI.thumbnail
            case .preview:   return RenderingConstants.DPI.preview
            case .high:      return RenderingConstants.DPI.high
            }
        }
    }
}
