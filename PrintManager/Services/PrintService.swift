//
//  PrintService.swift
//  PrintManager
//
//  Service for handling print operations using the LP command
//

import Foundation
import AppKit
import ImageIO

class PrintService {
    
    func printFile(file: FileItem, settings: PrintSettings) async throws {
        // Build LP command
        var command = ["/usr/bin/lp"]
        command.append(contentsOf: settings.toLPArguments())
        command.append(file.url.path)
        
        // Execute print command
        try await executeCommand(command: command)
    }
    
    func printFiles(files: [FileItem], settings: PrintSettings) async throws {
        for file in files {
            try await printFile(file: file, settings: settings)
        }
    }
    
    private func executeCommand(command: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PrintError.commandFailed(output)
        }
    }
}

// MARK: - Printer Status

enum PrinterStatus: Equatable {
    case idle
    case inUse
    case offline
    case error(String)

    var label: String {
        switch self {
        case .idle:    return "Idle"
        case .inUse:   return "In use"
        case .offline: return "Offline"
        case .error(let msg): return msg.isEmpty ? "Error" : msg
        }
    }

    var color: NSColor {
        switch self {
        case .idle:    return .systemGreen
        case .inUse:   return .systemYellow
        case .offline: return .systemRed
        case .error:   return .systemOrange
        }
    }
}

// MARK: - PrintManager

class PrintManager: ObservableObject {
    @Published var availablePrinters: [String] = []
    @Published var defaultPrinter: String?
    @Published var printerStatuses: [String: PrinterStatus] = [:]

