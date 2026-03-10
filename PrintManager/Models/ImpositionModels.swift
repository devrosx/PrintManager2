//
//  ImpositionModels.swift
//  PrintManager
//
//  Data models for PDF Imposition (digital layout / montáž)
//

import Foundation
import CoreGraphics
import PDFKit

// MARK: - Imposition Mode

enum ImpositionMode: String, CaseIterable, Identifiable {
    case nUp        = "N-up"
    case stepRepeat = "Step-Repeat"
    case booklet    = "Booklet"
    case cutStacks  = "Cut Stacks"

    var id: String { rawValue }
}

// MARK: - Paper Size

enum ImpositionPaperSize: String, CaseIterable, Identifiable {
    case a5         = "A5 (148 × 210 mm)"
    case a4         = "A4 (210 × 297 mm)"
    case a3         = "A3 (297 × 420 mm)"
    case sra4       = "SRA4 (225 × 320 mm)"
    case sra3       = "SRA3 (320 × 450 mm)"
    case w480x320   = "480 × 320 mm"
    case letter     = "Letter (216 × 279 mm)"
    case tabloid    = "Tabloid (279 × 432 mm)"
    case custom     = "Custom"

    var id: String { rawValue }

    /// Size in points (portrait orientation). 1 pt = 1/72 inch; 1 mm ≈ 2.834645669 pt
    var size: CGSize {
        let pt = { (mm: Double) -> CGFloat in CGFloat(mm * 2.834645669) }
        switch self {
        case .a5:       return CGSize(width: pt(148), height: pt(210))
        case .a4:       return CGSize(width: pt(210), height: pt(297))
        case .a3:       return CGSize(width: pt(297), height: pt(420))
        case .sra4:     return CGSize(width: pt(225), height: pt(320))
        case .sra3:     return CGSize(width: pt(320), height: pt(450))
        case .w480x320: return CGSize(width: pt(320), height: pt(480))   // portrait base; landscape = 480×320
        case .letter:   return CGSize(width: pt(216), height: pt(279))
        case .tabloid:  return CGSize(width: pt(279), height: pt(432))
        case .custom:   return CGSize(width: pt(210), height: pt(297))
        }
    }
}

// MARK: - Orientation

enum ImpositionOrientation: String, CaseIterable, Identifiable {
    case portrait  = "Portrait"
    case landscape = "Landscape"
    case auto      = "Auto"

    var id: String { rawValue }
}

// MARK: - PDF Box

/// Which PDF page bounding box to use for placement
enum ImpositionPDFBox: String, CaseIterable, Identifiable {
    case media  = "Media Box"
    case crop   = "Crop Box"
    case bleed  = "Bleed Box"
    case trim   = "Trim Box"
    case art    = "Art Box"

    var id: String { rawValue }

    var pdfKitBox: PDFDisplayBox {
        switch self {
        case .media:  return .mediaBox
        case .crop:   return .cropBox
        case .bleed:  return .bleedBox
        case .trim:   return .trimBox
        case .art:    return .artBox
        }
    }
}

// MARK: - Margins

struct ImpositionMargins {
    var top:    Double = 8
    var bottom: Double = 8
    var left:   Double = 8
    var right:  Double = 8
}

// MARK: - Settings

struct ImpositionSettings {
    var mode:              ImpositionMode        = .nUp
    var columns:           Int                   = 2
    var rows:              Int                   = 2
    var paperSize:         ImpositionPaperSize   = .a4
    var orientation:       ImpositionOrientation = .auto
    var margins:           ImpositionMargins     = ImpositionMargins()
    var gutterH:           Double                = 4     // mm (jen kladné)
    var gutterV:           Double                = 4     // mm (jen kladné)
    /// Ořez PDF dovnitř ze všech stran (v mm). Ořeže viditelnou plochu každé stránky.
    var cropInsetMM:       Double                = 0     // mm
    /// Scale in % — used as literal size when fitToPage=false, or as fraction of fit when fitToPage=true
    var scale:             Double                = 100
    /// false = 100 % natural size (clips if larger than cell); true = scale to fill frame
    var fitToPage:         Bool                  = false
    /// Which PDF bounding box to use for page placement
    var pdfBox:            ImpositionPDFBox      = .media
    /// Custom paper size in mm (used when paperSize == .custom)
    var customWidth:       Double                = 210
    var customHeight:      Double                = 297
    var autoRotate:        Bool                  = true
    var useManualFrameSize: Bool                 = false
    var manualFrameWidth:  Double                = 100  // mm
    var manualFrameHeight: Double                = 100  // mm
    var addCropMarks:      Bool                  = false
    var cropMarkLength:    Double                = 5     // mm
    var cropMarkOffset:    Double                = 2     // mm
    var cropMarkLineWidth: Double                = 0.25  // pt
    /// Tenkā šedá linka (0,5 pt, 50 % šedá) okolo každého rámečku objektu
    var addFrameBorder:    Bool                  = false
    /// Velikost stránky v bodech (pt) — nastavuje se z PDF při otevření dialogu.
    /// Používá se pro výchozí 1:1 rámeček (fitToPage=false, useManualFrameSize=false).
    var sourcePageSizePt: CGSize? = nil
}

// MARK: - Result

struct ImpositionResult {
    let outputURL:     URL
    let sheetCount:    Int
    let pagesPerSheet: Int
}
