//
//  FileParser.swift
//  PrintManager
//
//  Service for parsing files and extracting metadata.
//  Používá ThumbnailCache pro persist disk cache thumbnailu.
//

import Foundation
import AppKit
import PDFKit

class FileParser {

    // MARK: - Public API

    /// Parsuje metadata souboru (rychlé). Thumbnail načte z disk cache pokud existuje,
    /// jinak vrátí FileItem s thumbnail = nil — volající pak zavolá generateThumbnail().
    func parseFile(url: URL) -> FileItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let fileExtension = url.pathExtension.lowercased()
        let fileType = FileType.from(extension: fileExtension)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize   = attributes[.size] as? Int64 else { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent

        switch fileType {
        case .pdf:
            return parsePDF(url: url, fileName: fileName, fileSize: fileSize)
        case .jpeg, .png, .tiff, .bmp, .gif:
            return parseImage(url: url, fileName: fileName, fileSize: fileSize, fileType: fileType)
        case .doc, .docx, .xls, .xlsx, .ppt, .pptx, .odt, .ods, .odp:
            return parseOfficeDocument(url: url, fileName: fileName, fileSize: fileSize, fileType: fileType)
        default:
            return FileItem(
                url: url, name: fileName, fileType: fileType,
                fileSize: fileSize, pageCount: 1, pageSize: .zero, colorInfo: "Unknown"
            )
        }
    }

    /// Generuje thumbnail pro soubor a uloží do disk cache.
    /// Volat na background threadu po parseFile() pokud parseFile() vrátil thumbnail = nil.
    func generateThumbnail(url: URL, fileType: FileType) -> NSImage? {
        // Znovu zkus cache (mohla být naplněna jiným vláknem mezitím)
        if let cached = ThumbnailCache.shared.thumbnail(for: url) { return cached }

        let thumb: NSImage?
        switch fileType {
        case .pdf:
            guard let doc  = PDFDocument(url: url),
                  let page = doc.page(at: 0) else { return nil }
            thumb = page.thumbnail(of: CGSize(width: 80, height: 80), for: .mediaBox)
        case _ where fileType.isImage:
            guard let img = loadImageEfficiently(url: url) else { return nil }
            thumb = img.resized(to: NSSize(width: 80, height: 80))
        default:
            return nil
        }
        if let t = thumb { ThumbnailCache.shared.store(t, for: url) }
        return thumb
    }

    // MARK: - PDF Parsing

    private func parsePDF(url: URL, fileName: String, fileSize: Int64) -> FileItem? {
        guard let doc = PDFDocument(url: url) else { return nil }

        let pageCount = doc.pageCount
        var pageSize: CGSize = .zero
        var colorInfo = "Unknown"

        if let firstPage = doc.page(at: 0) {
            let bounds = firstPage.bounds(for: .mediaBox)
            let rot    = ((firstPage.rotation % 360) + 360) % 360
            pageSize   = (rot == 90 || rot == 270)
                ? CGSize(width: bounds.height, height: bounds.width)
                : bounds.size
            colorInfo  = detectPDFColorSpace(page: firstPage)
        }

        // Thumbnail: disk cache → generuj z již načteného dokumentu → ulož
        let thumbnail: NSImage?
        if let cached = ThumbnailCache.shared.thumbnail(for: url) {
            thumbnail = cached
        } else {
            let t = doc.page(at: 0).flatMap {
                $0.thumbnail(of: CGSize(width: 80, height: 80), for: .mediaBox)
            }
            thumbnail = t
            if let t { ThumbnailCache.shared.store(t, for: url) }
        }

        return FileItem(
            url: url, name: fileName, fileType: .pdf,
            fileSize: fileSize, pageCount: pageCount,
            pageSize: pageSize, colorInfo: colorInfo,
            thumbnail: thumbnail
        )
    }

    private func detectPDFColorSpace(page: PDFPage) -> String {
        let img = page.thumbnail(of: CGSize(width: 200, height: 200), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cs = cg.colorSpace, let name = cs.name else { return "RGB" }
        let n = name as String
        if n == (CGColorSpace.genericGrayGamma2_2 as String) { return "Grayscale" }
        if n.contains("CMYK") { return "CMYK" }
        return "RGB"
    }

    // MARK: - Image Parsing

    private func parseImage(url: URL, fileName: String, fileSize: Int64, fileType: FileType) -> FileItem? {
        // Použij CGImageSource pro efektivní načtení bez dekódování plné velikosti
        guard let image = loadImageEfficiently(url: url) else { return nil }

        let pageSize  = image.size
        let colorInfo = detectImageColorSpace(image: image)

        let thumbnail: NSImage?
        if let cached = ThumbnailCache.shared.thumbnail(for: url) {
            thumbnail = cached
        } else {
            let t = image.resized(to: NSSize(width: 80, height: 80))
            ThumbnailCache.shared.store(t, for: url)
            thumbnail = t
        }

        return FileItem(
            url: url, name: fileName, fileType: fileType,
            fileSize: fileSize, pageCount: 1,
            pageSize: pageSize, colorInfo: colorInfo,
            thumbnail: thumbnail
        )
    }

    /// Načte obrázek přes CGImageSource — efektivnější než NSImage(contentsOf:)
    /// protože umožňuje přeskočit plné dekódování při čtení metadat.
    private func loadImageEfficiently(url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func detectImageColorSpace(image: NSImage) -> String {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Unknown"
        }
        let bpp = cg.bitsPerPixel
        guard let name = cg.colorSpace?.name else { return "Unknown" }
        let n = name as String
        if n == (CGColorSpace.genericGrayGamma2_2 as String) { return "Grayscale (\(bpp)bpp)" }
        if n.contains("CMYK") { return "CMYK (\(bpp)bpp)" }
        return "RGB (\(bpp)bpp)"
    }

    // MARK: - Office Document Parsing

    private func parseOfficeDocument(url: URL, fileName: String, fileSize: Int64, fileType: FileType) -> FileItem? {
        FileItem(
            url: url, name: fileName, fileType: fileType,
            fileSize: fileSize, pageCount: 1, pageSize: .zero,
            colorInfo: "Requires Conversion", status: .ready
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
        if let date = attributes[.creationDate] as? Date {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            info.append("Created: \(f.string(from: date))")
        }
        if let date = attributes[.modificationDate] as? Date {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            info.append("Modified: \(f.string(from: date))")
        }
    } catch {
        info.append("Unable to read file attributes")
    }
    return info.joined(separator: "\n")
}
