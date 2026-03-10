//
//  SettingsView.swift
//  PrintManager
//
//  Application settings and preferences
//

import SwiftUI
import UserNotifications
import AppKit

struct SettingsView: View {
    @Binding var isPresented: Bool

    @AppStorage("defaultPrinter")      private var defaultPrinter      = ""
    @AppStorage("autoRefreshPrinters") private var autoRefreshPrinters = true
    @AppStorage("compressionQuality")  private var compressionQuality  = 0.7
    @AppStorage("ocrLanguage")         private var ocrLanguage         = "en"
    @AppStorage("defaultDPI")          private var defaultDPI          = 300

    @StateObject private var printManager = PrintManager()
    @State private var selectedTab: SettingsTab = .general

    // MARK: - Tab definition

    enum SettingsTab: String, CaseIterable {
        case general      = "Obecné"
        case pdf          = "PDF"
        case printing     = "Tisk"
        case cloudConvert = "CloudConvert"
        case ilovepdf     = "iLovePDF"
        case google       = "Google"
        case cena         = "Cena"
        case about        = "About"

        var icon: String {
            switch self {
            case .general:      return "gear"
            case .pdf:          return "doc.fill"
            case .printing:     return "printer.fill"
            case .cloudConvert: return "cloud.fill"
            case .ilovepdf:     return "heart.circle.fill"
            case .google:       return "g.circle.fill"
            case .cena:         return "eurosign.circle"
            case .about:        return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .general:      return .gray
            case .pdf:          return .red
            case .printing:     return .indigo
            case .cloudConvert: return .blue
            case .ilovepdf:     return .pink
            case .google:       return Color(red: 0.25, green: 0.52, blue: 0.96)
            case .cena:         return .orange
            case .about:        return .accentColor
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Toolbar ──────────────────────────────────────────────
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        SettingsTabButton(tab: tab, isSelected: selectedTab == tab) {
                            selectedTab = tab
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Zavřít")
            }
            .background(DS.Colors.windowBackground)

            Divider()

            // ── Obsah ─────────────────────────────────────────────────
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(
                        defaultPrinter: $defaultPrinter,
                        autoRefreshPrinters: $autoRefreshPrinters,
                        printManager: printManager
                    )
                case .pdf:
                    PDFSettingsView(
                        compressionQuality: $compressionQuality,
                        ocrLanguage: $ocrLanguage,
                        defaultDPI: $defaultDPI
                    )
                case .printing:
                    PrintingSettingsView()
                case .cloudConvert:
                    CloudConvertSettingsView()
                case .ilovepdf:
                    ILovePDFSettingsView()
                case .google:
                    GoogleSettingsView()
                case .cena:
                    PriceSettingsView()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 540)
        .background {
            // Cmd+W zavře okno (keyboardShortcut nefunguje na VStack přímo)
            Button("") { isPresented = false }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
    }
}

// MARK: - Tab Button

private struct SettingsTabButton: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(isSelected ? tab.tint : Color.secondary)
                    .frame(height: 26)
                Text(LocalizedStringKey(tab.rawValue))
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? tab.tint : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? tab.tint.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.13), value: isSelected)
    }
}

// MARK: - Printing Settings View

struct PrintingSettingsView: View {

    enum CUPSStatus { case unknown, running, stopped }

    @State private var cupsStatus: CUPSStatus = .unknown
    @State private var maxJobTimeResult: ActionResult = .idle
    @State private var cupsEnableResult: ActionResult = .idle

    enum ActionResult { case idle, ok, failed(String) }

