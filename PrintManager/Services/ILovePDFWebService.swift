//
//  ILovePDFWebService.swift
//  PrintManager
//
//  Služba pro konverzi Office dokumentů pomocí iLovePDF API
//  Vyžaduje API klíč z https://developer.ilovepdf.com/
//  Free tier: 250 requestů/měsíc
//

import Foundation
import UniformTypeIdentifiers

class ILovePDFWebService {

    private let baseURL = "https://api.ilovepdf.com"
    private let publicKey: String
    private let secretKey: String

    // MARK: - Init

    init(publicKey: String, secretKey: String) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }

    // MARK: - Convert Office to PDF

    /// Konvertuje Office dokument na PDF pomocí iLovePDF API
    /// Vyžaduje platný API klíč
    func convertOfficeToPDF(fileURL: URL) async throws -> URL {
        // 1. Start task
        let taskID = try await startTask(tool: "officepdf")

        // 2. Get server URL for upload
        let serverURL = try await getServerURL(taskID: taskID)

        // 3. Upload file
        _ = try await uploadFile(fileURL: fileURL, taskID: taskID, serverURL: serverURL)

        // 4. Process conversion
        try await processTask(taskID: taskID, serverURL: serverURL)

        // 5. Download result
        let outputURL = try await downloadResult(taskID: taskID, serverURL: serverURL, originalFileName: fileURL.deletingPathExtension().lastPathComponent, sourceURL: fileURL)

        return outputURL
    }

    // MARK: - Private Methods

    private func startTask(tool: String) async throws -> String {
        // iLovePDF uses only PUBLIC key in Authorization header
        let url = URL(string: "\(baseURL)/v1/start/\(tool)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ILovePDFError.requestFailed("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = "HTTP \(httpResponse.statusCode)"
            if let responseString = String(data: data, encoding: .utf8) {
                throw ILovePDFError.requestFailed("Start task failed: \(errorMsg) - \(responseString)")
            } else {
                throw ILovePDFError.requestFailed("Start task failed: \(errorMsg)")
            }
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let task = json?["task"] as? String else {
            throw ILovePDFError.invalidResponse("No task ID in response")
        }

        return task
    }

    private func getServerURL(taskID: String) async throws -> String {
        // iLovePDF používá různé servery pro upload
        // Obvykle vrací server URL v response z start task
        // Pro zjednodušení použijeme hlavní server
        return "https://api.ilovepdf.com"
    }

    private func uploadFile(fileURL: URL, taskID: String, serverURL: String) async throws -> String {
        let uploadURL = URL(string: "\(serverURL)/v1/upload")!

        // Multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")

        var body = Data()

        // Add task parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"task\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(taskID)\r\n".data(using: .utf8)!)

        // Add file
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        let mimeType = mimeTypeForFile(fileURL: fileURL)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ILovePDFError.uploadFailed("Upload failed")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let serverFilename = json?["server_filename"] as? String else {
            throw ILovePDFError.invalidResponse("No server filename")
        }

        return serverFilename
    }

    private func processTask(taskID: String, serverURL: String) async throws {
        let processURL = URL(string: "\(serverURL)/v1/process")!
        var request = URLRequest(url: processURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["task": taskID]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ILovePDFError.processingFailed("Processing failed")
        }

        // Počkat chvíli než se soubor zpracuje
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 sekundy
    }

    private func downloadResult(taskID: String, serverURL: String, originalFileName: String, sourceURL: URL) async throws -> URL {
        let downloadURL = URL(string: "\(serverURL)/v1/download/\(taskID)")!
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.addValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ILovePDFError.downloadFailed("Download failed")
        }

        // Výstup do složky zdrojového souboru; fallback na /tmp
        let sourceDir = sourceURL.deletingLastPathComponent()
        let outputDir: URL
        if FileManager.default.isWritableFile(atPath: sourceDir.path) {
            outputDir = sourceDir
        } else {
            outputDir = FileManager.default.temporaryDirectory
        }
        let outputURL = outputDir.appendingPathComponent("\(originalFileName).pdf")
        try data.write(to: outputURL)
        return outputURL
    }

    private func mimeTypeForFile(fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":
            return "application/vnd.ms-excel"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":
            return "application/vnd.ms-powerpoint"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "odt":
            return "application/vnd.oasis.opendocument.text"
        case "ods":
            return "application/vnd.oasis.opendocument.spreadsheet"
        case "odp":
            return "application/vnd.oasis.opendocument.presentation"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - Errors

enum ILovePDFError: LocalizedError {
    case requestFailed(String)
    case invalidResponse(String)
    case uploadFailed(String)
    case processingFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg):
            return "iLovePDF request failed: \(msg)"
        case .invalidResponse(let msg):
            return "iLovePDF invalid response: \(msg)"
        case .uploadFailed(let msg):
            return "iLovePDF upload failed: \(msg)"
        case .processingFailed(let msg):
            return "iLovePDF processing failed: \(msg)"
        case .downloadFailed(let msg):
            return "iLovePDF download failed: \(msg)"
        }
    }
}
