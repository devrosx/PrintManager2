//
//  AppState.swift
//  PrintManager
//
//  Central state management for the application
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import PDFKit
import Combine
import Compression
import UserNotifications

// MARK: - ExternalApp Model

struct ExternalApp: Identifiable, Codable {
    var id: UUID
    var name: String
    var path: String           // absolutní cesta k .app bundle

    var url: URL { URL(fileURLWithPath: path) }

    var icon: NSImage? {
        NSWorkspace.shared.icon(forFile: path)
    }
}


class AppState: ObservableObject {
    // File management
    @Published var files: [FileItem] = []
    @Published var selectedFiles: Set<UUID> = []
    @Published var showingFilePicker = false

    // External Apps
    @Published var externalApps: [ExternalApp] = []
    
    // Print settings
    @Published var selectedPrinter: String = ""
    @Published var selectedPreset: String? = nil
    @Published var availableSystemPresets: [SystemPrinterPreset] = []
    @Published var printCopies: Int = 1
    @Published var printTwoSided: Bool = false
    @Published var printCollate: Bool = true
    @Published var printFitToPage: Bool = false
    @Published var printLandscape: Bool = false
    @Published var printColorMode: String = "auto"
    @Published var printPaperSize: String = "A4"
    
    // Preview
    @Published var previewFile: FileItem?
    @Published var previewPage: Int = 0
    
    // Crop
    @Published var showCropView = false
    @Published var cropFile: FileItem?

    // MultiCrop
    @Published var showMultiCropDialog = false
    @Published var multiCropFile: FileItem?

    // Color Page Selector
    @Published var showColorPageSelector = false
    @Published var colorPageSelectorFile: FileItem?

    // Batch Rename
    @Published var showBatchRename = false

    // Rename
    @Published var editingFileID: UUID? = nil
    
    // Compression
    @Published var showCompressionWindow = false
    @Published var compressionSettings = CompressionSettings()
    
    // Debug output
    @Published var debugMessages: [DebugMessage] = []

    // PDF metadata cache — sdílený mezi CompactFileMetadata a FilePricePanel
    @Published var pdfMetadataCache: [UUID: PDFMetadata] = [:]
    private var loadingMetadataIDs: Set<UUID> = []

