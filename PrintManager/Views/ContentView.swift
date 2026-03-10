//
//  ContentView.swift
//  PrintManager
//
//  Main window with 3-column layout: Printers | Settings+Table+Log | Preview
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO

// MARK: - Main Content View

// MARK: - Window Level Helper

/// NSViewRepresentable, který drží okno nad ostatními při alwaysOnTop = true.
private struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window, !window.isSheet else { return }
            window.level = floating ? .floating : .normal
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var printManager = PrintManager()
    @State private var keyMonitor: Any?
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        HStack(spacing: 0) {
            // Left: Printers list (collapsible)
            if appState.showPrinterPanel {
                PrinterListPanel(printManager: printManager)
                    .frame(width: 165)
                    .transition(.move(edge: .leading))

                Divider()
            }

            // Middle: Table + Log + Actions NEBO Inline QuickLook
            VStack(spacing: 0) {
                if appState.showInlineQuickLook {
                    // Inline QuickLook - zobrazí náhled místo tabulky
                    InlineQuickLookView()
                        .environmentObject(appState)
                        .frame(minHeight: 200)
                        .transition(.move(edge: .top))
                } else {
                    // Normální tabulka souborů
                    DropFileTableView()
                        .frame(minHeight: 200)
                        .transition(.move(edge: .top))
                }

                Divider()

                InlineLogView()
                    .frame(height: 100)

                Divider()

                BottomActionBar()
                    .compactPadding()
                    .background(DS.Colors.controlBackground)
            }
            .frame(minWidth: 460)

            Divider()

            // Right: Preview (collapsible)
            if appState.showPreview {
                CompactPreviewPanel()
                    .frame(width: 220)
                    .transition(.move(edge: .trailing))
            }
        }
        .fileImporter(
            isPresented: $appState.showingFilePicker,
            allowedContentTypes: appState.allowedFileTypes,
            allowsMultipleSelection: true
        ) { result in
            appState.handleFileSelection(result)
        }
        .sheet(isPresented: $appState.showCropView) {
            if let file = appState.cropFile {
                CropView(file: file)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showCompressionWindow) {
            CompressionDialog(isPresented: $appState.showCompressionWindow)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showPDFInfoWindow) {
            if let metadata = appState.currentPDFMetadata {
                PDFInfoView(isPresented: $appState.showPDFInfoWindow, metadata: metadata)
            }
        }
        .sheet(isPresented: $appState.showOfficeImportDialog) {
            OfficeImportDialog(isPresented: $appState.showOfficeImportDialog)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showMultiCropDialog) {
            if let file = appState.multiCropFile {
                MultiCropDialog(isPresented: $appState.showMultiCropDialog, file: file)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showColorPageSelector) {
            if let file = appState.colorPageSelectorFile {
                ColorPageSelectorView(isPresented: $appState.showColorPageSelector, file: file)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showBatchRename) {
            BatchRenameView(isPresented: $appState.showBatchRename)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showDrawingsDialog) {
            DrawingsDialog(isPresented: $appState.showDrawingsDialog)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingImpositionDialog) {
            if let file = appState.impositionSourceFile {
                ImpositionDialog(isPresented: $appState.showingImpositionDialog, sourceFile: file)
            }
        }
        .sheet(isPresented: $appState.showTilePDFDialog) {
            if !appState.tilePDFFiles.isEmpty {
                TilePDFDialog(isPresented: $appState.showTilePDFDialog,
                              files: appState.tilePDFFiles)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showExpandDialog) {
            if let file = appState.expandFile {
                ExpandDialog(isPresented: $appState.showExpandDialog, file: file)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(isPresented: $appState.showSettings)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showInDesignImport) {
            let selected = appState.files.filter { appState.selectedFiles.contains($0.id) }
            InDesignImportDialog(isPresented: $appState.showInDesignImport, files: selected)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showStitchDialog) {
            StitchDialog(isPresented: $appState.showStitchDialog,
                         imageFiles: appState.stitchImageFiles)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showWatermarkDialog) {
            WatermarkDialog(isPresented: $appState.showWatermarkDialog)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showResizeDialog) {
            if !appState.resizeDialogFiles.isEmpty {
                ResizeDialog(isPresented: $appState.showResizeDialog,
                             files: appState.resizeDialogFiles)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showImageAdjustDialog) {
            ImageAdjustDialog(isPresented: $appState.showImageAdjustDialog,
                              imageFiles: appState.imageAdjustFiles)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showGalleryDialog) {
            if !appState.galleryImageFiles.isEmpty {
                GalleryDialog(isPresented: $appState.showGalleryDialog,
                              imageFiles: appState.galleryImageFiles)
                    .environmentObject(appState)
                    // Každé otevření s jiným výběrem vynucí novou instanci view (reset @State)
                    .id(appState.galleryImageFiles.map(\.id.uuidString).joined())
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Cmd+I to toggle preview
                if event.modifierFlags.contains(.command) && event.keyCode == 34 { // 34 = I key
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.showPreview.toggle()
                        }
                    }
                    return nil
                }
                // Cmd+Shift+P to toggle printer panel
                if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) && event.keyCode == 35 { // 35 = P key
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.showPrinterPanel.toggle()
                        }
                    }
                    return nil
                }
                // Mezerník — Inline Quick Look (přepíná mezi seznamem souborů a náhledem)
                if event.keyCode == 49 {
                    let responder = NSApp.keyWindow?.firstResponder
                    let inTextField = responder is NSTextView || responder is NSTextField
                    if !inTextField && !appState.files.isEmpty {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appState.showInlineQuickLook.toggle()

                                if appState.showInlineQuickLook {
                                    // Naplnit seznam souborů k procházení (zachovat pořadí z files)
                                    if appState.selectedFiles.count > 1 {
                                        appState.quickLookFileIDs = appState.files
                                            .filter { appState.selectedFiles.contains($0.id) }
                                            .map(\.id)
                                    } else {
                                        appState.quickLookFileIDs = appState.files.map(\.id)
                                    }
                                    // Při otevření nastavit aktuálně vybraný soubor
                                    if let firstID = appState.selectedFiles.first {
                                        appState.quickLookFileID = firstID
                                    } else if let firstFile = appState.files.first {
                                        appState.quickLookFileID = firstFile.id
                                    }
                                    // Pro obrázky rovnou detailní náhled, pro ostatní thumbnails
                                    let selectedFile = appState.files.first { $0.id == appState.quickLookFileID }
                                    if selectedFile?.fileType.isImage == true {
                                        appState.quickLookMode = .singlePage
                                    } else {
                                        appState.quickLookMode = .thumbnails
                                    }
                                    appState.quickLookCurrentPage = 0
                                } else {
                                    // Při zavření resetovat režim
                                    appState.quickLookMode = .thumbnails
                                }
                            }
                        }
                        return nil
                    }
                }
                // Backspace / Cmd+Backspace — jen pokud není fokus v textovém poli
                if event.keyCode == 51 {
                    let responder = NSApp.keyWindow?.firstResponder
                    let inTextField = responder is NSTextView || responder is NSTextField
                    if !inTextField && !appState.selectedFiles.isEmpty {
                        let hasCommand = event.modifierFlags.contains(.command)
                        DispatchQueue.main.async {
                            if hasCommand {
                                appState.moveSelectedFilesToTrash() // Cmd+Backspace → koš
                            } else {
                                appState.removeSelectedFiles()       // Backspace → odstranit z listu
                            }
                        }
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        // Always on Top — sleduje AppStorage a nastavuje window.level
        .background(WindowLevelSetter(floating: alwaysOnTop))
        // Auto-výběr default tiskárny při prvním načtení
        .onChange(of: printManager.availablePrinters) { printers in
            guard appState.selectedPrinter.isEmpty, !printers.isEmpty else { return }
            let preferred = UserDefaults.standard.string(forKey: "defaultPrinter") ?? ""
            let def: String
            if !preferred.isEmpty && printers.contains(preferred) {
                def = preferred
            } else {
                def = printManager.defaultPrinter ?? printers[0]
            }
            appState.selectedPrinter = def
            appState.loadSystemPresets()
        }
    }
}

// MARK: - Printer List Panel

struct PrinterListPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var printManager: PrintManager
    @State private var printerIcons: [String: NSImage] = [:]
    @State private var selectedAppID: UUID? = nil
    @AppStorage("defaultPrinter") private var preferredPrinter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Apps sekce (přesná výška dle počtu aplikací) ─────────────────
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Spacing.xxSmall) {
                    Text("Apps")
                        .font(DS.Typography.captionSemibold)
                    Spacer()
                    Button { pickApp() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Přidat aplikaci")

                    Button {
                        if let id = selectedAppID {
                            appState.removeExternalApp(id: id)
                            selectedAppID = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Odebrat vybranou aplikaci")
                    .disabled(selectedAppID == nil)
                }
                .padding(.horizontal, DS.Spacing.smallMedium)
                .padding(.vertical, 7)

                Divider()

                if appState.externalApps.isEmpty {
                    HStack {
                        Spacer()
                        Text("Přidej aplikaci klikem na +")
                            .font(DS.Typography.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                } else {
                    // Přesná výška bez ScrollView — každý řádek ~38 px
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.externalApps) { app in
                            AppRowView(
                                app: app,
                                isSelected: selectedAppID == app.id,
                                onSelect: {
                                    selectedAppID = (selectedAppID == app.id) ? nil : app.id
                                }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Spacing.xSmall)
                    .padding(.vertical, DS.Spacing.xxSmall)
                }
            }
            .background(DS.Colors.controlBackground)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // ── Hlavička tiskáren ─────────────────────────────────────────────
            HStack(spacing: DS.Spacing.xxSmall) {
                Text("Printers")
                    .font(DS.Typography.captionSemibold)
                Spacer()
                Button {
                    printManager.refreshPrinters()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Aktualizovat seznam tiskáren")
            }
            .padding(.horizontal, DS.Spacing.smallMedium)
            .padding(.vertical, 7)

            Divider()

            // ── Seznam tiskáren (zbývající místo) ────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if printManager.availablePrinters.isEmpty {
                        Text("No printers found")
                            .font(DS.Typography.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, DS.Spacing.smallMedium)
                            .padding(.top, DS.Spacing.smallMedium)
                    } else {
                        ForEach(printManager.availablePrinters, id: \.self) { printer in
                            PrinterRowView(
                                printer: printer,
                                isSelected: appState.selectedPrinter == printer,
                                icon: printerIcons[printer],
                                status: printManager.printerStatuses[printer] ?? .idle,
                                isDefault: printManager.defaultPrinter == printer,
                                isPreferred: !preferredPrinter.isEmpty && preferredPrinter == printer,
                                ip: printManager.printerIPs[printer],
                                onSelect: {
                                    appState.selectedPrinter = printer
                                    appState.loadSystemPresets()
                                },
                                onOpenCUPS: { printManager.openCUPSPage(for: printer) },
                                onOpenCUPSMain: { printManager.openCUPSMainPage() },
                                onOpenQueue: { printManager.openPrintQueue(for: printer) },
                                onOpenIP: {
                                    if let host = printManager.printerIPs[printer] {
                                        printManager.openPrinterIPAddress(host)
                                    }
                                },
                                onDropFiles: { urls in
                                    appState.printFiles(urls: urls, toPrinter: printer)
                                }
                            )
                            .onAppear {
                                guard printerIcons[printer] == nil else { return }
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let icon = printManager.getNativePrinterIcon(for: printer)
                                    DispatchQueue.main.async {
                                        printerIcons[printer] = icon
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.xSmall)
                .padding(.vertical, DS.Spacing.xxSmall)
            }
            .background(DS.Colors.controlBackground)

            // ── Preset sekce ─────────────────────────────────────────────────
            if !appState.selectedPrinter.isEmpty {
                Divider()
                PresetSectionView()
                    .environmentObject(appState)
            }
        }
        .onAppear {
            if !appState.selectedPrinter.isEmpty {
                appState.loadSystemPresets()
            }
        }
    }

    // Otevře NSOpenPanel pro výběr .app aplikace
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Přidat"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                appState.addExternalApp(url: url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}

// MARK: - Preset Section View

struct PresetSectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPresetDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Záhlaví
            HStack(spacing: DS.Spacing.xxSmall) {
                Text("Preset")
                    .font(DS.Typography.captionSemibold)
                Spacer()

                // Zobrazit preset soubor ve Finderu
                if let fileURL = appState.systemPresetsFilePath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(DS.Typography.smallIcon)
                    }
                    .buttonStyle(.borderless)
                    .help("Ukázat preset soubor ve Finderu")
                }

                Button { appState.loadSystemPresets() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(DS.Typography.smallIcon)
                }
                .buttonStyle(.borderless)
                .help("Znovu načíst presety ze systému")

                Button {
                    if let name = appState.selectedPreset {
                        appState.deleteSystemPreset(name: name)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(DS.Typography.smallIcon)
                        .foregroundColor(appState.selectedPreset != nil ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(appState.selectedPreset == nil)
                .help("Smazat vybraný preset ze systému")
            }
            .padding(.horizontal, DS.Spacing.smallMedium)
            .padding(.vertical, 7)

            Divider()

            if appState.availableSystemPresets.isEmpty {
                Text("Žádné presety")
                    .font(DS.Typography.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                // Picker presetu
                Picker("", selection: $appState.selectedPreset) {
                    Text("— bez presetu —").tag(nil as String?)
                    ForEach(appState.availableSystemPresets) { preset in
                        Text(preset.name).tag(preset.name as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.horizontal, DS.Spacing.small)
                .padding(.top, DS.Spacing.xSmall)
                .onChange(of: appState.selectedPreset) { _ in showPresetDetails = false }

                // Info o vybraném presetu – skládací detail (jako u kalkulace)
                if let name = appState.selectedPreset,
                   let preset = appState.availableSystemPresets.first(where: { $0.name == name }) {
                    let info = PresetInfoParser.parse(preset.lpOptions)
                    if info.isEmpty {
                        Text("Žádné specifické nastavení")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, DS.Spacing.xSmall)
                    } else {
                        // Souhrnný řádek s chevronem
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) { showPresetDetails.toggle() }
                        }) {
                            HStack(spacing: DS.Spacing.xxSmall) {
                                Image(systemName: showPresetDetails ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 10)
                                Text("\(info.count) nastavení")
                                    .font(DS.Typography.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, DS.Spacing.small)
                        .padding(.top, DS.Spacing.xxSmall)
                        .padding(.bottom, showPresetDetails ? 0 : DS.Spacing.xSmall)

                        // Výklápěcí detail
                        if showPresetDetails {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(info, id: \.label) { item in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text(item.label + ":")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .frame(width: 62, alignment: .leading)
                                            .lineLimit(1)
                                        Text(item.value)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.windowBackgroundColor))
                            .cornerRadius(DS.Radius.medium)
                            .padding(.horizontal, DS.Spacing.small)
                            .padding(.bottom, DS.Spacing.xSmall)
                        }
                    }
                }
                Spacer().frame(height: DS.Spacing.xSmall)
            }
        }
        .background(DS.Colors.controlBackground)
    }
}

// MARK: - Preset Info Parser

enum PresetInfoParser {
    /// Parsuje lpOptions a vrací seznam párů (popisek, hodnota) pro zobrazení.
    static func parse(_ lpOptions: [String]) -> [(label: String, value: String)] {
        var result: [(label: String, value: String)] = []
        var i = 0
        while i < lpOptions.count {
            let token = lpOptions[i]
            if token == "-n", i + 1 < lpOptions.count {
                let n = lpOptions[i + 1]
                if let count = Int(n), count > 1 {
                    result.append((label: "Kopie", value: "\(count)"))
                }
                i += 2
            } else if token == "-o", i + 1 < lpOptions.count {
                if let pair = interpret(lpOptions[i + 1]) {
                    result.append(pair)
                }
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func interpret(_ opt: String) -> (label: String, value: String)? {
        switch opt {
        case "sides=two-sided-long-edge":   return ("Strany", "Oboustranný (dl.)")
        case "sides=two-sided-short-edge":  return ("Strany", "Oboustranný (kr.)")
        case "sides=one-sided":             return nil
        case "fit-to-page":                 return ("Velikost", "Přizpůsobit")
        case "orientation-requested=4",
             "orientation-requested=6":     return ("Orientace", "Na šířku")
        case "orientation-requested=3":     return nil
        default: break
        }

        let parts = opt.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let key = parts[0], value = parts[1]

        switch key {
        case "Collate":
            return value.lowercased() == "false" ? ("Řazení", "Vypnuto") : nil

        case "ColorModel":
            switch value.lowercased() {
            case "gray", "grayscale", "black", "greyscale": return ("Barvy", "ČB")
            case "rgb":  return nil
            case "color": return ("Barvy", "Barevně")
            default:      return ("Barvy", value)
            }

        case "media", "PageSize":
            return ("Formát", value)

        case "print-quality":
            switch value {
            case "3": return ("Kvalita", "Náhled")
            case "5": return nil
            case "7": return ("Kvalita", "Vysoká")
            default:  return nil
            }

        case "MediaType":
            let epsonCodes: [String: String] = [
                "0": "Obyčejný papír", "1": "Bright White Paper",
                "2": "Matný fotopapír", "3": "Fotopapír",
                "7": "CD/DVD", "9": "Ultra Premium Photo",
                "10": "Premium Presentation Matte", "12": "Speciální médium",
                "13": "Premium Photo Glossy"
            ]
            let textCodes: [String: String] = [
                "Plain": "Obyčejný papír", "Photo": "Fotopapír",
                "Cardstock": "Kartón", "Envelope": "Obálka",
                "Transparency": "Fólie", "Matte": "Matný"
            ]
            let label = epsonCodes[value] ?? textCodes[value] ?? value
            return ("Médium", label)

        case "Resolution":
            let clean = value
                .replacingOccurrences(of: "x", with: "×")
                .replacingOccurrences(of: "dpi", with: " dpi")
            return ("Rozlišení", clean)

        case "CustomProfile":
            let filename = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
            return ("Profil", filename)

        default:
            let skipKeys: Set<String> = [
                "PresetName", "PresetMenuName", "DocumentName",
                "PMTiogaScalingFactor", "PMScaling", "PaperInfoIsSuggested"
            ]
            if skipKeys.contains(key) { return nil }
            if key.hasPrefix("com.") || key.hasPrefix("PMTicket") { return nil }
            if key.hasPrefix("EPIJ_") || key.hasPrefix("EPSON.") { return nil }
            if Int(value) != nil && key.count > 8 { return nil }
            return (key, value)
        }
    }
}

// MARK: - Save Preset View

struct SavePresetView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var presetStore: PrinterPresetStore
    let printerName: String
    @Binding var isPresented: Bool
    
    @State private var presetName = ""
    @State private var copies: Int = 1
    @State private var twoSided: Bool = false
    @State private var collate: Bool = true
    @State private var fitToPage: Bool = false
    @State private var landscape: Bool = false
    @State private var colorMode: String = "auto"
    @State private var paperSize: String = "A4"
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Save Printer Preset")
                .font(.headline)
            
            Form {
                TextField("Preset Name:", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                
                Section("Current Settings") {
                    HStack {
                        Text("Copies:")
                        Stepper("\(copies)", value: $copies, in: 1...999)
                    }
                    
                    Toggle("Two-sided", isOn: $twoSided)
                    Toggle("Collate", isOn: $collate)
                    Toggle("Fit to page", isOn: $fitToPage)
                    Toggle("Landscape", isOn: $landscape)
                    
                    Picker("Color:", selection: $colorMode) {
                        Text("Auto").tag("auto")
                        Text("Color").tag("color")
                        Text("Grayscale").tag("grayscale")
                    }
                    
                    Picker("Paper Size:", selection: $paperSize) {
                        Text("A4").tag("A4")
                        Text("A3").tag("A3")
                        Text("A5").tag("A5")
                        Text("Letter").tag("Letter")
                        Text("Legal").tag("Legal")
                    }
                }
            }
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Save") {
                    savePreset()
                }
                .disabled(presetName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 320, height: 400)
        .onAppear {
            // Initialize with current appState values
            copies = appState.printCopies
            twoSided = appState.printTwoSided
            collate = appState.printCollate
            fitToPage = appState.printFitToPage
            landscape = appState.printLandscape
            colorMode = appState.printColorMode
            paperSize = appState.printPaperSize
        }
    }
    
    private func savePreset() {
        let preset = PrinterPreset(
            name: presetName,
            printerName: printerName,
            copies: copies,
            twoSided: twoSided,
            collate: collate,
            fitToPage: fitToPage,
            landscape: landscape,
            colorMode: colorMode,
            paperSize: paperSize
        )
        presetStore.addPreset(preset)
        isPresented = false
    }
}

// MARK: - Printer Row View

struct PrinterRowView: View {
    let printer: String
    let isSelected: Bool
    let icon: NSImage?
    let status: PrinterStatus
    let isDefault: Bool
    let isPreferred: Bool
    let ip: String?
    let onSelect: () -> Void
    let onOpenCUPS: () -> Void
    let onOpenCUPSMain: () -> Void
    let onOpenQueue: () -> Void
    let onOpenIP: () -> Void
    var onDropFiles: (([URL]) -> Void)? = nil

    @State private var isDropTargeted = false

    private var statusLabel: String {
        isDefault ? "\(status.label), Default" : status.label
    }

    private var dotColor: Color {
        isSelected ? .white.opacity(0.85) : Color(status.color)
    }

    var body: some View {
        HStack(spacing: DS.Spacing.smallMedium) {
            // Printer icon
            if let nsImage = icon {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "printer.fill")
                    .font(.system(size: 22))
                    .frame(width: 32, height: 32)
                    .foregroundColor(isSelected ? .white : .accentColor)
            }

            // Name + status
            VStack(alignment: .leading, spacing: DS.Spacing.xxxSmall) {
                Text(printer)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white : .primary)

                HStack(spacing: DS.Spacing.xxSmall) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(statusLabel)
                        .font(DS.Typography.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(statusLabel)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Preferred marker (nastaveno v Preferences)
            if isPreferred {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white.opacity(0.9) : .accentColor)
                    .help("Výchozí tiskárna (nastaveno v Preferences)")
            }
        }
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, DS.Spacing.xSmall)
        .background(
            isDropTargeted
                ? Color.accentColor.opacity(0.18)
                : (isSelected ? Color.accentColor : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .cornerRadius(DS.Radius.small)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenQueue() }
        .onTapGesture(count: 1) { onSelect() }
        .onDrop(of: [.fileURL], isTargeted: onDropFiles != nil ? $isDropTargeted : .constant(false)) { providers in
            guard let handler = onDropFiles else { return false }
            let group = DispatchGroup()
            var dropped: [URL] = []
            let q = DispatchQueue(label: "pm.printerrow.drop")
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        q.sync { dropped.append(url) }
                    }
                }
            }
            group.notify(queue: .main) {
                guard !dropped.isEmpty else { return }
                handler(dropped)
            }
            return true
        }
        .contextMenu {
            Button {
                onOpenQueue()
            } label: {
                Label("Otevřít tiskovou frontu", systemImage: "tray.full")
            }
            if let host = ip {
                Button {
                    onOpenIP()
                } label: {
                    Label("Otevřít IP adresu (\(host))", systemImage: "network")
                }
            }
            Divider()
            Button {
                onOpenCUPS()
            } label: {
                Label("Open CUPS page for \(printer)", systemImage: "network")
            }
            Divider()
            Button {
                onOpenCUPSMain()
            } label: {
                Label("Open CUPS Interface", systemImage: "globe")
            }
        }
    }
}

