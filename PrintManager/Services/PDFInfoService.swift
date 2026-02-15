//
//  PDFInfoService.swift
//  PrintManager
//
//  Service for extracting detailed PDF metadata
//

import Foundation
import PDFKit

struct PDFMetadata {
    var title: String?
    var author: String?
    var subject: String?
    var creator: String?
    var producer: String?
    var creationDate: Date?
    var modificationDate: Date?
    var version: String?
    var pageCount: Int
    var isEncrypted: Bool
    var isLinearized: Bool
    var containsOutlines: Bool
    var containsAnnotations: Bool
    var containsForms: Bool
    var pageSize: CGSize
    var fileSize: Int64
    
    // Page color analysis
    var colorPageCount: Int = 0
    var blackWhitePageCount: Int = 0
    
    var titleOrFilename: String {
        title ?? "Unknown"
    }
    
    var creationDateFormatted: String? {
        guard let date = creationDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var modificationDateFormatted: String? {
        guard let date = modificationDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var pdfVersion: String {
        version ?? "Unknown"
    }
    
    var pageSizeFormatted: String {
        let widthMM = pageSize.width * 0.352777778
        let heightMM = pageSize.height * 0.352777778
        return String(format: "%.1f × %.1f mm", widthMM, heightMM)
    }
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var compressionInfo: String {
        if isEncrypted {
            return "Encrypted"
        }
        if isLinearized {
            return "Linearized"
        }
        return "Standard"
    }
    
    var features: [String] {
        var features: [String] = []
        if containsOutlines { features.append("Bookmarks") }
        if containsAnnotations { features.append("Annotations") }
        if containsForms { features.append("Forms") }
        return features
    }
    
    var featuresString: String {
        features.isEmpty ? "None" : features.joined(separator: ", ")
    }
    
    /// Color info string for display (e.g., "B&W: 5, Color: 3")
    var colorInfoString: String {
        if colorPageCount == 0 && blackWhitePageCount == 0 {
            return ""
        }
        return "B&W: \(blackWhitePageCount), Color: \(colorPageCount)"
    }
}

class PDFInfoService {
    
    static let shared = PDFInfoService()
    
    private init() {}
    
    func extractMetadata(from url: URL) -> PDFMetadata? {
        guard let pdfDocument = PDFDocument(url: url) else {
            return nil
        }
        
        let attributes = pdfDocument.documentAttributes ?? [:]
        
        // Get file size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            fileSize = attrs[.size] as? Int64 ?? 0
        }
        
        // Get first page size
        var pageSize = CGSize.zero
        if let firstPage = pdfDocument.page(at: 0) {
            pageSize = firstPage.bounds(for: .mediaBox).size
        }
        
        // Check for PDF version
        var pdfVersion = "1.4"
        if let data = try? Data(contentsOf: url),
           let header = String(data: data.prefix(8), encoding: .ascii) {
            if header.contains("PDF-1.0") { pdfVersion = "1.0" }
            else if header.contains("PDF-1.1") { pdfVersion = "1.1" }
            else if header.contains("PDF-1.2") { pdfVersion = "1.2" }
            else if header.contains("PDF-1.3") { pdfVersion = "1.3" }
            else if header.contains("PDF-1.4") { pdfVersion = "1.4" }
            else if header.contains("PDF-1.5") { pdfVersion = "1.5" }
            else if header.contains("PDF-1.6") { pdfVersion = "1.6" }
            else if header.contains("PDF-1.7") { pdfVersion = "1.7" }
            else if header.contains("%PDF-2.0") { pdfVersion = "2.0" }
        }
        
        // Check for encryption
        let isEncrypted = pdfDocument.isEncrypted
        
        // Check for outlines/bookmarks
        let containsOutlines = pdfDocument.outlineRoot != nil
        
        // Check for annotations
        var containsAnnotations = false
        for i in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: i),
               !page.annotations.isEmpty {
                containsAnnotations = true
                break
            }
        }
        
        // Check for forms (check document attributes)
        var containsForms = false
        if attributes["AcroForm"] != nil {
            containsForms = true
        }
        
        // Linearization is not directly available in PDFKit, set to false
        let isLinearized = false
        
        return PDFMetadata(
            title: attributes[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attributes[PDFDocumentAttribute.subjectAttribute] as? String,
            creator: attributes[PDFDocumentAttribute.creatorAttribute] as? String,
            producer: attributes[PDFDocumentAttribute.producerAttribute] as? String,
            creationDate: attributes[PDFDocumentAttribute.creationDateAttribute] as? Date,
            modificationDate: attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date,
            version: pdfVersion,
            pageCount: pdfDocument.pageCount,
            isEncrypted: isEncrypted,
            isLinearized: isLinearized,
            containsOutlines: containsOutlines,
            containsAnnotations: containsAnnotations,
            containsForms: containsForms,
            pageSize: pageSize,
            fileSize: fileSize
        )
    }
}
