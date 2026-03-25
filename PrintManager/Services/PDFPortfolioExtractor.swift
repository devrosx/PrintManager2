//
//  PDFPortfolioExtractor.swift
//  PrintManager
//
//  Detekce a extrakce souborů z PDF portfolií (PDF packages).
//

import Foundation
import PDFKit

class PDFPortfolioExtractor {

    struct ExtractedFile {
        let name: String
        let data: Data
    }

    // MARK: - Detekce portfolia

    /// Vrací true pokud PDF obsahuje /Collection v katalogu (= je portfolio/package).
    static func isPortfolio(url: URL) -> Bool {
        guard let doc = CGPDFDocument(url as CFURL),
              let catalog = doc.catalog else { return false }

        // Portfolio PDF má /Collection dictionary v katalogu
        var collectionDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Collection", &collectionDict) {
            return true
        }

        // Fallback: má /Names/EmbeddedFiles i bez /Collection?
        var namesDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict) {
            var efDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(namesDict!, "EmbeddedFiles", &efDict) {
                return true
            }
        }

        return false
    }

    // MARK: - Extrakce souborů

    /// Extrahuje vložené soubory z PDF portfolia do dočasného adresáře.
    /// Vrací URL extrahovaných souborů.
    static func extractFiles(from url: URL) -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL),
              let catalog = doc.catalog else { return [] }

        let extractedFiles = extractEmbeddedFiles(from: catalog)
        guard !extractedFiles.isEmpty else { return [] }

        // Vytvoř temp adresář
        let portfolioName = url.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintManager_Portfolio")
            .appendingPathComponent(portfolioName + "_" + UUID().uuidString.prefix(8))

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var resultURLs: [URL] = []

        for file in extractedFiles {
            let sanitizedName = sanitizeFileName(file.name)
            let fileURL = tempDir.appendingPathComponent(sanitizedName)
            do {
                try file.data.write(to: fileURL)
                resultURLs.append(fileURL)
            } catch {
                continue
            }
        }

        return resultURLs
    }

    // MARK: - Private

    private static func extractEmbeddedFiles(from catalog: CGPDFDictionaryRef) -> [ExtractedFile] {
        var namesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict) else { return [] }

        var efDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(namesDict!, "EmbeddedFiles", &efDict) else { return [] }

        // EmbeddedFiles je name tree — může mít /Names array přímo nebo /Kids
        var results: [ExtractedFile] = []
        collectFromNameTree(efDict!, into: &results)
        return results
    }

    private static func collectFromNameTree(_ node: CGPDFDictionaryRef, into results: inout [ExtractedFile]) {
        // Přímý /Names array
        var namesArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &namesArray) {
            let count = CGPDFArrayGetCount(namesArray!)
            // Pole je: [name1, filespec1, name2, filespec2, ...]
            var i = 0
            while i + 1 < count {
                var name: CGPDFStringRef?
                var fileSpec: CGPDFDictionaryRef?

                if CGPDFArrayGetString(namesArray!, i, &name),
                   CGPDFArrayGetDictionary(namesArray!, i + 1, &fileSpec) {
                    let fileName = CGPDFStringCopyTextString(name!) as String? ?? "unknown"
                    if let file = extractFile(from: fileSpec!, name: fileName) {
                        results.append(file)
                    }
                }
                i += 2
            }
        }

        // /Kids array — rekurzivní uzly name tree
        var kidsArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kidsArray) {
            let count = CGPDFArrayGetCount(kidsArray!)
            for i in 0..<count {
                var kidDict: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kidsArray!, i, &kidDict) {
                    collectFromNameTree(kidDict!, into: &results)
                }
            }
        }
    }

    private static func extractFile(from fileSpec: CGPDFDictionaryRef, name: String) -> ExtractedFile? {
        // /EF dictionary obsahuje embedded file streams
        var efDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(fileSpec, "EF", &efDict) else { return nil }

        // /F stream je hlavní embedded soubor
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(efDict!, "F", &stream) else { return nil }

        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(stream!, &format) as Data? else { return nil }

        // Použij /UF (Unicode filename) nebo /F (filename) z filespec, fallback na name z name tree
        let displayName = getStringValue(from: fileSpec, key: "UF")
            ?? getStringValue(from: fileSpec, key: "F")
            ?? name

        return ExtractedFile(name: displayName, data: data)
    }

    private static func getStringValue(from dict: CGPDFDictionaryRef, key: String) -> String? {
        var str: CGPDFStringRef?
        if CGPDFDictionaryGetString(dict, key, &str) {
            return CGPDFStringCopyTextString(str!) as String?
        }
        return nil
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:")
        var sanitized = name.components(separatedBy: invalidChars).joined(separator: "_")
        if sanitized.isEmpty { sanitized = "embedded_file" }
        return sanitized
    }
}
