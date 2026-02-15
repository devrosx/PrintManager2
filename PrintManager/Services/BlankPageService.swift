//
//  BlankPageService.swift
//  PrintManager
//
//  Service for adding blank pages to documents with odd page count
//

import Foundation
import PDFKit

class BlankPageService {
    
    // MARK: - Add Blank Page to Odd Documents
    
    func addBlankPageToOddDocuments(urls: [URL]) async throws -> [URL] {
        var outputURLs: [URL] = []
        
        for url in urls {
            let outputURL: URL
            
            if url.pathExtension.lowercased() == "pdf" {
                outputURL = try await addBlankPageToPDF(url: url)
            } else {
                // Skip non-PDF files
                outputURL = url
            }
            
            outputURLs.append(outputURL)
        }
        
        return outputURLs
    }
    
    // MARK: - Add Blank Page to PDF
    
    private func addBlankPageToPDF(url: URL) async throws -> URL {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw BlankPageError.invalidPDF
        }
        
        let pageCount = pdfDocument.pageCount
        
        // Check if document has odd number of pages
        guard pageCount > 0 && pageCount % 2 == 1 else {
            // Even number of pages or empty document - return original
            return url
        }
        
        // Create output URL
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_with_blank_page")
            .appendingPathExtension("pdf")
        
        // Create new PDF document
        let newPDFDocument = PDFDocument()
        
        // Copy all existing pages
        for pageIndex in 0..<pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            newPDFDocument.insert(page, at: pageIndex)
        }
        
        // Add blank page
        let blankPage = createBlankPage()
        newPDFDocument.insert(blankPage, at: pageCount)
        
        // Save the new document
        guard newPDFDocument.write(to: outputURL) else {
            throw BlankPageError.saveFailed
        }
        
        return outputURL
    }
    
    // MARK: - Create Blank Page
    
    private func createBlankPage() -> PDFPage {
        // Create a blank page with standard A4 size (612 x 792 points)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let blankPage = PDFPage()
        blankPage.setBounds(pageRect, for: .mediaBox)
        
        // Create a blank PDF with the page
        let blankPDFDocument = PDFDocument()
        blankPDFDocument.insert(blankPage, at: 0)
        
        // Get the page from the document to ensure proper formatting
        return blankPDFDocument.page(at: 0)!
    }
}

// MARK: - Blank Page Errors

enum BlankPageError: LocalizedError {
    case invalidPDF
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "Invalid PDF file"
        case .saveFailed:
            return "Failed to save document with blank page"
        }
    }
}