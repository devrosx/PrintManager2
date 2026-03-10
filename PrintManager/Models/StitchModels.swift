//
//  StitchModels.swift
//  PrintManager
//
//  Models for image stitching feature.
//

import Foundation

// MARK: - StitchSettings

struct StitchSettings {
    var features: StitchFeatureType = .orb
    var warpType: StitchWarpType = .plane
    var blendType: StitchBlendType = .multiband
    var workMegapix: Double = 0.6
    var confidenceThresh: Double = 0.8
}

enum StitchFeatureType: String, CaseIterable {
    case orb = "orb"
    case sift = "sift"
    case akaze = "akaze"

    var label: String {
        switch self {
        case .orb:   return "ORB"
        case .sift:  return "SIFT"
        case .akaze: return "AKAZE"
        }
    }
}

enum StitchWarpType: String, CaseIterable {
    case plane = "plane"
    case spherical = "spherical"
    case affine = "affine"

    var label: String {
        switch self {
        case .plane:     return "Plane"
        case .spherical: return "Spherical"
        case .affine:    return "Affine"
        }
    }
}

enum StitchBlendType: String, CaseIterable {
    case multiband = "multiband"
    case feather = "feather"
    case no = "no"

    var label: String {
        switch self {
        case .multiband: return "Multiband"
        case .feather:   return "Feather"
        case .no:        return "Bez blendingu"
        }
    }
}

// MARK: - StitchResult

struct StitchResult {
    let outputURL: URL
    let width: Int
    let height: Int
}

// MARK: - StitchError

enum StitchError: LocalizedError {
    case pythonNotFound
    case scriptNotFound
    case opencvNotInstalled
    case stitchingFailed(String)
    case notEnoughImages
    case tooManyImages
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Python 3 nebyl nalezen. Nainstalujte: brew install python@3.12"
        case .scriptNotFound:
            return "Skript stitch_images.py nebyl nalezen v bundle."
        case .opencvNotInstalled:
            return "OpenCV není nainstalováno. Nainstalujte: pip3 install opencv-python numpy"
        case .stitchingFailed(let msg):
            return "Spojení selhalo: \(msg)"
        case .notEnoughImages:
            return "Potřeba alespoň 2 obrázky pro spojení."
        case .tooManyImages:
            return "Maximálně 8 obrázků najednou."
        case .invalidOutput:
            return "Neplatný výstup z Python skriptu."
        }
    }
}
