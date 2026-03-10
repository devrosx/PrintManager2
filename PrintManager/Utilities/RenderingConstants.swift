//
//  RenderingConstants.swift
//  PrintManager
//
//  Centralized rendering constants for PDF and image processing
//

import Foundation
import CoreGraphics

/// Centralized constants for rendering operations across the app
enum RenderingConstants {

    /// DPI (dots per inch) values for different quality levels
    enum DPI {
        /// Low quality for thumbnails (72 DPI)
        static let thumbnail: CGFloat = 72

        /// Medium quality for preview (200 DPI)
        static let preview: CGFloat = 200

        /// High quality for processing and export (300 DPI)
        static let high: CGFloat = 300

        /// Standard conversion factor from points to pixels at 72 DPI
        static let pointsToPixels: CGFloat = 72
    }

    /// Maximum sizes for preview rendering
    enum PreviewSize {
        /// Maximum size for Quick Look panel preview (high quality)
        static let quickLook = CGSize(width: 2400, height: 3200)

        /// Maximum size for standard preview panels
        static let standardPreview = CGSize(width: 2400, height: 2400)

        /// Maximum size for thumbnail previews (low quality)
        static let thumbnailPreview = CGSize(width: 600, height: 800)

        /// Small thumbnail size for file lists
        static let listThumbnail = CGSize(width: 80, height: 80)
    }

    /// Auto-crop detection parameters
    enum AutoCrop {
        /// Minimum image dimensions for auto-crop to work
        static let minimumDimension: Int = 50

        /// Minimum crop dimensions after detection
        static let minimumCropDimension: Int = 20

        /// Margin added around detected content (in pixels)
        static let detectionMargin: Int = 5

        /// Sampling interval for brightness analysis (in pixels)
        static let sampleInterval: Int = 10

        /// Fine sampling interval for content detection (in pixels)
        static let contentSampleInterval: Int = 2
    }

    /// Compression quality settings
    enum Compression {
        /// JPEG compression quality (0.0 - 1.0)
        static let jpegQuality: Double = 0.92

        /// PNG compression - lossless (ignored by system, kept for documentation)
        static let pngQuality: Double = 1.0
    }

    /// Task delays and timeouts
    enum Timing {
        /// Debounce delay for preview updates (in nanoseconds)
        static let previewDebounce: UInt64 = 300_000_000 // 300ms

        /// Thumbnail loading batch delay
        static let thumbnailLoadDelay: Double = 0.3
    }

    /// Maximum counts for batch operations
    enum Limits {
        /// Maximum number of thumbnails to load simultaneously
        static let maxSimultaneousThumbnails: Int = 20
    }
}
