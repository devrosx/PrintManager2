//
//  GoogleDocsConversionService.swift
//  PrintManager
//
//  Converts Office files to PDF via Google Drive API
//  OAuth 2.0 s PKCE + localhost redirect server (RFC 8252)
//

import Foundation
import AppKit
import Network
import CommonCrypto
import Security

// MARK: - Google Drive Conversion Service

class GoogleDocsConversionService {

    func convertToPDF(fileURL: URL) async throws -> URL {
        let accessToken = try await GoogleOAuthManager.shared.accessTokenOrRefresh()
        return try await convertViaGoogleDrive(fileURL: fileURL, accessToken: accessToken)
    }

    private func convertViaGoogleDrive(fileURL: URL, accessToken: String) async throws -> URL {
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        // Content-Type odesílaného souboru (skutečný formát)
        let uploadMimeType = officeMimeType(for: fileURL)
        // Cílový Google Workspace formát — Drive soubor při uploadu automaticky převede,
        // díky čemuž pak funguje /export?mimeType=application/pdf
        let googleMimeType = googleAppsMimeType(for: fileURL)

        let metadataJSON = try JSONSerialization.data(withJSONObject: ["name": fileName, "mimeType": googleMimeType])

        let boundary = UUID().uuidString
        var uploadRequest = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        uploadRequest.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(uploadMimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        uploadRequest.httpBody = body

        let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        guard let httpUpload = uploadResponse as? HTTPURLResponse, httpUpload.statusCode == 200 else {
            throw GoogleConversionError.uploadFailed
        }
        guard let uploadJSON = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
              let fileId = uploadJSON["id"] as? String else {
            throw GoogleConversionError.invalidResponse
        }

        var exportRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/export?mimeType=application/pdf")!)
        exportRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (pdfData, pdfResponse) = try await URLSession.shared.data(for: exportRequest)

        // Smazat soubor z Drive
        var deleteRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!)
        deleteRequest.httpMethod = "DELETE"
        deleteRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: deleteRequest)

        guard let httpPdf = pdfResponse as? HTTPURLResponse, httpPdf.statusCode == 200 else {
            throw GoogleConversionError.exportFailed
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintManager-Google", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("pdf")
        try pdfData.write(to: outputURL)
        return outputURL
    }

    /// Skutečný MIME typ souboru — použije se jako Content-Type při uploadu.
    private func officeMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "doc":  return "application/msword"
        case "xls":  return "application/vnd.ms-excel"
        case "ppt":  return "application/vnd.ms-powerpoint"
        case "odt":  return "application/vnd.oasis.opendocument.text"
        case "ods":  return "application/vnd.oasis.opendocument.spreadsheet"
        case "odp":  return "application/vnd.oasis.opendocument.presentation"
        case "rtf":  return "application/rtf"
        case "txt":  return "text/plain"
        case "csv":  return "text/csv"
        default:     return "application/octet-stream"
        }
    }

    /// Google Workspace MIME typ — nastaví se v metadatech uploadu, aby Drive
    /// soubor automaticky převedl a umožnil export jako PDF přes /export endpoint.
    private func googleAppsMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "doc", "docx", "odt", "rtf", "txt":
            return "application/vnd.google-apps.document"
        case "xls", "xlsx", "ods", "csv":
            return "application/vnd.google-apps.spreadsheet"
        case "ppt", "pptx", "odp":
            return "application/vnd.google-apps.presentation"
        default:
            return "application/vnd.google-apps.document"
        }
    }
}

// MARK: - OAuth Manager

@MainActor
class GoogleOAuthManager: ObservableObject {
    static let shared = GoogleOAuthManager()

    @Published var isAuthenticated  = false
    @Published var isAuthenticating = false
    @Published var authError: String?

    private let scope = "https://www.googleapis.com/auth/drive.file"

    /// Client ID — nastavuje se v Nastavení → Google.
    var clientId: String {
        UserDefaults.standard.string(forKey: "googleClientId") ?? ""
    }

    /// Client Secret — nastavuje se v Nastavení → Google.
    var clientSecret: String {
        UserDefaults.standard.string(forKey: "googleClientSecret") ?? ""
    }

