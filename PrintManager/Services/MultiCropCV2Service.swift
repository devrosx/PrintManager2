//
//  MultiCropCV2Service.swift
//  PrintManager
//
//  Alternativní detekce fotografií pomocí OpenCV (Python skript).
//  Volá multicrop_cv2.py přes Process, parsuje JSON, ořezává fotky přes CoreImage.
//

import Foundation
import CoreImage
import AppKit

class MultiCropCV2Service {

    // MARK: - Python paths (v pořadí priority)

    private static let pythonPaths = [
        "/usr/local/opt/python@3.12/bin/python3.12",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3",
    ]

    // MARK: - Public API

    func detect(
        imageURL: URL,
        sensitivity: Float = 0.5,
        minRelativeSize: Float = 0.04,
        maxRelativeSize: Float = 0.50,
        maxCount: Int = 20,
        trimFactor: Double = 0.020
    ) async throws -> [DetectedPhoto] {
        let boxes = try await runPythonDetection(
            imageURL: imageURL,
            sensitivity: sensitivity,
            minArea: minRelativeSize,
            maxArea: maxRelativeSize,
            maxCount: maxCount
        )

        guard let ciImage = CIImage(contentsOf: imageURL) else {
            throw MultiCropError.cannotLoadImage
        }
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

        var results: [DetectedPhoto] = []
        for box in boxes {
            guard !Task.isCancelled else { break }

            // Převod pixel souřadnic (y-dolů) na normalizované Vision souřadnice (y-nahoru, 0–1)
            let imgW = CGFloat(box.imgW)
            let imgH = CGFloat(box.imgH)

            let normX = CGFloat(box.x) / imgW
            let normY = 1.0 - (CGFloat(box.y) + CGFloat(box.h)) / imgH  // flip y + posun na spodní hranu
            let normW = CGFloat(box.w) / imgW
            let normH = CGFloat(box.h) / imgH

            let quad = DetectedQuad(
                topLeft:     CGPoint(x: normX,         y: normY + normH),
                topRight:    CGPoint(x: normX + normW, y: normY + normH),
                bottomLeft:  CGPoint(x: normX,         y: normY),
                bottomRight: CGPoint(x: normX + normW, y: normY)
            )

            guard let cropped = cropImage(ciImage, quad: quad, context: ciCtx,
                                          trimFactor: trimFactor) else { continue }
            results.append(DetectedPhoto(quad: quad, croppedImage: cropped))
        }

        return results
    }

    func save(_ photos: [DetectedPhoto], basedOn sourceURL: URL) throws -> [URL] {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext  = sourceURL.pathExtension.lowercased()
        let dir  = sourceURL.deletingLastPathComponent()

        var urls: [URL] = []
        for (i, photo) in photos.enumerated() {
            let outputExt = (ext == "png") ? "png" : "jpg"
            let url = dir.appendingPathComponent("\(base)_\(i + 1).\(outputExt)")
            let imageToSave = photo.displayImage
            guard let tiff = imageToSave.tiffRepresentation,
                  let rep  = NSBitmapImageRep(data: tiff)
            else { continue }
            let data: Data?
            if outputExt == "png" {
                data = rep.representation(using: .png, properties: [:])
            } else {
                data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            }
            if let data {
                try data.write(to: url)
                urls.append(url)
            }
        }
        if urls.isEmpty { throw MultiCropError.noPhotosFound }
        return urls
    }

    // MARK: - Python availability check

    static func isAvailable() -> Bool {
        findPython() != nil && findScript() != nil
    }

    // MARK: - Private: Python execution

    private struct BoxResult {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let imgW: Int
        let imgH: Int
    }

    private func runPythonDetection(
        imageURL: URL,
        sensitivity: Float,
        minArea: Float,
        maxArea: Float,
        maxCount: Int
    ) async throws -> [BoxResult] {
        guard let pythonPath = Self.findPython() else {
            throw CV2Error.pythonNotFound
        }
        guard let scriptPath = Self.findScript() else {
            throw CV2Error.scriptNotFound
        }

        let args = [
            scriptPath,
            imageURL.path,
            "--sensitivity", String(format: "%.2f", sensitivity),
            "--min-area", String(format: "%.3f", minArea),
            "--max-area", String(format: "%.3f", maxArea),
            "--max-count", "\(maxCount)",
        ]

        let (stdout, stderr, exitCode) = try await runProcess(
            executable: pythonPath, arguments: args
        )

        guard exitCode == 0 else {
            let msg = stderr.isEmpty ? "Python exit code \(exitCode)" : stderr
            throw CV2Error.pythonError(msg)
        }

        guard let data = stdout.data(using: .utf8) else {
            throw CV2Error.invalidOutput
        }

        // Zkontroluj jestli výstup je error objekt
        if let errorObj = try? JSONDecoder().decode(CV2ErrorResponse.self, from: data) {
            throw CV2Error.pythonError(errorObj.error)
        }

        guard let arr = try? JSONDecoder().decode([CV2Box].self, from: data) else {
            throw CV2Error.invalidOutput
        }

        return arr.map { BoxResult(x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                                    imgW: $0.img_w, imgH: $0.img_h) }
    }

    private static func findPython() -> String? {
        for path in pythonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func findScript() -> String? {
        // 1. Bundle resources (flat — Xcode kopíruje bez adresářové struktury)
        if let bundlePath = Bundle.main.resourcePath {
            let scriptPath = (bundlePath as NSString)
                .appendingPathComponent("multicrop_cv2.py")
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }
        // 2. Bundle resources s adresářem Scripts (pro případ manuálního copy)
        if let bundlePath = Bundle.main.resourcePath {
            let scriptPath = (bundlePath as NSString)
                .appendingPathComponent("Scripts/multicrop_cv2.py")
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }
        return nil
    }

    private func runProcess(
        executable: String,
        arguments: [String]
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: (stdout, stderr, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Image cropping

    private func cropImage(
        _ ciImage: CIImage,
        quad: DetectedQuad,
        context: CIContext,
        trimFactor: Double
    ) -> NSImage? {
        let ext = ciImage.extent

        func toCI(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * ext.width + ext.origin.x,
                     y: p.y * ext.height + ext.origin.y)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage,                  forKey: kCIInputImageKey)
        filter.setValue(toCI(quad.topLeft),       forKey: "inputTopLeft")
        filter.setValue(toCI(quad.topRight),      forKey: "inputTopRight")
        filter.setValue(toCI(quad.bottomLeft),    forKey: "inputBottomLeft")
        filter.setValue(toCI(quad.bottomRight),   forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return nil }

        let trim = Swift.max(2, Swift.min(output.extent.width, output.extent.height) * CGFloat(trimFactor))
        let trimRect = output.extent.insetBy(dx: trim, dy: trim)
        let trimmed = output.cropped(to: trimRect)

        guard let cgImg = context.createCGImage(trimmed, from: trimmed.extent) else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }
}

// MARK: - JSON models

private struct CV2Box: Decodable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let img_w: Int
    let img_h: Int
}

private struct CV2ErrorResponse: Decodable {
    let error: String
}

// MARK: - Errors

enum CV2Error: LocalizedError {
    case pythonNotFound
    case scriptNotFound
    case pythonError(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Python 3 s OpenCV nebyl nalezen. Nainstalujte: brew install python@3.12 && pip3 install opencv-python"
        case .scriptNotFound:
            return "Skript multicrop_cv2.py nebyl nalezen v bundle."
        case .pythonError(let msg):
            return "Python chyba: \(msg)"
        case .invalidOutput:
            return "Neplatný výstup z Python skriptu."
        }
    }
}
