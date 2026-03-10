//
//  SystemPresetService.swift
//  PrintManager
//
//  Načítá tiskové presety z macOS systémových plistů
//  (~Library/Preferences/com.apple.print.custompresets.forprinter.{printer}.plist)
//
//  Podporuje dva formáty:
//  - Starý formát: root = array [[PresetName, PrintSettings, ...]]
//                  nebo root dict s klíčem "com.apple.print.customPresetsInfo" = array
//  - Nový formát:  root = dict, kde každý preset je uložen pod svým ID jako klíčem
//                  + "com.apple.print.customPresetsInfo" = [{PresetName: id}, ...]

import Foundation

// MARK: - Model

struct SystemPrinterPreset: Identifiable, Hashable, Codable {
    /// Klíč v plistu — používá se při mazání (root dict key nebo PresetName v array)
    let id: String
    /// Zobrazovaný název
    let name: String
    /// Hotové argumenty pro příkaz `lp`
    let lpOptions: [String]
}

// MARK: - Load Result

struct SystemPresetLoadResult {
    let presets: [SystemPrinterPreset]
    let searchedPaths: [String]
    let foundPath: String?
}

// MARK: - Service

class SystemPresetService {

    func loadPresets(for printerName: String) -> [SystemPrinterPreset] {
        return loadPresetsWithInfo(for: printerName).presets
    }

    func loadPresetsWithInfo(for printerName: String) -> SystemPresetLoadResult {
        let candidates = presetFilePaths(for: printerName)
        let paths = candidates.map { $0.path }
        for url in candidates {
            if let presets = parseFile(at: url), !presets.isEmpty {
                return SystemPresetLoadResult(presets: presets, searchedPaths: paths, foundPath: url.path)
            }
        }
        return SystemPresetLoadResult(presets: [], searchedPaths: paths, foundPath: nil)
    }

    // MARK: - Delete Preset

