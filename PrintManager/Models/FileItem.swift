//
//  FileItem.swift
//  PrintManager
//
//  Model representing a file in the print queue
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FileItem: Identifiable, Hashable {
    var id: UUID
    let url: URL
    let name: String
    let fileType: FileType
    let fileSize: Int64
    let pageCount: Int
    let pageSize: CGSize
    let colorInfo: String
    var status: FileStatus
    /// Inkrementuje se při každé modifikaci obsahu (rotace, crop…).
    /// Views ji používají pro detekci změny obsahu i při stejném UUID.
    var contentVersion: Int = 0
    /// true = soubor byl vytvořen operací PrintManageru (ne přidán uživatelem ručně)
    var isConverted: Bool = false
    /// Název zdrojového PDF portfolia (nil = běžný soubor)
    var portfolioSource: String? = nil
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    private enum SizeConstants {
        static let ptToMM: CGFloat = 0.352777778
        static let matchTolerance: CGFloat = 5.0
    }

    var pageSizeString: String {
        if pageSize.width == 0 || pageSize.height == 0 {
            return "N/A"
        }

        let widthMM  = pageSize.width  * SizeConstants.ptToMM
        let heightMM = pageSize.height * SizeConstants.ptToMM
        let t        = SizeConstants.matchTolerance

        if abs(widthMM - 210) < t && abs(heightMM - 297) < t { return "A4" }
        if abs(widthMM - 148) < t && abs(heightMM - 210) < t { return "A5" }
        if abs(widthMM - 297) < t && abs(heightMM - 420) < t { return "A3" }
        if abs(widthMM - 216) < t && abs(heightMM - 279) < t { return "Letter" }
        if abs(widthMM - 216) < t && abs(heightMM - 356) < t { return "Legal" }

        return "\(Int(widthMM))×\(Int(heightMM))mm"
    }
    
    init(id: UUID = UUID(),
         url: URL,
         name: String,
         fileType: FileType,
         fileSize: Int64,
         pageCount: Int,
         pageSize: CGSize,
         colorInfo: String,
         status: FileStatus = .ready) {
        self.id = id
        self.url = url
        self.name = name
        self.fileType = fileType
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.colorInfo = colorInfo
        self.status = status
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(contentVersion)
    }

    /// Porovnává i obsah, aby SwiftUI Table vědělo, že se řádek změnil
    /// (např. status .processing → .ready, pageCount 0 → N).
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.pageCount == rhs.pageCount
            && lhs.colorInfo == rhs.colorInfo
            && lhs.name == rhs.name
            && lhs.url == rhs.url
            && lhs.contentVersion == rhs.contentVersion
            && lhs.isConverted == rhs.isConverted
            && lhs.portfolioSource == rhs.portfolioSource
    }
}

// MARK: - FileType

enum FileType: String, Codable {
    case pdf = "PDF"
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"
    case bmp = "BMP"
    case gif = "GIF"
    case heic = "HEIC"
    case webp = "WebP"
    case raw = "RAW"
    case doc = "DOC"
    case docx = "DOCX"
    case xls = "XLS"
    case xlsx = "XLSX"
    case ppt = "PPT"
    case pptx = "PPTX"
    case odt = "ODT"
    case ods = "ODS"
    case odp = "ODP"
    case unknown = "Unknown"
    
    var icon: String {
        switch self {
        case .pdf:
            return "doc.richtext.fill"
        case .jpeg, .png, .tiff, .bmp, .gif, .heic, .webp, .raw:
            return "photo.fill"
        case .doc, .docx, .odt:
            return "doc.text.fill"
        case .xls, .xlsx, .ods:
            return "tablecells.fill"
        case .ppt, .pptx, .odp:
            return "play.rectangle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    /// Barva ikony v seznamu souborů
    var listColor: Color {
        switch self {
        case .pdf:
            return Color(red: 0.85, green: 0.15, blue: 0.10)   // červená (PDF)
        case .jpeg, .png, .tiff, .bmp, .gif, .heic, .webp, .raw:
            return Color(red: 0.10, green: 0.50, blue: 0.90)   // modrá (obrázek)
        case .doc, .docx, .odt:
            return Color(red: 0.18, green: 0.38, blue: 0.78)   // tmavě modrá (Word)
        case .xls, .xlsx, .ods:
            return Color(red: 0.15, green: 0.60, blue: 0.30)   // zelená (Excel)
        case .ppt, .pptx, .odp:
            return Color(red: 0.85, green: 0.38, blue: 0.10)   // oranžová (PPT)
        case .unknown:
            return .secondary
        }
    }
    
    var isImage: Bool {
        switch self {
        case .jpeg, .png, .tiff, .bmp, .gif, .heic, .webp, .raw:
            return true
        default:
            return false
        }
    }
    
    var isPDF: Bool {
        return self == .pdf
    }
    
    var requiresConversion: Bool {
        switch self {
        case .doc, .docx, .xls, .xlsx, .ppt, .pptx, .odt, .ods, .odp:
            return true
        default:
            return false
        }
    }
    
    static func from(extension ext: String) -> FileType {
        switch ext.lowercased() {
        case "pdf":
            return .pdf
        case "jpg", "jpeg":
            return .jpeg
        case "png":
            return .png
        case "tif", "tiff":
            return .tiff
        case "bmp":
            return .bmp
        case "gif":
            return .gif
        case "heic", "heif":
            return .heic
        case "webp":
            return .webp
        case "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "raw":
            return .raw
        case "doc":
            return .doc
        case "docx":
            return .docx
        case "xls":
            return .xls
        case "xlsx":
            return .xlsx
        case "ppt":
            return .ppt
        case "pptx":
            return .pptx
        case "odt":
            return .odt
        case "ods":
            return .ods
        case "odp":
            return .odp
        default:
            return .unknown
        }
    }
}

// MARK: - FileStatus

enum FileStatus: String, Codable {
    case ready = "Ready"
    case processing = "Processing"
    case printed = "Printed"
    case error = "Error"
    case converting = "Converting"
    
    var icon: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .processing:
            return "arrow.triangle.2.circlepath"
        case .printed:
            return "printer.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .converting:
            return "arrow.triangle.2.circlepath"
        }
    }
    
