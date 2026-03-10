//
//  DrawingsModels.swift
//  PrintManager
//
//  Models and enums for technical drawing processing
//

import Foundation
import CoreGraphics

// MARK: - Settings Model

/// Comprehensive settings for technical drawing processing pipeline
struct DrawingsSettings: Equatable {
    // Threshold settings
    var applyThreshold: Bool = false
    var thresholdMode: ThresholdMode = .auto
    var thresholdValue: Double = 0.5
    var brightnessBoost: Double = 0.0
    var contrastBoost: Double = 0.0

    // Crop settings
    var applyCrop: Bool = false
    var cropMode: CropMode = .autoDetect
    var cropSensitivity: Double = 0.5  // 0 = less sensitive, 1 = more sensitive
    var cropTopMargin: Double = 0.02
    var cropBottomMargin: Double = 0.02
    var cropLeftMargin: Double = 0.02
    var cropRightMargin: Double = 0.02

    // Deskew settings
    var applyDeskew: Bool = false
    var deskewWithCrop: Bool = true

    // Rotation settings
    var applyRotation: Bool = false
    var rotationSteps: Int = 1

    // Alignment settings
    var applyAlignment: Bool = false
    var alignmentFormat: PaperFormat = .a4
    var alignmentMode: AlignmentMode = .fit

    // Color conversion settings
    var applyColorConversion: Bool = false
    var colorMode: ColorMode = .grayscale

    // Noise reduction settings
    var applyNoiseReduction: Bool = false
    var noiseLevel: Double = 0.02
    var noiseSharpness: Double = 0.40

    // OCR settings (top-left origin, 0-1 normalized coordinates)
    var applyOCR: Bool = false
    var ocrUseCustomRegion: Bool = false
    var ocrRegionLeft: Double = 0.75
    var ocrRegionTop: Double = 0.75
    var ocrRegionWidth: Double = 0.25
    var ocrRegionHeight: Double = 0.25
}

// MARK: - Enums

/// Threshold calculation mode
enum ThresholdMode: Equatable {
    case auto    // Automatic Otsu threshold
    case manual  // User-specified threshold value
}

/// Standard paper formats with dimensions at 300 DPI
enum PaperFormat: String, CaseIterable, Equatable {
    case a5 = "A5"
    case a4 = "A4"
    case a3 = "A3"
    case a2 = "A2"
    case letter = "Letter"

    /// Returns the size in pixels at 300 DPI
    var sizeAt300DPI: CGSize {
        switch self {
        case .a5:     return CGSize(width: 1748,  height: 2480)
        case .a4:     return CGSize(width: 2480,  height: 3508)
        case .a3:     return CGSize(width: 3508,  height: 4961)
        case .a2:     return CGSize(width: 4961,  height: 7016)
        case .letter: return CGSize(width: 2550,  height: 3300)
        }
    }
}

/// Alignment mode for fitting image to paper format
enum AlignmentMode: String, CaseIterable, Equatable {
    case fit = "Fit"   // Fit entire image within format
    case fill = "Fill" // Fill entire format (may crop image)
}

/// Color mode for output
enum ColorMode: String, CaseIterable, Equatable {
    case bitmap = "Bitmapa"           // Black and white bitmap
    case grayscale = "Stupně šedi"    // Grayscale
    case color = "Barevné"            // Full color
}

/// Crop detection mode
enum CropMode: String, CaseIterable, Equatable {
    case autoDetect = "Automaticky"   // Automatic edge detection
    case manualMargins = "Ručně"      // Manual margin specification
}

// MARK: - Errors

/// Errors that can occur during drawing processing
enum DrawingsError: LocalizedError {
    case unsupportedFile
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Nepodporovaný formát souboru"
        case .processingFailed(let message):
            return "Zpracování selhalo: \(message)"
        }
    }
}
