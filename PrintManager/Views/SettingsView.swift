//
//  SettingsView.swift
//  PrintManager
//
//  Application settings and preferences
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("defaultPrinter")    private var defaultPrinter    = ""
    @AppStorage("defaultCopies")     private var defaultCopies     = 1
    @AppStorage("defaultTwoSided")   private var defaultTwoSided   = false
    @AppStorage("defaultCollate")    private var defaultCollate    = true
    @AppStorage("defaultFitToPage")  private var defaultFitToPage  = false
    @AppStorage("autoRefreshPrinters") private var autoRefreshPrinters = true
    @AppStorage("compressionQuality") private var compressionQuality = 0.7
    @AppStorage("ocrLanguage")       private var ocrLanguage       = "en"
    @AppStorage("defaultDPI")        private var defaultDPI        = 300

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
            .tabItem { Label("General", systemImage: "gear") }

            // PDF Settings
            PDFSettingsView(
                compressionQuality: $compressionQuality,
                ocrLanguage: $ocrLanguage,
                defaultDPI: $defaultDPI
            )
            .tabItem { Label("PDF", systemImage: "doc.fill") }

            // CloudConvert
            CloudConvertSettingsView()
                .tabItem { Label("CloudConvert", systemImage: "cloud.fill") }

            // Google
            GoogleSettingsView()
                .tabItem { Label("Google", systemImage: "g.circle.fill") }

            // Cena tisku
            PriceSettingsView()
                .tabItem { Label("Cena", systemImage: "eurosign.circle") }

            // About
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Price Settings View

struct PriceSettingsView: View {

    // A4 ČB
    @AppStorage("price.a4.bw.1")    private var a4bw1:    Double = 2.0
    @AppStorage("price.a4.bw.10")   private var a4bw10:   Double = 1.5
    @AppStorage("price.a4.bw.50")   private var a4bw50:   Double = 1.2
    @AppStorage("price.a4.bw.100")  private var a4bw100:  Double = 1.0
    // A4 Barevně
    @AppStorage("price.a4.col.1")   private var a4col1:   Double = 8.0
    @AppStorage("price.a4.col.10")  private var a4col10:  Double = 6.0
    @AppStorage("price.a4.col.50")  private var a4col50:  Double = 5.0
    @AppStorage("price.a4.col.100") private var a4col100: Double = 4.0
    // A3 ČB
    @AppStorage("price.a3.bw.1")    private var a3bw1:    Double = 4.0
    @AppStorage("price.a3.bw.10")   private var a3bw10:   Double = 3.0
    @AppStorage("price.a3.bw.50")   private var a3bw50:   Double = 2.5
    @AppStorage("price.a3.bw.100")  private var a3bw100:  Double = 2.0
    // A3 Barevně
    @AppStorage("price.a3.col.1")   private var a3col1:   Double = 16.0
    @AppStorage("price.a3.col.10")  private var a3col10:  Double = 12.0
    @AppStorage("price.a3.col.50")  private var a3col50:  Double = 10.0
    @AppStorage("price.a3.col.100") private var a3col100: Double = 8.0

    var body: some View {
        VStack(spacing: 0) {
            // Záhlaví tabulky
            HStack(spacing: 0) {
                Text("Formát / Typ")
                    .frame(maxWidth: .infinity, alignment: .leading)
                tierHeader("1+")
                tierHeader("10+")
                tierHeader("50+")
                tierHeader("100+")
                Text("Kč/str")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    priceRow(label: "A4 ČB",
                             v1: $a4bw1, v10: $a4bw10, v50: $a4bw50, v100: $a4bw100)
                    Divider().padding(.leading, 16)
                    priceRow(label: "A4 Barevně",
                             v1: $a4col1, v10: $a4col10, v50: $a4col50, v100: $a4col100)
                    Divider().padding(.leading, 16)
                    priceRow(label: "A3 ČB",
                             v1: $a3bw1, v10: $a3bw10, v50: $a3bw50, v100: $a3bw100)
                    Divider().padding(.leading, 16)
                    priceRow(label: "A3 Barevně",
                             v1: $a3col1, v10: $a3col10, v50: $a3col50, v100: $a3col100)
                }
            }

            Divider()

            // Vysvětlivka
            VStack(alignment: .leading, spacing: 2) {
                Text("Cenová hladina se určí podle celkového počtu stran ve výběru.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Ceny jsou v Kč za stránku včetně DPH.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func tierHeader(_ t: String) -> some View {
        Text(t)
            .frame(width: 62, alignment: .trailing)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func priceRow(label: String,
                          v1: Binding<Double>, v10: Binding<Double>,
                          v50: Binding<Double>, v100: Binding<Double>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            PriceField(value: v1)
            PriceField(value: v10)
            PriceField(value: v50)
            PriceField(value: v100)
            Text("Kč")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// Editovatelné pole pro cenu — TextField s Double binding
private struct PriceField: View {
    @Binding var value: Double
    @State private var text: String = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            .font(.system(size: 11, design: .monospaced))
            .onAppear { text = fmt(value) }
            .onSubmit { commit() }
            .onChange(of: value) { text = fmt($0) }
            .onExitCommand { commit() }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if let d = Double(cleaned), d >= 0 {
            value = d
        }
        text = fmt(value)
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

    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("tableRowFontSize")     private var tableRowFontSize: Double = 12
    @AppStorage("alwaysOnTop")          private var alwaysOnTop = false

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

            Section("Zobrazení") {
                Picker("Velikost písma v tabulce:", selection: $tableRowFontSize) {
                    Text("8").tag(8.0)
                    Text("10").tag(10.0)
                    Text("11").tag(11.0)
                    Text("12 (výchozí)").tag(12.0)
                    Text("13").tag(13.0)
                    Text("14").tag(14.0)
                    Text("16").tag(16.0)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 340)
            }

            Section("Behavior") {
                Toggle("Auto-refresh printer list", isOn: $autoRefreshPrinters)
                Toggle("Always on top", isOn: $alwaysOnTop)
                    .onChange(of: alwaysOnTop) { val in
                        applyWindowLevel(floating: val)
                    }
            }

            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { newValue in
                        if newValue {
                            UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                        }
                    }
                if !notificationsEnabled {
                    Text("Notifications are disabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }

    private func applyWindowLevel(floating: Bool) {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.isVisible && !w.isSheet {
                w.level = floating ? .floating : .normal
            }
        }
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

    @AppStorage("googleClientId")     private var clientId     = ""
    @AppStorage("googleClientSecret") private var clientSecret = ""
    @State private var showSecret = false

    private var credentialsConfigured: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty
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
                        .disabled(googleAuth.isAuthenticating || !credentialsConfigured)
                    }
                }

                if let err = googleAuth.authError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if !credentialsConfigured && !googleAuth.isAuthenticated {
                    Label("Nejdříve zadejte Client ID a Client Secret níže.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // OAuth přihlašovací údaje
            Section("OAuth přihlašovací údaje") {
                HStack {
                    Text("Client ID:")
                        .frame(width: 110, alignment: .trailing)
                    TextField("681515…apps.googleusercontent.com", text: $clientId)
                        .textFieldStyle(.roundedBorder)
                }

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
                    Text("1. Vytvoř OAuth 2.0 Desktop App klienta v Google Cloud Console")
                    Text("2. Zkopíruj Client ID a Client Secret sem")
                    Text("3. Klikni \"Přihlásit se\" — otevře se prohlížeč s přihlašovací stránkou Google")
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
