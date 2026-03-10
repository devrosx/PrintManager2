//
//  StitchService.swift
//  PrintManager
//
//  Service for stitching scanned images using Python/OpenCV.
//  Follows the same pattern as MultiCropCV2Service.
//

import Foundation

class StitchService {

    // MARK: - Python paths (v pořadí priority)

    private static let pythonPaths = [
        "/usr/local/opt/python@3.12/bin/python3.12",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3",
    ]

    // MARK: - Public API

    static func isAvailable() -> Bool {
        findPython() != nil && findScript() != nil
    }

    func stitch(imageURLs: [URL], settings: StitchSettings) async throws -> StitchResult {
        guard imageURLs.count >= 2 else { throw StitchError.notEnoughImages }
        guard imageURLs.count <= 8 else { throw StitchError.tooManyImages }

        guard let pythonPath = Self.findPython() else {
            throw StitchError.pythonNotFound
        }
        guard let scriptPath = Self.findScript() else {
            throw StitchError.scriptNotFound
        }

        var args = [scriptPath]
        args += imageURLs.map { $0.path }
        args += ["--features", settings.features.rawValue]
        args += ["--warp", settings.warpType.rawValue]
        args += ["--blend", settings.blendType.rawValue]
        args += ["--work-megapix", String(format: "%.2f", settings.workMegapix)]
        args += ["--confidence", String(format: "%.2f", settings.confidenceThresh)]

        let (stdout, stderr, exitCode) = try await runProcess(
            executable: pythonPath, arguments: args
        )

        guard exitCode == 0 else {
            // Try to parse JSON error from stdout first
            if let data = stdout.data(using: .utf8),
               let errorObj = try? JSONDecoder().decode(StitchErrorResponse.self, from: data) {
                throw StitchError.stitchingFailed(errorObj.error)
            }
            let msg = stderr.isEmpty ? "Python exit code \(exitCode)" : stderr
            if msg.contains("No module named") {
                throw StitchError.opencvNotInstalled
            }
            throw StitchError.stitchingFailed(msg)
        }

        guard let data = stdout.data(using: .utf8) else {
            throw StitchError.invalidOutput
        }

        // Check for error response
        if let errorObj = try? JSONDecoder().decode(StitchErrorResponse.self, from: data) {
            throw StitchError.stitchingFailed(errorObj.error)
        }

        guard let result = try? JSONDecoder().decode(StitchSuccessResponse.self, from: data) else {
            throw StitchError.invalidOutput
        }

        let outputURL = URL(fileURLWithPath: result.output)
        return StitchResult(outputURL: outputURL, width: result.width, height: result.height)
    }

    // MARK: - Private: Python helpers

    private static func findPython() -> String? {
        for path in pythonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func findScript() -> String? {
        if let bundlePath = Bundle.main.resourcePath {
            let scriptPath = (bundlePath as NSString)
                .appendingPathComponent("stitch_images.py")
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }
        if let bundlePath = Bundle.main.resourcePath {
            let scriptPath = (bundlePath as NSString)
                .appendingPathComponent("Scripts/stitch_images.py")
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
}

// MARK: - JSON response models

private struct StitchSuccessResponse: Decodable {
    let output: String
    let width: Int
    let height: Int
}

private struct StitchErrorResponse: Decodable {
    let error: String
}