    /// Smaže preset s daným ID z plist souboru pro danou tiskárnu.
    func deletePreset(named presetID: String, forPrinter printerName: String) -> Bool {
        let candidates = presetFilePaths(for: printerName)
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let raw  = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            else { continue }

            // ── Nový formát: root dict s preset záznamy ──────────────────────
            if var rootDict = raw as? [String: Any],
               rootDict[presetID] != nil {
                rootDict.removeValue(forKey: presetID)
                // Odebrání z indexu com.apple.print.customPresetsInfo
                if var ci = rootDict["com.apple.print.customPresetsInfo"] as? [[String: Any]] {
                    ci.removeAll { ($0["PresetName"] as? String) == presetID }
                    rootDict["com.apple.print.customPresetsInfo"] = ci
                }
                return writePlist(rootDict, to: url)
            }

            // ── Starý formát: root array ──────────────────────────────────────
            if var arr = raw as? [[String: Any]] {
                arr.removeAll { ($0["PresetName"] as? String) == presetID }
                return writePlist(arr, to: url)
            }

            // ── Starý formát: dict s klíčem customPresetsInfo ─────────────────
            if var dict = raw as? [String: Any],
               var ci = dict["com.apple.print.customPresetsInfo"] as? [[String: Any]] {
                ci.removeAll { ($0["PresetName"] as? String) == presetID }
                dict["com.apple.print.customPresetsInfo"] = ci
                return writePlist(dict, to: url)
            }
        }
        return false
    }

    // MARK: - Private helpers

    private func writePlist(_ object: Any, to url: URL) -> Bool {
        // Zachovat formát (binární) jako originál
        guard let outData = try? PropertyListSerialization.data(
            fromPropertyList: object, format: .binary, options: 0
        ) else { return false }
        do {
            try outData.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private func presetFilePaths(for printerName: String) -> [URL] {
        let userPrefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let sysPrefsDir = URL(fileURLWithPath: "/Library/Preferences")

        // macOS CUPS normalizuje jméno tiskárny různě — zkoušíme všechny varianty
        var nameSet: [String] = [printerName]
        // Mezery → podtržítka
        let spacesToUnderscores = printerName.replacingOccurrences(of: " ", with: "_")
        if !nameSet.contains(spacesToUnderscores) { nameSet.append(spacesToUnderscores) }
        // Mezery → pomlčky
        let spacesToDashes = printerName.replacingOccurrences(of: " ", with: "-")
        if !nameSet.contains(spacesToDashes) { nameSet.append(spacesToDashes) }
        // Mezery + pomlčky → podtržítka (CUPS běžně normalizuje takto)
        let allToUnderscores = printerName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if !nameSet.contains(allToUnderscores) { nameSet.append(allToUnderscores) }
        // Mezery + pomlčky → pomlčky
        let allToDashes = printerName
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if !nameSet.contains(allToDashes) { nameSet.append(allToDashes) }

        var urls: [URL] = []
        for name in nameSet {
            let filename = "com.apple.print.custompresets.forprinter.\(name).plist"
            urls.append(userPrefsDir.appendingPathComponent(filename))
            urls.append(sysPrefsDir.appendingPathComponent(filename))
        }
        return urls
    }

    // MARK: - Parsing

    private func parseFile(at url: URL) -> [SystemPrinterPreset]? {
        guard let data = try? Data(contentsOf: url),
              let raw  = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }

        // ── Nový formát: root = dict kde hodnoty s "com.apple.print.preset.settings" jsou presety ──
        if let rootDict = raw as? [String: Any] {
            // Zkontrolujeme jestli dict obsahuje preset záznamy
            let hasPresets = rootDict.values.contains {
                ($0 as? [String: Any])?["com.apple.print.preset.settings"] != nil
            }
            if hasPresets {
                return parseNewFormat(rootDict)
            }

            // ── Starý formát: dict s klíčem com.apple.print.customPresetsInfo ──
            if let arr = rootDict["com.apple.print.customPresetsInfo"] as? [[String: Any]] {
                return arr.compactMap { parsePresetOld($0) }
            }
        }

        // ── Nejstarší formát: root = array ──────────────────────────────────────
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { parsePresetOld($0) }
        }

        return nil
    }

    /// Parsuje nový formát (macOS 12+): root dict s preset záznamy
    private func parseNewFormat(_ rootDict: [String: Any]) -> [SystemPrinterPreset] {
        // Pořadí z customPresetsInfo (zachovává pořadí jak je macOS uložilo)
        let ordering: [String]
        if let ci = rootDict["com.apple.print.customPresetsInfo"] as? [[String: Any]] {
            ordering = ci.compactMap { $0["PresetName"] as? String }
        } else {
            ordering = rootDict.keys.filter {
                (rootDict[$0] as? [String: Any])?["com.apple.print.preset.settings"] != nil
            }.sorted()
        }

        return ordering.compactMap { presetID -> SystemPrinterPreset? in
            guard let presetEntry = rootDict[presetID] as? [String: Any],
                  let settings = presetEntry["com.apple.print.preset.settings"] as? [String: Any]
            else { return nil }
            return parsePresetNew(id: presetID, settings: settings)
        }
    }

    /// Parsuje jeden preset v novém formátu (com.apple.print.preset.settings)
    private func parsePresetNew(id: String, settings: [String: Any]) -> SystemPrinterPreset {
        var lp: [String] = []

        // ── Počet kopií ──────────────────────────────────────────────────────────
        if let copies = settings["com.apple.print.PrintSettings.PMCopies"] as? Int, copies > 1 {
            lp += ["-n", "\(copies)"]
        }

        // ── Oboustranný tisk ─────────────────────────────────────────────────────
        // Nový formát používá string "Duplex" (CUPS hodnoty)
        if let duplex = settings["Duplex"] as? String {
            switch duplex {
            case "DuplexNoTumble": lp += ["-o", "sides=two-sided-long-edge"]
            case "DuplexTumble":   lp += ["-o", "sides=two-sided-short-edge"]
            default:               lp += ["-o", "sides=one-sided"]
            }
        } else if let duplex = settings["com.apple.print.PrintSettings.PMDuplexing"] as? Int {
            switch duplex {
            case 2: lp += ["-o", "sides=two-sided-long-edge"]
            case 3: lp += ["-o", "sides=two-sided-short-edge"]
            default: lp += ["-o", "sides=one-sided"]
            }
        }

        // ── Orientace ────────────────────────────────────────────────────────────
        if let orient = settings["com.apple.print.PrintSettings.PMOrientation"] as? Int, orient == 2 {
            lp += ["-o", "orientation-requested=4"]
        }

        // ── Barevný model ─────────────────────────────────────────────────────────
        if let cm = settings["ColorModel"] as? String, !cm.isEmpty {
            lp += ["-o", "ColorModel=\(cm)"]
        }

        // ── Velikost papíru ───────────────────────────────────────────────────────
        // Zkusí EPIJ_PageRegion, EPIJ_PageSize, poté CUPS media key
        let paperKeys = ["EPIJ_PageRegion", "EPIJ_PageSize",
                         "com.apple.print.PageToPaperMappingMediaName"]
        for pk in paperKeys {
            if let paper = settings[pk] as? String, !paper.isEmpty, paper != "0" {
                lp += ["-o", "media=\(paper)"]
                break
            }
        }

        // ── Rozlišení ─────────────────────────────────────────────────────────────
        if let res = settings["Resolution"] as? String, !res.isEmpty {
            lp += ["-o", "Resolution=\(res)"]
        }

        // ── Typ média ─────────────────────────────────────────────────────────────
        if let mt = settings["MediaType"] as? String, mt != "0", !mt.isEmpty {
            lp += ["-o", "MediaType=\(mt)"]
        }

        // ── Vlastní ICC profil ────────────────────────────────────────────────────
        if let profiles = settings["PMCustomProfileDictionaryStr"] as? [String: Any],
           let profilePath = profiles.values.first as? String, !profilePath.isEmpty {
            lp += ["-o", "CustomProfile=\(profilePath)"]
        }

        // ── Řazení ───────────────────────────────────────────────────────────────
        if let collate = settings["com.apple.print.PrintSettings.PMCopyCollate"] as? Int {
            lp += ["-o", "Collate=\(collate == 1 ? "True" : "False")"]
        }

        return SystemPrinterPreset(id: id, name: id, lpOptions: lp)
    }

    /// Parsuje jeden preset ve starém formátu (PresetName + PrintSettings)
    private func parsePresetOld(_ dict: [String: Any]) -> SystemPrinterPreset? {
        guard let name = dict["PresetName"] as? String else { return nil }

        var lp: [String] = []
        let ps: [String: Any] = (dict["com.apple.print.PrintSettings"] as? [String: Any]) ?? dict

        if let copies = ps["com.apple.print.PrintSettings.PMCopies"] as? Int, copies > 1 {
            lp += ["-n", "\(copies)"]
        }

        if let duplex = ps["com.apple.print.PrintSettings.PMDuplex"] as? Int {
            switch duplex {
            case 1:  lp += ["-o", "sides=two-sided-long-edge"]
            case 2:  lp += ["-o", "sides=two-sided-short-edge"]
            default: lp += ["-o", "sides=one-sided"]
            }
        }

        if let collate = ps["com.apple.print.PrintSettings.PMCopyCollate"] as? Int {
            lp += ["-o", "Collate=\(collate == 1 ? "True" : "False")"]
        }

        if let pageFormat = dict["com.apple.print.PageFormat"] as? [String: Any],
           let orient = pageFormat["com.apple.print.PageFormat.PMOrientation"] as? Int,
           orient == 2 {
            lp += ["-o", "orientation-requested=4"]
        }

        if let pageFormat = dict["com.apple.print.PageFormat"] as? [String: Any],
           let paperDict = pageFormat["com.apple.print.PageFormat.PMPaper"] as? [String: Any],
           let paperName = paperDict["com.apple.print.PageFormat.PMPaperName"] as? String {
            lp += ["-o", "media=\(paperName)"]
        }

        let skip: Set<String> = ["PresetName", "PresetMenuName", "DocumentName"]
        for (key, value) in ps {
            guard !key.hasPrefix("com."), !key.hasPrefix("PMTicket"),
                  !skip.contains(key) else { continue }
            if let s = value as? String, !s.isEmpty {
                lp += ["-o", "\(key)=\(s)"]
            } else if let i = value as? Int {
                lp += ["-o", "\(key)=\(i)"]
            }
        }

        return SystemPrinterPreset(id: name, name: name, lpOptions: lp)
    }
}
