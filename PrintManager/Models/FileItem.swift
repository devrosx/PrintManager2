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
    let id: UUID
    let url: URL
    let name: String
    let fileType: FileType
    let fileSize: Int64
    let pageCount: Int
    let pageSize: CGSize
    let colorInfo: String
    var status: FileStatus
    var thumbnail: NSImage?
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var pageSizeString: String {
        if pageSize.width == 0 || pageSize.height == 0 {
            return "N/A"
        }
        
        // Convert points to mm
        let widthMM = pageSize.width * 0.352777778
        let heightMM = pageSize.height * 0.352777778
        
        // Try to match common paper sizes
        if abs(widthMM - 210) < 5 && abs(heightMM - 297) < 5 {
            return "A4"
        } else if abs(widthMM - 148) < 5 && abs(heightMM - 210) < 5 {
            return "A5"
        } else if abs(widthMM - 297) < 5 && abs(heightMM - 420) < 5 {
            return "A3"
        } else if abs(widthMM - 216) < 5 && abs(heightMM - 279) < 5 {
            return "Letter"
        } else if abs(widthMM - 216) < 5 && abs(heightMM - 356) < 5 {
            return "Legal"
        }
        
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
         status: FileStatus = .ready,
         thumbnail: NSImage? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.fileType = fileType
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.colorInfo = colorInfo
        self.status = status
        self.thumbnail = thumbnail
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
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
            return "doc.fill"
        case .jpeg, .png, .tiff, .bmp, .gif:
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
    
    var isImage: Bool {
        switch self {
        case .jpeg, .png, .tiff, .bmp, .gif:
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

    var description: String {
        switch self {
        case .auto:         return "Automaticky (OpenOffice → CloudConvert)"
        case .openOffice:   return "OpenOffice / LibreOffice (lokálně)"
        case .cloudConvert: return "CloudConvert (online, API klíč)"
        case .googleDrive:  return "Google Drive (online, Google účet)"
        }
    }

    var icon: String {
        switch self {
        case .auto:         return "wand.and.stars"
        case .openOffice:   return "desktopcomputer"
        case .cloudConvert: return "cloud.fill"
        case .googleDrive:  return "g.circle.fill"
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

        if !presetOptions.isEmpty {
            // Preset režim: použij options z macOS systémového presetu
            args += presetOptions
            // Počet kopií lze přepsat manuálně pokud se liší od výchozí 1
            if copies != 1 && !presetOptions.contains("-n") {
                args += ["-n", "\(copies)"]
            }
        } else {
            // Manuální režim: individuální nastavení
            args += ["-o", "media=\(paperSize)"]
            args += ["-n", "\(copies)"]
            if twoSided {
                args += ["-o", "sides=two-sided-long-edge"]
            }
            if collate {
                args += ["-o", "Collate=True"]
            }
            if fitToPage {
                args += ["-o", "fit-to-page"]
            }
            if landscape {
                args += ["-o", "landscape"]
            }
            switch colorMode {
            case "grayscale": args += ["-o", "ColorModel=Gray"]
            case "color":     args += ["-o", "ColorModel=RGB"]
            default:          break
            }
        }

        return args
    }
}