// MARK: - App Row View

struct AppRowView: View {
    let app: ExternalApp
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var icon: NSImage? = nil
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Group {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(Color(NSColor.controlColor))
                        .frame(width: 28, height: 28)
                }
            }

            Text(app.name)
                .font(DS.Typography.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(isSelected ? .white : .primary)
        }
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(isSelected
                      ? Color.accentColor
                      : (isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        // Jeden klik = výběr, dvojklik = otevřít vybrané soubory
        .onTapGesture(count: 2) { appState.openSelectedFilesInApp(app) }
        .onTapGesture(count: 1) { onSelect() }
        // Drop zóna — přetáhni soubory z Finderu nebo jiné aplikace
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let group = DispatchGroup()
            var dropped: [URL] = []
            let q = DispatchQueue(label: "pm.approw.drop")
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        q.sync { dropped.append(url) }
                    }
                }
            }
            group.notify(queue: .main) {
                guard !dropped.isEmpty else { return }
                NSWorkspace.shared.open(dropped, withApplicationAt: app.url,
                                        configuration: .init()) { _, err in
                    DispatchQueue.main.async {
                        if let err = err {
                            appState.logError("\(app.name): \(err.localizedDescription)")
                        } else {
                            appState.logSuccess("Otevřeno v \(app.name): \(dropped.count) soubor(ů)")
                        }
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button(role: .destructive) {
                appState.removeExternalApp(id: app.id)
            } label: {
                Label("Odebrat ze seznamu", systemImage: "trash")
            }
        }
        .onAppear {
            guard icon == nil else { return }
            DispatchQueue.global(qos: .utility).async {
                let img = NSWorkspace.shared.icon(forFile: app.path)
                DispatchQueue.main.async { icon = img }
            }
        }
    }
}