    init() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let printers = self.getPrinters()
            let def = self.getDefaultPrinter()
            let statuses: [String: PrinterStatus] = Dictionary(
                uniqueKeysWithValues: printers.map { ($0, self.getPrinterStatus(for: $0)) }
            )
            await MainActor.run {
                self.availablePrinters = printers
                self.defaultPrinter = def
                self.printerStatuses = statuses
            }
        }
    }

    func refreshPrinters() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let printers = self.getPrinters()
            let def = self.getDefaultPrinter()
            let statuses: [String: PrinterStatus] = Dictionary(
                uniqueKeysWithValues: printers.map { ($0, self.getPrinterStatus(for: $0)) }
            )
            await MainActor.run {
                self.availablePrinters = printers
                self.defaultPrinter = def
                self.printerStatuses = statuses
            }
        }
    }
    
    func getPrinters() -> [String] {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
            process.arguments = ["-a"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }
            
            let printers = output.split(separator: "\n").compactMap { line -> String? in
                let components = line.split(separator: " ")
                return components.first.map(String.init)
            }
            
            return printers
        } catch {
            print("Error getting printers: \(error)")
            return []
        }
    }
    
    func getDefaultPrinter() -> String? {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
            process.arguments = ["-d"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            
            // Parse output: "system default destination: PrinterName"
            let components = output.split(separator: ":")
            if components.count > 1 {
                return components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            return nil
        } catch {
            print("Error getting default printer: \(error)")
            return nil
        }
    }
    
    func getPresetsForPrinter(_ printer: String) -> [String] {
        // Read printer presets from plist files
        do {
            let prefsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences")
            
            let files = try FileManager.default.contentsOfDirectory(
                at: prefsDir,
                includingPropertiesForKeys: nil
            )
            
            let presetFiles = files.filter { file in
                file.lastPathComponent.hasPrefix("com.apple.print.custompresets")
            }
            
            var allPresets: [String] = []
            
            for file in presetFiles {
                if let plistData = try? Data(contentsOf: file),
                   let plist = try? PropertyListSerialization.propertyList(
                    from: plistData,
                    options: [],
                    format: nil
                   ) as? [String: Any],
                   let presets = plist["com.apple.print.customPresetsInfo"] as? [[String: Any]] {
                    
                    let presetNames = presets.compactMap { preset in
                        preset["PresetName"] as? String
                    }
                    
                    allPresets.append(contentsOf: presetNames)
                }
            }
            
            return allPresets
        } catch {
            print("Error reading presets: \(error)")
            return []
        }
    }
    
    func getPrinterStatus(for printerName: String) -> PrinterStatus {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
            process.arguments = ["-p", printerName]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if output.contains("processing") || output.contains("printing") {
                return .inUse
            } else if output.contains("offline") || output.contains("disabled") {
                return .offline
            } else if output.contains("idle") {
                return .idle
            } else if output.contains("error") || output.contains("stopped") {
                return .error("Error")
            }
            return .idle
        } catch {
            return .idle
        }
    }

    func isCUPSRunning() -> Bool {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "cupsd"]
            
            try process.run()
            process.waitUntilExit()
            
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    // MARK: - Native Printer Icons

    /// Returns the printer icon: first tries the .icns path from the PPD (*APPrinterIconPath),
    /// then falls back to a generic SF Symbol coloured by connection type.
    func getNativePrinterIcon(for printerName: String) -> NSImage {
        if let icon = iconFromPPD(for: printerName) {
            return icon
        }
        return fallbackIcon(for: printerName)
    }

    /// Reads /etc/cups/ppd/<name>.ppd and looks for *APPrinterIconPath to load the .icns file.
    private func iconFromPPD(for printerName: String) -> NSImage? {
        let ppdPath = "/etc/cups/ppd/\(printerName).ppd"
        guard let content = try? String(contentsOfFile: ppdPath, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let str = line.trimmingCharacters(in: .whitespaces)
            guard str.hasPrefix("*APPrinterIconPath:") else { continue }
            let raw = str
                .dropFirst("*APPrinterIconPath:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return NSImage(contentsOfFile: raw)
        }
        return nil
    }

    /// Coloured SF Symbol based on connection type (original fallback).
    private func fallbackIcon(for printerName: String) -> NSImage {
        let uri = getDeviceURI(for: printerName)
        let symbolName: String
        let color: NSColor
        if let uri {
            if uri.contains("usb://") {
                symbolName = "printer.fill"; color = .systemGray
            } else if uri.contains("ipp://") || uri.contains("ipps://") {
                symbolName = "printer.fill"; color = .systemBlue
            } else if uri.contains("socket://") {
                symbolName = "printer.fill"; color = .systemGreen
            } else if uri.contains("lpd://") {
                symbolName = "printer.fill"; color = .systemOrange
            } else if uri.contains("pdf") || uri.contains("virtual") || uri.contains("cups-brf") {
                symbolName = "doc.richtext.fill"; color = .systemRed
            } else {
                symbolName = "printer.fill"; color = .systemBlue
            }
        } else {
            symbolName = "printer.fill"; color = .systemBlue
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: printerName)?
            .withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "printer.fill", accessibilityDescription: nil)!
    }

    /// Returns the raw device URI string from lpstat -v for a given printer.
    private func getDeviceURI(for printerName: String) -> String? {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
            process.arguments = ["-v", printerName]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    /// Opens the CUPS web interface for a specific printer
    func openCUPSPage(for printerName: String) {
        // CUPS web interface URL for specific printer
        let encodedName = printerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? printerName
        let cupsURL = URL(string: "http://localhost:631/printers/\(encodedName)")!
        
        NSWorkspace.shared.open(cupsURL)
    }
    
    /// Opens the main CUPS web interface
    func openCUPSMainPage() {
        let cupsURL = URL(string: "http://localhost:631/")!
        NSWorkspace.shared.open(cupsURL)
    }
}

// MARK: - Print Errors

enum PrintError: LocalizedError {
    case commandFailed(String)
    case printerNotFound
    case fileNotAccessible
    
    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "Print command failed: \(message)"
        case .printerNotFound:
            return "Printer not found"
        case .fileNotAccessible:
            return "File is not accessible"
        }
    }
}
