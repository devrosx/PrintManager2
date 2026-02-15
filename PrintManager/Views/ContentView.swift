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

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var printManager = PrintManager()
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            // Left: Printers list
            PrinterListPanel(printManager: printManager)
                .frame(width: 165)

            Divider()

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
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
}

// MARK: - Printer List Panel

struct PrinterListPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var printManager: PrintManager
    @State private var printerIcons: [String: NSImage] = [:]

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
                                onSelect: {
                                    appState.selectedPrinter = printer
                                    appState.loadSystemPresets()
                                },
                                onOpenCUPS: { printManager.openCUPSPage(for: printer) },
                                onOpenCUPSMain: { printManager.openCUPSMainPage() }
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
        }
        .onAppear {
            if !appState.selectedPrinter.isEmpty {
                appState.loadSystemPresets()
            }
        }
    }
}

// MARK: - Printer Row View (below)
    
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
    let onSelect: () -> Void
    let onOpenCUPS: () -> Void
    let onOpenCUPSMain: () -> Void

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
        .onTapGesture { onSelect() }
        .contextMenu {
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
                .contextMenu(forSelectionType: UUID.self) { items in
                    if !items.isEmpty {
                        Button(action: { appState.revealInFinder(items: items) }) {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Button(action: { appState.openInDefaultApp(items: items) }) {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }
                        Divider()
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
                        Divider()
                        // Get selected files to determine types
                        let selectedFiles = appState.files.filter { items.contains($0.id) }
                        let hasPDF = selectedFiles.contains { $0.fileType == .pdf }
                        
                        if hasPDF {
                            Button(action: { appState.showPDFInfo() }) {
                                Label("PDF Info", systemImage: "info.circle")
                            }
                        }
                        Divider()
                        Button(role: .destructive, action: { appState.removeFiles(items: items) }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } primaryAction: { items in
                    // Double-click action could be handled here
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
            var droppedURLs: [URL] = []
            
            for provider in providers {
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        droppedURLs.append(url)
                    }
                }
            }
            
            // Give time for async loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !droppedURLs.isEmpty {
                    appState.addFiles(urls: droppedURLs)
                    
                    // Select the newly added file(s)
                    let newFiles = appState.files.suffix(droppedURLs.count)
                    appState.selectedFiles = Set(newFiles.map { $0.id })
                }
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
            // Add files
            Button(action: { appState.showingFilePicker = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("Add files")

            // Remove selected
            Button(action: { appState.removeSelectedFiles() }) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(appState.selectedFiles.isEmpty)
            .help("Remove selected")

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

            // Print button
            Button("Print selected") {
                appState.printSelectedFiles()
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.selectedFiles.isEmpty)

            Spacer()

            // Summary
            Text(selectionSummary)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var selectionSummary: String {
        let selected = appState.files.filter { appState.selectedFiles.contains($0.id) }
        if selected.isEmpty { return "No files selected" }
        let pages = selected.reduce(0) { $0 + $1.pageCount }
        return "\(pages) PDF pages selected"
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

            if let file = selectedFile {
                    ScrollView {
                        VStack(spacing: 8) {
                            PreviewImageView(file: file, currentPage: $currentPage)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)

                            // File name
                            Text(file.name + "." + file.fileType.rawValue.lowercased())
                                .font(.system(size: 11, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 6)

                            // Page navigation
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

                            // Metadata block
                            CompactFileMetadata(file: file)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                        }
                    }
                    .onChange(of: appState.selectedFiles) { _ in
                        currentPage = 0
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No file selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Compact File Metadata

struct CompactFileMetadata: View {
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
        
        // Reset metadata when file changes
        pdfMetadata = nil
        isAnalyzingColors = false
        
        // First load basic metadata
        var metadata = PDFInfoService.shared.extractMetadata(from: file.url)
        
        // Then analyze colors in background
        guard metadata != nil else {
            self.pdfMetadata = metadata
            return
        }

        guard PageColorAnalyzer.shared.isGSAvailable else {
            self.pdfMetadata = metadata
            return
        }

        isAnalyzingColors = true
        PageColorAnalyzer.shared.analyzePDF(at: file.url) { result in
            self.isAnalyzingColors = false
            switch result {
            case .success(let colorInfo):
                metadata?.colorPageCount = colorInfo.colorCount
                metadata?.blackWhitePageCount = colorInfo.blackWhiteCount
                self.pdfMetadata = metadata
            case .failure:
                self.pdfMetadata = metadata
            }
        }

        self.pdfMetadata = metadata
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

// MARK: - File Row View with Rename Support

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let file: FileItem
    @State private var isEditing = false
    @State private var editedName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = file.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: file.fileType.icon)
                    .font(.system(size: 14))
            }
            
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
        .onTapGesture(count: 2) {
            if !isEditing {
                editedName = file.name
                isEditing = true
                isFocused = true
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
