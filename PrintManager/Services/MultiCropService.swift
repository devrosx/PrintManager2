//
//  MultiCropService.swift
//  PrintManager
//
//  Rozřeže naskenovaný obrázek (A3/A4 bílé pozadí) na jednotlivé fotografie.
//
//  Algoritmus: threshold + connected components + convex-hull bounding rectangle.
//  Na rozdíl od VNDetectRectanglesRequest (který hledá jakékoliv obdélníky —
//  okna, rámečky, texty…) tento přístup hledá TMAVÉ OBLASTI na BÍLÉM POZADÍ,
//  což přesně odpovídá fotkám položeným na skeneru.
//
//  Žádné externí závislosti.
//

import Foundation
import CoreImage
import AppKit

// MARK: - Detected Quad (nahrazuje VNRectangleObservation)

/// Normalizovaný čtyřúhelník (0–1, počátek vlevo dole, y nahoru — stejně jako Vision).
struct DetectedQuad {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
}

// MARK: - Detected Photo

struct DetectedPhoto: Identifiable {
    let id = UUID()
    let quad: DetectedQuad
    let croppedImage: NSImage
    var rotationCCW: Double = 0

    var displayImage: NSImage {
        rotationCCW == 0 ? croppedImage : DetectedPhoto.rotate(croppedImage, ccwDegrees: rotationCCW)
    }

    mutating func rotateCW90() {
        rotationCCW = (rotationCCW - 90).truncatingRemainder(dividingBy: 360)
        if rotationCCW < 0 { rotationCCW += 360 }
    }

    static func rotate(_ image: NSImage, ccwDegrees: Double) -> NSImage {
        guard ccwDegrees != 0,
              let tiff = image.tiffRepresentation,
              let src = NSBitmapImageRep(data: tiff),
              let cg = src.cgImage else { return image }

        var ci = CIImage(cgImage: cg)
        let radians = CGFloat(ccwDegrees) * .pi / 180
        ci = ci.transformed(by: CGAffineTransform(rotationAngle: radians))
        ci = ci.transformed(by: CGAffineTransform(
            translationX: -ci.extent.minX, y: -ci.extent.minY))

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = ctx.createCGImage(ci, from: ci.extent) else { return image }
        return NSImage(cgImage: result,
                       size: NSSize(width: result.width, height: result.height))
    }
}

// MARK: - Service

class MultiCropService {

    /// Rozlišení pro zpracování (delší strana v pixelech).
    private let processingSize = 1000

    // MARK: - Public API

