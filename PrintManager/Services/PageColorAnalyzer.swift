//
//  PageColorAnalyzer.swift
//  PrintManager
//
//  Analyzes PDF pages to determine black & white vs color pages using Ghostscript
//

import Foundation

struct PageColorInfo {
    let totalPages: Int
    let colorPages: [Int]  // 1-indexed page numbers that are color
    let blackWhitePages: [Int]  // 1-indexed page numbers that are B&W
    
    var colorCount: Int { colorPages.count }
    var blackWhiteCount: Int { blackWhitePages.count }
}

class PageColorAnalyzer {
    static let shared = PageColorAnalyzer()

    private init() {}
    
    /// Check if Ghostscript is available
    var isGSAvailable: Bool {
        // Check common Ghostscript locations
        let gsPaths = [
            "/usr/bin/gs",
            "/usr/local/bin/gs",
            "/opt/homebrew/bin/gs",
            "/opt/bin/gs"
        ]
        
        for path in gsPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        // Also check via which
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["gs"]
        
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = pipe
        
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            return whichProcess.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// Analyze PDF to count black & white pages
    func analyzePDF(at url: URL, completion: @escaping (Result<PageColorInfo, Error>) -> Void) {
        guard isGSAvailable else {
            completion(.failure(PageColorAnalyzerError.ghostscriptNotFound))
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                let result = try self.runGSAnalysis(url: url)
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Synchronous analysis
    func analyzePDFSync(at url: URL) throws -> PageColorInfo {
        guard isGSAvailable else {
            throw PageColorAnalyzerError.ghostscriptNotFound
        }
        return try runGSAnalysis(url: url)
    }
    
    private func getGSPath() -> String? {
        let gsPaths = [
            "/usr/bin/gs",
            "/usr/local/bin/gs",
            "/opt/homebrew/bin/gs",
            "/opt/bin/gs"
        ]
        
        for path in gsPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func runGSAnalysis(url: URL) throws -> PageColorInfo {
        guard let gsPath = getGSPath() else {
            throw PageColorAnalyzerError.ghostscriptNotFound
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gsPath)
        process.arguments = [
            "-o", "-",
            "-sDEVICE=inkcov",
            url.path
        ]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw PageColorAnalyzerError.parseError
        }
        
        return parseOutput(output)
    }
    
    private func parseOutput(_ output: String) -> PageColorInfo {
        var colorPages: [Int] = []
        var blackWhitePages: [Int] = []
        var pageCounter = 0   // inkrementuje se pro každý platný CMYK řádek

        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let fields = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            // Potřebujeme alespoň 4 CMYK hodnoty
            guard fields.count >= 4 else { continue }

            // Každé pole musí být float v rozsahu 0–1
            let validCMYK = fields.prefix(4).allSatisfy { field in
                if let v = Double(field) { return v >= 0 && v <= 1 }
                return false
            }
            guard validCMYK else { continue }

            guard let c = Double(fields[0]),
                  let m = Double(fields[1]),
                  let y = Double(fields[2]) else { continue }

            pageCounter += 1   // toto je číslo stránky (1-indexed)

            // Práh 0.01: DeviceGray objekty přes inkcov mohou generovat
            // nepatrné plovoucí CMY hodnoty (< 0.005) u šedých stránek.
            let colorThreshold = 0.01
            if c > colorThreshold || m > colorThreshold || y > colorThreshold {
                colorPages.append(pageCounter)
            } else {
                blackWhitePages.append(pageCounter)
            }
        }

        let totalPages = max(pageCounter, 1)
        return PageColorInfo(
            totalPages: totalPages,
            colorPages: colorPages,
            blackWhitePages: blackWhitePages
        )
    }
    
}

enum PageColorAnalyzerError: LocalizedError {
    case ghostscriptNotFound
    case parseError
    case analysisFailed
    
    var errorDescription: String? {
        switch self {
        case .ghostscriptNotFound:
            return "Ghostscript (gs) not found. Please install Ghostscript."
        case .parseError:
            return "Failed to parse Ghostscript output"
        case .analysisFailed:
            return "Failed to analyze PDF pages"
        }
    }
}

// Extension to get page count from PDF URL using PDFKit
extension PageColorAnalyzer {
    func getPDFPageCount(from url: URL) -> Int? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.pageCount
    }
}

import PDFKit
