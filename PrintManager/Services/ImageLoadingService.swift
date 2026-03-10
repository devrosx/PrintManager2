//
//  ImageLoadingService.swift
//  PrintManager
//
//  Unified service for image loading with EXIF orientation support
//

import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Service for loading images with proper orientation handling
struct ImageLoadingService {

    // MARK: - Public API

    /// Load an image from URL with optional EXIF orientation correction
    /// - Parameters:
    ///   - url: URL of the image file
    ///   - respectOrientation: Whether to apply EXIF orientation (default: true)
    /// - Returns: NSImage with corrected orientation, or nil if loading failed
    static func loadImage(from url: URL, respectOrientation: Bool = true) async -> NSImage? {
        if respectOrientation {
            return await loadImageWithOrientation(url: url)
        } else {
            return await MainActor.run {
                NSImage(contentsOf: url)
            }
        }
    }

    /// Load a CGImage from URL with optional EXIF orientation correction
    /// - Parameters:
    ///   - url: URL of the image file
    ///   - respectOrientation: Whether to apply EXIF orientation (default: true)
    /// - Returns: CGImage with corrected orientation, or nil if loading failed
    static func loadCGImage(from url: URL, respectOrientation: Bool = true) async -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        if respectOrientation {
            let orientation = getOrientation(from: imageSource)
            if orientation > 1 {
                return applyOrientation(cgImage: cgImage, orientation: orientation)
            }
        }

        return cgImage
    }

    // MARK: - Private Methods

    /// Load image with EXIF orientation correction
    private static func loadImageWithOrientation(url: URL) async -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return await MainActor.run {
                NSImage(contentsOf: url)
            }
        }

        let orientation = getOrientation(from: imageSource)

        // Apply orientation if needed
        if orientation > 1 {
            guard let orientedImage = applyOrientation(cgImage: cgImage, orientation: orientation) else {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            return NSImage(cgImage: orientedImage, size: NSSize(width: orientedImage.width, height: orientedImage.height))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Extract EXIF orientation from image source
    /// - Parameter imageSource: CGImageSource to read orientation from
    /// - Returns: Orientation value (1-8), default is 1 (normal)
    private static func getOrientation(from imageSource: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return 1
        }

        // Check TIFF properties first
        if let tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let orientation = tiffProperties[kCGImagePropertyTIFFOrientation] as? Int32 {
            return Int(orientation)
        }

        // Check orientation property directly
        if let orientation = properties[kCGImagePropertyOrientation] as? Int32 {
            return Int(orientation)
        }

        return 1 // Default: normal orientation
    }

    /// Apply EXIF orientation transformation to CGImage
    /// - Parameters:
    ///   - cgImage: Source CGImage
    ///   - orientation: EXIF orientation value (1-8)
    /// - Returns: Transformed CGImage or nil if transformation failed
    private static func applyOrientation(cgImage: CGImage, orientation: Int) -> CGImage? {
        var transform = CGAffineTransform.identity

        switch orientation {
        case 2: // Flip horizontally
            transform = transform.translatedBy(x: CGFloat(cgImage.width), y: 0)
            transform = transform.scaledBy(x: -1, y: 1)

        case 3: // Rotate 180 degrees
            transform = transform.translatedBy(x: CGFloat(cgImage.width), y: CGFloat(cgImage.height))
            transform = transform.rotated(by: .pi)

        case 4: // Flip vertically
            transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.height))
            transform = transform.scaledBy(x: 1, y: -1)

        case 5: // Rotate 90 CW + Flip horizontally
            transform = transform.translatedBy(x: CGFloat(cgImage.height), y: 0)
            transform = transform.rotated(by: .pi / 2)
            transform = transform.scaledBy(x: -1, y: 1)

        case 6: // Rotate 90 CW
            transform = transform.translatedBy(x: CGFloat(cgImage.height), y: 0)
            transform = transform.rotated(by: .pi / 2)

        case 7: // Rotate 270 CW + Flip horizontally
            transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.width))
            transform = transform.rotated(by: -.pi / 2)
            transform = transform.scaledBy(x: -1, y: 1)

        case 8: // Rotate 270 CW (90 CCW)
            transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.width))
            transform = transform.rotated(by: -.pi / 2)

        default:
            return cgImage
        }

        // Calculate transformed dimensions
        let width: Int
        let height: Int

        if orientation >= 5 && orientation <= 8 {
            // Orientations 5-8 swap width and height
            width = cgImage.height
            height = cgImage.width
        } else {
            width = cgImage.width
            height = cgImage.height
        }

        // Create context and apply transformation
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else {
            return nil
        }

        context.concatenate(transform)

        // Draw based on orientation
        let drawRect: CGRect
        if orientation >= 5 && orientation <= 8 {
            drawRect = CGRect(x: 0, y: 0, width: cgImage.height, height: cgImage.width)
        } else {
            drawRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        }

        context.draw(cgImage, in: drawRect)

        return context.makeImage()
    }
}