    func detect(
        imageURL: URL,
        sensitivity: Float = 0.5,
        minRelativeSize: Float = 0.04,
        maxRelativeSize: Float = 0.50,
        maxCount: Int = 20,
        trimFactor: Double = 0.020
    ) async throws -> [DetectedPhoto] {
        guard let ciImage = CIImage(contentsOf: imageURL) else {
            throw MultiCropError.cannotLoadImage
        }

        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

        // ── 1. Downscale & grayscale ────────────────────────────────────────
        guard let fullCG = ciCtx.createCGImage(ciImage, from: ciImage.extent) else {
            throw MultiCropError.cannotLoadImage
        }
        let longer = max(ciImage.extent.width, ciImage.extent.height)
        let scale  = min(1.0, CGFloat(processingSize) / longer)
        let procW  = Int(ciImage.extent.width * scale)
        let procH  = Int(ciImage.extent.height * scale)

        let gray = grayscaleBitmap(from: fullCG, width: procW, height: procH)

        try Task.checkCancellation()

        // ── 2. Threshold ────────────────────────────────────────────────────
        //    Threshold je mírně vyšší při nižší citlivosti (detekuje jen velmi tmavé)
        //    a nižší při vyšší citlivosti (detekuje i světlejší fotky).
        //    sensitivity 0.1 → threshold ~205 (střídmý)
        //    sensitivity 0.9 → threshold ~232 (zachytí i světlejší plochy)
        let threshold = UInt8(clamping: Int(200.0 + Double(sensitivity) * 35.0))
        var foreground = [Bool](repeating: false, count: procW * procH)
        for i in 0..<gray.count {
            foreground[i] = gray[i] < threshold
        }

        // ── 3. Morfologický close (vyplní díry uvnitř fotek) ────────────────
        //    Radius závisí inverzně na citlivosti:
        //    sensitivity=Více(0.9) → radius=1 → fotky zůstávají odděleny
        //    sensitivity=Méně(0.1) → radius=6 → větší uzávěr mezer
        let morphRadius = Int(max(1.0, round(7.0 * (1.0 - Double(sensitivity)))))
        dilateInPlace(&foreground, width: procW, height: procH, radius: morphRadius)
        erodeInPlace(&foreground, width: procW, height: procH, radius: morphRadius)
        fillHoles(&foreground, width: procW, height: procH)

        try Task.checkCancellation()

        // ── 4. Connected components ─────────────────────────────────────────
        let components = connectedComponents(foreground, width: procW, height: procH)

        // ── 5. Filtrovat podle velikosti, seřadit od největšího ─────────────
        let totalPixels = procW * procH
        let minPixels = Int(Float(totalPixels) * minRelativeSize)
        let maxPixels = Int(Float(totalPixels) * maxRelativeSize)
        let valid = components
            .filter { $0.area >= minPixels && $0.area <= maxPixels }
            .sorted { $0.area > $1.area }
            .prefix(maxCount)

        try Task.checkCancellation()

        // ── 6. Pro každou oblast: convex hull → bounding quad → ořez ────────
        var results: [DetectedPhoto] = []

        for comp in valid {
            guard !Task.isCancelled else { break }

            let hull = convexHull(comp.boundary)
            guard hull.count >= 4 else { continue }

            let rect = minAreaBoundingRect(hull)

            // Normalizovat do Vision souřadnic (0–1, y-up)
            let quad = normalizeToVision(rect, width: procW, height: procH)

            guard let cropped = perspectiveCrop(
                ciImage, quad: quad, context: ciCtx, trimFactor: trimFactor
            ) else { continue }

            results.append(DetectedPhoto(quad: quad, croppedImage: cropped))
        }

        return results
    }

    func save(_ photos: [DetectedPhoto], basedOn sourceURL: URL) throws -> [URL] {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext  = sourceURL.pathExtension.lowercased()
        let dir  = sourceURL.deletingLastPathComponent()

        var urls: [URL] = []
        for (i, photo) in photos.enumerated() {
            let outputExt = (ext == "png") ? "png" : "jpg"
            let url = dir.appendingPathComponent("\(base)_\(i + 1).\(outputExt)")
            let imageToSave = photo.displayImage
            guard let tiff = imageToSave.tiffRepresentation,
                  let rep  = NSBitmapImageRep(data: tiff)
            else { continue }
            let data: Data?
            if outputExt == "png" {
                data = rep.representation(using: .png, properties: [:])
            } else {
                data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            }
            if let data {
                try data.write(to: url)
                urls.append(url)
            }
        }
        if urls.isEmpty { throw MultiCropError.noPhotosFound }
        return urls
    }

    // MARK: - Grayscale bitmap

    private func grayscaleBitmap(from cgImage: CGImage, width w: Int, height h: Int) -> [UInt8] {
        var gray = [UInt8](repeating: 255, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &gray, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: cs, bitmapInfo: 0
        ) else { return gray }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return gray
    }

    // MARK: - Morphological operations