    func loadPDFMetadataIfNeeded(for file: FileItem) {
        guard file.fileType == .pdf,
              pdfMetadataCache[file.id] == nil,
              !loadingMetadataIDs.contains(file.id) else { return }
        loadingMetadataIDs.insert(file.id)
        let url = file.url
        let id  = file.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard var metadata = PDFInfoService.shared.extractMetadata(from: url) else {
                DispatchQueue.main.async { self.loadingMetadataIDs.remove(id) }
                return
            }
            DispatchQueue.main.async { self.pdfMetadataCache[id] = metadata }
            guard PageColorAnalyzer.shared.isGSAvailable else {
                DispatchQueue.main.async { self.loadingMetadataIDs.remove(id) }
                return
            }
            PageColorAnalyzer.shared.analyzePDF(at: url) { result in
                if case .success(let colorInfo) = result {
                    metadata.colorPageCount     = colorInfo.colorCount
                    metadata.blackWhitePageCount = colorInfo.blackWhiteCount
                }
                DispatchQueue.main.async {
                    self.pdfMetadataCache[id] = metadata
                    self.loadingMetadataIDs.remove(id)
                }
            }
        }
    }
    
    // Notification Center
    private let notificationCenter = UNUserNotificationCenter.current()
    
    // MARK: - Notifications
    
    private func sendNotification(title: String, body: String, sound: UNNotificationSound = .default) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("Notification error: \(error.localizedDescription)")
            }
        }
    }
    
    func notifyPrintComplete(fileCount: Int, printerName: String) {
        sendNotification(
            title: "Print Complete",
            body: "\(fileCount) file(s) sent to \(printerName)"
        )
    }
    
    func notifyCompressionComplete(originalSize: Int64, compressedSize: Int64) {
        let savings = Double(originalSize - compressedSize) / Double(originalSize) * 100
        sendNotification(
            title: "Compression Complete",
            body: "Saved \(Int(savings))% (\(ByteCountFormatter.string(fromByteCount: compressedSize, countStyle: .file)))"
        )
    }
    
    func notifyConversionComplete(fileCount: Int, successCount: Int) {
        let title = "Conversion Complete"
        let body: String
        if successCount == fileCount {
            body = "Successfully converted \(successCount) file(s)"
        } else {
            body = "Converted \(successCount) of \(fileCount) files"
        }
        sendNotification(title: title, body: body)
    }
    
    func notifyError(title: String, message: String) {
        sendNotification(title: title, body: message, sound: .defaultCritical)
    }
    
    // Services
    private let fileParser = FileParser()
    private let printService = PrintService()
    private let pdfService = PDFService()
    private let imageService = ImageService()
    private let smartCropService = SmartCropService()
    private let officeConversionService = OfficeConversionService()
    private let blankPageService = BlankPageService()
    
    // Drawings
    @Published var showDrawingsDialog = false

    // Quick Look
    var quickLookFileID: UUID?

    func quickLookMoveUp() {
        guard let current = quickLookFileID,
              let idx = files.firstIndex(where: { $0.id == current }),
              idx > 0 else { return }
        let prev = files[idx - 1]
        quickLookFileID = prev.id
        selectedFiles = [prev.id]
        NotificationCenter.default.post(name: .quickLookFileChanged, object: nil)
    }

    func quickLookMoveDown() {
        guard let current = quickLookFileID,
              let idx = files.firstIndex(where: { $0.id == current }),
              idx < files.count - 1 else { return }
        let next = files[idx + 1]
        quickLookFileID = next.id
        selectedFiles = [next.id]
        NotificationCenter.default.post(name: .quickLookFileChanged, object: nil)
    }

    func openDrawingsDialog() {
        guard !selectedFiles.isEmpty else {
            logWarning("Vyber soubory pro zpracování výkresů")
            return
        }
        showDrawingsDialog = true
    }

    // Compression state
    @Published var compressionProgress: Double = 0.0
    @Published var compressionMessage = ""
    @Published var compressionResults: [CompressionResult] = []
    
    // PDF Info
    @Published var showPDFInfoWindow = false
    @Published var currentPDFMetadata: PDFMetadata?
    
    // Office Import
    @Published var showOfficeImportDialog = false
    @Published var pendingOfficeFiles: [URL] = []
    @Published var selectedImportMethod: ImportMethod = .auto
    
    // Preview Panel
    @Published var showPreview = false {
        didSet {
            UserDefaults.standard.set(showPreview, forKey: "showPreview")
        }
    }
    
    // Printer Panel (left sidebar) - collapsible
    @Published var showPrinterPanel = true {
        didSet {
            UserDefaults.standard.set(showPrinterPanel, forKey: "showPrinterPanel")
        }
    }

    // Search
    @Published var searchText: String = ""
    
    // Loading state
    @Published var isLoading = false
    @Published var loadingMessage = ""
    
    init() {
        self.showPrinterPanel = UserDefaults.standard.object(forKey: "showPrinterPanel") as? Bool ?? true
        self.showPreview = UserDefaults.standard.bool(forKey: "showPreview")
        loadExternalApps()
    }

    // MARK: - External Apps

    private func loadExternalApps() {
        guard let data = UserDefaults.standard.data(forKey: "pm.externalApps"),
              let apps = try? JSONDecoder().decode([ExternalApp].self, from: data) else { return }
        externalApps = apps
    }

    private func saveExternalApps() {
        guard let data = try? JSONEncoder().encode(externalApps) else { return }
        UserDefaults.standard.set(data, forKey: "pm.externalApps")
    }

    func addExternalApp(url: URL) {
        guard url.pathExtension.lowercased() == "app" else {
            logWarning("Vyber soubor .app")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard !externalApps.contains(where: { $0.path == url.path }) else {
            logWarning("Aplikace \(name) je již v seznamu")
            return
        }
        externalApps.append(ExternalApp(id: UUID(), name: name, path: url.path))
        saveExternalApps()
        logSuccess("Přidána aplikace: \(name)")
    }

    func removeExternalApp(id: UUID) {
        guard let name = externalApps.first(where: { $0.id == id })?.name else { return }
        externalApps.removeAll { $0.id == id }
        saveExternalApps()
        logInfo("Odebrána aplikace: \(name)")
    }

    func openSelectedFilesInApp(_ app: ExternalApp) {
        let filesToOpen = files.filter { selectedFiles.contains($0.id) }
        guard !filesToOpen.isEmpty else {
            logWarning("Nejsou vybrány žádné soubory")
            return
        }
        let urls = filesToOpen.map { $0.url }
        NSWorkspace.shared.open(urls, withApplicationAt: app.url,
                                configuration: .init()) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.logError("Nelze otevřít v \(app.name): \(error.localizedDescription)")
                } else {
                    self.logSuccess("Otevřeno v \(app.name): \(urls.count) soubor(ů)")
                }
            }
        }
    }
    
    // Filtered files based on search
    var filteredFiles: [FileItem] {
        if searchText.isEmpty {
            return files
        }
        return files.filter { file in
            file.name.localizedCaseInsensitiveContains(searchText) ||
            file.fileType.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    // Allowed file types
    let allowedFileTypes: [UTType] = [
        .pdf,
        .jpeg, .png, .tiff, .bmp, .gif,
        .rtf, .plainText,
        UTType(filenameExtension: "doc")!,
        UTType(filenameExtension: "docx")!,
        UTType(filenameExtension: "xls")!,
        UTType(filenameExtension: "xlsx")!,
        UTType(filenameExtension: "ppt")!,
        UTType(filenameExtension: "pptx")!,
        UTType(filenameExtension: "odt")!,
        UTType(filenameExtension: "ods")!,
        UTType(filenameExtension: "odp")!
    ]
    
    // MARK: - File Management
    
    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addFiles(urls: urls)
        case .failure(let error):
            logError("Failed to select files: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Directory expansion helpers

    /// Rozbalí složky na jejich obsah (rekurzivně, přeskočí skryté soubory a neznámé typy).
    private func expandURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                expandDirectory(url, into: &result)
            } else {
                result.append(url)
            }
        }
        return result
    }

    private func expandDirectory(_ dirURL: URL, into result: inout [URL]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                expandDirectory(item, into: &result)
            } else if FileType.from(extension: item.pathExtension.lowercased()) != .unknown {
                result.append(item)
            }
        }
    }

    func addFiles(urls: [URL]) {
        let expandedURLs = expandURLs(urls)
        let folderCount = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }.count
        if folderCount > 0 {
            logInfo("Přidávám \(expandedURLs.count) soubor(ů) (z \(folderCount) složky/složek)…")
        } else {
            logInfo("Přidávám \(expandedURLs.count) soubor(ů)…")
        }

        var officeURLs: [URL] = []
        var otherURLs: [URL] = []

        for url in expandedURLs {
            let fileType = FileType.from(extension: url.pathExtension.lowercased())
            if fileType.requiresConversion { officeURLs.append(url) }
            else { otherURLs.append(url) }
        }

        // ── Neoffice soubory — přidej placeholder okamžitě, parsuj na pozadí ──
        for url in otherURLs {
            let fileType = FileType.from(extension: url.pathExtension.lowercased())
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let placeholder = FileItem(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                fileType: fileType,
                fileSize: fileSize,
                pageCount: 0,
                pageSize: .zero,
                colorInfo: "…",
                status: .processing
            )
            files.append(placeholder)
            let placeholderID = placeholder.id

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                guard let parsed = self.fileParser.parseFile(url: url) else {
                    DispatchQueue.main.async {
                        self.files.removeAll { $0.id == placeholderID }
                        self.logError("Nelze načíst: \(url.lastPathComponent)")
                    }
                    return
                }
                var updated = parsed
                updated.id = placeholderID   // zachovat UUID → selection zůstane
                DispatchQueue.main.async {
                    if let idx = self.files.firstIndex(where: { $0.id == placeholderID }) {
                        self.files[idx] = updated
                        self.logSuccess("Načteno: \(updated.name)")
                    }
                }
            }
        }

        // ── Office soubory — dialog pro konverzi ──────────────────────────────
        if !officeURLs.isEmpty {
            pendingOfficeFiles = officeURLs
            showOfficeImportDialog = true
            logInfo("\(officeURLs.count) Office soubor(ů) vyžaduje konverzi do PDF")
        }
    }
    
    func removeSelectedFiles() {
        files.removeAll { selectedFiles.contains($0.id) }
        selectedFiles.removeAll()
        logInfo("Removed selected files")
    }

    func moveSelectedFilesToTrash() {
        let filesToTrash = files.filter { selectedFiles.contains($0.id) }
        guard !filesToTrash.isEmpty else { return }
        let ids = Set(filesToTrash.map { $0.id })
        var successCount = 0
        for file in filesToTrash {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                successCount += 1
            } catch {
                logError("Nelze přesunout do koše: \(file.name) – \(error.localizedDescription)")
            }
        }
        files.removeAll { ids.contains($0.id) }
        selectedFiles.subtract(ids)
        if successCount > 0 {
            logInfo("Přesunuto do koše: \(successCount) soubor(ů)")
        }
    }
    
    func removeFiles(items: Set<UUID>) {
        files.removeAll { items.contains($0.id) }
        selectedFiles.subtract(items)
        logInfo("Removed \(items.count) file(s)")
    }
    
    func clearAllFiles() {
        let count = files.count
        files.removeAll()
        selectedFiles.removeAll()
        logInfo("Cleared \(count) file(s)")
    }
    
    func selectAll() {
        selectedFiles = Set(files.map { $0.id })
    }
    
    // MARK: - Printing
    
    func printSelectedFiles() {
        guard !selectedFiles.isEmpty else {
            logWarning("No files selected for printing")
            return
        }
        
        let filesToPrint = files.filter { selectedFiles.contains($0.id) }
        logInfo("Printing \(filesToPrint.count) file(s)...")
        
        let presetOptions = availableSystemPresets.first(where: { $0.name == selectedPreset })?.lpOptions ?? []
        let settings = PrintSettings(
            printer: selectedPrinter,
            preset: selectedPreset,
            presetOptions: presetOptions,
            copies: printCopies,
            twoSided: printTwoSided,
            collate: printCollate,
            fitToPage: printFitToPage,
            landscape: printLandscape,
            colorMode: printColorMode,
            paperSize: printPaperSize
        )
        
        Task {
            do {
                for file in filesToPrint {
                    try await printService.printFile(file: file, settings: settings)
                    await MainActor.run {
                        updateFileStatus(id: file.id, status: .printed)
                        logSuccess("Printed: \(file.name)")
                    }
                }
                await MainActor.run { [self] in
                    logSuccess("Print job completed")
                    notifyPrintComplete(
                        fileCount: filesToPrint.count,
                        printerName: selectedPrinter.isEmpty ? "Default Printer" : selectedPrinter
                    )
                }
            } catch {
                await MainActor.run { [self] in
                    logError("Print failed: \(error.localizedDescription)")
                    notifyError(title: "Print Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - PDF Operations
    
    func splitPDF() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to split")
            return
        }
        
        logInfo("Splitting PDF: \(selectedFile.name)")
        
        Task {
            do {
                let outputFiles = try await pdfService.splitPDF(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("Split PDF into \(outputFiles.count) files")
                    addFiles(urls: outputFiles)
                }
            } catch {
                await MainActor.run {
                    logError("Failed to split PDF: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func mergePDFs() {
        let pdfFiles = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        
        guard pdfFiles.count >= 2 else {
            logWarning("Select at least 2 PDF files to merge")
            return
        }
        
        logInfo("Merging \(pdfFiles.count) PDFs...")
        
        Task {
            do {
                let outputURL = try await pdfService.mergePDFs(urls: pdfFiles.map { $0.url })
                await MainActor.run {
                    logSuccess("Merged PDFs successfully")
                    addFiles(urls: [outputURL])
                }
            } catch {
                await MainActor.run {
                    logError("Failed to merge PDFs: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func compressPDF() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to compress")
            return
        }
        
        showCompressionWindow = true
    }
    
    func compressPDFWithSettings() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to compress")
            return
        }
        
        logInfo("Compressing PDF: \(selectedFile.name) with settings: \(compressionSettings.levelDescription())")
        showCompressionWindow = false
        
        Task {
            do {
                let startTime = Date()
                let outputURL = try await pdfService.compressPDF(url: selectedFile.url, settings: compressionSettings)
                let processingTime = Date().timeIntervalSince(startTime)
                
                do {
                    let inputSize = try FileManager.default.attributesOfItem(atPath: selectedFile.url.path)[.size] as? Int64 ?? 0
                    let outputSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
                    let result = CompressionResult(
                        originalSize: inputSize,
                        compressedSize: outputSize,
                        compressionRatio: Double(inputSize) / Double(outputSize),
                        processingTime: processingTime,
                        warnings: []
                    )
                    
                    await MainActor.run { [self] in
                        compressionResults.append(result)
                        compressionProgress = 0.0
                        compressionMessage = ""
                        
                        logSuccess("Compressed PDF: \(String(format: "%.1f", result.savingsPercent))% smaller (\(result.fileSizeFormatted))")
                        addFiles(urls: [outputURL])
                        notifyCompressionComplete(originalSize: inputSize, compressedSize: outputSize)
                    }
                } catch {
                    await MainActor.run {
                        logError("Failed to get file sizes: \(error.localizedDescription)")
                    }
                }
            } catch {
                await MainActor.run { [self] in
                    compressionProgress = 0.0
                    compressionMessage = ""
                    logError("Failed to compress PDF: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func cropPDF() {
        guard let selectedFile = getSelectedFile(), (selectedFile.fileType == .pdf || selectedFile.fileType.isImage) else {
            logWarning("Select a single PDF or image file to crop")
            return
        }
        
        logInfo("Opening crop dialog for: \(selectedFile.name)")
        cropFile = selectedFile
        showCropView = true
    }
    
    func openMultiCrop() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType.isImage else {
            logWarning("Vyber jeden obrázek pro MultiCrop")
            return
        }
        logInfo("Otevírám MultiCrop pro: \(selectedFile.name)")
        multiCropFile = selectedFile
        showMultiCropDialog = true
    }

    func openColorPageSelector() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Vyber jeden PDF soubor pro výběr barevných stránek")
            return
        }
        logInfo("Otevírám výběr barevných stránek pro: \(selectedFile.name)")
        colorPageSelectorFile = selectedFile
        showColorPageSelector = true
    }

    func openBatchRename() {
        guard !selectedFiles.isEmpty else {
            logWarning("Vyber soubory pro přejmenování")
            return
        }
        showBatchRename = true
    }

    /// Nahradí soubor se stejným UUID novým FileItem (používá BatchRenameView).
    func replaceFile(_ item: FileItem) {
        if let idx = files.firstIndex(where: { $0.id == item.id }) {
            files[idx] = item
        }
    }


    func applySelectiveGray(file: FileItem, colorPages: Set<Int>, completion: @escaping () -> Void) {
        let colorCount  = colorPages.count
        let totalPages  = file.pageCount
        let grayCount   = totalPages - colorCount
        logInfo("Selektivní šedá: \(colorCount) barevných, \(grayCount) šedých stránek…")
        Task {
            do {
                let outputURL = try await pdfService.convertSelectiveToGray(url: file.url, colorPages: colorPages)
                await MainActor.run {
                    logSuccess("Selektivní šedá hotova: \(outputURL.lastPathComponent)")
                    addFiles(urls: [outputURL])
                    completion()
                }
            } catch {
                await MainActor.run {
                    logError("Selektivní šedá selhala: \(error.localizedDescription)")
                    completion()
                }
            }
        }
    }

    func smartCropFiles() {
        let selectedFiles = files.filter { self.selectedFiles.contains($0.id) }
        
        guard !selectedFiles.isEmpty else {
            logWarning("Select files to smart crop")
            return
        }
        
        logInfo("Smart cropping \(selectedFiles.count) file(s)...")
        
        Task {
            do {
                let outputURLs = try await smartCropService.smartCropFiles(urls: selectedFiles.map { $0.url })
                await MainActor.run {
                    logSuccess("Smart crop completed for \(outputURLs.count) file(s)")
                    addFiles(urls: outputURLs)
                }
            } catch {
                await MainActor.run {
                    logError("Smart crop failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func addBlankPagesToOddDocuments() {
        let selectedFiles = files.filter { self.selectedFiles.contains($0.id) }
        
        guard !selectedFiles.isEmpty else {
            logWarning("Select files to add blank pages")
            return
        }
        
        logInfo("Adding blank pages to odd documents...")
        
        Task {
            do {
                let outputURLs = try await blankPageService.addBlankPageToOddDocuments(urls: selectedFiles.map { $0.url })
                await MainActor.run {
                    logSuccess("Added blank pages to \(outputURLs.count) document(s)")
                    addFiles(urls: outputURLs)
                }
            } catch {
                await MainActor.run {
                    logError("Failed to add blank pages: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func rasterizePDF() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to rasterize")
            return
        }
        
        logInfo("Rasterizing PDF: \(selectedFile.name)")
        
        Task {
            do {
                let outputURL = try await pdfService.rasterizePDF(url: selectedFile.url, dpi: 300)
                await MainActor.run {
                    logSuccess("Rasterized PDF successfully")
                    addFiles(urls: [outputURL])
                }
            } catch {
                await MainActor.run {
                    logError("Failed to rasterize PDF: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func ocrPDF() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file for OCR")
            return
        }
        
        logInfo("Performing OCR on: \(selectedFile.name)")
        
        Task {
            do {
                let outputURL = try await pdfService.ocrPDF(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("OCR completed successfully")
                    addFiles(urls: [outputURL])
                }
            } catch {
                await MainActor.run {
                    logError("Failed to perform OCR: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func extractImagesFromPDF() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to extract images")
            return
        }
        
        logInfo("Extracting images from: \(selectedFile.name)")
        
        Task {
            do {
                let imageURLs = try await pdfService.extractImages(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("Extracted \(imageURLs.count) image(s)")
                    addFiles(urls: imageURLs)
                }
            } catch {
                await MainActor.run {
                    logError("Failed to extract images: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func showPDFInfo() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to view info")
            return
        }
        
        logInfo("Loading PDF info for: \(selectedFile.name)")
        
        if let metadata = PDFInfoService.shared.extractMetadata(from: selectedFile.url) {
            currentPDFMetadata = metadata
            showPDFInfoWindow = true
            logSuccess("PDF info loaded: \(metadata.pageCount) pages, \(metadata.pdfVersion)")
        } else {
            logError("Failed to read PDF info")
        }
    }

    // MARK: - PDF Actions: Convert to Gray, Flatten, Fix
    
    func convertToGray() {
        guard let selectedFile = getSelectedFile(), 
              (selectedFile.fileType == .pdf || selectedFile.fileType.isImage) else {
            logWarning("Select a single PDF or image file to convert to gray")
            return
        }
        
        logInfo("Converting to gray: \(selectedFile.name)")
        
        Task {
            do {
                let outputURL = try await pdfService.convertToGray(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("Converted to gray: \(outputURL.lastPathComponent)")
                    addFiles(urls: [outputURL])
                }
            } catch {
                await MainActor.run {
                    logError("Failed to convert to gray: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func flattenTransparency() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to flatten transparency")
            return
        }
        
        logInfo("Flattening transparency: \(selectedFile.name)")
        
        Task {
            do {
                let outputURL = try await pdfService.flattenTransparency(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("Flattened transparency: \(outputURL.lastPathComponent)")
                    addFiles(urls: [outputURL])
                }
            } catch {
                await MainActor.run {
                    logError("Failed to flatten transparency: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func fixPDF() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType == .pdf else {
            logWarning("Select a single PDF file to fix")
            return
        }
        
        logInfo("Fixing PDF: \(selectedFile.name)")
        
        Task {
            do {
                let outputURL = try await pdfService.fixPDF(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("Fixed PDF: \(outputURL.lastPathComponent)")
                    addFiles(urls: [outputURL])
                }
            } catch {
                await MainActor.run {
                    logError("Failed to fix PDF: \(error.localizedDescription)")
                }
            }
        }
    }

    
    // MARK: - Image Operations
    
    func convertImageToPDF() {
        let imageFiles = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        
        guard !imageFiles.isEmpty else {
            logWarning("Select image files to convert to PDF")
            return
        }
        
        logInfo("Converting \(imageFiles.count) image(s) to PDF...")
        
        Task {
            do {
                let outputURL = try await imageService.convertToPDF(urls: imageFiles.map { $0.url })
                await MainActor.run { [self] in
                    logSuccess("Converted images to PDF")
                    addFiles(urls: [outputURL])
                    notifyConversionComplete(fileCount: imageFiles.count, successCount: 1)
                }
            } catch {
                await MainActor.run { [self] in
                    logError("Failed to convert to PDF: \(error.localizedDescription)")
                    notifyError(title: "Conversion Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    func resizeImage() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType.isImage else {
            logWarning("Select a single image file to resize")
            return
        }
        
        logInfo("Opening resize dialog for: \(selectedFile.name)")
    }
    
    func rotateImage() {
        let imageFiles = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        
        guard !imageFiles.isEmpty else {
            logWarning("Select image files to rotate")
            return
        }
        
        logInfo("Rotating \(imageFiles.count) image(s)...")
        
        Task {
            do {
                for file in imageFiles {
                    let outputURL = try await imageService.rotateImage(url: file.url, degrees: 90)
                    await MainActor.run {
                        if let index = files.firstIndex(where: { $0.id == file.id }) {
                            if let newFile = fileParser.parseFile(url: outputURL) {
                                files[index] = newFile
                            }
                        }
                        logSuccess("Rotated: \(file.name)")
                    }
                }
            } catch {
                await MainActor.run {
                    logError("Failed to rotate image: \(error.localizedDescription)")
                }
            }
        }
    }

    // Rotate selected files (images and PDFs) 90° clockwise
    // Overwrites the original file in-place and preserves UUID/selection
    func rotateSelectedFiles(degrees: Double = 90) {
        let selectedFilesList = files.filter { selectedFiles.contains($0.id) }

        guard !selectedFilesList.isEmpty else {
            logWarning("Select files to rotate")
            return
        }

        let dir = degrees == 90 ? "CW" : "CCW"
        logInfo("Rotating \(selectedFilesList.count) file(s) \(dir)...")

        Task {
            for file in selectedFilesList {
                do {
                    let originalURL = file.url
                    let originalID = file.id

                    if file.fileType.isImage {
                        // Rotate to temp file, then atomically replace original
                        let tempURL = try await imageService.rotateImage(url: originalURL, degrees: degrees)
                        try FileManager.default.replaceItem(
                            at: originalURL, withItemAt: tempURL,
                            backupItemName: nil, options: [], resultingItemURL: nil
                        )
                    } else if file.fileType == .pdf {
                        let tempURL = try await pdfService.rotatePDF(url: originalURL, degrees: degrees)
                        try FileManager.default.replaceItem(
                            at: originalURL, withItemAt: tempURL,
                            backupItemName: nil, options: [], resultingItemURL: nil
                        )
                    } else {
                        continue
                    }

                    // Re-parse the file at the same URL, then restore original ID
                    await MainActor.run {
                        if let index = files.firstIndex(where: { $0.id == originalID }),
                           var refreshed = fileParser.parseFile(url: originalURL) {
                            // Preserve the original UUID so selection stays intact
                            refreshed.id = originalID
                            // Inkrementovat verzi obsahu — views (preview, metadata)
                            // ji sledují a překreslí se i když UUID zůstane stejné
                            refreshed.contentVersion = files[index].contentVersion + 1
                            files[index] = refreshed
                        }
                        logSuccess("Rotated \(dir): \(file.name)")
                    }
                } catch {
                    await MainActor.run {
                        logError("Failed to rotate \(file.name): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func rotateSelectedFilesLeft() {
        rotateSelectedFiles(degrees: 270.0)
    }
    
    func invertImage() {
        let imageFiles = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        
        guard !imageFiles.isEmpty else {
            logWarning("Select image files to invert")
            return
        }
        
        logInfo("Inverting \(imageFiles.count) image(s)...")
        
        Task {
            do {
                for file in imageFiles {
                    let outputURL = try await imageService.invertImage(url: file.url)
                    await MainActor.run {
                        if let index = files.firstIndex(where: { $0.id == file.id }) {
                            if let newFile = fileParser.parseFile(url: outputURL) {
                                files[index] = newFile
                            }
                        }
                        logSuccess("Inverted: \(file.name)")
                    }
                }
            } catch {
                await MainActor.run {
                    logError("Failed to invert image: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func detectAndExtractImages() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType.isImage else {
            logWarning("Select a single image file")
            return
        }
        
        logInfo("Detecting images within: \(selectedFile.name)")
        
        Task {
            do {
                let extractedURLs = try await imageService.detectAndExtractImages(url: selectedFile.url)
                await MainActor.run {
                    logSuccess("Extracted \(extractedURLs.count) sub-image(s)")
                    addFiles(urls: extractedURLs)
                }
            } catch {
                await MainActor.run {
                    logError("Failed to detect images: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Office Conversion

    func convertViaCloudConvert() {
        let officeFiles = files.filter {
            selectedFiles.contains($0.id) && $0.fileType.requiresConversion
        }

        guard !officeFiles.isEmpty else {
            logWarning("Select Office files for CloudConvert conversion")
            return
        }

        let apiKey = UserDefaults.standard.string(forKey: "cloudConvertApiKey") ?? ""
        guard !apiKey.isEmpty else {
            logError("CloudConvert API key not set. Configure in Settings → CloudConvert.")
            return
        }

        let service = CloudConvertService(apiKey: apiKey)
        logInfo("Starting CloudConvert conversion (\(officeFiles.count) file(s))...")

        Task {
            var successCount = 0
            for file in officeFiles {
                await MainActor.run {
                    updateFileStatus(id: file.id, status: .converting)
                    logInfo("Uploading to CloudConvert: \(file.name)...")
                }
                do {
                    let pdfURL = try await service.convertToPDF(fileURL: file.url)
                    await MainActor.run {
                        addFiles(urls: [pdfURL])
                        updateFileStatus(id: file.id, status: .ready)
                        logSuccess("CloudConvert: done → \(pdfURL.lastPathComponent)")
                    }
                    successCount += 1
                } catch {
                    await MainActor.run {
                        updateFileStatus(id: file.id, status: .error)
                        logError("CloudConvert (\(file.name)): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func convertViaGoogle() {
        let officeFiles = files.filter {
            selectedFiles.contains($0.id) && $0.fileType.requiresConversion
        }

        guard !officeFiles.isEmpty else {
            logWarning("Select Office files for Google conversion")
            return
        }

        let service = GoogleDocsConversionService()

        logInfo("Starting Google conversion (\(officeFiles.count) file(s))...")

        Task {
            let authenticated = await GoogleOAuthManager.shared.isAuthenticated
            guard authenticated else {
                await MainActor.run {
                    self.logError("Nejste přihlášeni k Google. Přihlaste se v Nastavení → Google.")
                }
                return
            }
            var successCount = 0
            for file in officeFiles {
                await MainActor.run {
                    updateFileStatus(id: file.id, status: .converting)
                    logInfo("Converting via Google: \(file.name)...")
                }
                do {
                    let pdfURL = try await service.convertToPDF(fileURL: file.url)
                    await MainActor.run {
                        addFiles(urls: [pdfURL])
                        updateFileStatus(id: file.id, status: .ready)
                        logSuccess("Google: done → \(pdfURL.lastPathComponent)")
                    }
                    successCount += 1
                } catch {
                    await MainActor.run {
                        updateFileStatus(id: file.id, status: .error)
                        logError("Google (\(file.name)): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func convertOfficeToPDF() {
        let officeFiles = files.filter {
            selectedFiles.contains($0.id) && $0.fileType.requiresConversion
        }

        guard !officeFiles.isEmpty else {
            logWarning("Select Office files (.doc, .docx, .xls, .xlsx, .ppt, .pptx, .odt...)")
            return
        }

        guard officeConversionService.isAvailable else {
            logError("LibreOffice / OpenOffice not found. Install from libreoffice.org.")
            return
        }

        logInfo("Converting \(officeFiles.count) files via LibreOffice...")

        Task {
            var successCount = 0
            for file in officeFiles {
                await MainActor.run {
                    updateFileStatus(id: file.id, status: .converting)
                    logInfo("Converting: \(file.name).\(file.fileType.rawValue.lowercased())")
                }

                do {
                    let pdfURL = try await officeConversionService.convertToPDF(url: file.url)
                    await MainActor.run {
                        addFiles(urls: [pdfURL])
                        updateFileStatus(id: file.id, status: .ready)
                        logSuccess("Done → \(pdfURL.lastPathComponent)")
                    }
                    successCount += 1
                } catch {
                    await MainActor.run {
                        updateFileStatus(id: file.id, status: .error)
                        logError("Error (\(file.name)): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - File Operations

    func revealInFinder(items: Set<UUID>) {
        let filesToReveal = files.filter { items.contains($0.id) }
        for file in filesToReveal {
            NSWorkspace.shared.selectFile(file.url.path, inFileViewerRootedAtPath: "")
        }
    }
    
    func openInDefaultApp(items: Set<UUID>) {
        let filesToOpen = files.filter { items.contains($0.id) }
        for file in filesToOpen {
            NSWorkspace.shared.open(file.url)
        }
    }
    
    func quickLook(items: Set<UUID>) {
        let filesToView = files.filter { items.contains($0.id) }
        for file in filesToView {
            NSWorkspace.shared.open(file.url)
        }
    }
    
    // MARK: - Rename
    
    func renameFile(_ file: FileItem, to newName: String) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        
        let selectedId = file.id
        
        let oldURL = file.url
        let fileExtension = oldURL.pathExtension
        let newFileName = newName.hasSuffix(".\(fileExtension)") ? newName : "\(newName).\(fileExtension)"
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newFileName)
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            if let renamedFile = fileParser.parseFile(url: newURL) {
                files[index] = renamedFile
                selectedFiles = [selectedId]
                logSuccess("Renamed to: \(newFileName)")
            }
        } catch {
            logError("Failed to rename: \(error.localizedDescription)")
        }
    }
    
    func showRenameDialog(for items: Set<UUID>) {
        guard items.count == 1, let fileId = items.first else {
            logWarning("Select only one file to rename")
            return
        }
        
        guard let file = files.first(where: { $0.id == fileId }) else { return }
        
        logInfo("Rename: \(file.name)")
    }
    
    // MARK: - Helper Methods
    
    private func getSelectedFile() -> FileItem? {
        guard selectedFiles.count == 1,
              let firstId = selectedFiles.first,
              let file = files.first(where: { $0.id == firstId }) else {
            return nil
        }
        return file
    }
    
    private func updateFileStatus(id: UUID, status: FileStatus) {
        if let index = files.firstIndex(where: { $0.id == id }) {
            files[index].status = status
        }
    }
    
    // MARK: - Debug Logging
    
    func logInfo(_ message: String) {
        debugMessages.append(DebugMessage(message: message, level: .info))
    }
    
    func logSuccess(_ message: String) {
        debugMessages.append(DebugMessage(message: message, level: .success))
    }
    
    func logWarning(_ message: String) {
        debugMessages.append(DebugMessage(message: message, level: .warning))
    }
    
    func logError(_ message: String) {
        debugMessages.append(DebugMessage(message: message, level: .error))
    }
    
    func clearDebugLog() {
        debugMessages.removeAll()
    }

    /// Načte systémové tiskové presety pro vybranou tiskárnu z macOS plistů.
    func loadSystemPresets() {
        guard !selectedPrinter.isEmpty else {
            availableSystemPresets = []
            selectedPreset = nil
            return
        }

        let printer   = selectedPrinter
        let cacheKey  = "pm.cache.presets.\(printer)"

        // 1. Okamžitě zobraz z cache (bez I/O blokování UI)
        if let data   = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([SystemPrinterPreset].self, from: data) {
            availableSystemPresets = cached
            validateSelectedPreset()
        }

        // 2. Na pozadí načti čerstvá data ze systémového plistu a přeulož cache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fresh = SystemPresetService().loadPresets(for: printer)
            if let data = try? JSONEncoder().encode(fresh) {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                // Aktualizuj jen pokud se stále díváme na stejnou tiskárnu
                guard self.selectedPrinter == printer else { return }
                self.availableSystemPresets = fresh
                self.validateSelectedPreset()
            }
        }
    }

    private func validateSelectedPreset() {
        if let current = selectedPreset,
           !availableSystemPresets.contains(where: { $0.name == current }) {
            selectedPreset = nil
        }
    }
}

extension Notification.Name {
    static let quickLookFileChanged = Notification.Name("quickLookFileChanged")
}
