//
//  PrintService.swift
//  PrintManager
//
//  Service for handling print operations using native NSPrintOperation (AppKit + PDFKit).
//

import Foundation
import AppKit
import PDFKit

class PrintService {

    func printFile(file: FileItem, settings: PrintSettings) async throws {
        try await MainActor.run {
            let pi = buildPrintInfo(settings: settings)
            let op: NSPrintOperation

            if file.fileType == .pdf {
                guard let doc = PDFDocument(url: file.url) else {
                    throw PrintError.fileNotAccessible
                }
                guard let pdfOp = doc.printOperation(for: pi, scalingMode: .pageScaleToFit, autoRotate: true) else {
                    throw PrintError.commandFailed("Nelze vytvořit tiskovou operaci pro PDF")
                }
                op = pdfOp
            } else if file.fileType.isImage {
                guard let img = NSImage(contentsOf: file.url) else {
                    throw PrintError.fileNotAccessible
                }
                let view = NSImageView(frame: NSRect(origin: .zero, size: pi.paperSize))
                view.image = img
                view.imageScaling = settings.fitToPage ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
                op = NSPrintOperation(view: view, printInfo: pi)
            } else {
                throw PrintError.commandFailed("Nepodporovaný formát souboru pro tisk")
            }

            op.showsPrintPanel   = false
            op.showsProgressPanel = true
            if !op.run() {
                throw PrintError.commandFailed("Tisk se nezdařil")
            }
        }
    }

    func printFiles(files: [FileItem], settings: PrintSettings) async throws {
        for file in files {
            try await printFile(file: file, settings: settings)
        }
    }

    /// Sestaví ekvivalentní lp příkaz pro logování (nevykoná ho).
    func lpCommand(file: FileItem, settings: PrintSettings) -> String {
        let parts = ["/usr/bin/lp"] + settings.toLPArguments() + [file.url.path]
        return parts.joined(separator: " ")
    }

    // MARK: - Helpers

    private func buildPrintInfo(settings: PrintSettings) -> NSPrintInfo {
        // Kopie shared info — lepší základ než NSPrintInfo() (zachová papír atd.)
        let pi = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()

        // Tiskárna — nastav pokud je zvolena
        if !settings.printer.isEmpty {
            // Primárně přes NSPrinter
            if let p = NSPrinter(name: settings.printer) {
                pi.printer = p
            } else {
                // Fallback: jméno mohlo přijít z lpstat s jiným casem — zkus prefix-match
                let lower = settings.printer.lowercased()
                if let match = NSPrinter.printerNames.first(where: { $0.lowercased() == lower }),
                   let p = NSPrinter(name: match) {
                    pi.printer = p
                }
            }
        }

        // Papír a orientace
        pi.paperName  = NSPrinter.PaperName(rawValue: settings.paperSize)
        pi.orientation = settings.landscape ? .landscape : .portrait

        // Zarovnání na stránku
        if settings.fitToPage {
            pi.horizontalPagination  = .fit
            pi.verticalPagination    = .fit
            pi.isHorizontallyCentered = true
            pi.isVerticallyCentered   = true
        }

        let dict = pi.dictionary()

        // Kopie a oboustranný tisk — základní hodnoty
        dict.setValue(settings.copies, forKey: NSPrintInfo.AttributeKey.copies.rawValue)
        if settings.twoSided {
            dict.setValue("two-sided-long-edge", forKey: "sides")
        }

        // Preset options (CUPS/PPD volby z vybraného presetu)
        // Formát: ["-o","key=value", "-o","key2=value2", "-n","2", ...]
        // Tyto přepíší základní hodnoty pokud jsou v presetu definovány jinak.
        applyLPOptions(settings.presetOptions, to: dict)

        return pi
    }