// MARK: - Printer Settings Bar

struct PrinterSettingsBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var printManager: PrintManager

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            Text("Printer setting")
                .font(DS.Typography.headline)

            HStack(spacing: DS.Spacing.large) {
                // Copies
                HStack(spacing: DS.Spacing.xxSmall) {
                    Text("Copies:")
                        .font(DS.Typography.subheadline)
                    Stepper("\(appState.printCopies)", value: $appState.printCopies, in: 1...999)
                        .frame(width: 88)
                }

                // Paper size
                HStack(spacing: DS.Spacing.xxSmall) {
                    Text("Paper size:")
                        .font(DS.Typography.subheadline)
                    Picker("", selection: $appState.printPaperSize) {
                        Text("A4").tag("A4")
                        Text("A3").tag("A3")
                        Text("A5").tag("A5")
                        Text("Letter").tag("Letter")
                        Text("Legal").tag("Legal")
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }

                Divider().frame(height: 20)

                // Two-sided
                Toggle("two-sided", isOn: $appState.printTwoSided)
                    .font(DS.Typography.subheadline)

                // Orientation button
                Button(action: { appState.printLandscape.toggle() }) {
                    Image(systemName: appState.printLandscape
                          ? "rectangle" : "rectangle.portrait")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .help(appState.printLandscape ? "Landscape" : "Portrait")
                .accessibilityLabel(appState.printLandscape ? "Landscape orientation" : "Portrait orientation")

                // Fit to page
                Toggle("Fit to page", isOn: $appState.printFitToPage)
                    .font(DS.Typography.subheadline)

                Divider().frame(height: 20)

                // Color
                HStack(spacing: DS.Spacing.xxSmall) {
                    Text("Color:")
                        .font(DS.Typography.subheadline)
                    Picker("", selection: $appState.printColorMode) {
                        Text("Auto").tag("auto")
                        Text("Color").tag("color")
                        Text("Grayscale").tag("grayscale")
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }

                Spacer()

                // Refresh button
                Button(action: { printManager.refreshPrinters() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(DS.Typography.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh printers")
                .accessibilityLabel("Refresh printers")
            }
        }
    }
}

// MARK: - Drop File Table View

// MARK: - Column Widths (shared state)

final class ColumnWidths: ObservableObject {
    @Published var size:      CGFloat
    @Published var kind:      CGFloat
    @Published var fileSize:  CGFloat
    @Published var pages:     CGFloat
    @Published var colors:    CGFloat
    @Published var converted: CGFloat

    private enum K {
        static let size      = "cw3_size"
        static let kind      = "cw3_kind"
        static let fileSize  = "cw3_fileSize"
        static let pages     = "cw3_pages"
        static let colors    = "cw3_colors"
        static let converted = "cw3_converted"
    }

    init() {
        let ud = UserDefaults.standard
        func r(_ key: String, _ def: CGFloat) -> CGFloat {
            let v = ud.double(forKey: key); return v > 0 ? CGFloat(v) : def
        }
        size      = r(K.size,      80)
        kind      = r(K.kind,      50)
        fileSize  = r(K.fileSize,  70)
        pages     = r(K.pages,     48)
        colors    = r(K.colors,    65)
        converted = r(K.converted, 36)
    }

    func persist() {
        let ud = UserDefaults.standard
        ud.set(Double(size),      forKey: K.size)
        ud.set(Double(kind),      forKey: K.kind)
        ud.set(Double(fileSize),  forKey: K.fileSize)
        ud.set(Double(pages),     forKey: K.pages)
        ud.set(Double(colors),    forKey: K.colors)
        ud.set(Double(converted), forKey: K.converted)
    }
}

struct DropFileTableView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false
    @AppStorage("tableRowFontSize") private var tableRowFontSize: Double = 12
    @StateObject private var colWidths = ColumnWidths()

    var body: some View {
        Group {
            if !appState.files.isEmpty {
                VStack(spacing: 0) {
                    FileListHeader(
                        hiddenColumns: $appState.hiddenColumns,
                        sortKey: $appState.fileSortKey,
                        sortAscending: $appState.fileSortAscending
                    )
                    .environmentObject(colWidths)

                    Divider()

                    List(appState.sortedFiles, selection: $appState.selectedFiles) { file in
                        FileListRow(file: file, hiddenColumns: appState.hiddenColumns)
                            .tag(file.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .environment(\.font, .system(size: CGFloat(tableRowFontSize)))
                    .environmentObject(colWidths)
                    .contextMenu(forSelectionType: UUID.self) { items in
                        if !items.isEmpty {
                            // File Operations
                            Button(action: { appState.revealInFinder(items: items) }) {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Button(action: { appState.openInDefaultApp(items: items) }) {
                                Label("Open", systemImage: "arrow.up.forward.app")
                            }
                            Divider()
                            if items.count == 1 {
                                Button(action: { appState.editingFileID = items.first }) {
                                    Label("Rename", systemImage: "pencil")
                                }
                            }
                            Button(action: { appState.openBatchRename() }) {
                                Label("Rename Selected…", systemImage: "pencil.line")
                            }
                            Divider()

                            // PDF / Image akce podle výběru
                            let selectedFiles = appState.files.filter { items.contains($0.id) }
                            let hasImage = selectedFiles.contains { $0.fileType.isImage }
                            let hasPDF   = selectedFiles.contains { $0.fileType == .pdf }

                            if hasImage && !hasPDF {
                                imageActionsMenuContent(appState)
                            } else {
                                pdfActionsMenuContent(appState)
                            }

                            Divider()
                            Button(role: .destructive, action: {
                                DispatchQueue.main.async {
                                    appState.removeFiles(items: items)
                                }
                            }) {
                                Label("Remove from List", systemImage: "trash")
                            }
                        }
                    } primaryAction: { items in
                        appState.openInDefaultApp(items: items)
                    }
                }
            } else {
                VStack(spacing: DS.Spacing.smallMedium) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Drag files here or click + to add")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(DS.Spacing.xxxSmall)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let group = DispatchGroup()
            var droppedURLs: [URL] = []
            let serialQ = DispatchQueue(label: "pm.drop.urls")

            for provider in providers {
                group.enter()
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        serialQ.sync { droppedURLs.append(url) }
                    }
                }
            }

            group.notify(queue: .main) {
                guard !droppedURLs.isEmpty else { return }
                // Filtrovat soubory již přítomné v listu — zabrání duplicitám
                // při přetažení řádku v rámci samotného listu (row.onDrag → table.onDrop)
                let existingPaths = Set(appState.files.map { $0.url.path })
                let newURLs = droppedURLs.filter { !existingPaths.contains($0.path) }
                guard !newURLs.isEmpty else { return }
                appState.addFiles(urls: newURLs)
            }
            return true
        }
    }
}

// MARK: - Column Resize Strip (overlay on trailing edge of header cell)

private struct ColResizeStrip: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = 40
    var maxWidth: CGFloat = 500
    var onEnd: () -> Void = {}

    @State private var startWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.0001))
            .frame(width: 8)
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startWidth == 0 { startWidth = width }
                        width = min(maxWidth, max(minWidth, startWidth + v.translation.width))
                    }
                    .onEnded { _ in
                        startWidth = 0
                        onEnd()
                    }
            )
    }
}

