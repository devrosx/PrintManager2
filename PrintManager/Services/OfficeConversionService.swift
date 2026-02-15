//
//  OfficeConversionService.swift
//  PrintManager
//
//  Converts Office documents to PDF using LibreOffice / OpenOffice (soffice)
//

import Foundation

class OfficeConversionService {

    // Common installation locations for LibreOffice and OpenOffice on macOS
    private let sofficePaths = [
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/Applications/OpenOffice.app/Contents/MacOS/soffice",
        "/usr/local/bin/soffice",
        "/opt/homebrew/bin/soffice",
        "/opt/local/bin/soffice",
    ]

    /// Returns the path to the `soffice` binary, or nil if not installed
    func findSoffice() -> String? {
        sofficePaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    var isAvailable: Bool { findSoffice() != nil }

    /// Converts a single Office document to PDF.
    /// Runs `soffice --headless --convert-to pdf --outdir <tmp> <file>`.
    /// - Returns: URL of the generated PDF in a temporary directory.
    func convertToPDF(url: URL) async throws -> URL {
        guard let soffice = findSoffice() else {
            throw OfficeConversionError.sofficeNotFound
        }

        let outputDir = try makeOutputDir()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSoffice(
                        soffice: soffice,
                        inputURL: url,
                        outputDir: outputDir
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func makeOutputDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintManager-Office", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func runSoffice(soffice: String, inputURL: URL, outputDir: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: soffice)
        process.arguments = [
            "--headless",
            "--convert-to", "pdf",
            "--outdir", outputDir.path,
            inputURL.path,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg  = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw OfficeConversionError.conversionFailed(errMsg)
        }

        // soffice names the output <basename>.pdf in the outdir
        let pdfName = inputURL.deletingPathExtension().lastPathComponent + ".pdf"
        let outputURL = outputDir.appendingPathComponent(pdfName)

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw OfficeConversionError.outputNotFound(pdfName)
        }

        return outputURL
    }
}

// MARK: - Errors

enum OfficeConversionError: LocalizedError {
    case sofficeNotFound
    case conversionFailed(String)
    case outputNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sofficeNotFound:
            return "LibreOffice / OpenOffice nebyl nalezen. Nainstalujte z libreoffice.org."
        case .conversionFailed(let msg):
            return "Konverze selhala: \(msg)"
        case .outputNotFound(let name):
            return "Výstupní soubor '\(name)' nebyl nalezen po konverzi."
        }
    }
}