    /// Parsuje LP argumenty a aplikuje je do NSPrintInfo slovníku.
    /// LP formát: ["-o", "sides=two-sided-long-edge", "-o", "ColorModel=Gray", "-n", "2"]
    private func applyLPOptions(_ options: [String], to dict: NSMutableDictionary) {
        var i = 0
        while i < options.count {
            switch options[i] {
            case "-o" where i + 1 < options.count:
                let kv = options[i + 1]
                if let eq = kv.firstIndex(of: "=") {
                    let key   = String(kv[kv.startIndex..<eq])
                    let value = String(kv[kv.index(after: eq)...])
                    dict.setValue(value, forKey: key)
                }
                i += 2
            case "-n" where i + 1 < options.count:
                if let n = Int(options[i + 1]) {
                    dict.setValue(n, forKey: NSPrintInfo.AttributeKey.copies.rawValue)
                }
                i += 2
            default:
                i += 1
            }
        }
    }
}

// MARK: - Printer Status

enum PrinterStatus: Equatable, Codable {
    case idle
    case inUse
    case offline
    case error(String)

    // Ruční Codable — enum má associated value
    private enum CodingKeys: String, CodingKey { case type, message }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:           try c.encode("idle",    forKey: .type)
        case .inUse:          try c.encode("inUse",   forKey: .type)
        case .offline:        try c.encode("offline", forKey: .type)
        case .error(let msg): try c.encode("error",   forKey: .type)
                              try c.encode(msg,        forKey: .message)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "inUse":   self = .inUse
        case "offline": self = .offline
        case "error":   self = .error((try? c.decode(String.self, forKey: .message)) ?? "")
        default:        self = .idle
        }
    }

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
    @Published var printerIPs: [String: String] = [:]

    // MARK: - Cache klíče

    private enum CK {
        static let printers = "pm.cache.printers"
        static let defPrinter = "pm.cache.defaultPrinter"
        static let statuses = "pm.cache.statuses"
        static let ips = "pm.cache.ips"
    }

    init() {
        // 1. Okamžitě zobraz data z cache (bez čekání na lpstat)
        loadFromCache()
        // 2. Na pozadí obnov a přeulož cache
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fetchAndApply()
        }
    }

    func refreshPrinters() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fetchAndApply()
        }
    }

    // MARK: - Shared fetch logic

    @discardableResult
    private func fetchAndApply() async -> Void {
        // Všechny 4 lpstat volání běží paralelně
        async let printersTask  = Task.detached(priority: .userInitiated) { self.getPrinters() }.value
        async let defaultTask   = Task.detached(priority: .userInitiated) { self.getDefaultPrinter() }.value
        async let allStatuses   = Task.detached(priority: .userInitiated) { self.getAllPrinterStatuses() }.value
        async let allURIs       = Task.detached(priority: .userInitiated) { self.getAllDeviceURIs() }.value

        let (printers, def, statusMap, uriMap) = await (printersTask, defaultTask, allStatuses, allURIs)

        // Sestavit finální mapy jen pro tiskárny které lpstat -a vrátil
        let statuses = Dictionary(uniqueKeysWithValues: printers.map {
            ($0, statusMap[$0] ?? .idle)
        })
        let ips = uriMap.compactMapValues { extractHost(from: $0) }

        await MainActor.run {
            self.availablePrinters = printers
            self.defaultPrinter    = def
            self.printerStatuses   = statuses
            self.printerIPs        = ips
            self.saveToCache()
        }
    }

    /// Jeden lpstat -p (bez jména) → stavy všech tiskáren najednou.
    private func getAllPrinterStatuses() -> [String: PrinterStatus] {
        let output = runLpstat(args: ["-p"]) ?? ""
        var result: [String: PrinterStatus] = [:]
        for line in output.split(separator: "\n") {
            let s = line.lowercased()
            // "printer PrinterName is idle.  enabled since ..."
            guard s.hasPrefix("printer ") else { continue }
            let parts = line.split(separator: " ", maxSplits: 4)
            guard parts.count >= 4 else { continue }
            let name = String(parts[1])
            let state = s
            if state.contains("processing") || state.contains("printing") {
                result[name] = .inUse
            } else if state.contains("offline") || state.contains("disabled") {
                result[name] = .offline
            } else if state.contains("error") || state.contains("stopped") {
                result[name] = .error("Error")
            } else {
                result[name] = .idle
            }
        }
        return result
    }

    /// Jeden lpstat -v (bez jména) → URI všech tiskáren najednou.
    private func getAllDeviceURIs() -> [String: String] {
        let output = runLpstat(args: ["-v"]) ?? ""
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            // "device for PrinterName: ipp://..."
            guard line.hasPrefix("device for ") else { continue }
            let rest = line.dropFirst("device for ".count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let name = String(rest[rest.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let uri  = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[name] = uri
        }
        return result
    }

    /// Extrahuje hostname/IP z URI tiskárny.
    private func extractHost(from uri: String) -> String? {
        guard let url = URL(string: uri), let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Spustí lpstat s danými argumenty a vrátí stdout.
    private func runLpstat(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    // MARK: - Persistence

    private func loadFromCache() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: CK.printers),
           let v = try? JSONDecoder().decode([String].self, from: data) {
            availablePrinters = v
        }
        defaultPrinter = ud.string(forKey: CK.defPrinter)
        if let data = ud.data(forKey: CK.statuses),
           let v = try? JSONDecoder().decode([String: PrinterStatus].self, from: data) {
            printerStatuses = v
        }
        if let data = ud.data(forKey: CK.ips),
           let v = try? JSONDecoder().decode([String: String].self, from: data) {
            printerIPs = v
        }
    }

    private func saveToCache() {
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(availablePrinters)  { ud.set(d, forKey: CK.printers) }
        ud.set(defaultPrinter, forKey: CK.defPrinter)
        if let d = try? JSONEncoder().encode(printerStatuses)    { ud.set(d, forKey: CK.statuses) }
        if let d = try? JSONEncoder().encode(printerIPs)         { ud.set(d, forKey: CK.ips) }
    }
    
    func getPrinters() -> [String] {
        let output = runLpstat(args: ["-a"]) ?? ""
        return output.split(separator: "\n").compactMap { line -> String? in
            let name = String(line.split(separator: " ").first ?? "")
            return name.isEmpty ? nil : name
        }
    }

    func getDefaultPrinter() -> String? {
        let output = runLpstat(args: ["-d"]) ?? ""
        // "system default destination: PrinterName"
        let parts = output.split(separator: ":", maxSplits: 1)
        guard parts.count > 1 else { return nil }
        let name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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
            #if DEBUG
            print("Error reading presets: \(error)")
            #endif
            return []
        }
    }
    
    func getPrinterStatus(for printerName: String) -> PrinterStatus {
        let output = (runLpstat(args: ["-p", printerName]) ?? "").lowercased()
        if output.contains("processing") || output.contains("printing") { return .inUse }
        if output.contains("offline")    || output.contains("disabled")  { return .offline }
        if output.contains("error")      || output.contains("stopped")   { return .error("Error") }
        return .idle
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
        if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: printerName)?
            .withSymbolConfiguration(config) {
            return icon
        }
        return NSImage(systemSymbolName: "printer.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    /// Returns the raw device URI string from lpstat -v for a given printer.
    private func getDeviceURI(for printerName: String) -> String? {
        runLpstat(args: ["-v", printerName])
    }
    
    /// Opens the CUPS web interface for a specific printer
    func openCUPSPage(for printerName: String) {
        // CUPS web interface URL for specific printer
        let encodedName = printerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? printerName
        guard let cupsURL = URL(string: "http://localhost:631/printers/\(encodedName)") else { return }
        NSWorkspace.shared.open(cupsURL)
    }
    
    /// Opens the main CUPS web interface
    func openCUPSMainPage() {
        guard let cupsURL = URL(string: "http://localhost:631/") else { return }
        NSWorkspace.shared.open(cupsURL)
    }

/// Opens the print queue app from ~/Library/Printers/<name>.app
    func openPrintQueue(for printerName: String) {
        let printerApp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Printers/\(printerName).app")
        if FileManager.default.fileExists(atPath: printerApp.path) {
            NSWorkspace.shared.open(printerApp)
        } else {
            // Fallback: CUPS web interface
            let encoded = printerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? printerName
            if let url = URL(string: "http://localhost:631/printers/\(encoded)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Opens the printer's IP address in the default browser
    func openPrinterIPAddress(_ host: String) {
        guard let url = URL(string: "http://\(host)") else { return }
        NSWorkspace.shared.open(url)
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