    var body: some View {
        Form {
            // MARK: CUPS Status
            Section("CUPS") {
                HStack(spacing: 10) {
                    Image(systemName: "printer.fill")
                        .font(DS.Typography.mediumIcon)
                        .foregroundColor(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CUPS – Common Unix Printing System")
                            .font(.headline)
                        Text("Spravuje tiskové fronty a komunikaci s tiskárnami.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)

                HStack(spacing: 10) {
                    switch cupsStatus {
                    case .unknown:
                        Image(systemName: "circle.dotted").foregroundColor(.secondary)
                        Text("Zjišťuji stav…").foregroundColor(.secondary)
                    case .running:
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("CUPS běží")
                    case .stopped:
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        Text("CUPS není spuštěn")
                    }
                    Spacer()
                    Button("Obnovit") { checkCUPSStatus() }
                        .controlSize(.small)
                }
            }

            // MARK: Enable CUPS
            Section("Zapnout CUPS") {
                Text("Pokud CUPS není spuštěn, tisk nebude fungovat. Toto tlačítko ho načte a povolí jako systémovou službu.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button("Zapnout CUPS") { enableCUPS() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.indigo)

                    resultBadge(cupsEnableResult)
                }
            }

            // MARK: MaxJobTime
            Section("Opravit zaseknuté tiskové joby") {
                Text("macOS CUPS někdy zastaví tiskový job před dokončením (výchozí časový limit). Nastavení MaxJobTime=0 odstraní tento limit — vhodné pro velké soubory a dávkový tisk.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button("Nastavit MaxJobTime = 0") { fixMaxJobTime() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.indigo)

                    resultBadge(maxJobTimeResult)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { checkCUPSStatus() }
    }

    @ViewBuilder
    private func resultBadge(_ result: ActionResult) -> some View {
        switch result {
        case .idle:
            EmptyView()
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

    // MARK: - Actions

    private func checkCUPSStatus() {
        cupsStatus = .unknown
        // Nejspolehlivější check: zkusit HTTP request na localhost:631
        // launchctl list bez sudo nevidí system-domain služby
        guard let url = URL(string: "http://localhost:631") else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode > 0 {
                    cupsStatus = .running
                } else if error == nil {
                    cupsStatus = .running
                } else {
                    cupsStatus = .stopped
                }
            }
        }.resume()
    }

    private func enableCUPS() {
        let cmd = "launchctl load -w /System/Library/LaunchDaemons/org.cups.cupsd.plist"
        runPrivileged(cmd) { success, error in
            cupsEnableResult = success ? .ok : .failed(error ?? NSLocalizedString("Chyba", comment: ""))
            if success { checkCUPSStatus() }
        }
    }

    private func fixMaxJobTime() {
        runPrivileged("cupsctl MaxJobTime=0") { success, error in
            maxJobTimeResult = success ? .ok : .failed(error ?? NSLocalizedString("Chyba", comment: ""))
        }
    }

    // Spustí příkaz bez oprávnění (jen čtení stavu)
    @discardableResult
    private func shell(_ command: String) -> String {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // Spustí privilegovaný příkaz přes AppleScript (zobrazí macOS dialog pro heslo)
    private func runPrivileged(_ command: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global().async {
            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            let src = "do shell script \"\(escaped)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&error)
            let success = error == nil
            let msg = error?[NSAppleScript.errorBriefMessage] as? String
            DispatchQueue.main.async { completion(success, msg) }
        }
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
        ScrollView {
            VStack(spacing: 0) {
                // ── Záhlaví tabulky A4/A3 ──
                HStack(spacing: 0) {
                    Text("Formát / Typ")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    tierHeader("1+")
                    tierHeader("10+")
                    tierHeader("50+")
                    tierHeader("100+")
                    Text("Kč/str")
                        .font(DS.Typography.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .font(DS.Typography.captionSemibold)
                .sectionPadding()
                .background(DS.Colors.controlBackground)

                Divider()

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

                Divider()

                // ── Velkoformátový tisk (ploter) ──
                LargeFormatPriceSettingsView()

                Divider()

                // Vysvětlivka
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cenová hladina A4/A3 se určí podle celkového počtu stran ve výběru.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Velkoformátový tisk: cena Kč za cm délky výtisku (délka zaokrouhlena nahoru).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Ceny jsou v Kč včetně DPH.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.small)
                .background(DS.Colors.controlBackground)
            }
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
                .font(DS.Typography.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            PriceField(value: v1)
            PriceField(value: v10)
            PriceField(value: v50)
            PriceField(value: v100)
            Text("Kč")
                .font(DS.Typography.caption2)
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Colors.windowBackground)
    }
}

// MARK: - Large Format Price Settings

struct LargeFormatPriceSettingsView: View {
    // ČB – Kč/cm
    @AppStorage("price.lf.914.bw") private var lf914bw: Double = 0.63
    @AppStorage("price.lf.841.bw") private var lf841bw: Double = 0.57
    @AppStorage("price.lf.594.bw") private var lf594bw: Double = 0.51
    @AppStorage("price.lf.420.bw") private var lf420bw: Double = 0.34
    @AppStorage("price.lf.297.bw") private var lf297bw: Double = 0.23
    // Barevně – Kč/cm
    @AppStorage("price.lf.914.col") private var lf914col: Double = 1.30
    @AppStorage("price.lf.841.col") private var lf841col: Double = 1.25
    @AppStorage("price.lf.594.col") private var lf594col: Double = 1.00
    @AppStorage("price.lf.420.col") private var lf420col: Double = 0.75
    @AppStorage("price.lf.297.col") private var lf297col: Double = 0.50
    // Složení – Kč/výkres
    @AppStorage("price.lf.914.fold") private var lf914fold: Double = 9.0
    @AppStorage("price.lf.841.fold") private var lf841fold: Double = 7.0
    @AppStorage("price.lf.594.fold") private var lf594fold: Double = 5.0
    @AppStorage("price.lf.420.fold") private var lf420fold: Double = 4.0
    @AppStorage("price.lf.297.fold") private var lf297fold: Double = 2.0

    var body: some View {
        VStack(spacing: 0) {
            // Záhlaví sekce
            HStack {
                Image(systemName: "printer.dotmatrix")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Velkoformátový tisk – ploter")
                    .font(DS.Typography.captionSemibold)
                    .foregroundColor(.primary)
                Spacer()
            }
            .sectionPadding()
            .background(DS.Colors.controlBackground)

            Divider()

            // Záhlaví tabulky
            HStack(spacing: 0) {
                Text("Šíře role")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("ČB Kč/cm")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundColor(.secondary)
                Text("Bar Kč/cm")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundColor(.secondary)
                Text("Složení Kč")
                    .frame(width: 74, alignment: .trailing)
                    .foregroundColor(.secondary)
            }
            .font(DS.Typography.caption2)
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.xxSmall)
            .background(DS.Colors.controlBackground)

            Divider()

            lfRow(label: "914 mm", bw: $lf914bw, col: $lf914col, fold: $lf914fold)
            Divider().padding(.leading, 16)
            lfRow(label: "841 mm", bw: $lf841bw, col: $lf841col, fold: $lf841fold)
            Divider().padding(.leading, 16)
            lfRow(label: "594 mm", bw: $lf594bw, col: $lf594col, fold: $lf594fold)
            Divider().padding(.leading, 16)
            lfRow(label: "420 mm", bw: $lf420bw, col: $lf420col, fold: $lf420fold)
            Divider().padding(.leading, 16)
            lfRow(label: "297 mm", bw: $lf297bw, col: $lf297col, fold: $lf297fold)
        }
    }

    @ViewBuilder
    private func lfRow(label: String,
                       bw: Binding<Double>,
                       col: Binding<Double>,
                       fold: Binding<Double>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(DS.Typography.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            PriceField(value: bw)
            PriceField(value: col)
            PriceField(value: fold)
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Colors.windowBackground)
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
            .font(DS.Typography.mono)
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
    @Binding var autoRefreshPrinters: Bool
    @ObservedObject var printManager: PrintManager

    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("tableRowFontSize")     private var tableRowFontSize: Double = 12
    @AppStorage("alwaysOnTop")          private var alwaysOnTop = false

    var body: some View {
        Form {
            Section("Výchozí tiskárna") {
                Picker("Tiskárna:", selection: $defaultPrinter) {
                    Text("Systémová výchozí").tag("")
                    ForEach(printManager.availablePrinters, id: \.self) { printer in
                        Text(printer).tag(printer)
                    }
                }
                Text("Vybraná tiskárna bude při spuštění automaticky označena v seznamu tiskáren.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
            }

            Section("Chování") {
                Toggle("Automaticky obnovit seznam tiskáren", isOn: $autoRefreshPrinters)
                Toggle("Vždy navrchu", isOn: $alwaysOnTop)
                    .onChange(of: alwaysOnTop) { val in
                        applyWindowLevel(floating: val)
                    }
            }

            Section("Oznámení") {
                Toggle("Povolit oznámení", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { newValue in
                        if newValue {
                            UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                        }
                    }
                if !notificationsEnabled {
                    Text("Oznámení jsou zakázána.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ImpositionGeneralSettingsSection()
        }
        .formStyle(.grouped)
    }

    private func applyWindowLevel(floating: Bool) {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.isVisible && !w.isSheet {
                w.level = floating ? .floating : .normal
            }
        }
    }
}

// MARK: - Imposition Settings Section (použito v GeneralSettingsView)

private struct ImpositionGeneralSettingsSection: View {
    @AppStorage("printerMarginMM") private var printerMarginMM: Double = 5.0

    var body: some View {
        Section("Imposition") {
            HStack {
                Text("Tiskový okraj tiskárny (mm):")
                Spacer()
                Stepper(value: $printerMarginMM, in: 0...30, step: 0.5) {
                    TextField("", value: $printerMarginMM, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }
            Text("Výchozí okraj od hrany papíru při vytváření imposice.\nTiskárna obvykle nemůže tisknout blíže k okraji.")
                .font(.caption)
                .foregroundColor(.secondary)
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
            Section("Komprese") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kvalita: \(Int(compressionQuality * 100))%")
                    Slider(value: $compressionQuality, in: 0.1...1.0)
                    Text("Nižší kvalita = menší soubor")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("OCR") {
                Picker("Jazyk:", selection: $ocrLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
            }

            Section("Rasterizace") {
                Picker("DPI:", selection: $defaultDPI) {
                    Text("150 DPI (náhled)").tag(150)
                    Text("300 DPI (standard)").tag(300)
                    Text("600 DPI (vysoká kvalita)").tag(600)
                }
                Text("Vyšší DPI = větší soubor")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
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
            
            Text("Version 2.0")
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
                        .font(DS.Typography.mediumIcon)
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
                    TextField("xxxxxxxxx.apps.googleusercontent.com", text: $clientId)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Client Secret:")
                        .frame(width: 110, alignment: .trailing)
                    Group {
                        if showSecret {
                            TextField("Client Secret", text: $clientSecret)
                        } else {
                            SecureField("Client Secret", text: $clientSecret)
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
        .formStyle(.grouped)
        .onDisappear { showSecret = false }
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
                        .font(DS.Typography.mediumIcon)
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
                            TextField("API Key", text: $apiKey)
                        } else {
                            SecureField("API Key", text: $apiKey)
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
        .formStyle(.grouped)
        .onDisappear { showApiKey = false }
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

// MARK: - iLovePDF Settings

struct ILovePDFSettingsView: View {
    @AppStorage("iLovePDFPublicKey") private var publicKey = ""
    @AppStorage("iLovePDFSecretKey") private var secretKey = ""

    @State private var showKeys = false
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "heart.circle.fill")
                        .font(DS.Typography.mediumIcon)
                        .foregroundColor(.pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iLovePDF")
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
                    Text("Public Key:")
                        .frame(width: 90, alignment: .trailing)
                    Group {
                        if showKeys {
                            TextField("project_public_...", text: $publicKey)
                        } else {
                            SecureField("project_public_...", text: $publicKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button(action: { showKeys.toggle() }) {
                        Image(systemName: showKeys ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showKeys ? "Skrýt klíč" : "Zobrazit klíč")
                }

                Text("ℹ️ Secret Key není potřeba - API používá pouze Public Key")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Spacer()
                    Button("Získat API klíče") {
                        NSWorkspace.shared.open(
                            URL(string: "https://developer.ilovepdf.com/")!
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section("Test spojení") {
                HStack {
                    Button("Ověřit Public Key") {
                        testConnection()
                    }
                    .disabled(publicKey.isEmpty || testStatus == .testing)

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
                VStack(alignment: .leading, spacing: 4) {
                    Text("• Free tier: 250 requestů/měsíc zdarma")
                    Text("• Registrace na: https://developer.ilovepdf.com/")
                    Text("• Potřebuješ pouze Public Key (začíná project_public_...)")
                    Text("• Secret Key se nepoužívá pro API (jen pro webhooks)")
                    Text("• Klíč se ukládá lokálně v nastavení aplikace")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { showKeys = false }
    }

    private func testConnection() {
        testStatus = .testing
        let pubKey = publicKey
        Task {
            do {
                // Test API - iLovePDF uses ONLY public key in Authorization
                let url = URL(string: "https://api.ilovepdf.com/v1/start/officepdf")!

                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue("Bearer \(pubKey)", forHTTPHeaderField: "Authorization")

                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run { testStatus = .ok }
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if let responseString = String(data: data, encoding: .utf8) {
                        await MainActor.run { testStatus = .failed("HTTP \(code) – \(responseString)") }
                    } else {
                        await MainActor.run { testStatus = .failed("HTTP \(code) – neplatné klíče?") }
                    }
                }
            } catch {
                await MainActor.run { testStatus = .failed(error.localizedDescription) }
            }
        }
    }
}

extension ILovePDFSettingsView.TestStatus: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.testing, .testing), (.ok, .ok): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

#Preview {
    SettingsView(isPresented: .constant(true))
}