    private func dilateInPlace(_ bmp: inout [Bool], width w: Int, height h: Int, radius r: Int) {
        // Horizontal pass
        var tmp = bmp
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                if bmp[row + x] { continue }
                let lo = max(0, x - r), hi = min(w - 1, x + r)
                for dx in lo...hi {
                    if bmp[row + dx] { tmp[row + x] = true; break }
                }
            }
        }
        // Vertical pass
        bmp = tmp
        for y in 0..<h {
            for x in 0..<w {
                if tmp[y * w + x] { continue }
                let lo = max(0, y - r), hi = min(h - 1, y + r)
                for dy in lo...hi {
                    if tmp[dy * w + x] { bmp[y * w + x] = true; break }
                }
            }
        }
    }

    private func erodeInPlace(_ bmp: inout [Bool], width w: Int, height h: Int, radius r: Int) {
        // Horizontal pass
        var tmp = bmp
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                guard bmp[row + x] else { continue }
                let lo = max(0, x - r), hi = min(w - 1, x + r)
                for dx in lo...hi {
                    if !bmp[row + dx] { tmp[row + x] = false; break }
                }
            }
        }
        // Vertical pass
        bmp = tmp
        for y in 0..<h {
            for x in 0..<w {
                guard tmp[y * w + x] else { continue }
                let lo = max(0, y - r), hi = min(h - 1, y + r)
                for dy in lo...hi {
                    if !tmp[dy * w + x] { bmp[y * w + x] = false; break }
                }
            }
        }
    }

    /// Vyplní díry (uzavřené oblasti pozadí uvnitř popředí).
    private func fillHoles(_ bmp: inout [Bool], width w: Int, height h: Int) {
        var exterior = [Bool](repeating: false, count: w * h)
        var queue: [(Int, Int)] = []

        // Seed: všechny okrajové background pixely
        for x in 0..<w {
            if !bmp[x]              { exterior[x] = true; queue.append((x, 0)) }
            let b = (h - 1) * w + x
            if !bmp[b]              { exterior[b] = true; queue.append((x, h - 1)) }
        }
        for y in 1..<(h - 1) {
            if !bmp[y * w]          { exterior[y * w] = true; queue.append((0, y)) }
            let r = y * w + w - 1
            if !bmp[r]              { exterior[r] = true; queue.append((w - 1, y)) }
        }

        // BFS — najdi veškerý vnější background
        var qi = 0
        while qi < queue.count {
            let (x, y) = queue[qi]; qi += 1
            for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
                guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                let idx = ny * w + nx
                if !bmp[idx] && !exterior[idx] {
                    exterior[idx] = true
                    queue.append((nx, ny))
                }
            }
        }

        // Vyplň: background pixel který není externím = díra uvnitř fotky
        for i in 0..<bmp.count {
            if !bmp[i] && !exterior[i] { bmp[i] = true }
        }
    }

    // MARK: - Connected components

    private struct Component {
        var area: Int = 0
        var boundary: [CGPoint] = []
    }

    private func connectedComponents(_ bmp: [Bool], width w: Int, height h: Int) -> [Component] {
        var labels = [Int](repeating: -1, count: w * h)
        var comps: [Component] = []
        var label = 0

        for startY in 0..<h {
            for startX in 0..<w {
                let startIdx = startY * w + startX
                guard bmp[startIdx] && labels[startIdx] == -1 else { continue }

                var comp = Component()
                var queue = [(startX, startY)]
                labels[startIdx] = label
                var qi = 0

                while qi < queue.count {
                    let (x, y) = queue[qi]; qi += 1
                    comp.area += 1

                    var isBoundary = false
                    for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
                        if nx < 0 || nx >= w || ny < 0 || ny >= h {
                            isBoundary = true; continue
                        }
                        let nIdx = ny * w + nx
                        if !bmp[nIdx] {
                            isBoundary = true
                        } else if labels[nIdx] == -1 {
                            labels[nIdx] = label
                            queue.append((nx, ny))
                        }
                    }
                    if isBoundary {
                        comp.boundary.append(CGPoint(x: x, y: y))
                    }
                }

                comps.append(comp)
                label += 1
            }
        }
        return comps
    }

    // MARK: - Convex hull (Andrew's monotone chain)

    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    // MARK: - Minimum area bounding rectangle (rotating calipers)

    /// Vrátí 4 rohy (v souřadnicích zpracovávacího bitmapu — pixely, y dolů).
    private func minAreaBoundingRect(_ hull: [CGPoint]) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        guard hull.count >= 3 else {
            let xs = hull.map(\.x), ys = hull.map(\.y)
            let mn = CGPoint(x: xs.min()!, y: ys.min()!)
            let mx = CGPoint(x: xs.max()!, y: ys.max()!)
            return (mn, CGPoint(x: mx.x, y: mn.y), CGPoint(x: mn.x, y: mx.y), mx)
        }

        var bestArea = CGFloat.greatestFiniteMagnitude
        var best: (CGPoint, CGPoint, CGPoint, CGPoint) = (.zero, .zero, .zero, .zero)

        for i in 0..<hull.count {
            let j = (i + 1) % hull.count
            let edge = CGPoint(x: hull[j].x - hull[i].x, y: hull[j].y - hull[i].y)
            let angle = atan2(edge.y, edge.x)
            let cosA = cos(-angle), sinA = sin(-angle)

            var minRX = CGFloat.greatestFiniteMagnitude
            var maxRX = -CGFloat.greatestFiniteMagnitude
            var minRY = CGFloat.greatestFiniteMagnitude
            var maxRY = -CGFloat.greatestFiniteMagnitude

            for p in hull {
                let rx = p.x * cosA - p.y * sinA
                let ry = p.x * sinA + p.y * cosA
                minRX = min(minRX, rx); maxRX = max(maxRX, rx)
                minRY = min(minRY, ry); maxRY = max(maxRY, ry)
            }

            let area = (maxRX - minRX) * (maxRY - minRY)
            if area < bestArea {
                bestArea = area
                let cosB = cos(angle), sinB = sin(angle)
                func unrot(_ rx: CGFloat, _ ry: CGFloat) -> CGPoint {
                    CGPoint(x: rx * cosB - ry * sinB, y: rx * sinB + ry * cosB)
                }
                // 4 rohy AABB v rotovaném prostoru → zpět do pixelových souřadnic
                best = (unrot(minRX, minRY), unrot(maxRX, minRY),
                        unrot(minRX, maxRY), unrot(maxRX, maxRY))
            }
        }
        return best
    }

    // MARK: - Coordinate conversion

    /// Převede 4 pixelové body (y-dolů) na normalizované Vision souřadnice (y-nahoru, 0–1).
    /// Zároveň přiřadí správné labely: topLeft/topRight/bottomLeft/bottomRight.
    private func normalizeToVision(
        _ rect: (CGPoint, CGPoint, CGPoint, CGPoint),
        width: Int, height: Int
    ) -> DetectedQuad {
        let corners = [rect.0, rect.1, rect.2, rect.3].map { p in
            CGPoint(x: p.x / CGFloat(width),
                    y: 1.0 - p.y / CGFloat(height))   // flip y
        }
        // Seřadit: horní dva (větší y) a spodní dva (menší y)
        let sorted = corners.sorted { $0.y > $1.y }
        let top    = Array(sorted.prefix(2)).sorted { $0.x < $1.x }
        let bottom = Array(sorted.suffix(2)).sorted { $0.x < $1.x }

        return DetectedQuad(
            topLeft: top[0], topRight: top[1],
            bottomLeft: bottom[0], bottomRight: bottom[1]
        )
    }

    // MARK: - Perspective correction

    private func perspectiveCrop(
        _ ciImage: CIImage,
        quad: DetectedQuad,
        context: CIContext,
        trimFactor: Double
    ) -> NSImage? {
        let ext = ciImage.extent

        func toCI(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * ext.width + ext.origin.x,
                     y: p.y * ext.height + ext.origin.y)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage,                  forKey: kCIInputImageKey)
        filter.setValue(toCI(quad.topLeft),       forKey: "inputTopLeft")
        filter.setValue(toCI(quad.topRight),      forKey: "inputTopRight")
        filter.setValue(toCI(quad.bottomLeft),    forKey: "inputBottomLeft")
        filter.setValue(toCI(quad.bottomRight),   forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return nil }

        let trim = Swift.max(2, Swift.min(output.extent.width, output.extent.height) * CGFloat(trimFactor))
        let trimRect = output.extent.insetBy(dx: trim, dy: trim)
        let trimmed = output.cropped(to: trimRect)

        guard let cgImg = context.createCGImage(trimmed, from: trimmed.extent) else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }
}

// MARK: - Errors

enum MultiCropError: LocalizedError {
    case cannotLoadImage
    case noPhotosFound

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage: return "Nelze načíst obrázek."
        case .noPhotosFound:   return "Nebyly nalezeny žádné fotografie."
        }
    }
}
