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

class AppState: ObservableObject {
    // File management
    @Published var files: [FileItem] = []
    @Published var selectedFiles: Set<UUID> = []
    @Published var showingFilePicker = false
    
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
    
    // Compression
    @Published var showCompressionWindow = false
    @Published var compressionSettings = CompressionSettings()
    
    // Debug output
    @Published var debugMessages: [DebugMessage] = []
    
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
    
    // Search
    @Published var searchText: String = ""
    
    // Loading state
    @Published var isLoading = false
    @Published var loadingMessage = ""
    
    init() {
        self.showPreview = UserDefaults.standard.bool(forKey: "showPreview")
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
    
    func addFiles(urls: [URL]) {
        let startTime = Date()
        logInfo("Adding \(urls.count) file(s)...")
        
        // Separate Office files from other files
        var officeURLs: [URL] = []
        var otherURLs: [URL] = []
        
        for url in urls {
            let fileExtension = url.pathExtension.lowercased()
            let fileType = FileType.from(extension: fileExtension)
            
            if fileType.requiresConversion {
                officeURLs.append(url)
            } else {
                otherURLs.append(url)
            }
        }
        
        // Process non-Office files immediately
        for url in otherURLs {
            if let fileItem = fileParser.parseFile(url: url) {
                files.append(fileItem)
                logSuccess("Added: \(fileItem.name)")
            } else {
                logError("Failed to parse: \(url.lastPathComponent)")
            }
        }
        
        // If there are Office files, show import dialog
        if !officeURLs.isEmpty {
            pendingOfficeFiles = officeURLs
            showOfficeImportDialog = true
            logInfo("\(officeURLs.count) Office file(s) require conversion to PDF")
        }
        
        let duration = Date().timeIntervalSince(startTime)
        let totalProcessed = otherURLs.count + (officeURLs.isEmpty ? 0 : officeURLs.count)
        logInfo("Processed \(totalProcessed) files in \(String(format: "%.2f", duration))s")
    }
    
    func removeSelectedFiles() {
        files.removeAll { selectedFiles.contains($0.id) }
        selectedFiles.removeAll()
        logInfo("Removed selected files")
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
        availableSystemPresets = SystemPresetService().loadPresets(for: selectedPrinter)
        // Pokud aktuálně vybraný preset neexistuje pro novou tiskárnu, resetuj
        if let current = selectedPreset, !availableSystemPresets.contains(where: { $0.name == current }) {
            selectedPreset = nil
        }
    }
}
