//
//  ThumbnailCache.swift
//  PrintManager
//
//  Disk cache pro thumbnaily souborů.
//  Klíč = base64(cesta|mtime) — automaticky se invaliduje při změně souboru.
//  Záznamy starší 30 dní se při startu aplikace smažou.
//

import AppKit
import Foundation

class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let dir: URL

    private init() {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrintManager/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
        pruneOldEntries()
    }

    // MARK: - Public API

    /// Načte thumbnail z disku. Vrátí nil pokud není v cache nebo soubor byl změněn.
    func thumbnail(for url: URL) -> NSImage? {
        let file = cacheFile(for: url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(contentsOf: file)
    }

    /// Uloží thumbnail na disk.
    func store(_ image: NSImage, for url: URL) {
        let file = cacheFile(for: url)
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file)
    }

    // MARK: - Private

    private func cacheFile(for url: URL) -> URL {
        dir.appendingPathComponent(cacheKey(for: url) + ".png")
    }

    /// Klíč obsahuje cestu a čas modifikace → při změně souboru je klíč jiný.
    private func cacheKey(for url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let ts    = mtime.map { Int64($0.timeIntervalSince1970) } ?? 0
        let raw   = "\(url.path)|\(ts)"
        return (raw.data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: ""))
            ?? String(abs(raw.hashValue))
    }

    /// Smaže záznamy starší než 30 dní na pozadí.
    private func pruneOldEntries() {
        DispatchQueue.global(qos: .background).async { [dir] in
            let fm     = FileManager.default
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            for f in files {
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m = mtime, m < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}
