//
//  CloudConvertService.swift
//  PrintManager
//
//  Converts files to PDF via the CloudConvert API v2
//  https://cloudconvert.com/api/v2
//

import Foundation

// MARK: - Service

class CloudConvertService {
    private let baseURL = "https://api.cloudconvert.com/v2"
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Public API

    /// Converts an Office document to PDF via CloudConvert.
    func convertToPDF(fileURL: URL) async throws -> URL {
        guard isConfigured else { throw CloudConvertError.notConfigured }

        // 1. Create job
        let job = try await createJob(filename: fileURL.lastPathComponent)

        // 2. Upload file
        guard let uploadTask = job.tasks.first(where: { $0.name == "upload-file" }),
              let form = uploadTask.result?.form else {
            throw CloudConvertError.invalidResponse("Chybí upload form v odpovědi")
        }

        try await uploadFile(fileURL: fileURL, form: form)

        // 3. Poll for completion
        let completedJob = try await pollForCompletion(jobId: job.id)

        // 4. Download result
        guard let exportTask = completedJob.tasks.first(where: { $0.name == "export-result" }),
              let ccFile = exportTask.result?.files?.first,
              let exportURL = URL(string: ccFile.url) else {
            throw CloudConvertError.invalidResponse("Chybí export URL v dokončené úloze")
        }

        return try await downloadResult(from: exportURL, filename: ccFile.filename)
    }

    // MARK: - Step 1: Create job

    private func createJob(filename: String) async throws -> CCJob {
        let url = URL(string: "\(baseURL)/jobs")!
        var req = authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "tasks": [
                "upload-file": ["operation": "import/upload"],
                "convert-file": [
                    "operation": "convert",
                    "input": "upload-file",
                    "output_format": "pdf"
                ],
                "export-result": [
                    "operation": "export/url",
                    "input": "convert-file"
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)

        return try JSONDecoder().decode(CCJobResponse.self, from: data).data
    }

    // MARK: - Step 2: Upload file

    private func uploadFile(fileURL: URL, form: CCUploadForm) async throws {
        guard var components = URLComponents(string: form.url) else {
            throw CloudConvertError.invalidResponse("Neplatné upload URL")
        }

        // Append parameters as query items if present
        if let params = form.parameters, !params.isEmpty {
            components.queryItems = params.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }

        guard let uploadURL = components.url else {
            throw CloudConvertError.invalidResponse("Nepodařilo se sestavit upload URL")
        }

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.setValue(mimeType(for: fileURL), forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        let (_, response) = try await URLSession.shared.upload(for: req, from: fileData)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw CloudConvertError.uploadFailed("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Step 3: Poll for completion

    private func pollForCompletion(jobId: String) async throws -> CCJob {
        let maxAttempts = 100    // ~5 min at 3 s/attempt
        let intervalNs: UInt64 = 3_000_000_000

        for _ in 1...maxAttempts {
            try await Task.sleep(nanoseconds: intervalNs)

            let job = try await getJob(jobId: jobId)

            switch job.status {
            case "finished":
                return job
            case "error":
                let msg = job.tasks.compactMap(\.message).first ?? "Neznámá chyba"
                throw CloudConvertError.conversionFailed(msg)
            default:
                continue
            }
        }

        throw CloudConvertError.timeout
    }

    private func getJob(jobId: String) async throws -> CCJob {
        let url = URL(string: "\(baseURL)/jobs/\(jobId)")!
        let req = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)
        return try JSONDecoder().decode(CCJobResponse.self, from: data).data
    }

    // MARK: - Step 4: Download result

    private func downloadResult(from url: URL, filename: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CloudConvertError.downloadFailed("HTTP \(http.statusCode)")
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintManager-CC", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        let outputURL = outputDir.appendingPathComponent(filename)
        try data.write(to: outputURL)
        return outputURL
    }

    // MARK: - Helpers

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["message"] as? String }
                ?? "HTTP \(http.statusCode)"
            throw CloudConvertError.apiError(http.statusCode, msg)
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc":  return "application/msword"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls":  return "application/vnd.ms-excel"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppt":  return "application/vnd.ms-powerpoint"
        case "odt":  return "application/vnd.oasis.opendocument.text"
        case "ods":  return "application/vnd.oasis.opendocument.spreadsheet"
        case "odp":  return "application/vnd.oasis.opendocument.presentation"
        default:     return "application/octet-stream"
        }
    }
}

// MARK: - Codable models

struct CCJobResponse: Codable {
    let data: CCJob
}

struct CCJob: Codable {
    let id: String
    let status: String
    let tasks: [CCTask]
}

struct CCTask: Codable {
    let id: String?
    let name: String
    let operation: String
    let status: String
    let message: String?
    let result: CCTaskResult?
}

struct CCTaskResult: Codable {
    let form: CCUploadForm?
    let files: [CCFile]?
}

struct CCUploadForm: Codable {
    let url: String
    let parameters: [String: String]?
}

struct CCFile: Codable {
    let filename: String
    let url: String
}

// MARK: - Errors

enum CloudConvertError: LocalizedError {
    case notConfigured
    case invalidResponse(String)
    case uploadFailed(String)
    case conversionFailed(String)
    case downloadFailed(String)
    case apiError(Int, String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "CloudConvert API klíč není nastaven (Nastavení → CloudConvert)."
        case .invalidResponse(let msg):
            return "Neplatná odpověď od CloudConvert: \(msg)"
        case .uploadFailed(let msg):
            return "Nahrávání selhalo: \(msg)"
        case .conversionFailed(let msg):
            return "Konverze selhala: \(msg)"
        case .downloadFailed(let msg):
            return "Stahování výsledku selhalo: \(msg)"
        case .apiError(let code, let msg):
            return "CloudConvert API chyba \(code): \(msg)"
        case .timeout:
            return "CloudConvert: konverze přesáhla 5 minut (timeout)."
        }
    }
}
