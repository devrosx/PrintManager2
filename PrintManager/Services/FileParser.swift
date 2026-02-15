//
//  FileParser.swift
//  PrintManager
//
//  Service for parsing files and extracting metadata
//

import Foundation
import AppKit
import PDFKit

class FileParser {
    
    func parseFile(url: URL) -> FileItem? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        let fileExtension = url.pathExtension.lowercased()
        let fileType = FileType.from(extension: fileExtension)
        
        // Get basic file info
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return nil
        }
        
        let fileName = url.deletingPathExtension().lastPathComponent
        
        // Parse based on file type
        switch fileType {
        case .pdf:
            return parsePDF(url: url, fileName: fileName, fileSize: fileSize)
            
        case .jpeg, .png, .tiff, .bmp, .gif:
            return parseImage(url: url, fileName: fileName, fileSize: fileSize, fileType: fileType)
            
        case .doc, .docx, .xls, .xlsx, .ppt, .pptx, .odt, .ods, .odp:
            return parseOfficeDocument(url: url, fileName: fileName, fileSize: fileSize, fileType: fileType)
            
        default:
            return FileItem(
                url: url,
                name: fileName,
                fileType: fileType,
                fileSize: fileSize,
                pageCount: 1,
                pageSize: .zero,
                colorInfo: "Unknown"
            )
        }
    }
    
    // MARK: - PDF Parsing
    
    private func parsePDF(url: URL, fileName: String, fileSize: Int64) -> FileItem? {
        guard let pdfDocument = PDFDocument(url: url) else {
            return nil
        }
        
        let pageCount = pdfDocument.pageCount
        var pageSize: CGSize = .zero
        var colorInfo = "Unknown"
        
        // Get first page info
        if let firstPage = pdfDocument.page(at: 0) {
            pageSize = firstPage.bounds(for: .mediaBox).size
            colorInfo = detectPDFColorSpace(page: firstPage)
        }
        
        // Generate thumbnail
        let thumbnail = generatePDFThumbnail(document: pdfDocument)
        
        return FileItem(
            url: url,
            name: fileName,
            fileType: .pdf,
            fileSize: fileSize,
            pageCount: pageCount,
            pageSize: pageSize,
            colorInfo: colorInfo,
            thumbnail: thumbnail
        )
    }
    
    private func detectPDFColorSpace(page: PDFPage) -> String {
        // Try to detect color space
        let pageImage = page.thumbnail(of: CGSize(width: 200, height: 200), for: .mediaBox)
        guard let cgImage = pageImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Unknown"
        }
        
        let colorSpace = cgImage.colorSpace
        
        if let name = colorSpace?.name {
            switch name {
            case CGColorSpace.sRGB, CGColorSpace.genericRGBLinear, CGColorSpace.displayP3:
                return "RGB"
            case CGColorSpace.genericGrayGamma2_2:
                return "Grayscale"
            default:
                // Cast CFString to String
                let nameString = name as String
                if nameString.contains("CMYK") {
                    return "CMYK"
                }
                return "RGB"
            }
        }
        
        return "RGB"
    }
    
    private func generatePDFThumbnail(document: PDFDocument) -> NSImage? {
        guard let firstPage = document.page(at: 0) else {
            return nil
        }
        
        return firstPage.thumbnail(of: CGSize(width: 80, height: 80), for: .mediaBox)
    }
    
    // MARK: - Image Parsing
    
    private func parseImage(url: URL, fileName: String, fileSize: Int64, fileType: FileType) -> FileItem? {
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        
        let pageSize = image.size
        let colorInfo = detectImageColorSpace(image: image)
        
        // Generate thumbnail
        let thumbnail = image.resized(to: NSSize(width: 80, height: 80))
        
        return FileItem(
            url: url,
            name: fileName,
            fileType: fileType,
            fileSize: fileSize,
            pageCount: 1,
            pageSize: pageSize,
            colorInfo: colorInfo,
            thumbnail: thumbnail
        )
    }
    
    private func detectImageColorSpace(image: NSImage) -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Unknown"
        }
        
        let colorSpace = cgImage.colorSpace
        let bitsPerPixel = cgImage.bitsPerPixel
        
        if let name = colorSpace?.name {
            switch name {
            case CGColorSpace.sRGB, CGColorSpace.genericRGBLinear, CGColorSpace.displayP3:
                return "RGB (\(bitsPerPixel)bpp)"
            case CGColorSpace.genericGrayGamma2_2:
                return "Grayscale (\(bitsPerPixel)bpp)"
            default:
                // Cast CFString to String
                let nameString = name as String
                if nameString.contains("CMYK") {
                    return "CMYK (\(bitsPerPixel)bpp)"
                }
                return "RGB (\(bitsPerPixel)bpp)"
            }
        }
        
        return "Unknown"
    }
    
    // MARK: - Office Document Parsing
    
    private func parseOfficeDocument(url: URL, fileName: String, fileSize: Int64, fileType: FileType) -> FileItem? {
        // Office documents require conversion
        // For now, return basic info with conversion required status
        
        return FileItem(
            url: url,
            name: fileName,
            fileType: fileType,
            fileSize: fileSize,
            pageCount: 1,
            pageSize: .zero,
            colorInfo: "Requires Conversion",
            status: .ready
        )
    }
}

// MARK: - File Info Helper

func getFileInfo(url: URL) -> String {
    var info: [String] = []
    
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        
        if let size = attributes[.size] as? Int64 {
            info.append("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        
        if let creationDate = attributes[.creationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            info.append("Created: \(formatter.string(from: creationDate))")
        }
        
        if let modificationDate = attributes[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            info.append("Modified: \(formatter.string(from: modificationDate))")
        }
        
    } catch {
        info.append("Unable to read file attributes")
    }
    
    return info.joined(separator: "\n")
}
