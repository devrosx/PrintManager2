//
//  BackgroundRemovalService.swift
//  PrintManager
//
//  Odstranění pozadí — tři metody:
//  • Vision AI macOS 14+:  VNGenerateForegroundInstanceMaskRequest (libovolné objekty)
//  • Vision AI macOS 12–13: VNGeneratePersonSegmentationRequest    (osoby)
//  • Barevný klíč:          CIColorCube — bez závislosti na verzi macOS
//

import Foundation
import Vision
import CoreImage
import AppKit

class BackgroundRemovalService {
    static let shared = BackgroundRemovalService()
    private init() {}

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Dostupnost Vision

    static var visionSupported: Bool {
        if #available(macOS 12.0, *) { return true }
        return false
    }

    // MARK: - Standalone URL API (menu akce)

    func removeBackground(from url: URL) throws -> URL {
        guard let ci = CIImage(contentsOf: url) else { throw Err.loadFailed(url.lastPathComponent) }
        let masked = try applyVision(ci)
        return try savePNG(masked, near: url)
    }

    // MARK: - Vision CI→CI (interně volané z pipeline)

    @available(macOS 14.0, *)
    func foregroundMaskCI(_ ci: CIImage) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first as? VNInstanceMaskObservation else { throw Err.noSubject }
        let buf = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        return blendWithMask(CIImage(cvPixelBuffer: buf), over: ci)
    }

    @available(macOS 12.0, *)
    func personMaskCI(_ ci: CIImage) throws -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first as? VNPixelBufferObservation else { throw Err.noSubject }
        let raw = CIImage(cvPixelBuffer: obs.pixelBuffer)
        let sx  = ci.extent.width  / raw.extent.width
        let sy  = ci.extent.height / raw.extent.height
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return blendWithMask(scaled, over: ci)
    }

    // MARK: - Barevný klíč (verze-nezávislé, CIColorCube)

    /// Odstraní pixely blízké zadané barvě.
    /// `tolerance` 0–1 (doporučeno 0.08–0.25), `softness` = šířka přechodu.
    func colorKeyMask(_ ci: CIImage,
                      keyR: Float, keyG: Float, keyB: Float,
                      tolerance: Float,
                      softness: Float = 0.04) -> CIImage {
        let size = 32
        let count = size * size * size * 4
        var cube = [Float](repeating: 0, count: count)

        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let fr = Float(r) / Float(size - 1)
                    let fg = Float(g) / Float(size - 1)
                    let fb = Float(b) / Float(size - 1)

                    // Vzdálenost od klíčové barvy (normalizovaná na 0–1)
                    let dist = sqrt( pow(fr - keyR, 2) + pow(fg - keyG, 2) + pow(fb - keyB, 2) )
                               / sqrt(3)

                    // Plynulý přechod: 0 = průhledné, 1 = neprůhledné
                    let alpha: Float
                    if dist < tolerance {
                        alpha = 0
                    } else if dist < tolerance + softness {
                        alpha = (dist - tolerance) / softness
                    } else {
                        alpha = 1
                    }

                    let idx = (b * size * size + g * size + r) * 4
                    cube[idx + 0] = fr * alpha  // premultiplied RGBA
                    cube[idx + 1] = fg * alpha
                    cube[idx + 2] = fb * alpha
                    cube[idx + 3] = alpha
                }
            }
        }

        let data = Data(bytes: cube, count: count * MemoryLayout<Float>.size) as NSData
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData":      data,
            "inputColorSpace":    CGColorSpace(name: CGColorSpace.sRGB) as Any,
            kCIInputImageKey:     ci
        ]) else { return ci }
        return filter.outputImage ?? ci
    }

    // MARK: - Detekce barvy pozadí (průměr rohů)

    /// Odhadne barvu pozadí vzorkováním čtyř rohů obrázku.
    func detectBGColor(_ ci: CIImage) -> (r: Float, g: Float, b: Float) {
        let ext = ci.extent
        let sz  = min(20.0, min(ext.width, ext.height) / 8)
        let corners: [CGRect] = [
            CGRect(x: ext.minX,        y: ext.minY,        width: sz, height: sz),
            CGRect(x: ext.maxX - sz,   y: ext.minY,        width: sz, height: sz),
            CGRect(x: ext.minX,        y: ext.maxY - sz,   width: sz, height: sz),
            CGRect(x: ext.maxX - sz,   y: ext.maxY - sz,   width: sz, height: sz)
        ]

        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0, n: Float = 0
        for corner in corners {
            guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey:   ci.cropped(to: corner),
                kCIInputExtentKey:  CIVector(cgRect: corner)
            ])?.outputImage else { continue }

            var px = [Float](repeating: 0, count: 4)
            ciContext.render(avg, toBitmap: &px, rowBytes: 16,
                             bounds: avg.extent,
                             format: .RGBAf,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            sumR += px[0]; sumG += px[1]; sumB += px[2]; n += 1
        }
        return n > 0 ? (sumR/n, sumG/n, sumB/n) : (1, 1, 1)
    }

    // MARK: - Helpers

    func blendWithMask(_ mask: CIImage, over image: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey:       mask
        ])
    }

    func savePNG(_ ciImage: CIImage, near url: URL) throws -> URL {
        let stem   = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_nobg.png")
        guard let cs   = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.pngRepresentation(of: ciImage, format: .RGBA8,
                                                    colorSpace: cs) else {
            throw Err.renderFailed
        }
        try data.write(to: outURL)
        return outURL
    }

    private func applyVision(_ ci: CIImage) throws -> CIImage {
        if #available(macOS 14.0, *) { return try foregroundMaskCI(ci) }
        if #available(macOS 12.0, *) { return try personMaskCI(ci) }
        throw Err.unsupported
    }

    // MARK: - Chyby

    enum Err: LocalizedError {
        case loadFailed(String), noSubject, renderFailed, unsupported
        var errorDescription: String? {
            switch self {
            case .loadFailed(let n): return "Nelze načíst: \(n)"
            case .noSubject:         return "Nepodařilo se detekovat popředí."
            case .renderFailed:      return "Uložení PNG selhalo."
            case .unsupported:       return "Vyžaduje macOS 12 nebo novější."
            }
        }
    }
}
