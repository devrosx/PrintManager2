//
//  GalleryModels.swift
//  PrintManager
//
//  Datové modely pro funkci Create Gallery (sazba obrázků do PDF archu).
//

import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Paper Size

enum GalleryPaperSize: String, CaseIterable, Identifiable {
    // A-série
    case a8       = "A8 (52 × 74 mm)"
    case a7       = "A7 (74 × 105 mm)"
    case a6       = "A6 (105 × 148 mm)"
    case a5       = "A5 (148 × 210 mm)"
    case a4       = "A4 (210 × 297 mm)"
    case a3       = "A3 (297 × 420 mm)"
    // Ostatní
    case sra4     = "SRA4 (225 × 320 mm)"
    case sra3     = "SRA3 (320 × 450 mm)"
    case p480x320 = "480 × 320 mm"
    case letter   = "Letter (216 × 279 mm)"
    case postcard = "Pohlednice (148 × 105 mm)"
    case custom   = "Vlastní"

    var id: String { rawValue }

    /// true pro poslední A-formát (A3) – Picker vloží Divider za ním
    var isLastASeries: Bool { self == .a3 }
    /// true pro formáty před Vlastní
    var isLastOther: Bool   { self == .postcard }

    /// Velikost v mm (na výšku), šířka × výška
    var sizeMM: CGSize {
        switch self {
        case .a8:       return CGSize(width: 52,   height: 74)
        case .a7:       return CGSize(width: 74,   height: 105)
        case .a6:       return CGSize(width: 105,  height: 148)
        case .a5:       return CGSize(width: 148,  height: 210)
        case .a4:       return CGSize(width: 210,  height: 297)
        case .a3:       return CGSize(width: 297,  height: 420)
        case .sra4:     return CGSize(width: 225,  height: 320)
        case .sra3:     return CGSize(width: 320,  height: 450)
        case .p480x320: return CGSize(width: 320,  height: 480)
        case .letter:   return CGSize(width: 216,  height: 279)
        case .postcard: return CGSize(width: 148,  height: 105)
        case .custom:   return CGSize(width: 210,  height: 297)
        }
    }
}

// MARK: - Frame Size (předdefinované velikosti obrázků)

enum GalleryFrameSize: String, CaseIterable, Identifiable {
    case fill       = "Vyplnit stránku"
    // Foto formáty
    case s9x13      = "9 × 13 cm"
    case s10x15     = "10 × 15 cm"
    case s13x18     = "13 × 18 cm"
    case s15x21     = "15 × 21 cm"
    case s20x30     = "20 × 30 cm"
    case square10   = "10 × 10 cm (čtverec)"
    case square15   = "15 × 15 cm (čtverec)"
    // A-série
    case a8         = "A8 (52 × 74 mm)"
    case a7         = "A7 (74 × 105 mm)"
    case a6         = "A6 (105 × 148 mm)"
    case a5         = "A5 (148 × 210 mm)"
    case a4         = "A4 (210 × 297 mm)"
    case a3         = "A3 (297 × 420 mm)"
    // Ostatní standardní
    case sra4       = "SRA4 (225 × 320 mm)"
    case sra3       = "SRA3 (320 × 450 mm)"
    case p480x320   = "480 × 320 mm"
    case letter     = "Letter (216 × 279 mm)"
    case postcard   = "Pohlednice (148 × 105 mm)"
    case custom     = "Vlastní"

    var id: String { rawValue }

    /// Velikost rámečku v mm (šířka × výška v portrait orientaci)
    var sizeMM: CGSize? {
        switch self {
        case .fill:     return nil
        case .s9x13:    return CGSize(width: 90,  height: 130)
        case .s10x15:   return CGSize(width: 100, height: 150)
        case .s13x18:   return CGSize(width: 130, height: 180)
        case .s15x21:   return CGSize(width: 150, height: 210)
        case .s20x30:   return CGSize(width: 200, height: 300)
        case .square10: return CGSize(width: 100, height: 100)
        case .square15: return CGSize(width: 150, height: 150)
        case .a8:       return CGSize(width: 52,  height: 74)
        case .a7:       return CGSize(width: 74,  height: 105)
        case .a6:       return CGSize(width: 105, height: 148)
        case .a5:       return CGSize(width: 148, height: 210)
        case .a4:       return CGSize(width: 210, height: 297)
        case .a3:       return CGSize(width: 297, height: 420)
        case .sra4:     return CGSize(width: 225, height: 320)
        case .sra3:     return CGSize(width: 320, height: 450)
        case .p480x320: return CGSize(width: 320, height: 480)
        case .letter:   return CGSize(width: 216, height: 279)
        case .postcard: return CGSize(width: 148, height: 105)
        case .custom:   return nil
        }
    }
}

// MARK: - Orientation

enum GalleryOrientation: String, CaseIterable, Identifiable {
    case portrait  = "Na výšku"
    case landscape = "Na šířku"

    var id: String { rawValue }
}

// MARK: - Label Alignment

enum GalleryLabelAlignment: String, CaseIterable, Identifiable {
    case left   = "Vlevo"
    case center = "Na střed"
    case right  = "Vpravo"

    var id: String { rawValue }

