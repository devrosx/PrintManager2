//
//  Utilities.swift
//  PrintManager
//
//  Helper functions and extensions
//

import Foundation
import SwiftUI
import AppKit

// MARK: - File Utilities

func humansize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func getTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
}

func createOutputDirectory(name: String) throws -> URL {
    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    return outputDir
}

// MARK: - System Checks

func checkSystemRequirements() -> Bool {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}

func isCUPSRunning() -> Bool {
    let task = Process()
    task.launchPath = "/usr/bin/pgrep"
    task.arguments = ["-x", "cupsd"]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Logging

func setupLogging() {
    // Configure logging if needed
    print("PrintManager started")
}

// MARK: - Color Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - String Extensions

extension String {
    func sanitizeFilename() -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return self.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
    
    var fileExtension: String {
        (self as NSString).pathExtension
    }
    
    var fileName: String {
        (self as NSString).deletingPathExtension
    }
}

// MARK: - URL Extensions

extension URL {
    var fileSize: Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    func appendingTimestamp() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        return deletingLastPathComponent()
            .appendingPathComponent("\(filename)_\(timestamp)")
            .appendingPathExtension(ext)
    }
}

// MARK: - Date Extensions

extension Date {
    func formatted() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - CGSize Extensions

extension CGSize {
    var aspectRatio: CGFloat {
        guard height != 0 else { return 0 }
        return width / height
    }
    
    func scaled(toFit size: CGSize) -> CGSize {
        let aspectWidth = size.width / width
        let aspectHeight = size.height / height
        let aspectRatio = min(aspectWidth, aspectHeight)
        
        return CGSize(
            width: width * aspectRatio,
            height: height * aspectRatio
        )
    }
}

// MARK: - NSImage Extensions

extension NSImage {
    convenience init?(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }
    
    func jpegData(compressionQuality: CGFloat = 0.8) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) else {
            return nil
        }
        return jpegData
    }
}

// MARK: - Process Helpers

func executeShellCommand(_ command: String, arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    
    try process.run()
    process.waitUntilExit()
    
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    
    if process.terminationStatus != 0 {
        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        throw ShellError.commandFailed(errorString)
    }
    
    return String(data: outputData, encoding: .utf8) ?? ""
}

enum ShellError: LocalizedError {
    case commandFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "Shell command failed: \(message)"
        }
    }
}

// MARK: - File System Helpers

func moveToTrash(url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
}

func revealInFinder(url: URL) {
    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
}

func openInDefaultApp(url: URL) {
    NSWorkspace.shared.open(url)
}

// MARK: - Clipboard Helpers

func copyToClipboard(text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func copyToClipboard(image: NSImage) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([image])
}

// MARK: - Alert Helpers

func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

func showConfirmation(title: String, message: String, completion: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Yes")
    alert.addButton(withTitle: "No")
    
    let response = alert.runModal()
    completion(response == .alertFirstButtonReturn)
}

// MARK: - Performance Helpers

func measure<T>(label: String, block: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try block()
    let duration = Date().timeIntervalSince(start)
    print("\(label): \(String(format: "%.3f", duration))s")
    return result
}

func measureAsync<T>(label: String, block: () async throws -> T) async rethrows -> T {
    let start = Date()
    let result = try await block()
    let duration = Date().timeIntervalSince(start)
    print("\(label): \(String(format: "%.3f", duration))s")
    return result
}

// MARK: - Paper Size Helpers

enum PaperSize: String, CaseIterable {
    case a4 = "A4"
    case a3 = "A3"
    case a5 = "A5"
    case letter = "Letter"
    case legal = "Legal"
    case tabloid = "Tabloid"
    
    var sizeInPoints: CGSize {
        switch self {
        case .a4:
            return CGSize(width: 595, height: 842)
        case .a3:
            return CGSize(width: 842, height: 1191)
        case .a5:
            return CGSize(width: 420, height: 595)
        case .letter:
            return CGSize(width: 612, height: 792)
        case .legal:
            return CGSize(width: 612, height: 1008)
        case .tabloid:
            return CGSize(width: 792, height: 1224)
        }
    }
    
    var sizeInMM: CGSize {
        let points = sizeInPoints
        return CGSize(
            width: points.width * 0.352777778,
            height: points.height * 0.352777778
        )
    }
    
    static func from(size: CGSize, tolerance: CGFloat = 10) -> PaperSize? {
        let widthMM = size.width * 0.352777778
        let heightMM = size.height * 0.352777778
        
        for paperSize in PaperSize.allCases {
            let paperMM = paperSize.sizeInMM
            if abs(widthMM - paperMM.width) < tolerance && abs(heightMM - paperMM.height) < tolerance {
                return paperSize
            }
        }
        
        return nil
    }
}