    /// Vrátí true pokud jsou OAuth přihlašovací údaje nakonfigurovány.
    var hasCredentials: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty
    }

    private var accessToken:       String?
    private var tokenExpiry:       Date?
    private var codeVerifier:      String?
    private var currentRedirectURI: String?

    private var localServer: NWListener?

    private let keychainService = "PrintManager.Google"
    private let refreshTokenKey = "refresh_token"

    private init() {
        if keychainLoad(key: refreshTokenKey) != nil {
            isAuthenticated = true
        }
    }

    // MARK: - Public API

    func accessTokenOrRefresh() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refreshToken = keychainLoad(key: refreshTokenKey) else {
            throw GoogleConversionError.authenticationFailed
        }
        return try await performRefresh(refreshToken: refreshToken)
    }

    /// Spustí lokální HTTP server, otevře prohlížeč s přihlášením Google.
    /// Přihlášení proběhne automaticky — uživatel nemusí nic kopírovat.
    func startLogin() {
        guard !isAuthenticating else { return }
        guard hasCredentials else {
            authError = "Nastavte Client ID a Client Secret v Nastavení → Google."
            return
        }
        isAuthenticating = true
        startLocalServer { [weak self] code in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isAuthenticating = false }
                guard let verifier     = self.codeVerifier,
                      let redirectURI  = self.currentRedirectURI else { return }
                self.codeVerifier      = nil
                self.currentRedirectURI = nil
                do {
                    self.authError = nil
                    try await self.exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
                } catch {
                    self.authError = error.localizedDescription
                    print("Google OAuth chyba: \(error)")
                }
            }
        }
    }

    func signOut() {
        localServer?.cancel()
        localServer        = nil
        accessToken        = nil
        tokenExpiry        = nil
        isAuthenticated    = false
        isAuthenticating   = false
        keychainDelete(key: refreshTokenKey)
    }

    // MARK: - Localhost server

    private func startLocalServer(onCode: @escaping (String) -> Void) {
        guard let listener = try? NWListener(using: .tcp, on: 0) else {
            isAuthenticating = false
            return
        }
        localServer = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state,
                  let port = listener.port?.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.openBrowserWithPort(Int(port))
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let data = data,
                      let request = String(data: data, encoding: .utf8) else {
                    print("Google OAuth: nepřišla žádná data")
                    return
                }
                print("Google OAuth HTTP request:\n\(request.prefix(300))")
                guard let code = self?.extractCodeFrom(httpRequest: request) else {
                    print("Google OAuth: nepodařilo se extrahovat code")
                    return
                }
                print("Google OAuth: code extrahován (\(code.prefix(20))…)")

                // Vrátíme uživateli hezkou stránku a zavřeme server
                let html = """
                    <html><head><meta charset='utf-8'>
                    <style>body{font-family:-apple-system;text-align:center;padding:60px;}</style></head>
                    <body><h2>✓ Přihlášení proběhlo úspěšně</h2>
                    <p>Můžete zavřít toto okno a vrátit se do PrintManager.</p>
                    <script>setTimeout(()=>window.close(),2000)</script></body></html>
                    """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .idempotent)

                Task { @MainActor [weak self] in
                    self?.localServer?.cancel()
                    self?.localServer = nil
                }
                onCode(code)
            }
        }

        listener.start(queue: .main)
    }

    private func openBrowserWithPort(_ port: Int) {
        let redirectURI    = "http://127.0.0.1:\(port)"
        currentRedirectURI = redirectURI

        let verifier = makeCodeVerifier()
        codeVerifier = verifier

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: clientId),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: scope),
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "consent"),
            URLQueryItem(name: "code_challenge",        value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Parsuje HTTP request a vytáhne `code` parametr z GET řádku.
    /// Ruční parsování query stringu — vyhýbá se problémům s URLComponents při výskytu
    /// neescape‑ovaného '/' v hodnotě kódu (např. "4/0Afr…").
    private func extractCodeFrom(httpRequest: String) -> String? {
        // První řádek: "GET /?code=4/0A...&scope=... HTTP/1.1"
        guard let firstLine = httpRequest.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let path = parts[1]          // "/?code=...&scope=..."

        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])

        // Parsujeme &-oddělené páry klíč=hodnota
        for pair in query.components(separatedBy: "&") {
            // Rozdělíme jen na první '=' — hodnota může obsahovat '='
            guard let eqRange = pair.range(of: "=") else { continue }
            let key   = String(pair[pair.startIndex..<eqRange.lowerBound])
            let value = String(pair[eqRange.upperBound...])
                        if key == "code" {
                // Dekódujeme percent-encoding (kód bývá i bez něj, ale pro jistotu)
                return value.removingPercentEncoding ?? value
            }
        }
        return nil
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws {
        let params: [String: String] = [
            "code":          code,
            "client_id":     clientId,
            "client_secret": clientSecret,
            "redirect_uri":  redirectURI,
            "grant_type":    "authorization_code",
            "code_verifier": verifier,
        ]
        let json = try await tokenRequest(params: params)
        try storeTokens(from: json)
    }

    private func performRefresh(refreshToken: String) async throws -> String {
        let params: [String: String] = [
            "refresh_token": refreshToken,
            "client_id":     clientId,
            "client_secret": clientSecret,
            "grant_type":    "refresh_token",
        ]
        let json = try await tokenRequest(params: params)
        try storeTokens(from: json)
        guard let token = accessToken else { throw GoogleConversionError.authenticationFailed }
        return token
    }

    private func tokenRequest(params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyString = String(data: data, encoding: .utf8) ?? "(prázdná odpověď)"
        print("Google token endpoint → HTTP \(statusCode): \(bodyString)")

        guard statusCode == 200 else {
            isAuthenticated = false
            accessToken     = nil
            throw GoogleConversionError.authenticationFailed
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleConversionError.invalidResponse
        }
        return json
    }

    private func storeTokens(from json: [String: Any]) throws {
        guard let token = json["access_token"] as? String else {
            throw GoogleConversionError.invalidResponse
        }
        accessToken     = token
        tokenExpiry     = Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600)
        isAuthenticated = true
        if let refreshToken = json["refresh_token"] as? String {
            keychainSave(key: refreshTokenKey, value: refreshToken)
        }
    }

    // MARK: - PKCE

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private func keychainSave(key: String, value: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: keychainService,
            kSecValueData:   Data(value.utf8),
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainLoad(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: keychainService,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum GoogleConversionError: LocalizedError {
    case authenticationFailed
    case uploadFailed
    case exportFailed
    case invalidResponse
    case rateLimited
    case httpError(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "Ověření Google účtu selhalo. Přihlaste se znovu v Nastavení."
        case .uploadFailed:         return "Nahrání souboru na Google Drive selhalo."
        case .exportFailed:         return "Export souboru do PDF selhal."
        case .invalidResponse:      return "Neplatná odpověď od Google API."
        case .rateLimited:          return "Příliš mnoho požadavků. Zkuste to znovu za chvíli."
        case .httpError(let code):  return "HTTP chyba: \(code)"
        case .apiError(let msg):    return "Google API chyba: \(msg)"
        }
    }
}