    var swiftUIAlignment: Alignment {
        switch self { case .left: .leading; case .center: .center; case .right: .trailing }
    }
    var nsAlignment: NSTextAlignment {
        switch self { case .left: .left; case .center: .center; case .right: .right }
    }
    var textAlignment: TextAlignment {
        switch self { case .left: .leading; case .center: .center; case .right: .trailing }
    }
    /// InDesign JSX Justification konstanta
    var indesignJustification: String {
        switch self {
        case .left:   return "Justification.LEFT_ALIGN"
        case .center: return "Justification.CENTER_ALIGN"
        case .right:  return "Justification.RIGHT_ALIGN"
        }
    }
}

// MARK: - Crop Marks Style (stejné jako u Imposition)

enum GalleryCropMarkStyle: String, CaseIterable, Identifiable {
    case none    = "Žádné"
    case corner  = "Rohové"
    case full    = "Plné"

    var id: String { rawValue }
}

// MARK: - Settings

struct GallerySettings {
    // Papír
    var paperSize:       GalleryPaperSize    = .a4
    var orientation:     GalleryOrientation  = .portrait
    var customPaperW:    Double              = 210
    var customPaperH:    Double              = 297

    // Rámeček obrázku
    var frameSize:       GalleryFrameSize    = .s10x15
    var customFrameW:    Double              = 100
    var customFrameH:    Double              = 150

    // Mezery a okraje (mm)
    var marginTop:       Double              = 10
    var marginBottom:    Double              = 10
    var marginLeft:      Double              = 10
    var marginRight:     Double              = 10
    var gutterH:         Double              = 5    // mezera vodorovně
    var gutterV:         Double              = 5    // mezera svisle

    // Ořezové značky
    var addCropMarks:    Bool                = false
    var cropMarkLength:  Double              = 5    // mm
    var cropMarkOffset:  Double              = 2    // mm
    var cropMarkWidth:   Double              = 0.25 // pt

    // Linka okolo obrázku
    var addFrameBorder:  Bool                = false
    var frameBorderWidth: Double             = 0.5  // pt
    var frameBorderColor: Color              = .black

    // Rovnoměrné vyplnění stránky (auto cols/rows z počtu obrázků)
    var fillPageEvenly:  Bool                = false
    // Automaticky doplnit kopie obrázků aby se vyplnily všechny buňky na stránce
    var autoFillPage:    Bool                = false

    // Popisek obrázku (jméno souboru bez přípony)
    var showImageLabel:    Bool               = false
    var labelInside:       Bool               = false  // true = uvnitř obrázku (dole), false = pod obrázkem
    var labelFontName:     String             = "Helvetica Neue"
    var labelFontSize:     Double             = 9      // pt
    var labelColor:        Color              = .black
    var labelBackground:   Color              = .clear
    var labelAlignment:    GalleryLabelAlignment = .center

    /// Fyzická výška oblasti popisku v mm (vždy z velikosti fontu, nezávisle na pozici)
    var labelAreaHeightMM: Double {
        guard showImageLabel else { return 0 }
        return labelFontSize / 2.834645669 * 1.6 + 2.0
    }

    /// Výška extra prostoru pod rámečkem – 0 pokud je popisek uvnitř obrázku
    var effectiveLabelHeightMM: Double {
        (showImageLabel && !labelInside) ? labelAreaHeightMM : 0
    }

    // Uložení / převzorkování
    var resampleImages:  Bool                = true  // optimalizace na výslednou DPI

    // Computed: skutečná velikost papíru v mm (respektuje orientaci)
    var effectivePaperMM: CGSize {
        let base: CGSize
        if paperSize == .custom {
            base = CGSize(width: customPaperW, height: customPaperH)
        } else {
            base = paperSize.sizeMM
        }
        if orientation == .landscape {
            return CGSize(width: max(base.width, base.height),
                          height: min(base.width, base.height))
        } else {
            return CGSize(width: min(base.width, base.height),
                          height: max(base.width, base.height))
        }
    }

    /// Efektivní velikost rámečku v mm
    var effectiveFrameMM: CGSize? {
        if frameSize == .fill { return nil }
        if frameSize == .custom {
            return CGSize(width: customFrameW, height: customFrameH)
        }
        return frameSize.sizeMM
    }
}

// MARK: - Per-image pan/zoom state

struct GalleryImageState: Identifiable {
    let id: UUID
    let url: URL
    /// Offset středu viditelné plochy vůči středu obrázku (v mm od středu rámečku, normalizovaně)
    var panOffset: CGSize   = .zero
    /// Měřítko přiblížení (1.0 = vyplní rámeček)
    var zoom: Double        = 1.0
    // Původní rozměry obrázku v px (pro převzorkování)
    var pixelSize: CGSize   = .zero
    var dpi: Double         = 72
    /// Fit mode: obrázek se vejde celý do rámečku (vznikne bílé místo); false = fill (výchozí)
    var fitMode: Bool       = false
    /// Barva pozadí viditelná v fit módu (bílé místo)
    var fitBackground: Color = .white
    /// Manuální rotace nad rámec auto-rotace (0 / 90 / 180 / 270 stupňů)
    var extraRotation: Int  = 0
    /// Vlastní popisek; nil = použít jméno souboru bez přípony
    var customLabel: String? = nil

    /// Zobrazovaný text popisku
    var displayLabel: String {
        customLabel ?? url.deletingPathExtension().lastPathComponent
    }
}
