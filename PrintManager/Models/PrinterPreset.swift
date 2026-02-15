//
//  PrinterPreset.swift
//  PrintManager
//
//  Model for printer-specific presets
//

import Foundation

// MARK: - Printer Preset

struct PrinterPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var printerName: String
    
    // Print settings
    var copies: Int
    var twoSided: Bool
    var collate: Bool
    var fitToPage: Bool
    var landscape: Bool
    var colorMode: String // "auto", "color", "grayscale"
    var paperSize: String // "A4", "A3", "Letter", etc.
    var mediaType: String? // "plain", "photo", "cardstock", etc.
    var printQuality: String? // "draft", "normal", "high"
    var duplex: String? // "none", "long-edge", "short-edge"
    
    init(
        id: UUID = UUID(),
        name: String,
        printerName: String,
        copies: Int = 1,
        twoSided: Bool = false,
        collate: Bool = true,
        fitToPage: Bool = false,
        landscape: Bool = false,
        colorMode: String = "auto",
        paperSize: String = "A4",
        mediaType: String? = nil,
        printQuality: String? = nil,
        duplex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.printerName = printerName
        self.copies = copies
        self.twoSided = twoSided
        self.collate = collate
        self.fitToPage = fitToPage
        self.landscape = landscape
        self.colorMode = colorMode
        self.paperSize = paperSize
        self.mediaType = mediaType
        self.printQuality = printQuality
        self.duplex = duplex
    }
    
    /// Convert preset to lp command arguments
    func toLPArguments() -> [String] {
        var args: [String] = []
        
        // Printer destination
        args.append(contentsOf: ["-d", printerName])
        
        // Copies
        if copies > 1 {
            args.append(contentsOf: ["-n", "\(copies)"])
        }
        
        // Two-sided / duplex
        if twoSided {
            if duplex == "short-edge" {
                args.append(contentsOf: ["-o", "sides=two-sided-short-edge"])
            } else {
                args.append(contentsOf: ["-o", "sides=two-sided-long-edge"])
            }
        } else {
            args.append(contentsOf: ["-o", "sides=one-sided"])
        }
        
        // Collate
        if collate {
            args.append(contentsOf: ["-o", "collate=true"])
        }
        
        // Fit to page
        if fitToPage {
            args.append(contentsOf: ["-o", "fit-to-page"])
        }
        
        // Orientation
        if landscape {
            args.append(contentsOf: ["-o", "orientation-requested=6"]) // Landscape
        } else {
            args.append(contentsOf: ["-o", "orientation-requested=3"]) // Portrait
        }
        
        // Color mode
        switch colorMode {
        case "color":
            args.append(contentsOf: ["-o", "ColorModel=RGB"])
        case "grayscale":
            args.append(contentsOf: ["-o", "ColorModel=Grayscale"])
        default:
            break
        }
        
        // Paper size
        if !paperSize.isEmpty {
            args.append(contentsOf: ["-o", "PageSize=\(paperSize)"])
        }
        
        // Media type
        if let media = mediaType, !media.isEmpty {
            args.append(contentsOf: ["-o", "MediaType=\(media)"])
        }
        
        // Print quality
        if let quality = printQuality, !quality.isEmpty {
            switch quality {
            case "draft":
                args.append(contentsOf: ["-o", "print-quality=3"])
            case "normal":
                args.append(contentsOf: ["-o", "print-quality=5"])
            case "high":
                args.append(contentsOf: ["-o", "print-quality=7"])
            default:
                break
            }
        }
        
        return args
    }
    
    /// Create a preset from current AppState
    static func fromAppState(name: String, printerName: String, appState: AppState) -> PrinterPreset {
        return PrinterPreset(
            name: name,
            printerName: printerName,
            copies: appState.printCopies,
            twoSided: appState.printTwoSided,
            collate: appState.printCollate,
            fitToPage: appState.printFitToPage,
            landscape: appState.printLandscape,
            colorMode: appState.printColorMode,
            paperSize: appState.printPaperSize
        )
    }
    
    /// Apply preset to AppState
    func applyToAppState(_ appState: AppState) {
        appState.printCopies = copies
        appState.printTwoSided = twoSided
        appState.printCollate = collate
        appState.printFitToPage = fitToPage
        appState.printLandscape = landscape
        appState.printColorMode = colorMode
        appState.printPaperSize = paperSize
    }
}

// MARK: - Printer Preset Storage

class PrinterPresetStore: ObservableObject {
    static let shared = PrinterPresetStore()
    
    @Published var presets: [PrinterPreset] = []
    
    private let presetsKey = "printerPresets"
    private let userDefaults = UserDefaults.standard
    
    private init() {
        loadPresets()
    }
    
    func loadPresets() {
        guard let data = userDefaults.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([PrinterPreset].self, from: data) else {
            presets = []
            return
        }
        presets = decoded
    }
    
    func savePresets() {
        guard let encoded = try? JSONEncoder().encode(presets) else { return }
        userDefaults.set(encoded, forKey: presetsKey)
    }
    
    func addPreset(_ preset: PrinterPreset) {
        presets.append(preset)
        savePresets()
    }
    
    func updatePreset(_ preset: PrinterPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            savePresets()
        }
    }
    
    func deletePreset(_ preset: PrinterPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }
    
    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }
    
    /// Get presets for a specific printer
    func presetsForPrinter(_ printerName: String) -> [PrinterPreset] {
        return presets.filter { $0.printerName == printerName }
    }
    
    /// Get preset by ID
    func preset(byId id: UUID) -> PrinterPreset? {
        return presets.first { $0.id == id }
    }
}
