//
//  SystemPresetService.swift
//  PrintManager
//
//  Načítá tiskové presety z macOS systémových plistů
//  (~Library/Preferences/com.apple.print.custompresets.forprinter.{printer}.plist)
//

import Foundation

// MARK: - Model

struct SystemPrinterPreset: Identifiable, Hashable {
    let id: String   // == name
    let name: String
    /// Hotové argumenty pro příkaz `lp`, např. ["-n","2","-o","sides=two-sided-long-edge","-o","ColorModel=Gray"]
    let lpOptions: [String]
}

// MARK: - Service

class SystemPresetService {

    func loadPresets(for printerName: String) -> [SystemPrinterPreset] {
        let candidates = presetFilePaths(for: printerName)
        for url in candidates {
            if let presets = parseFile(at: url), !presets.isEmpty {
                return presets
            }
        }
        return []
    }

    // MARK: - Private

    private func presetFilePaths(for printerName: String) -> [URL] {
        let filename = "com.apple.print.custompresets.forprinter.\(printerName).plist"
        let userPrefs  = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent(filename)
        let sysPrefs   = URL(fileURLWithPath: "/Library/Preferences/\(filename)")
        return [userPrefs, sysPrefs]
    }

    private func parseFile(at url: URL) -> [SystemPrinterPreset]? {
        guard let data = try? Data(contentsOf: url),
              let raw  = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }

        // Starší macOS: root = dict s klíčem "com.apple.print.customPresetsInfo"
        // Novější macOS: root = array
        let presetsArray: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            presetsArray = arr
        } else if let dict = raw as? [String: Any],
                  let arr  = dict["com.apple.print.customPresetsInfo"] as? [[String: Any]] {
            presetsArray = arr
        } else {
            return nil
        }

        return presetsArray.compactMap { parsePreset($0) }
    }

    private func parsePreset(_ dict: [String: Any]) -> SystemPrinterPreset? {
        guard let name = dict["PresetName"] as? String else { return nil }

        var lp: [String] = []

        // Tisková nastavení mohou být zanořena pod "com.apple.print.PrintSettings"
        // nebo rovnou v hlavním slovníku (záleží na verzi macOS / ovladači)
        let printSettings: [String: Any] = (dict["com.apple.print.PrintSettings"] as? [String: Any]) ?? dict

        // ── Počet kopií ──────────────────────────────────────────────────────────
        if let copies = printSettings["com.apple.print.PrintSettings.PMCopies"] as? Int, copies > 1 {
            lp += ["-n", "\(copies)"]
        }

        // ── Oboustranný tisk ─────────────────────────────────────────────────────
        // PMDuplex: 0 = simplexní, 1 = DuplexNoTumble (podél dlouhé strany), 2 = DuplexTumble
        if let duplex = printSettings["com.apple.print.PrintSettings.PMDuplex"] as? Int {
            switch duplex {
            case 1:  lp += ["-o", "sides=two-sided-long-edge"]
            case 2:  lp += ["-o", "sides=two-sided-short-edge"]
            default: lp += ["-o", "sides=one-sided"]
            }
        }

        // ── Řazení ───────────────────────────────────────────────────────────────
        if let collate = printSettings["com.apple.print.PrintSettings.PMCopyCollate"] as? Int {
            lp += ["-o", "Collate=\(collate == 1 ? "True" : "False")"]
        }

        // ── Orientace ────────────────────────────────────────────────────────────
        if let pageFormat = dict["com.apple.print.PageFormat"] as? [String: Any],
           let orientation = pageFormat["com.apple.print.PageFormat.PMOrientation"] as? Int,
           orientation == 2 {
            lp += ["-o", "orientation-requested=4"]   // landscape
        }

        // ── Velikost papíru ───────────────────────────────────────────────────────
        if let pageFormat = dict["com.apple.print.PageFormat"] as? [String: Any],
           let paperDict  = pageFormat["com.apple.print.PageFormat.PMPaper"] as? [String: Any],
           let paperName  = paperDict["com.apple.print.PageFormat.PMPaperName"] as? String {
            lp += ["-o", "media=\(paperName)"]
        }

        // ── Ovladačem specifické volby ────────────────────────────────────────────
        // Všechny ne-apple klíče s string/int hodnotou jsou PPD volby tiskárny
        // (např. ColorModel=Gray, Resolution=600dpi, MediaType=Plain …)
        for (key, value) in printSettings {
            guard !key.hasPrefix("com."), !key.hasPrefix("PMTicket") else { continue }
            if let s = value as? String, !s.isEmpty {
                lp += ["-o", "\(key)=\(s)"]
            } else if let i = value as? Int {
                lp += ["-o", "\(key)=\(i)"]
            }
        }

        return SystemPrinterPreset(id: name, name: name, lpOptions: lp)
    }
}
