//
//  ImageAdjustService.swift
//  PrintManager
//
//  Barevné a tónové úpravy obrázků pomocí Core Image.
//  Nepotřebuje Python ani OpenCV.
//

import Foundation
import CoreImage
import AppKit

// MARK: - Metoda odstraňování pozadí

enum BGRemovalMethod: String, Codable, CaseIterable {
    case vision   = "Vision AI"
    case colorKey = "Barevný klíč"
}

// MARK: - Settings

struct ImageAdjustSettings: Equatable, Codable {
    // Tón
    var exposure:   Double = 0.0   // -3 … +3 EV
    var brightness: Double = 0.0   // -0.5 … +0.5
    var contrast:   Double = 1.0   // 0.5 … 2.0
    // Barvy
    var saturation: Double = 1.0   // 0 … 2.0
    var vibrance:   Double = 0.0   // -1 … +1
    var hue:        Double = 0.0   // -180 … +180 ° (UI), interně radány
    var temperature:Double = 0.0   // offset od 6500 K, -3000 … +3000
    // Rozsah tónů
    var shadows:        Double = 0.0   // 0 … 1   (lift stínů)
    var highlights:     Double = 0.0   // 0 … 1   (recovery světel, 1 = plný)
    var blackPoint:     Double = 0.0   // 0 … 0.3 (ořez tónové škály zespodu)
    var whitePoint:     Double = 1.0   // 0.7 … 1 (ořez tónové škály shora)
    // Detail
    var sharpness:      Double = 0.0   // 0 … 2.0
    var blur:           Double = 0.0   // 0 … 20 px
    var noiseReduction: Double = 0.0   // 0 … 0.1
    // Odstranění pozadí
    var removeBG:       Bool   = false
    var bgMethod:       BGRemovalMethod = .vision
    var bgKeyR:         Double = 1.0   // barva klíče (sRGB)
    var bgKeyG:         Double = 1.0
    var bgKeyB:         Double = 1.0
    var bgKeyTolerance: Double = 0.15  // 0 … 0.5

    var isDefault: Bool {
        exposure == 0 && brightness == 0 && contrast == 1 &&
        saturation == 1 && vibrance == 0 && hue == 0 &&
        temperature == 0 && shadows == 0 && highlights == 0 &&
        blackPoint == 0 && whitePoint == 1 &&
        sharpness == 0 && blur == 0 && noiseReduction == 0 &&
        !removeBG
    }
}

// MARK: - Presets

struct ImageAdjustPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var settings: ImageAdjustSettings
}

final class ImageAdjustPresetsStore: ObservableObject {
    static let shared = ImageAdjustPresetsStore()
    private let udKey = "imageAdjustPresets_v1"

    @Published private(set) var presets: [ImageAdjustPreset] = []

    private init() { load() }

    func save(_ preset: ImageAdjustPreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(_ preset: ImageAdjustPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([ImageAdjustPreset].self, from: data)
        else { return }
        presets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }
}

// MARK: - Service

class ImageAdjustService {
    static let shared = ImageAdjustService()
    private init() {}

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Filter pipeline

