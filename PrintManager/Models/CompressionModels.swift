//
//  CompressionModels.swift
//  PrintManager
//
//  Models for PDF compression functionality
//

import Foundation

/// Settings for PDF compression
struct CompressionSettings: Codable {
    var quality: Quality = .medium
    var imageQuality: ImageQuality = .medium
    var removeMetadata: Bool = true
    var removeBookmarks: Bool = false
    var removeThumbnails: Bool = true
    var compressFonts: Bool = true
    var downsampleImages: Bool = true
    var imageDPI: Int = 150
    var dpi: Int = 150
    var compressImages: Bool = true
    var flattenTransparency: Bool = true
    var subsetFonts: Bool = true
    var linearize: Bool = false
    var optimizeForPrint: Bool = false
    var preserveText: Bool = true
    
    enum Quality: String, Codable, CaseIterable {
        case veryLow = "verylow"
        case low = "low"
        case medium = "medium"
        case high = "high"
        case veryHigh = "veryhigh"
        case minimal = "minimal"
        
        var displayName: String {
            switch self {
            case .veryLow: return "Very Low"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .veryHigh: return "Very High"
            case .minimal: return "Minimal"
            }
        }
        
        var description: String {
            switch self {
            case .veryLow: return "Maximum compression, lowest quality"
            case .low: return "High compression, reduced quality"
            case .medium: return "Balanced compression and quality"
            case .high: return "Low compression, high quality"
            case .veryHigh: return "Minimal compression, best quality"
            case .minimal: return "Maximum compression, minimal quality"
            }
        }
    }
    
    enum ImageQuality: String, Codable, CaseIterable {
        case veryLow = "verylow"
        case low = "low"
        case medium = "medium"
        case high = "high"
        case minimal = "minimal"
        
        var displayName: String {
            switch self {
            case .veryLow: return "Very Low"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .minimal: return "Minimal"
            }
        }
    }
    
    func levelDescription() -> String {
        return "\(quality.displayName) (\(imageQuality.displayName) images)"
    }
}

/// Result of a compression operation
struct CompressionResult: Codable {
    let originalSize: Int64
    let compressedSize: Int64
    let compressionRatio: Double
    let processingTime: TimeInterval
    let warnings: [String]
    
    var savingsPercent: Double {
        guard originalSize > 0 else { return 0 }
        return (Double(originalSize - compressedSize) / Double(originalSize)) * 100
    }
    
    var fileSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: compressedSize)
    }
    
    var processingTimeFormatted: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: processingTime) ?? "\(processingTime)s"
    }
}

/// Debug message for logging
struct CompressionDebugMessage: Identifiable, Codable {
    let id = UUID()
    let message: String
    let level: Level
    let timestamp: Date = Date()
    
    enum Level: String, Codable {
        case info = "info"
        case success = "success"
        case warning = "warning"
        case error = "error"
        
        var icon: String {
            switch self {
            case .info: return "ℹ️"
            case .success: return "✅"
            case .warning: return "⚠️"
            case .error: return "❌"
            }
        }
        
        var color: String {
            switch self {
            case .info: return "blue"
            case .success: return "green"
            case .warning: return "orange"
            case .error: return "red"
            }
        }
    }
}