// MARK: - File List Header

struct FileListHeader: View {
    @Binding var hiddenColumns: Set<FileListColumn>
    @Binding var sortKey: FileSortKey
    @Binding var sortAscending: Bool
    @EnvironmentObject var colWidths: ColumnWidths

    var body: some View {
        HStack(spacing: 0) {
            headerButton("File", key: .name)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

            if !hiddenColumns.contains(.size) {
                headerButton("Size", key: .size)
                    .frame(width: colWidths.size, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        ColResizeStrip(width: $colWidths.size) { colWidths.persist() }
                    }
            }
            if !hiddenColumns.contains(.kind) {
                headerButton("Kind", key: .kind)
                    .frame(width: colWidths.kind, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        ColResizeStrip(width: $colWidths.kind) { colWidths.persist() }
                    }
            }
            if !hiddenColumns.contains(.fileSize) {
                headerButton("File size", key: .fileSize)
                    .frame(width: colWidths.fileSize, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        ColResizeStrip(width: $colWidths.fileSize) { colWidths.persist() }
                    }
            }
            if !hiddenColumns.contains(.pages) {
                headerButton("Pages", key: .pages)
                    .frame(width: colWidths.pages, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        ColResizeStrip(width: $colWidths.pages) { colWidths.persist() }
                    }
            }
            if !hiddenColumns.contains(.colors) {
                headerButton("Colors", key: .colors)
                    .frame(width: colWidths.colors, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        ColResizeStrip(width: $colWidths.colors) { colWidths.persist() }
                    }
            }
            if !hiddenColumns.contains(.converted) {
                Text("✓")
                    .frame(width: colWidths.converted, alignment: .center)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Text("File").foregroundColor(.secondary)

            ForEach(FileListColumn.allCases, id: \.self) { column in
                Button {
                    if hiddenColumns.contains(column) {
                        hiddenColumns.remove(column)
                    } else {
                        hiddenColumns.insert(column)
                    }
                } label: {
                    HStack {
                        if !hiddenColumns.contains(column) {
                            Image(systemName: "checkmark")
                        }
                        Text(column.rawValue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headerButton(_ title: String, key: FileSortKey) -> some View {
        Button(action: {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = true
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                    .fontWeight(sortKey == key ? .semibold : .regular)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - File List Row

struct FileListRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var colWidths: ColumnWidths
    let file: FileItem
    let hiddenColumns: Set<FileListColumn>

    var body: some View {
        HStack(spacing: 0) {
            FileRowView(file: file)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

            if !hiddenColumns.contains(.size) {
                Text(file.pageSizeString)
                    .frame(width: colWidths.size, alignment: .leading)
            }
            if !hiddenColumns.contains(.kind) {
                Text(file.fileType.rawValue.lowercased())
                    .frame(width: colWidths.kind, alignment: .leading)
            }
            if !hiddenColumns.contains(.fileSize) {
                Text(file.fileSizeFormatted)
                    .frame(width: colWidths.fileSize, alignment: .leading)
            }
            if !hiddenColumns.contains(.pages) {
                Text("\(file.pageCount)")
                    .frame(width: colWidths.pages, alignment: .leading)
            }
            if !hiddenColumns.contains(.colors) {
                Text(file.colorInfo)
                    .foregroundColor(file.colorInfo.contains("CMYK") ? .cyan : .primary)
                    .frame(width: colWidths.colors, alignment: .leading)
            }
            if !hiddenColumns.contains(.converted) {
                Group {
                    if file.isConverted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: colWidths.converted, alignment: .center)
            }
        }
        .onDrag {
            // Registruje public.file-url – funguje pro přesun, otevření v aplikaci i tisk (ikona tiskárny)
            // SwiftUI List automaticky přidá providery všech vybraných řádků do drag session
            NSItemProvider(object: file.url as NSURL)
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: file.fileType.icon)
                    .foregroundColor(file.fileType.listColor)
                let isMulti = appState.selectedFiles.count > 1 && appState.selectedFiles.contains(file.id)
                Text(isMulti ? "\(appState.selectedFiles.count) souborů" : file.name)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .cornerRadius(8)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onEnded { value in
                // Ignoruj skutečný drag, jen reaguj na kliknutí (pohyb < 5 pt)
                let dist = hypot(value.translation.width, value.translation.height)
                guard dist < 5 else { return }
                let isShift = NSEvent.modifierFlags.contains(.shift)
                let isCmd   = NSEvent.modifierFlags.contains(.command)
                DispatchQueue.main.async {
                    if isShift,
                       let anchorID  = appState.rangeAnchorID,
                       let anchorIdx = appState.sortedFiles.firstIndex(where: { $0.id == anchorID }),
                       let curIdx    = appState.sortedFiles.firstIndex(where: { $0.id == file.id }) {
                        let lo = min(anchorIdx, curIdx)
                        let hi = max(anchorIdx, curIdx)
                        appState.selectedFiles = Set(appState.sortedFiles[lo...hi].map { $0.id })
                    } else if !isShift && !isCmd {
                        appState.rangeAnchorID = file.id
                    }
                }
            }
        )
    }
}

// MARK: - Inline Log View

struct InlineLogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(appState.debugMessages) { message in
                        Text(message.message)
                            .font(DS.Typography.mono)
                            .foregroundColor(logColor(for: message.level))
                            .textSelection(.enabled)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xSmall)
            }
            .background(DS.Colors.darkBackground)
            .onChange(of: appState.debugMessages.count) { _ in
                if let last = appState.debugMessages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logColor(for level: DebugLevel) -> Color {
        switch level {
        case .info:    return DS.Colors.logInfo
        case .success: return DS.Colors.logSuccess
        case .warning: return DS.Colors.logWarning
        case .error:   return DS.Colors.logError
        }
    }
}

// MARK: - Bottom Action Bar

struct BottomActionBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            // Rotate Left (90° CCW) — Cmd+Shift+R
            Button(action: { appState.rotateSelectedFilesLeft() }) {
                Image(systemName: "rotate.left")
                    .font(DS.Typography.actionIcon)
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Rotate 90° counter-clockwise (⌘⇧R)")
            .accessibilityLabel("Rotate left")
            .keyboardShortcut("r", modifiers: [.command, .shift])

            // Rotate Right (90° CW) — Cmd+R
            Button(action: { appState.rotateSelectedFiles() }) {
                Image(systemName: "rotate.right")
                    .font(DS.Typography.actionIcon)
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Rotate 90° clockwise (⌘R)")
            .accessibilityLabel("Rotate right")
            .keyboardShortcut("r", modifiers: .command)

            // PDF Actions menu
            Menu {
                pdfActionsMenuContent(appState)
            } label: {
                HStack(spacing: 3) {
                    Text("PDF Actions")
                        .font(DS.Typography.subheadline)
                    Image(systemName: "chevron.down")
                        .font(DS.Typography.menuChevron)
                }
            }
            .frame(width: 130)

            // Image Actions menu
            Menu {
                imageActionsMenuContent(appState)
            } label: {
                HStack(spacing: 3) {
                    Text("Image Actions")
                        .font(DS.Typography.subheadline)
                    Image(systemName: "chevron.down")
                        .font(DS.Typography.menuChevron)
                }
            }
            .frame(width: 140)

            // Výkresy
            Button {
                appState.openDrawingsDialog()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "pencil.and.ruler")
                    Text("Výkresy")
                }
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Zpracování naskenovaných výkresů")

            // Import to InDesign
            Button {
                appState.openInDesignImport()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text("Import to InDesign")
                }
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Importovat vybrané soubory do Adobe InDesign")

            // Print button
            Button("Print selected") {
                appState.printSelectedFiles()
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.selectedFiles.isEmpty)

            Spacer()
        }
    }
}

// MARK: - Compact Preview Panel

struct CompactPreviewPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage = 0
    @State private var selectedTab: Int = 0
    @State private var showLargePreview = false

    private var selectedFile: FileItem? {
        guard appState.selectedFiles.count == 1,
              let id = appState.selectedFiles.first else { return nil }
        return appState.files.first { $0.id == id }
    }

    // Spustí barevnou analýzu pro všechny vybrané PDF soubory (pro kalkulaci)
    private func triggerColorAnalysisForPricing() {
        let pdfFiles = appState.files.filter {
            appState.selectedFiles.contains($0.id) && $0.fileType == .pdf
        }
        for file in pdfFiles {
            appState.loadPDFMetadataIfNeeded(for: file)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with toggle
            HStack {
                Text("Preview file")
                    .font(DS.Typography.headline)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showPreview.toggle()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(DS.Typography.chevron)
                }
                .buttonStyle(.borderless)
                .help("Collapse")
                .accessibilityLabel("Collapse preview")
            }
            .headerPadding()

            Divider()

            if appState.selectedFiles.isEmpty {
                VStack(spacing: DS.Spacing.medium) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No file selected")
                        .font(DS.Typography.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nahoře vždy: preview obrázek
                if let file = selectedFile {
                    VStack(spacing: DS.Spacing.small) {
                        PreviewImageView(file: file, currentPage: $currentPage)
                            .id("\(file.id)-\(file.contentVersion)")
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, DS.Spacing.small)
                            .padding(.top, DS.Spacing.small)
                            .onTapGesture { showLargePreview = true }
                            .help("Klikni pro velký náhled")
                            .sheet(isPresented: $showLargePreview) {
                                LargePreviewSheet(file: file, startPage: currentPage)
                                    .environmentObject(appState)
                            }

                        Text(file.name + "." + file.fileType.rawValue.lowercased())
                            .font(DS.Typography.captionSemibold)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, DS.Spacing.xSmall)

                        if file.pageCount > 1 {
                            HStack(spacing: DS.Spacing.medium) {
                                Button(action: {
                                    if currentPage > 0 { currentPage -= 1 }
                                }) {
                                    Image(systemName: "arrow.left.circle")
                                        .font(.title3)
                                }
                                .disabled(currentPage == 0)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Previous page")

                                Text("\(currentPage + 1)")
                                    .font(DS.Typography.subheadline)

                                Button(action: {
                                    if currentPage < file.pageCount - 1 { currentPage += 1 }
                                }) {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.title3)
                                }
                                .disabled(currentPage >= file.pageCount - 1)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Next page")
                            }
                        }
                    }
                    .onChange(of: appState.selectedFiles) { _ in currentPage = 0 }
                }

                Divider()

                // Záložky
                Picker("", selection: $selectedTab) {
                    Text("Informace").tag(0)
                    Text("Kalkulace").tag(1)
                }
                .pickerStyle(.segmented)
                .compactPadding()
                .onChange(of: selectedTab) { newTab in
                    // Spustit B&W/Color analýzu jen když uživatel přepne na Kalkulaci
                    if newTab == 1 {
                        triggerColorAnalysisForPricing()
                    }
                }

                Divider()

                // Obsah záložky
                ScrollView {
                    VStack(spacing: 0) {
                        if selectedTab == 0 {
                            if let file = selectedFile {
                                CompactFileMetadata(file: file)
                                    .id("\(file.id)-\(file.contentVersion)")
                                    .padding(.horizontal, DS.Spacing.smallMedium)
                                    .padding(.vertical, DS.Spacing.xxSmall)
                                Divider().padding(.horizontal, DS.Spacing.small)
                            }
                            SelectionSummaryView()
                                .compactPadding()
                        } else {
                            FilePricePanel()
                                .compactPadding()
                        }
                    }
                }
            }
        }
        .background(DS.Colors.controlBackground)
    }
}

// MARK: - Compact File Metadata

struct CompactFileMetadata: View {
    @EnvironmentObject var appState: AppState
    let file: FileItem
    @State private var pdfMetadata: PDFMetadata?
    @State private var isAnalyzingColors = false
    @State private var iccProfileName: String? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            MetaLine(label: "Filesize", value: file.fileSizeFormatted)
            MetaLine(label: "Pages",    value: "\(file.pageCount)")
            MetaLine(label: "MediaBox", value: file.pageSizeString)
            MetaLine(label: "Colors",   value: file.colorInfo)

            // Image-specific metadata
            if file.fileType.isImage {
                if let icc = iccProfileName {
                    Divider().padding(.vertical, 2)
                    MetaLine(label: "ICC Profil", value: icc)
                }
            }

            // PDF-specific metadata
            if file.fileType == .pdf {
                if let metadata = pdfMetadata {
                    Divider()
                        .padding(.vertical, 4)

                    // B&W/Color analýza se nezobrazuje zde - jen v záložce Kalkulace

                    // Title
                    if let title = metadata.title, !title.isEmpty {
                        MetaLine(label: "Title", value: title)
                    }
                    MetaLine(label: "Author", value: metadata.author ?? "-")
                    // Subject
                    if let subject = metadata.subject, !subject.isEmpty {
                        MetaLine(label: "Subject", value: subject)
                    }
                    MetaLine(label: "Creator", value: metadata.creator ?? "-")
                    MetaLine(label: "Producer", value: metadata.producer ?? "-")
                    Divider()
                        .padding(.vertical, 2)
                    MetaLine(label: "PDF Ver", value: metadata.pdfVersion)
                    MetaLine(label: "Created", value: metadata.creationDateFormatted ?? "-")
                    MetaLine(label: "Modified", value: metadata.modificationDateFormatted ?? "-")
                    Divider()
                        .padding(.vertical, 2)
                    MetaLine(label: "Encryption", value: metadata.isEncrypted ? "Yes" : "No")
                    MetaLine(label: "Linearized", value: metadata.isLinearized ? "Yes" : "No")
                    MetaLine(label: "Compression", value: metadata.compressionInfo)
                    if !metadata.featuresString.isEmpty && metadata.featuresString != "None" {
                        MetaLine(label: "Features", value: metadata.featuresString)
                    }
                } else {
                    Divider()
                        .padding(.vertical, 4)
                    // Show loading indicator
                    HStack(spacing: DS.Spacing.xxSmall) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Loading...")
                            .font(DS.Typography.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear {
            loadPDFMetadata()
            loadICCProfile()
        }
    }

    private func loadICCProfile() {
        guard file.fileType.isImage else { return }
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async {
            var name: String? = nil
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                // TIFF/JFIF/PNG – profil je v kCGImagePropertyColorModel nebo v ICC datech
                if let raw = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    let dict = raw as? [CFString: Any]
                    // Zkus profil přes CGColorSpace z CGImage
                    if let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                       let cs = img.colorSpace,
                       let iccName = cs.name as String? {
                        name = iccName
                    }
                    // Fallback: kCGImagePropertyColorModel
                    if name == nil, let model = (props)[kCGImagePropertyColorModel] as? String {
                        name = model
                    }
                    _ = dict
                }
            }
            DispatchQueue.main.async { self.iccProfileName = name }
        }
    }

    private func loadPDFMetadata() {
        guard file.fileType == .pdf else { return }

        // Reset při změně souboru
        pdfMetadata = nil
        isAnalyzingColors = false

        // Základní metadata (synchronně) - BEZ barevné analýzy
        // Barevná analýza se spustí jen v záložce Kalkulace
        let metadata = PDFInfoService.shared.extractMetadata(from: file.url)
        self.pdfMetadata = metadata
        if let m = metadata {
            appState.pdfMetadataCache[file.id] = m
        }
    }
}

struct MetaLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: DS.Spacing.xSmall) {
            Text(label)
                .foregroundColor(.secondary)
            Text(value)
                .foregroundColor(.primary)
        }
        .font(DS.Typography.caption2)
    }
}

