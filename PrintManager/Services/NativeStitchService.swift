//
//  NativeStitchService.swift
//  PrintManager
//
//  Panorama stitch pomocí Apple Vision + Core Image.
//  Nepotřebuje Python ani OpenCV.
//

import Foundation
import Vision
import CoreImage
import AppKit
import simd

class NativeStitchService {
    static let shared = NativeStitchService()
    private init() {}

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Errors

    enum Err: LocalizedError {
        case notEnoughImages
        case loadFailed(String)
        case alignmentFailed
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .notEnoughImages:
                return "Potřeba alespoň 2 obrázky."
            case .loadFailed(let name):
                return "Nelze načíst obrázek: \(name)"
            case .alignmentFailed:
                return "Nepodařilo se zarovnat obrázky. Ujistěte se, že mají dostatečné překrytí (30–50 %) a dostatek textury."
            case .renderFailed:
                return "Renderování výsledku selhalo."
            }
        }
    }

    // MARK: - Public API

    /// Rychlý náhled při 20% rozlišení – vrátí NSImage bez uložení souboru.
    func preview(urls: [URL]) async throws -> NSImage {
        try await Task.detached(priority: .userInitiated) { [self] in
            let imgs = try loadImages(urls: urls, scale: 0.2)
            let result = try pipeline(imgs)
            return try toNSImage(result)
        }.value
    }

    /// Plné rozlišení – uloží JPG vedle prvního souboru a vrátí URL.
    func stitch(urls: [URL]) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { [self] in
            let imgs = try loadImages(urls: urls, scale: 1.0)
            let result = try pipeline(imgs)

            let outURL = urls[0].deletingLastPathComponent()
                .appendingPathComponent(
                    "\(urls[0].deletingPathExtension().lastPathComponent)_stitch.jpg"
                )
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = ciContext.jpegRepresentation(of: result, colorSpace: cs, options: [:]) else {
                throw Err.renderFailed
            }
            try data.write(to: outURL)
            return outURL
        }.value
    }

    // MARK: - Private pipeline

    private func loadImages(urls: [URL], scale: CGFloat) throws -> [CIImage] {
        try urls.map { url in
            guard let img = CIImage(contentsOf: url) else {
                throw Err.loadFailed(url.lastPathComponent)
            }
            return scale < 1.0
                ? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : img
        }
    }

    private func pipeline(_ images: [CIImage]) throws -> CIImage {
        guard images.count >= 2 else { throw Err.notEnoughImages }
        var result = images[0]
        for i in 1..<images.count {
            result = try alignAndComposite(base: result, floating: images[i])
        }
        return result
    }

    // MARK: - Vision alignment

    private func alignAndComposite(base: CIImage, floating: CIImage) throws -> CIImage {
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: base, options: [:])
        let handler = VNImageRequestHandler(ciImage: floating, options: [:])
        try handler.perform([request])

        guard let obs = request.results?.first as? VNImageHomographicAlignmentObservation,
              obs.confidence > 0.02 else {
            throw Err.alignmentFailed
        }

        let warped = warp(floating,
                          homography: obs.warpTransform,
                          floatingSize: floating.extent.size,
                          referenceSize: base.extent.size)

        // Expand canvas to hold both images
        let union = base.extent.union(warped.extent)
        let composite = base.composited(over: warped.cropped(to: union))
        return composite.cropped(to: union)
    }

    // MARK: - Perspective warp

    /// Aplikuje homografii H (Vision normalizované souřadnice floating → reference)
    /// a vrátí warped CIImage v souřadnicovém prostoru reference.
    private func warp(_ image: CIImage,
                      homography H: simd_float3x3,
                      floatingSize: CGSize,
                      referenceSize: CGSize) -> CIImage {
        let fw = Float(floatingSize.width)
        let fh = Float(floatingSize.height)
        let rw = CGFloat(referenceSize.width)
        let rh = CGFloat(referenceSize.height)

        func map(_ x: Float, _ y: Float) -> CGPoint {
            let v = H * SIMD3<Float>(x / fw, y / fh, 1)
            return CGPoint(x: CGFloat(v.x / v.z) * rw,
                           y: CGFloat(v.y / v.z) * rh)
        }

        let bl = map(0,  0)
        let br = map(fw, 0)
        let tr = map(fw, fh)
        let tl = map(0,  fh)

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return image }
        filter.setValue(image,                   forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: bl),   forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: br),   forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: tr),   forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: tl),   forKey: "inputTopLeft")
        return filter.outputImage ?? image
    }

    // MARK: - Render to NSImage

    private func toNSImage(_ ci: CIImage) throws -> NSImage {
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            throw Err.renderFailed
        }
        return NSImage(cgImage: cg, size: ci.extent.size)
    }
}
