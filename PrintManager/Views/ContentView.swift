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

            // Middle: Table + Log + Actions
            VStack(spacing: 0) {
                DropFileTableView()
                    .frame(minHeight: 200)

                Divider()

                InlineLogView()
                    .frame(height: 100)

                Divider()

                BottomActionBar()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
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
            let def = printManager.defaultPrinter ?? printers[0]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Printers")
                    .font(.headline)
                Spacer()
                Button {
                    printManager.refreshPrinters()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh printer list")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if printManager.availablePrinters.isEmpty {
                        Text("No printers found")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                    } else {
                        ForEach(printManager.availablePrinters, id: \.self) { printer in
                            PrinterRowView(
                                printer: printer,
                                isSelected: appState.selectedPrinter == printer,
                                icon: printerIcons[printer],
                                status: printManager.printerStatuses[printer] ?? .idle,
                                isDefault: printManager.defaultPrinter == printer,
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
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .background(Color(NSColor.controlBackgroundColor))
            
            // Preset Section — načítá se ze systémových plistů macOS
            if !appState.selectedPrinter.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Preset")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button {
                            appState.loadSystemPresets()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Znovu načíst presety ze systému")
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    if appState.availableSystemPresets.isEmpty {
                        Text("Žádné presety")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                    } else {
                        Picker("Preset:", selection: $appState.selectedPreset) {
                            Text("— bez presetu —").tag(nil as String?)
                            ForEach(appState.availableSystemPresets) { preset in
                                Text(preset.name).tag(preset.name as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.bottom, 8)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // ── Apps sekce ───────────────────────────────────────────────────
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                // Záhlaví Apps
                HStack(spacing: 4) {
                    Text("Apps")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    // "+" přidat aplikaci
                    Button {
                        pickApp()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Přidat aplikaci")

                    // "−" odebrat vybranou aplikaci
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                Divider()

                if appState.externalApps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "app.badge.plus")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary.opacity(0.45))
                        Text("Přidej aplikaci\nklikem na +")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else {
                    ScrollView {
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 170)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear {
            if !appState.selectedPrinter.isEmpty {
                appState.loadSystemPresets()
            }
        }
    }

    // Otevře NSOpenPanel pro výběr .app souboru
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Přidat"
        if panel.runModal() == .OK {
            for url in panel.urls {
                appState.addExternalApp(url: url)
            }
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
    let ip: String?
    let onSelect: () -> Void
    let onOpenCUPS: () -> Void
    let onOpenCUPSMain: () -> Void
    let onOpenQueue: () -> Void
    let onOpenIP: () -> Void

    private var statusLabel: String {
        isDefault ? "\(status.label), Default" : status.label
    }

    private var dotColor: Color {
        isSelected ? .white.opacity(0.85) : Color(status.color)
    }

    var body: some View {
        HStack(spacing: 10) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(printer)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text(statusLabel)
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenQueue() }
        .onTapGesture(count: 1) { onSelect() }
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
        HStack(spacing: 8) {
            Group {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlColor))
                        .frame(width: 28, height: 28)
                }
            }

            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(isSelected ? .white : .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.accentColor
                      : (isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Printer setting")
                .font(.headline)

            HStack(spacing: 16) {
                // Copies
                HStack(spacing: 4) {
                    Text("Copies:")
                        .font(.system(size: 12))
                    Stepper("\(appState.printCopies)", value: $appState.printCopies, in: 1...999)
                        .frame(width: 88)
                }

                // Paper size
                HStack(spacing: 4) {
                    Text("Paper size:")
                        .font(.system(size: 12))
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
                    .font(.system(size: 12))

                // Orientation button
                Button(action: { appState.printLandscape.toggle() }) {
                    Image(systemName: appState.printLandscape
                          ? "rectangle" : "rectangle.portrait")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .help(appState.printLandscape ? "Landscape" : "Portrait")

                // Fit to page
                Toggle("Fit to page", isOn: $appState.printFitToPage)
                    .font(.system(size: 12))

                Divider().frame(height: 20)

                // Color
                HStack(spacing: 4) {
                    Text("Color:")
                        .font(.system(size: 12))
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
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh printers")
            }
        }
    }
}

// MARK: - Drop File Table View

struct DropFileTableView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false
    @AppStorage("tableRowFontSize") private var tableRowFontSize: Double = 12

    var body: some View {
        Group {
            if !appState.files.isEmpty {
                Table(appState.files, selection: $appState.selectedFiles) {
                    TableColumn("File") { file in
                        FileRowView(file: file)
                    }
                    .width(min: 140, ideal: 210)

                    TableColumn("Size") { file in
                        Text(file.pageSizeString)
                    }
                    .width(100)

                    TableColumn("Kind") { file in
                        Text(file.fileType.rawValue.lowercased())
                    }
                    .width(45)

                    TableColumn("File size") { file in
                        Text(file.fileSizeFormatted)
                    }
                    .width(70)

                    TableColumn("Pages") { file in
                        Text("\(file.pageCount)")
                    }
                    .width(48)

                    TableColumn("Colors") { file in
                        Text(file.colorInfo)
                            .foregroundColor(
                                file.colorInfo.contains("CMYK") ? .cyan : .primary
                            )
                    }
                    .width(65)
                    
                    TableColumn("Status") { file in
                        StatusBadge(status: file.status)
                    }
                    .width(80)
                }
                .environment(\.font, .system(size: CGFloat(tableRowFontSize)))
                .contextMenu(forSelectionType: UUID.self) { items in
                    if !items.isEmpty {
                        Button(action: { appState.revealInFinder(items: items) }) {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Button(action: { appState.openInDefaultApp(items: items) }) {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }
                        if items.count == 1 {
                            Button(action: { appState.editingFileID = items.first }) {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                        Divider()

                        // Determine selected file types
                        let selectedFiles = appState.files.filter { items.contains($0.id) }
                        let hasImage = selectedFiles.contains { $0.fileType.isImage }
                        let hasPDF = selectedFiles.contains { $0.fileType == .pdf }

                        if hasImage && !hasPDF {
                            // Image Actions
                            Button(action: { appState.convertImageToPDF() }) {
                                Label("Convert to PDF", systemImage: "doc.badge.plus")
                            }
                            Button(action: { appState.cropPDF() }) {
                                Label("Crop Image", systemImage: "crop")
                            }
                            Button(action: { appState.smartCropFiles() }) {
                                Label("Smart Crop", systemImage: "sparkles")
                            }
                            Button(action: { appState.openMultiCrop() }) {
                                Label("MultiCrop", systemImage: "photo.stack")
                            }
                            Divider()
                            Button(action: { appState.invertImage() }) {
                                Label("Invert Colors", systemImage: "circle.lefthalf.filled")
                            }
                            Button(action: { appState.convertToGray() }) {
                                Label("Convert to Gray", systemImage: "circle.fill")
                            }
                        } else {
                            // PDF Actions
                            Button(action: { appState.mergePDFs() }) {
                                Label("Combine PDF", systemImage: "doc.on.doc")
                            }
                            Button(action: { appState.splitPDF() }) {
                                Label("Split PDF", systemImage: "doc.on.doc.fill")
                            }
                            Divider()
                            Button(action: { appState.compressPDF() }) {
                                Label("Compress PDF", systemImage: "arrow.down.circle")
                            }
                            Button(action: { appState.rasterizePDF() }) {
                                Label("Rasterize PDF", systemImage: "rectangle.dashed")
                            }
                            Divider()
                            Button(action: { appState.cropPDF() }) {
                                Label("Crop PDF/Image", systemImage: "crop")
                            }
                            Button(action: { appState.smartCropFiles() }) {
                                Label("Smart Crop", systemImage: "sparkles")
                            }
                            if hasPDF {
                                Divider()
                                Button(action: { appState.showPDFInfo() }) {
                                    Label("PDF Info", systemImage: "info.circle")
                                }
                            }
                        }

                        Divider()
                        Button(role: .destructive, action: {
                            // Odložení na další runloop — SwiftUI Table crashuje,
                            // pokud datový zdroj mutujeme přímo ve chvíli,
                            // kdy context menu teprve zavírá svou animaci.
                            DispatchQueue.main.async {
                                appState.removeFiles(items: items)
                            }
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } primaryAction: { items in
                    // Dvojklik = otevřít v defaultní aplikaci
                    appState.openInDefaultApp(items: items)
                }
            } else {
                VStack(spacing: 10) {
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
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(2)
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
                appState.addFiles(urls: droppedURLs)
            }
            return true
        }
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
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(logColor(for: message.level))
                            .textSelection(.enabled)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
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
        case .info:    return Color(red: 0.4, green: 0.85, blue: 0.4)
        case .success: return .green
        case .warning: return .orange
        case .error:   return Color(red: 1.0, green: 0.35, blue: 0.35)
        }
    }
}

// MARK: - Bottom Action Bar

struct BottomActionBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Rotate Left (90° CCW) — Cmd+Shift+R
            Button(action: { appState.rotateSelectedFilesLeft() }) {
                Image(systemName: "rotate.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Rotate 90° counter-clockwise (⌘⇧R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])

            // Rotate Right (90° CW) — Cmd+R
            Button(action: { appState.rotateSelectedFiles() }) {
                Image(systemName: "rotate.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Rotate 90° clockwise (⌘R)")
            .keyboardShortcut("r", modifiers: .command)

            // PDF Actions menu
            Menu {
                Button("Combine PDF") { appState.mergePDFs() }
                Button("Split PDF")   { appState.splitPDF() }
                Divider()
                Button("Compress PDF")  { appState.compressPDF() }
                Button("Rasterize PDF") { appState.rasterizePDF() }
                Divider()
                Button("Crop PDF/Image") { appState.cropPDF() }
                Button("Smart Crop") { appState.smartCropFiles() }
                Divider()
                Button("Choose Color Pages") { appState.openColorPageSelector() }
                Divider()
                Button("Add Blank Page to Odd") { appState.addBlankPagesToOddDocuments() }
                Divider()
                Button("PDF Info") { appState.showPDFInfo() }
            } label: {
                HStack(spacing: 3) {
                    Text("PDF Actions")
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .frame(width: 130)

            // Image Actions menu
            Menu {
                Button("Convert to PDF") { appState.convertImageToPDF() }
                Button("Crop Image") { appState.cropPDF() }
                Button("Smart Crop") { appState.smartCropFiles() }
                Button("MultiCrop") { appState.openMultiCrop() }
                Divider()
                Button("Invert Colors") { appState.invertImage() }
                Button("Convert to Gray") { appState.convertToGray() }
            } label: {
                HStack(spacing: 3) {
                    Text("Image Actions")
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .frame(width: 140)

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

    private var selectedFile: FileItem? {
        guard appState.selectedFiles.count == 1,
              let id = appState.selectedFiles.first else { return nil }
        return appState.files.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with toggle
            HStack {
                Text("Preview file")
                    .font(.headline)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showPreview.toggle()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Collapse")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if appState.selectedFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No file selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Preview a metadata — pouze pro jeden vybraný soubor
                        if let file = selectedFile {
                            VStack(spacing: 8) {
                                PreviewImageView(file: file, currentPage: $currentPage)
                                    .id("\(file.id)-\(file.contentVersion)")
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)

                                Text(file.name + "." + file.fileType.rawValue.lowercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 6)

                                if file.pageCount > 1 {
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            if currentPage > 0 { currentPage -= 1 }
                                        }) {
                                            Image(systemName: "arrow.left.circle")
                                                .font(.title3)
                                        }
                                        .disabled(currentPage == 0)
                                        .buttonStyle(.borderless)

                                        Text("\(currentPage + 1)")
                                            .font(.system(size: 12))

                                        Button(action: {
                                            if currentPage < file.pageCount - 1 { currentPage += 1 }
                                        }) {
                                            Image(systemName: "arrow.right.circle")
                                                .font(.title3)
                                        }
                                        .disabled(currentPage >= file.pageCount - 1)
                                        .buttonStyle(.borderless)
                                    }
                                }

                                Divider()
                                    .padding(.horizontal, 8)

                                CompactFileMetadata(file: file)
                                    .id("\(file.id)-\(file.contentVersion)")
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 4)
                            }
                            .onChange(of: appState.selectedFiles) { _ in
                                currentPage = 0
                            }
                        }

                        // Souhrn výběru — vždy viditelný
                        Divider().padding(.horizontal, 8)
                        SelectionSummaryView()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)

                        // Cena — pro PDF soubory
                        Divider().padding(.horizontal, 8)
                        FilePricePanel()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Compact File Metadata

struct CompactFileMetadata: View {
    @EnvironmentObject var appState: AppState
    let file: FileItem
    @State private var pdfMetadata: PDFMetadata?
    @State private var isAnalyzingColors = false
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            MetaLine(label: "Filesize", value: file.fileSizeFormatted)
            MetaLine(label: "Pages",    value: "\(file.pageCount)")
            MetaLine(label: "MediaBox", value: file.pageSizeString)
            MetaLine(label: "Colors",   value: file.colorInfo)
            
            // PDF-specific metadata
            if file.fileType == .pdf {
                if let metadata = pdfMetadata {
                    Divider()
                        .padding(.vertical, 4)
                    
                    // Color analysis
                    if isAnalyzingColors {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Analyzing colors...")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    } else if !metadata.colorInfoString.isEmpty {
                        MetaLine(label: "B&W/Color", value: metadata.colorInfoString)
                    }
                    
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
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Loading...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear {
            loadPDFMetadata()
        }
    }
    
    private func loadPDFMetadata() {
        guard file.fileType == .pdf else { return }

        // Reset při změně souboru
        pdfMetadata = nil
        isAnalyzingColors = false

        // Základní metadata (synchronně)
        var metadata = PDFInfoService.shared.extractMetadata(from: file.url)

        guard metadata != nil else {
            self.pdfMetadata = nil
            return
        }

        guard PageColorAnalyzer.shared.isGSAvailable else {
            // GS není dostupný — zobraz metadata bez barevné analýzy
            self.pdfMetadata = metadata
            if let m = metadata { appState.pdfMetadataCache[file.id] = m }
            return
        }

        // Analýza barev (asynchronně).
        // Poznámka: CompactFileMetadata je struct — [weak self] nelze použít.
        // Ochranu před race condition zajišťuje .id(file.id) v rodiči, který
        // celý view znovu vytvoří při změně souboru (čímž odloží stará pdfMetadata).
        isAnalyzingColors = true
        PageColorAnalyzer.shared.analyzePDF(at: file.url) { result in
            self.isAnalyzingColors = false
            switch result {
            case .success(let colorInfo):
                metadata?.colorPageCount = colorInfo.colorCount
                metadata?.blackWhitePageCount = colorInfo.blackWhiteCount
                self.pdfMetadata = metadata
                if let m = metadata { appState.pdfMetadataCache[file.id] = m }
            case .failure:
                self.pdfMetadata = metadata
                if let m = metadata { appState.pdfMetadataCache[file.id] = m }
            }
        }
        // Metadata se nezobrazí, dokud callback nedokončí analýzu barev
    }
}

struct MetaLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundColor(.secondary)
            Text(value)
                .foregroundColor(.primary)
        }
        .font(.system(size: 10))
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
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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

    private var selectedPDFFiles: [FileItem] {
        appState.files.filter {
            appState.selectedFiles.contains($0.id) && $0.fileType == .pdf
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Záhlaví
            HStack(spacing: 4) {
                Image(systemName: "eurosign.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Cena tisku")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            if selectedPDFFiles.isEmpty {
                Text("Žádné PDF soubory ve výběru")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                ForEach(selectedPDFFiles) { file in
                    FilePriceRow(file: file)
                }

                if selectedPDFFiles.count > 1 {
                    Divider()
                    HStack {
                        Text("Celkem:")
                            .font(.system(size: 11, weight: .semibold))
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
        }
    }

    // MARK: Výpočet ceny pro jeden soubor

    func priceForFile(_ file: FileItem) -> Double {
        let a3 = isA3(file.pageSize)
        let meta = appState.pdfMetadataCache[file.id]
        let bwCount: Int
        let colorCount: Int
        if let m = meta, (m.colorPageCount + m.blackWhitePageCount) > 0 {
            bwCount    = m.blackWhitePageCount
            colorCount = m.colorPageCount
        } else {
            // GS analýza ještě nedoběhla — považujeme vše za ČB
            bwCount    = file.pageCount
            colorCount = 0
        }
        return Double(bwCount)    * unitPrice(count: bwCount,    isA3: a3, isColor: false)
             + Double(colorCount) * unitPrice(count: colorCount, isA3: a3, isColor: true)
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

    // Ceny z AppStorage — musí mít stejné klíče
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

    private var panel: FilePricePanel { FilePricePanel() }

    private var meta: PDFMetadata? { appState.pdfMetadataCache[file.id] }
    private var isA3: Bool {
        let w = file.pageSize.width  * 0.352777778
        let h = file.pageSize.height * 0.352777778
        return (abs(w - 297) < 10 && abs(h - 420) < 10)
            || (abs(w - 420) < 10 && abs(h - 297) < 10)
    }
    private var sizeLabel: String { isA3 ? "A3" : "A4" }

    private var bwCount: Int {
        guard let m = meta, (m.colorPageCount + m.blackWhitePageCount) > 0 else {
            return file.pageCount
        }
        return m.blackWhitePageCount
    }
    private var colorCount: Int {
        guard let m = meta, (m.colorPageCount + m.blackWhitePageCount) > 0 else { return 0 }
        return m.colorPageCount
    }
    private var isAnalyzing: Bool {
        meta == nil || (meta!.colorPageCount == 0 && meta!.blackWhitePageCount == 0
                        && PageColorAnalyzer.shared.isGSAvailable)
    }

    private func up(_ count: Int, isColor: Bool) -> Double {
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

    private var totalPrice: Double {
        Double(bwCount) * up(bwCount, isColor: false)
      + Double(colorCount) * up(colorCount, isColor: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Název souboru (zkrácený)
            Text(file.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.primary)

            if isAnalyzing && meta == nil {
                // Metadata se ještě načítají
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.5)
                    Text("Analyzuji…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                // ČB řádek
                if bwCount > 0 {
                    HStack(spacing: 0) {
                        Text("\(sizeLabel) ČB: \(bwCount) str × ")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", up(bwCount, isColor: false)))
                        Text(" = ")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f Kč", Double(bwCount) * up(bwCount, isColor: false)))
                            .foregroundColor(.primary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                // Barevný řádek
                if colorCount > 0 {
                    HStack(spacing: 0) {
                        Text("\(sizeLabel) Bar: \(colorCount) str × ")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", up(colorCount, isColor: true)))
                        Text(" = ")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f Kč", Double(colorCount) * up(colorCount, isColor: true)))
                            .foregroundColor(.primary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                // Celkem za soubor
                HStack {
                    Spacer()
                    Text(String(format: "%.2f Kč", totalPrice))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
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
        HStack(spacing: 6) {
            // Obecná ikona podle typu souboru (bez thumbnail)
            Image(systemName: file.fileType.icon)
                .font(.system(size: 14))
                .foregroundColor(file.fileType.listColor)
                .frame(width: 18)

            if isEditing {
                TextField("name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
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
        HStack(spacing: 4) {
            if status == .converting || status == .processing {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Image(systemName: status.icon)
            }
            Text(status.rawValue)
        }
        .font(.system(size: 10))
        .foregroundColor(status.color)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 680)
}