// MARK: - Selection Summary View

struct SelectionSummaryView: View {
    @EnvironmentObject var appState: AppState

    private var summary: String {
        let selected = appState.files.filter { appState.selectedFiles.contains($0.id) }
        if selected.isEmpty { return "Nic nevybráno" }
        let pages = selected.reduce(0) { $0 + $1.pageCount }
        let allImages = selected.allSatisfy { $0.fileType.isImage }
        let label = allImages
            ? (selected.count == 1 ? "obrázek" : "obrázků")
            : (pages == 1 ? "strana" : "stran")
        return "\(pages) \(label) ve \(selected.count) souboru/ech"
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xxSmall) {
            Image(systemName: "doc.text")
                .font(DS.Typography.caption2)
                .foregroundColor(.secondary)
            Text(summary)
                .font(DS.Typography.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Large Format Pricing Helpers

/// Skupiny velkoformátových stránek dle šíře role a barevnosti
private struct LFGroup: Identifiable {
    let roll: Int       // šíře role v mm: 297, 420, 594, 841, 914
    let isColor: Bool
    var pageCount: Int = 0
    var totalLengthCm: Double = 0.0
    var id: String { "\(roll)-\(isColor)" }
}

/// Dostupné šíře rolí v mm (od nejmenší)
private let lfRollWidths = [297, 420, 594, 841, 914]

/// Vrátí true pro velkoformátový výkres: kratší strana ≥ 295 mm A delší strana > 420 mm
/// Tzn. od formátu 297×421 mm a více (A3 297×420 mm ještě NE, 297×421 mm a větší ANO)
private func lfIsLargePage(_ size: CGSize) -> Bool {
    let wMM    = Double(size.width)  * 0.352777778
    let hMM    = Double(size.height) * 0.352777778
    let narrow = min(wMM, hMM)
    let long   = max(wMM, hMM)
    return narrow >= 295 && long > 420
}

/// Nejmenší šíře role, která pojme kratší stranu stránky
private func lfRollWidth(for size: CGSize) -> Int {
    let wMM = Double(size.width)  * 0.352777778
    let hMM = Double(size.height) * 0.352777778
    let narrow = min(wMM, hMM)
    for w in lfRollWidths { if Double(w) >= narrow - 5 { return w } }
    return 914
}

/// Délka výtisku v cm (zaokrouhleno nahoru)
private func lfLengthCm(for size: CGSize) -> Double {
    let longMM = max(Double(size.width), Double(size.height)) * 0.352777778
    return ceil(longMM / 10.0)
}

// MARK: - File Price Panel

struct FilePricePanel: View {
    @EnvironmentObject var appState: AppState

    // Ceny z Preferences — stejné klíče jako PriceSettingsView
    @AppStorage("price.a4.bw.1")    private var a4bw1:    Double = 2.0
    @AppStorage("price.a4.bw.10")   private var a4bw10:   Double = 1.5
    @AppStorage("price.a4.bw.50")   private var a4bw50:   Double = 1.2
    @AppStorage("price.a4.bw.100")  private var a4bw100:  Double = 1.0
    @AppStorage("price.a4.col.1")   private var a4col1:   Double = 8.0
    @AppStorage("price.a4.col.10")  private var a4col10:  Double = 6.0
    @AppStorage("price.a4.col.50")  private var a4col50:  Double = 5.0
    @AppStorage("price.a4.col.100") private var a4col100: Double = 4.0
    @AppStorage("price.a3.bw.1")    private var a3bw1:    Double = 4.0
    @AppStorage("price.a3.bw.10")   private var a3bw10:   Double = 3.0
    @AppStorage("price.a3.bw.50")   private var a3bw50:   Double = 2.5
    @AppStorage("price.a3.bw.100")  private var a3bw100:  Double = 2.0
    @AppStorage("price.a3.col.1")   private var a3col1:   Double = 16.0
    @AppStorage("price.a3.col.10")  private var a3col10:  Double = 12.0
    @AppStorage("price.a3.col.50")  private var a3col50:  Double = 10.0
    @AppStorage("price.a3.col.100") private var a3col100: Double = 8.0
    // Velkoformátový tisk – ČB Kč/cm
    @AppStorage("price.lf.914.bw")  private var lf914bw:  Double = 0.63
    @AppStorage("price.lf.841.bw")  private var lf841bw:  Double = 0.57
    @AppStorage("price.lf.594.bw")  private var lf594bw:  Double = 0.51
    @AppStorage("price.lf.420.bw")  private var lf420bw:  Double = 0.34
    @AppStorage("price.lf.297.bw")  private var lf297bw:  Double = 0.23
    // Velkoformátový tisk – Barevně Kč/cm
    @AppStorage("price.lf.914.col") private var lf914col: Double = 1.30
    @AppStorage("price.lf.841.col") private var lf841col: Double = 1.25
    @AppStorage("price.lf.594.col") private var lf594col: Double = 1.00
    @AppStorage("price.lf.420.col") private var lf420col: Double = 0.75
    @AppStorage("price.lf.297.col") private var lf297col: Double = 0.50
    // Složení výkresů – Kč/výkres
    @AppStorage("price.lf.914.fold") private var lf914fold: Double = 9.0
    @AppStorage("price.lf.841.fold") private var lf841fold: Double = 7.0
    @AppStorage("price.lf.594.fold") private var lf594fold: Double = 5.0
    @AppStorage("price.lf.420.fold") private var lf420fold: Double = 4.0
    @AppStorage("price.lf.297.fold") private var lf297fold: Double = 2.0

    /// Globální přepínač složení – platí pro všechny velkoformátové výkresy ve výběru
    @State private var foldingEnabled: Bool = false
    /// Globální přepínač ČB tisku – pamatuje se napříč úlohami
    @AppStorage("price.forceBlackWhite") private var forceBlackWhite: Bool = false

    private var selectedPDFFiles: [FileItem] {
        appState.files.filter {
            appState.selectedFiles.contains($0.id) && $0.fileType == .pdf
        }
    }

    /// True pokud alespoň jeden vybraný soubor obsahuje velkoformátové stránky
    private var hasLargeFormatFiles: Bool {
        selectedPDFFiles.contains { file in
            guard let sizes = appState.pdfMetadataCache[file.id]?.pageSizes else { return false }
            return sizes.contains { lfIsLargePage($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            // Záhlaví
            HStack(spacing: DS.Spacing.xxSmall) {
                Image(systemName: "eurosign.circle")
                    .font(DS.Typography.caption2)
                    .foregroundColor(.secondary)
                Text("Cena tisku")
                    .font(DS.Typography.captionSemibold)
                    .foregroundColor(.secondary)
            }

            if selectedPDFFiles.isEmpty {
                Text("Žádné PDF soubory ve výběru")
                    .font(DS.Typography.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(selectedPDFFiles) { file in
                    FilePriceRow(file: file, foldingEnabled: foldingEnabled, forceBlackWhite: forceBlackWhite)
                }

                // Složení výkresů – zobrazit jen pokud jsou velkoformátové stránky
                if hasLargeFormatFiles {
                    Divider()
                    Toggle(isOn: $foldingEnabled) {
                        Text("Složení výkresů")
                            .font(DS.Typography.caption2)
                    }
                    .toggleStyle(.checkbox)
                }

                Divider()
                Toggle(isOn: $forceBlackWhite) {
                    Text("Celé černobíle")
                        .font(DS.Typography.caption2)
                }
                .toggleStyle(.checkbox)

                if selectedPDFFiles.count > 1 {
                    Divider()
                    HStack {
                        Text("Celkem:")
                            .font(DS.Typography.captionSemibold)
                        Spacer()
                        let total = selectedPDFFiles.reduce(0.0) { $0 + priceForFile($1) }
                        Text(priceString(total))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { triggerMissingLoads() }
        .onChange(of: appState.selectedFiles) { _ in triggerMissingLoads() }
    }

    private func triggerMissingLoads() {
        for file in selectedPDFFiles {
            appState.loadPDFMetadataIfNeeded(for: file)
            // Pokud metadata jsou v cache ale GS ještě neproběhl, spustí ho
            appState.ensureColorAnalysis(for: file)
        }
    }

    // MARK: Výpočet ceny pro jeden soubor

    func priceForFile(_ file: FileItem) -> Double {
        let meta = appState.pdfMetadataCache[file.id]
        let totalBW:    Int
        let totalColor: Int
        if let m = meta, (m.colorPageCount + m.blackWhitePageCount) > 0 {
            if forceBlackWhite {
                totalBW    = m.blackWhitePageCount + m.colorPageCount
                totalColor = 0
            } else {
                totalBW    = m.blackWhitePageCount
                totalColor = m.colorPageCount
            }
        } else {
            totalBW    = file.pageCount
            totalColor = 0
        }

        // Velkoformátové skupiny
        let lfGroups = computeLFGroups(meta: meta, forceBlackWhite: forceBlackWhite)
        let lfBWPages = lfGroups.reduce(0) { $0 + $1.pageCount }

        // Standardní stránky (A4/A3) = celkové minus velkoformátové
        let stdBW    = max(0, totalBW    - lfBWPages)
        let stdColor = max(0, totalColor)
        let a3       = isA3(file.pageSize)

        var total = Double(stdBW)    * unitPrice(count: stdBW,    isA3: a3, isColor: false)
                  + Double(stdColor) * unitPrice(count: stdColor, isA3: a3, isColor: true)

        // Velkoformátové stránky
        for g in lfGroups {
            total += g.totalLengthCm * lfPricePerCm(roll: g.roll, isColor: g.isColor)
            if foldingEnabled {
                total += Double(g.pageCount) * lfFoldPrice(roll: g.roll)
            }
        }
        return total
    }

    /// Sestaví skupiny velkoformátových stránek z metadat
    fileprivate func computeLFGroups(meta: PDFMetadata?, forceBlackWhite: Bool = false) -> [LFGroup] {
        guard let sizes = meta?.pageSizes, !sizes.isEmpty else { return [] }
        let colorNums = forceBlackWhite ? [] : (meta?.colorPageNumbers ?? [])
        var dict: [String: LFGroup] = [:]
        for (i, size) in sizes.enumerated() {
            guard lfIsLargePage(size) else { continue }
            let roll      = lfRollWidth(for: size)
            let lengthCm  = lfLengthCm(for: size)
            let isColor   = colorNums.contains(i + 1)
            let key       = "\(roll)-\(isColor)"
            dict[key, default: LFGroup(roll: roll, isColor: isColor)].pageCount += 1
            dict[key]!.totalLengthCm += lengthCm
        }
        return dict.values.sorted { $0.roll > $1.roll }
    }

    func lfPricePerCm(roll: Int, isColor: Bool) -> Double {
        if isColor {
            switch roll {
            case 914: return lf914col
            case 841: return lf841col
            case 594: return lf594col
            case 420: return lf420col
            default:  return lf297col
            }
        } else {
            switch roll {
            case 914: return lf914bw
            case 841: return lf841bw
            case 594: return lf594bw
            case 420: return lf420bw
            default:  return lf297bw
            }
        }
    }

    func lfFoldPrice(roll: Int) -> Double {
        switch roll {
        case 914: return lf914fold
        case 841: return lf841fold
        case 594: return lf594fold
        case 420: return lf420fold
        default:  return lf297fold
        }
    }

    private func isA3(_ size: CGSize) -> Bool {
        let w = size.width  * 0.352777778
        let h = size.height * 0.352777778
        return (abs(w - 297) < 10 && abs(h - 420) < 10)
            || (abs(w - 420) < 10 && abs(h - 297) < 10)
    }

    func unitPrice(count: Int, isA3: Bool, isColor: Bool) -> Double {
        guard count > 0 else { return 0 }
        let tier = count >= 100 ? 100 : count >= 50 ? 50 : count >= 10 ? 10 : 1
        switch (isA3, isColor, tier) {
        case (false, false, 1):   return a4bw1
        case (false, false, 10):  return a4bw10
        case (false, false, 50):  return a4bw50
        case (false, false, _):   return a4bw100
        case (false, true,  1):   return a4col1
        case (false, true,  10):  return a4col10
        case (false, true,  50):  return a4col50
        case (false, true,  _):   return a4col100
        case (true,  false, 1):   return a3bw1
        case (true,  false, 10):  return a3bw10
        case (true,  false, 50):  return a3bw50
        case (true,  false, _):   return a3bw100
        case (true,  true,  1):   return a3col1
        case (true,  true,  10):  return a3col10
        case (true,  true,  50):  return a3col50
        default:                  return a3col100
        }
    }

    func priceString(_ v: Double) -> String {
        String(format: "%.2f Kč", v)
    }
}

// MARK: - File Price Row (jeden soubor)

struct FilePriceRow: View {
    @EnvironmentObject var appState: AppState
    let file: FileItem
    let foldingEnabled: Bool
    var forceBlackWhite: Bool = false

    // Ceny A4/A3 z AppStorage
    @AppStorage("price.a4.bw.1")    private var a4bw1:    Double = 2.0
    @AppStorage("price.a4.bw.10")   private var a4bw10:   Double = 1.5
    @AppStorage("price.a4.bw.50")   private var a4bw50:   Double = 1.2
    @AppStorage("price.a4.bw.100")  private var a4bw100:  Double = 1.0
    @AppStorage("price.a4.col.1")   private var a4col1:   Double = 8.0
    @AppStorage("price.a4.col.10")  private var a4col10:  Double = 6.0
    @AppStorage("price.a4.col.50")  private var a4col50:  Double = 5.0
    @AppStorage("price.a4.col.100") private var a4col100: Double = 4.0
    @AppStorage("price.a3.bw.1")    private var a3bw1:    Double = 4.0
    @AppStorage("price.a3.bw.10")   private var a3bw10:   Double = 3.0
    @AppStorage("price.a3.bw.50")   private var a3bw50:   Double = 2.5
    @AppStorage("price.a3.bw.100")  private var a3bw100:  Double = 2.0
    @AppStorage("price.a3.col.1")   private var a3col1:   Double = 16.0
    @AppStorage("price.a3.col.10")  private var a3col10:  Double = 12.0
    @AppStorage("price.a3.col.50")  private var a3col50:  Double = 10.0
    @AppStorage("price.a3.col.100") private var a3col100: Double = 8.0
    // Ceny velkoformátového tisku z AppStorage
    @AppStorage("price.lf.914.bw")   private var lf914bw:   Double = 0.63
    @AppStorage("price.lf.841.bw")   private var lf841bw:   Double = 0.57
    @AppStorage("price.lf.594.bw")   private var lf594bw:   Double = 0.51
    @AppStorage("price.lf.420.bw")   private var lf420bw:   Double = 0.34
    @AppStorage("price.lf.297.bw")   private var lf297bw:   Double = 0.23
    @AppStorage("price.lf.914.col")  private var lf914col:  Double = 1.30
    @AppStorage("price.lf.841.col")  private var lf841col:  Double = 1.25
    @AppStorage("price.lf.594.col")  private var lf594col:  Double = 1.00
    @AppStorage("price.lf.420.col")  private var lf420col:  Double = 0.75
    @AppStorage("price.lf.297.col")  private var lf297col:  Double = 0.50
    @AppStorage("price.lf.914.fold") private var lf914fold: Double = 9.0
    @AppStorage("price.lf.841.fold") private var lf841fold: Double = 7.0
    @AppStorage("price.lf.594.fold") private var lf594fold: Double = 5.0
    @AppStorage("price.lf.420.fold") private var lf420fold: Double = 4.0
    @AppStorage("price.lf.297.fold") private var lf297fold: Double = 2.0

    // MARK: – Datový model pro jeden řádek výpisu

    private struct PageLine: Identifiable {
        enum Kind {
            case stdBW(sizeLabel: String)
            case stdColor(sizeLabel: String)
            case lfBW(roll: Int, lengthCm: Double)
            case lfColor(roll: Int, lengthCm: Double)
        }
        let pageNumber: Int
        var id: Int { pageNumber }
        let kind: Kind

        var isVF: Bool {
            switch kind { case .lfBW, .lfColor: true; default: false }
        }
        var isColor: Bool {
            switch kind { case .stdColor, .lfColor: true; default: false }
        }
        var roll: Int? {
            switch kind { case .lfBW(let r, _), .lfColor(let r, _): r; default: nil }
        }
        var lengthCm: Double? {
            switch kind { case .lfBW(_, let l), .lfColor(_, let l): l; default: nil }
        }
    }

    // MARK: – Computed

    private var meta: PDFMetadata? { appState.pdfMetadataCache[file.id] }

    private var isAnalyzing: Bool {
        meta == nil || (meta!.colorPageCount == 0 && meta!.blackWhitePageCount == 0
                        && PageColorAnalyzer.shared.isGSAvailable)
    }

    /// Vrátí per-page seznam pokud jsou k dispozici pageSizes, jinak nil
    private var pageLines: [PageLine]? {
        guard let sizes = meta?.pageSizes, !sizes.isEmpty else { return nil }
        let colorNums = forceBlackWhite ? [] : (meta?.colorPageNumbers ?? [])

        // Pomocná: je stránka A3?
        func pageIsA3(_ s: CGSize) -> Bool {
            let w = Double(s.width) * 0.352777778
            let h = Double(s.height) * 0.352777778
            return (abs(w - 297) < 10 && abs(h - 420) < 10)
                || (abs(w - 420) < 10 && abs(h - 297) < 10)
        }

        // 1. průchod – kategorizace
        struct RawPage {
            let num: Int; let isVF: Bool; let isColor: Bool
            let isA3: Bool; let roll: Int?; let lengthCm: Double?
        }
        let raw: [RawPage] = sizes.enumerated().map { (i, size) in
            let num     = i + 1
            let isColor = colorNums.contains(num)
            if lfIsLargePage(size) {
                return RawPage(num: num, isVF: true, isColor: isColor, isA3: false,
                               roll: lfRollWidth(for: size), lengthCm: lfLengthCm(for: size))
            } else {
                return RawPage(num: num, isVF: false, isColor: isColor,
                               isA3: pageIsA3(size), roll: nil, lengthCm: nil)
            }
        }

        // 2. průchod – sestavení PageLine
        return raw.map { p in
            if p.isVF, let r = p.roll, let l = p.lengthCm {
                return PageLine(pageNumber: p.num,
                                kind: p.isColor ? .lfColor(roll: r, lengthCm: l)
                                                : .lfBW(roll: r, lengthCm: l))
            } else {
                let label = p.isA3 ? "A3" : "A4"
                return PageLine(pageNumber: p.num,
                                kind: p.isColor ? .stdColor(sizeLabel: label)
                                                : .stdBW(sizeLabel: label))
            }
        }
        .sorted { $0.pageNumber < $1.pageNumber }
    }

    // MARK: – Ceny

    private func stdUnitPrice(count: Int, isA3: Bool, isColor: Bool) -> Double {
        guard count > 0 else { return 0 }
        let t = count >= 100 ? 100 : count >= 50 ? 50 : count >= 10 ? 10 : 1
        switch (isA3, isColor, t) {
        case (false, false, 1):   return a4bw1
        case (false, false, 10):  return a4bw10
        case (false, false, 50):  return a4bw50
        case (false, false, _):   return a4bw100
        case (false, true,  1):   return a4col1
        case (false, true,  10):  return a4col10
        case (false, true,  50):  return a4col50
        case (false, true,  _):   return a4col100
        case (true,  false, 1):   return a3bw1
        case (true,  false, 10):  return a3bw10
        case (true,  false, 50):  return a3bw50
        case (true,  false, _):   return a3bw100
        case (true,  true,  1):   return a3col1
        case (true,  true,  10):  return a3col10
        case (true,  true,  50):  return a3col50
        default:                  return a3col100
        }
    }

    private func lfPricePerCm(roll: Int, isColor: Bool) -> Double {
        if isColor {
            switch roll {
            case 914: return lf914col; case 841: return lf841col
            case 594: return lf594col; case 420: return lf420col; default: return lf297col
            }
        } else {
            switch roll {
            case 914: return lf914bw; case 841: return lf841bw
            case 594: return lf594bw; case 420: return lf420bw; default: return lf297bw
            }
        }
    }

    private func lfFoldPrice(_ roll: Int) -> Double {
        switch roll {
        case 914: return lf914fold; case 841: return lf841fold
        case 594: return lf594fold; case 420: return lf420fold; default: return lf297fold
        }
    }

    // MARK: – Výpočet ceny – závisí na celkových počtech pro tier pricing

    /// Spočítá ceny a vrátí (cena řádku, popis řádku) pro každou stránku
    private func buildDisplayLines() -> (lines: [(pageNum: Int, label: String, price: Double, isFold: Bool)], total: Double, bwTotal: Int, colorTotal: Int) {
        guard let raw = pageLines else {
            // Fallback: nemáme pageSizes – use file-level counts
            let gsOK = (meta?.colorPageCount ?? 0) + (meta?.blackWhitePageCount ?? 0) > 0
            let bwCnt: Int
            let colCnt: Int
            if forceBlackWhite {
                bwCnt  = gsOK ? (meta!.blackWhitePageCount + meta!.colorPageCount) : file.pageCount
                colCnt = 0
            } else {
                bwCnt  = gsOK ? (meta!.blackWhitePageCount) : file.pageCount
                colCnt = gsOK ? (meta!.colorPageCount)      : 0
            }
            let firstIsA3: Bool = {
                let w = file.pageSize.width  * 0.352777778
                let h = file.pageSize.height * 0.352777778
                return (abs(w - 297) < 10 && abs(h - 420) < 10)
                    || (abs(w - 420) < 10 && abs(h - 297) < 10)
            }()
            let up_bw  = stdUnitPrice(count: bwCnt,  isA3: firstIsA3, isColor: false)
            let up_col = stdUnitPrice(count: colCnt, isA3: firstIsA3, isColor: true)
            let sizeL  = firstIsA3 ? "A3" : "A4"
            var out: [(pageNum: Int, label: String, price: Double, isFold: Bool)] = []
            if bwCnt  > 0 { out.append((0, "\(sizeL) BLACK: \(bwCnt) str × \(String(format: "%.2f", up_bw))", Double(bwCnt) * up_bw, false)) }
            if colCnt > 0 { out.append((0, "\(sizeL) CMYK: \(colCnt) str × \(String(format: "%.2f", up_col))", Double(colCnt) * up_col, false)) }
            let total = Double(bwCnt) * up_bw + Double(colCnt) * up_col
            return (out, total, bwCnt, colCnt)
        }

        // Spočítej celkové počty pro tier pricing
        let cA4BW  = raw.filter { if case .stdBW(let s)   = $0.kind { return s == "A4" } ; return false }.count
        let cA4Col = raw.filter { if case .stdColor(let s) = $0.kind { return s == "A4" } ; return false }.count
        let cA3BW  = raw.filter { if case .stdBW(let s)   = $0.kind { return s == "A3" } ; return false }.count
        let cA3Col = raw.filter { if case .stdColor(let s) = $0.kind { return s == "A3" } ; return false }.count

        var out: [(pageNum: Int, label: String, price: Double, isFold: Bool)] = []
        var total = 0.0

        for line in raw {
            switch line.kind {
            case .stdBW(let sz):
                let up = stdUnitPrice(count: sz == "A3" ? cA3BW : cA4BW, isA3: sz == "A3", isColor: false)
                let p  = up
                out.append((line.pageNumber, "Str.\(line.pageNumber): \(sz) BLACK × \(String(format: "%.2f", up)) Kč", p, false))
                total += p

            case .stdColor(let sz):
                let up = stdUnitPrice(count: sz == "A3" ? cA3Col : cA4Col, isA3: sz == "A3", isColor: true)
                let p  = up
                out.append((line.pageNumber, "Str.\(line.pageNumber): \(sz) CMYK × \(String(format: "%.2f", up)) Kč", p, false))
                total += p

            case .lfBW(let roll, let len):
                let ppc = lfPricePerCm(roll: roll, isColor: false)
                let p   = len * ppc
                out.append((line.pageNumber,
                             "Str.\(line.pageNumber): VF BLACK \(roll)mm  \(Int(len))cm × \(String(format: "%.2f", ppc))",
                             p, false))
                total += p
                if foldingEnabled {
                    let fp = lfFoldPrice(roll)
                    out.append((line.pageNumber, "  + složení \(roll)mm", fp, true))
                    total += fp
                }

            case .lfColor(let roll, let len):
                let ppc = lfPricePerCm(roll: roll, isColor: true)
                let p   = len * ppc
                out.append((line.pageNumber,
                             "Str.\(line.pageNumber): VF CMYK \(roll)mm  \(Int(len))cm × \(String(format: "%.2f", ppc))",
                             p, false))
                total += p
                if foldingEnabled {
                    let fp = lfFoldPrice(roll)
                    out.append((line.pageNumber, "  + složení \(roll)mm", fp, true))
                    total += fp
                }
            }
        }

        let bwT  = raw.filter { !$0.isColor }.count
        let colT = raw.filter {  $0.isColor }.count
        return (out, total, bwT, colT)
    }

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxxSmall) {
            // Název souboru
            Text(file.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.primary)

            if isAnalyzing && meta == nil {
                HStack(spacing: DS.Spacing.xxSmall) {
                    ProgressView().scaleEffect(0.5)
                    Text("Analyzuji…")
                        .font(DS.Typography.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                let result = buildDisplayLines()

                // Souhrnný řádek s chevronem – vždy viditelný
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() } }) {
                    HStack(spacing: DS.Spacing.xxSmall) {
                        Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 10)
                        if result.bwTotal > 0 {
                            Text("\(result.bwTotal) BLACK")
                                .foregroundColor(.secondary)
                        }
                        if result.colorTotal > 0 {
                            Text("\(result.colorTotal) CMYK")
                                .foregroundColor(Color(nsColor: .systemBlue).opacity(0.9))
                        }
                        Spacer()
                        Text(String(format: "%.2f Kč", result.total))
                            .foregroundColor(.primary)
                    }
                    .font(DS.Typography.caption2)
                }
                .buttonStyle(.plain)

                // Výklápěcí detail stránek
                if showDetails {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(result.lines.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 0) {
                                Text(item.label)
                                    .foregroundColor(item.isFold ? .secondary.opacity(0.7) : .secondary)
                                Spacer()
                                Text(String(format: "%.2f Kč", item.price))
                                    .foregroundColor(item.isFold ? .secondary : .primary)
                            }
                            .font(DS.Typography.monoSmall)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - File Row View with Rename Support

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let file: FileItem
    @State private var isEditing = false
    @State private var editedName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.xSmall) {
            // Obecná ikona podle typu souboru (bez thumbnail)
            Image(systemName: file.fileType.icon)
                .font(.system(size: 14))
                .foregroundColor(file.fileType.listColor)
                .frame(width: 18)

            if isEditing {
                TextField("name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.subheadline)
                    .focused($isFocused)
                    .onSubmit {
                        commitRename()
                    }
                    .onAppear {
                        editedName = file.name
                        isFocused = true
                    }
            } else {
                Text(file.name)
                    .lineLimit(1)
            }
        }
        .onChange(of: appState.editingFileID) { editID in
            if editID == file.id && !isEditing {
                editedName = file.name
                isEditing = true
                isFocused = true
                appState.editingFileID = nil
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused && isEditing {
                commitRename()
            }
        }
    }

    private func commitRename() {
        isEditing = false
        isFocused = false

        let newName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != file.name else { return }

        appState.renameFile(file, to: newName)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: FileStatus

    var body: some View {
        HStack(spacing: DS.Spacing.xxSmall) {
            if status == .converting || status == .processing {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Image(systemName: status.icon)
            }
            Text(status.rawValue)
        }
        .font(DS.Typography.caption2)
        .foregroundColor(status.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.rawValue)")
    }
}

// MARK: - Large Preview Sheet

struct LargePreviewSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let file: FileItem
    @State private var page: Int

    init(file: FileItem, startPage: Int) {
        self.file = file
        self._page = State(initialValue: startPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(file.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if file.pageCount > 1 {
                    HStack(spacing: DS.Spacing.small) {
                        Button { if page > 0 { page -= 1 } } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(page == 0)
                        .buttonStyle(.borderless)

                        Text("\(page + 1) / \(file.pageCount)")
                            .font(DS.Typography.subheadline)
                            .monospacedDigit()

                        Button { if page < file.pageCount - 1 { page += 1 } } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(page >= file.pageCount - 1)
                        .buttonStyle(.borderless)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.small)

            Divider()

            // Preview
            PreviewImageView(file: file, currentPage: $page)
                .id("\(file.id)-\(page)")
                .padding(DS.Spacing.medium)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(DS.Colors.windowBackground)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 680)
}