    var color: Color {
        switch self {
        case .ready:
            return .green
        case .processing, .converting:
            return .blue
        case .printed:
            return .purple
        case .error:
            return .red
        }
    }
}

// MARK: - DebugMessage

struct DebugMessage: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: DebugLevel
    
    init(message: String, level: DebugLevel) {
        self.timestamp = Date()
        self.message = message
        self.level = level
    }
    
    var formattedMessage: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeString = formatter.string(from: timestamp)
        return "[\(timeString)] \(level.prefix) \(message)"
    }
}

enum DebugLevel {
    case info
    case success
    case warning
    case error
    
    var prefix: String {
        switch self {
        case .info:
            return "ℹ️"
        case .success:
            return "✅"
        case .warning:
            return "⚠️"
        case .error:
            return "❌"
        }
    }
    
    var color: Color {
        switch self {
        case .info:
            return .primary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

// MARK: - ImportMethod

enum ImportMethod: String, CaseIterable {
    case auto = "Auto"
    case openOffice = "OpenOffice"
    case cloudConvert = "CloudConvert"
    case googleDrive = "Google Drive"
    case iLovePDF = "iLovePDF (Web)"

    var description: String {
        switch self {
        case .auto:         return "Automaticky (OpenOffice → CloudConvert)"
        case .openOffice:   return "OpenOffice / LibreOffice (lokálně)"
        case .cloudConvert: return "CloudConvert (online, API klíč)"
        case .googleDrive:  return "Google Drive (online, Google účet)"
        case .iLovePDF:     return "iLovePDF (experimentální, bez API)"
        }
    }

    var icon: String {
        switch self {
        case .auto:         return "wand.and.stars"
        case .openOffice:   return "desktopcomputer"
        case .cloudConvert: return "cloud.fill"
        case .googleDrive:  return "g.circle.fill"
        case .iLovePDF:     return "heart.circle.fill"
        }
    }
}

// MARK: - PrintSettings

struct PrintSettings {
    let printer: String
    let preset: String?
    /// LP options extrahované z macOS systémového presetu (prázdné = preset nevybrán)
    let presetOptions: [String]
    let copies: Int
    let twoSided: Bool
    let collate: Bool
    let fitToPage: Bool
    let landscape: Bool
    let colorMode: String
    let paperSize: String

    init(printer: String, preset: String? = nil, presetOptions: [String] = [],
         copies: Int = 1, twoSided: Bool = false,
         collate: Bool = true, fitToPage: Bool = false, landscape: Bool = false,
         colorMode: String = "auto", paperSize: String = "A4") {
        self.printer       = printer
        self.preset        = preset
        self.presetOptions = presetOptions
        self.copies        = copies
        self.twoSided      = twoSided
        self.collate       = collate
        self.fitToPage     = fitToPage
        self.landscape     = landscape
        self.colorMode     = colorMode
        self.paperSize     = paperSize
    }

    func toLPArguments() -> [String] {
        var args: [String] = ["-d", printer]

        // Preset (Apple CUPS formát: -o preset="název")
        if let presetName = preset, !presetName.isEmpty {
            args += ["-o", "preset=\"\(presetName)\""]
        }

        // Rozvinuté options z macOS systémového presetu (mohou být prázdné)
        args += presetOptions

        // Papír, kopie — vždy
        args += ["-o", "media=\(paperSize)"]
        args += ["-n", "\(copies)"]

        // Collate
        if collate { args += ["-o", "collate=true"] }

        // Oboustranný tisk
        if twoSided { args += ["-o", "sides=two-sided-long-edge"] }

        // Přizpůsobit stránce
        if fitToPage { args += ["-o", "fit-to-page"] }

        // Orientace
        if landscape { args += ["-o", "landscape"] }

        // Barevný režim (CUPS ColorMode)
        switch colorMode {
        case "grayscale": args += ["-o", "ColorMode=GrayScale"]
        case "color":     args += ["-o", "ColorMode=Color"]
        default:          break
        }

        return args
    }
}