    func apply(_ settings: ImageAdjustSettings, to image: CIImage) -> CIImage {
        var img = image
        let originalExtent = img.extent

        // 0. Redukce šumu (před barevnými korekcemi, aby se nešum nezesiloval)
        if settings.noiseReduction > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": settings.noiseReduction,
                "inputSharpness":  0.4
            ])
        }

        // 1. Expozice
        if settings.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust",
                                     parameters: [kCIInputEVKey: settings.exposure])
        }

        // 2. Světla a stíny
        if settings.shadows != 0 || settings.highlights != 0 {
            let hlParam = 1.0 - settings.highlights * 0.25  // 1.0 (bez změny) → 0.75 (max recovery)
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": hlParam,
                "inputShadowAmount":    settings.shadows
            ])
        }

        // 3. Jas / Kontrast / Sytost
        if settings.brightness != 0 || settings.contrast != 1 || settings.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: settings.brightness,
                kCIInputContrastKey:   settings.contrast,
                kCIInputSaturationKey: settings.saturation
            ])
        }

        // 4. Černý / Bílý bod (tónová škála)
        if settings.blackPoint != 0 || settings.whitePoint != 1 {
            let bp    = Float(settings.blackPoint)
            let wp    = Float(settings.whitePoint)
            let range = max(0.001, wp - bp)
            let slope = Float(1.0 / range)
            let off   = Float(-bp / range)
            let coef  = CIVector(x: CGFloat(off), y: CGFloat(slope), z: 0, w: 0)
            img = img.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients":   coef,
                "inputGreenCoefficients": coef,
                "inputBlueCoefficients":  coef
            ])
        }

        // 5. Teplota barev
        if settings.temperature != 0 {
            let k = CGFloat(6500 + settings.temperature)
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: k,    y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }

        // 6. Odstín (hue rotation)
        if settings.hue != 0 {
            let rad = settings.hue * .pi / 180.0
            img = img.applyingFilter("CIHueAdjust",
                                     parameters: [kCIInputAngleKey: rad])
        }

        // 7. Živost (vibrance)
        if settings.vibrance != 0 {
            img = img.applyingFilter("CIVibrance",
                                     parameters: ["inputAmount": settings.vibrance])
        }

        // 8. Ostrost
        if settings.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: settings.sharpness,
                kCIInputRadiusKey:    1.69
            ])
        }

        // 9. Rozostření — CIGaussianBlur rozšiřuje extent, ořežeme zpět
        if settings.blur > 0 {
            img = img.applyingFilter("CIGaussianBlur",
                                     parameters: [kCIInputRadiusKey: settings.blur])
                .cropped(to: originalExtent)
        }

        // 10. Odstranění pozadí (poslední krok — pracuje s finálně upravenými barvami)
        if settings.removeBG {
            img = (try? applyBGRemoval(settings, to: img)) ?? img
        }

        return img
    }

    private func applyBGRemoval(_ settings: ImageAdjustSettings, to ci: CIImage) throws -> CIImage {
        let svc = BackgroundRemovalService.shared
        switch settings.bgMethod {
        case .vision:
            if #available(macOS 14.0, *) { return try svc.foregroundMaskCI(ci) }
            if #available(macOS 12.0, *) { return try svc.personMaskCI(ci) }
            // Fallback na color key na starých systémech
            fallthrough
        case .colorKey:
            return svc.colorKeyMask(ci,
                                    keyR: Float(settings.bgKeyR),
                                    keyG: Float(settings.bgKeyG),
                                    keyB: Float(settings.bgKeyB),
                                    tolerance: Float(settings.bgKeyTolerance))
        }
    }

    // MARK: - Náhled (zmenšený, v paměti)

    func preview(url: URL, settings: ImageAdjustSettings, maxSide: CGFloat = 1000) -> NSImage? {
        guard var ci = CIImage(contentsOf: url) else { return nil }
        let w = ci.extent.width, h = ci.extent.height
        if max(w, h) > maxSide {
            let s = maxSide / max(w, h)
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let out = apply(settings, to: ci)
        guard let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: out.extent.size)
    }

    // MARK: - Export (plné rozlišení)

    func export(url: URL, settings: ImageAdjustSettings) throws -> URL {
        guard let ci = CIImage(contentsOf: url) else {
            throw Err.loadFailed(url.lastPathComponent)
        }
        let out    = apply(settings, to: ci)
        let stem   = url.deletingPathExtension().lastPathComponent
        // Průhlednost (removeBG) vynucuje PNG; jinak zachováme původní formát
        let usePNG = settings.removeBG
        let ext    = usePNG ? "png" : (url.pathExtension.lowercased().isEmpty ? "jpg" : url.pathExtension.lowercased())
        let suffix = usePNG ? "_nobg" : "_adj"
        let outURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)\(suffix).\(ext)")

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { throw Err.renderFailed }

        if ext == "png" {
            guard let data = ciContext.pngRepresentation(of: out, format: .RGBA8,
                                                         colorSpace: cs) else {
                throw Err.renderFailed
            }
            try data.write(to: outURL)
        } else {
            let opts: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92
            ]
            guard let data = ciContext.jpegRepresentation(of: out, colorSpace: cs,
                                                          options: opts) else {
                throw Err.renderFailed
            }
            try data.write(to: outURL)
        }
        return outURL
    }

    // MARK: - Chyby

    enum Err: LocalizedError {
        case loadFailed(String)
        case renderFailed
        var errorDescription: String? {
            switch self {
            case .loadFailed(let n): return "Nelze načíst: \(n)"
            case .renderFailed:      return "Renderování selhalo."
            }
        }
    }
}
