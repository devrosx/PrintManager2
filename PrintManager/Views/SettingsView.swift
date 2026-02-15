//
//  SettingsView.swift
//  PrintManager
//
//  Application settings and preferences
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("defaultPrinter") private var defaultPrinter = ""
    @AppStorage("defaultCopies") private var defaultCopies = 1
    @AppStorage("defaultTwoSided") private var defaultTwoSided = false
    @AppStorage("defaultCollate") private var defaultCollate = true
    @AppStorage("defaultFitToPage") private var defaultFitToPage = false
    @AppStorage("autoRefreshPrinters") private var autoRefreshPrinters = true
    @AppStorage("compressionQuality") private var compressionQuality = 0.7
    @AppStorage("ocrLanguage") private var ocrLanguage = "en"
    @AppStorage("defaultDPI") private var defaultDPI = 300
    @AppStorage("thumbnailSize") private var thumbnailSize = 80.0
    
    @StateObject private var printManager = PrintManager()
    
    var body: some View {
        TabView {
            // General Settings
            GeneralSettingsView(
                defaultPrinter: $defaultPrinter,
                defaultCopies: $defaultCopies,
                defaultTwoSided: $defaultTwoSided,
                defaultCollate: $defaultCollate,
                defaultFitToPage: $defaultFitToPage,
                autoRefreshPrinters: $autoRefreshPrinters,
                printManager: printManager
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            // PDF Settings
            PDFSettingsView(
                compressionQuality: $compressionQuality,
                ocrLanguage: $ocrLanguage,
                defaultDPI: $defaultDPI
            )
            .tabItem {
                Label("PDF", systemImage: "doc.fill")
            }
            
            // Image Settings
            ImageSettingsView(
                thumbnailSize: $thumbnailSize
            )
            .tabItem {
                Label("Images", systemImage: "photo.fill")
            }
            
            // CloudConvert
            CloudConvertSettingsView()
                .tabItem {
                    Label("CloudConvert", systemImage: "cloud.fill")
                }
            
            // Google
            GoogleSettingsView()
                .tabItem {
                    Label("Google", systemImage: "g.circle.fill")
                }

            // About
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Binding var defaultPrinter: String
    @Binding var defaultCopies: Int
    @Binding var defaultTwoSided: Bool
    @Binding var defaultCollate: Bool
    @Binding var defaultFitToPage: Bool
    @Binding var autoRefreshPrinters: Bool
    @ObservedObject var printManager: PrintManager
    
    // Notification settings
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    
    var body: some View {
        Form {
            Section("Default Print Settings") {
                Picker("Printer:", selection: $defaultPrinter) {
                    Text("System Default").tag("")
                    ForEach(printManager.availablePrinters, id: \.self) { printer in
                        Text(printer).tag(printer)
                    }
                }
                
                Stepper("Copies: \(defaultCopies)", value: $defaultCopies, in: 1...999)
                
                Toggle("Two-sided printing", isOn: $defaultTwoSided)
                Toggle("Collate pages", isOn: $defaultCollate)
                Toggle("Fit to page", isOn: $defaultFitToPage)
            }
            
            Section("Behavior") {
                Toggle("Auto-refresh printer list", isOn: $autoRefreshPrinters)
            }
            
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { newValue in
                        if newValue {
                            // Request notification permission if not granted
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                        }
                    }
                
                if !notificationsEnabled {
                    Text("Notifications are disabled. You won't receive alerts when print jobs complete or errors occur.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - PDF Settings

struct PDFSettingsView: View {
    @Binding var compressionQuality: Double
    @Binding var ocrLanguage: String
    @Binding var defaultDPI: Int
    
    let languages = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean")
    ]
    
    var body: some View {
        Form {
            Section("Compression") {
                VStack(alignment: .leading) {
                    Text("Quality: \(Int(compressionQuality * 100))%")
                    Slider(value: $compressionQuality, in: 0.1...1.0)
                    Text("Lower quality = smaller file size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("OCR") {
                Picker("Language:", selection: $ocrLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
            }
            
            Section("Rasterization") {
                Picker("DPI:", selection: $defaultDPI) {
                    Text("150 DPI (Draft)").tag(150)
                    Text("300 DPI (Standard)").tag(300)
                    Text("600 DPI (High Quality)").tag(600)
                }
                
                Text("Higher DPI = larger file size")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Image Settings

struct ImageSettingsView: View {
    @Binding var thumbnailSize: Double
    
    var body: some View {
        Form {
            Section("Display") {
                VStack(alignment: .leading) {
                    Text("Thumbnail Size: \(Int(thumbnailSize))px")
                    Slider(value: $thumbnailSize, in: 40...160, step: 20)
                }
            }
            
            Section("Processing") {
                Text("Image processing settings")
                    .foregroundColor(.secondary)
                Text("More settings coming soon...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "printer.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("PrintManager")
                .font(.title)
                .bold()
            
            Text("Version 1.0")
                .foregroundColor(.secondary)
            
            Divider()
                .frame(width: 200)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Features:")
                    .font(.headline)
                
                FeatureRow(icon: "printer.fill", text: "Fast PDF and image printing")
                FeatureRow(icon: "scissors", text: "PDF split, merge, compress")
                FeatureRow(icon: "doc.text.viewfinder", text: "OCR support")
                FeatureRow(icon: "photo.fill", text: "Image operations and conversion")
                FeatureRow(icon: "rectangle.on.rectangle.angled", text: "Extract sub-images")
            }
            .padding()
            
            Spacer()
            
            Text("© 2024 PrintManager. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.caption)
        }
    }
}

// MARK: - Google Settings

struct GoogleSettingsView: View {
    @ObservedObject private var googleAuth = GoogleOAuthManager.shared

    @AppStorage("googleClientSecret") private var clientSecret = ""
    @State private var showSecret = false

    private var effectiveSecret: String {
        clientSecret.isEmpty ? "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" : clientSecret
    }

    var body: some View {
        Form {
            // Hlavička
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Drive konverze")
                            .font(.headline)
                        Text("Převod Office souborů do PDF přes Google Drive API")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Stav přihlášení
            Section("Přihlášení") {
                HStack(spacing: 10) {
                    if googleAuth.isAuthenticated {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Přihlášen k Google Drive").font(.body)
                    } else if googleAuth.isAuthenticating {
                        ProgressView().scaleEffect(0.8)
                        Text("Čekám na přihlášení v prohlížeči…").font(.body).foregroundColor(.secondary)
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        Text("Nepřihlášen").font(.body).foregroundColor(.secondary)
                    }
                    Spacer()
                    if googleAuth.isAuthenticated {
                        Button("Odhlásit") {
                            GoogleOAuthManager.shared.signOut()
                        }
                        .foregroundColor(.red)
                    } else {
                        Button("Přihlásit se…") {
                            GoogleOAuthManager.shared.startLogin()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(googleAuth.isAuthenticating)
                    }
                }

                if let err = googleAuth.authError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Client Secret
            Section("OAuth Client Secret") {
                HStack {
                    Text("Client Secret:")
                        .frame(width: 110, alignment: .trailing)
                    Group {
                        if showSecret {
                            TextField("GOCSPX-…", text: $clientSecret)
                        } else {
                            SecureField("GOCSPX-…", text: $clientSecret)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button(action: { showSecret.toggle() }) {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showSecret ? "Skrýt" : "Zobrazit")
                }

                Text("Aktuálně aktivní: \(String(effectiveSecret.prefix(12)))…")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Spacer()
                    Button("Otevřít Google Cloud Console") {
                        NSWorkspace.shared.open(
                            URL(string: "https://console.cloud.google.com/apis/credentials")!
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            // Informace
            Section("Jak to funguje") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Klikni \"Prihlas se\" — otevre se prohlizec s prihlasovaci strankou Google")
                    Text("2. Přihlásíš se a udělíš přístup k souborům na Drive")
                    Text("3. Přihlášení proběhne automaticky, okno se samo zavře")
                    Text("4. Soubory se nahrají na Drive, převedou do PDF a ihned smažou")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - CloudConvert Settings

struct CloudConvertSettingsView: View {
    @AppStorage("cloudConvertEmail")  private var email  = ""
    @AppStorage("cloudConvertApiKey") private var apiKey = ""

    @State private var showApiKey  = false
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CloudConvert")
                            .font(.headline)
                        Text("Online konverze Office souborů do PDF")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Přihlašovací údaje") {
                HStack {
                    Text("E-mail:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("vas@email.cz", text: $email)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("API klíč:")
                        .frame(width: 80, alignment: .trailing)
                    Group {
                        if showApiKey {
                            TextField("eyJ0eXAiOiJKV1QiLCJhbGci…", text: $apiKey)
                        } else {
                            SecureField("eyJ0eXAiOiJKV1QiLCJhbGci…", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button(action: { showApiKey.toggle() }) {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showApiKey ? "Skrýt API klíč" : "Zobrazit API klíč")
                }

                HStack {
                    Spacer()
                    Button("Vytvořit / spravovat API klíč") {
                        NSWorkspace.shared.open(
                            URL(string: "https://cloudconvert.com/dashboard/api/v2/keys")!
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section("Test spojení") {
                HStack {
                    Button("Ověřit API klíč") {
                        testConnection()
                    }
                    .disabled(apiKey.isEmpty || testStatus == .testing)

                    switch testStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .scaleEffect(0.7)
                    case .ok:
                        Label("OK", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }

            Section("Informace") {
                Text("API klíč se ukládá lokálně v nastavení aplikace. Pro citlivé produkční nasazení doporučujeme použít Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("CloudConvert je placená online služba. Každá konverze spotřebuje kredity z vašeho účtu.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private func testConnection() {
        testStatus = .testing
        let key = apiKey
        Task {
            do {
                // Call /v2/users to verify the API key
                let url = URL(string: "https://api.cloudconvert.com/v2/users/me")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run { testStatus = .ok }
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    await MainActor.run { testStatus = .failed("HTTP \(code) – neplatný klíč?") }
                }
            } catch {
                await MainActor.run { testStatus = .failed(error.localizedDescription) }
            }
        }
    }
}

extension CloudConvertSettingsView.TestStatus: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.testing, .testing), (.ok, .ok): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

#Preview {
    SettingsView()
}
