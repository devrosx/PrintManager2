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

// MARK: - QuickLook Mode

enum QuickLookMode {
    case thumbnails
    case singlePage
}

// MARK: - File Type Filter

enum FileTypeFilter: String, CaseIterable {
    case all      = "Vše"
    case pdf      = "PDF"
    case image    = "Obrázky"
    case document = "Dokumenty"
}

// MARK: - File List Column & Sort

enum FileListColumn: String, CaseIterable, Codable {
    case size      = "Size"
    case kind      = "Kind"
    case fileSize  = "File size"
    case pages     = "Pages"
    case colors    = "Colors"
    case converted = "Converted"
}

enum FileSortKey: String, Codable {
    case name, size, kind, fileSize, pages, colors
    /// Manuální pořadí — žádné třídění, pouze pořadí v `files`
    case manual
}

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
    @Published var files: [FileItem] = [] {
        didSet {
            let count = files.count
            DispatchQueue.main.async {
                NSApp.dockTile.badgeLabel = count == 0 ? nil : "\(count)"
                NSApp.dockTile.display()
            }
        }
    }
    @Published var selectedFiles: Set<UUID> = []
    @Published var rangeAnchorID: UUID? = nil
    @Published var showingFilePicker = false

    // External Apps
    @Published var externalApps: [ExternalApp] = []
    @Published var selectedAppID: UUID? = nil
    
    // Print settings
    @Published var selectedPrinter: String = ""
    @Published var selectedPreset: String? = nil
    @Published var availableSystemPresets: [SystemPrinterPreset] = []
    @Published var systemPresetsFilePath: URL? = nil
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

    // LineArt Crop
    @Published var showLineArtCropDialog = false
    @Published var lineArtCropFile: FileItem?

    // Color Page Selector
    @Published var showColorPageSelector = false
    @Published var colorPageSelectorFile: FileItem?
    @Published var colorPageSelectorQueue: [FileItem] = []

    // Imposition
    @Published var showingImpositionDialog = false
    @Published var impositionSourceFile: FileItem?

    // Batch Rename
    @Published var showBatchRename = false

    // Rename
    @Published var editingFileID: UUID? = nil
    
    // Settings
    @Published var showSettings = false

    // Compression
    @Published var showCompressionWindow = false
    @Published var compressionSettings = CompressionSettings()
    
    // Debug output
    @Published var debugMessages: [DebugMessage] = []

    // PDF metadata cache — sdílený mezi CompactFileMetadata a FilePricePanel
    @Published var pdfMetadataCache: [UUID: PDFMetadata] = [:]
    private var loadingMetadataIDs: Set<UUID> = []
    /// ID souborů, pro které GS analýza barev již proběhla (nebo proběhla chyba)
    private var colorAnalysisComplete: Set<UUID> = []

    /// Načte základní metadata PDF + spustí GS analýzu barev.
    /// Přeskočí pouze pokud obojí je již hotovo.
    func loadPDFMetadataIfNeeded(for file: FileItem) {
        guard file.fileType == .pdf,
              !loadingMetadataIDs.contains(file.id) else { return }

        if pdfMetadataCache[file.id] != nil {
            // Základní metadata jsou v cache – zkontroluj jen GS analýzu
            ensureColorAnalysis(for: file)
            return
        }

        // Načti základní metadata + spusť GS analýzu
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
                DispatchQueue.main.async {
                    self.loadingMetadataIDs.remove(id)
                    self.colorAnalysisComplete.insert(id)
                }
                return
            }
            PageColorAnalyzer.shared.analyzePDF(at: url) { result in
                if case .success(let colorInfo) = result {
                    metadata.colorPageCount      = colorInfo.colorCount
                    metadata.blackWhitePageCount = colorInfo.blackWhiteCount
                    metadata.colorPageNumbers    = Set(colorInfo.colorPages)
                }
                DispatchQueue.main.async {
                    self.pdfMetadataCache[id] = metadata
                    self.loadingMetadataIDs.remove(id)
                    self.colorAnalysisComplete.insert(id)
                }
            }
        }
    }

    /// Resetuje GS analýzu barev pro soubor — zavolej po in-place úpravě obsahu souboru.
    /// Vynuluje cache, takže `ensureColorAnalysis` ji znovu spustí.
    func resetColorAnalysis(for fileID: UUID) {
        colorAnalysisComplete.remove(fileID)
        if var meta = pdfMetadataCache[fileID] {
            meta.colorPageCount = 0
            meta.blackWhitePageCount = 0
            meta.colorPageNumbers = []
            pdfMetadataCache[fileID] = meta
        }
    }

    /// Spustí GS analýzu barev pro soubor, jehož základní metadata jsou již v cache,
    /// ale GS analýza ještě neproběhla. Bezpečné volat opakovaně.
    func ensureColorAnalysis(for file: FileItem) {
        guard file.fileType == .pdf,
              !colorAnalysisComplete.contains(file.id),
              !loadingMetadataIDs.contains(file.id),
              let existingMeta = pdfMetadataCache[file.id],
              PageColorAnalyzer.shared.isGSAvailable else { return }

        // Pokud GS data v cache jsou, jen označ jako hotovo a skonči
        if existingMeta.colorPageCount + existingMeta.blackWhitePageCount > 0 {
            colorAnalysisComplete.insert(file.id)
            return
        }

        loadingMetadataIDs.insert(file.id)
        let url = file.url
        let id  = file.id
        PageColorAnalyzer.shared.analyzePDF(at: url) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                if case .success(let colorInfo) = result,
                   var meta = self.pdfMetadataCache[id] {
                    meta.colorPageCount      = colorInfo.colorCount
                    meta.blackWhitePageCount = colorInfo.blackWhiteCount
                    meta.colorPageNumbers    = Set(colorInfo.colorPages)
                    self.pdfMetadataCache[id] = meta
                }
                self.loadingMetadataIDs.remove(id)
                self.colorAnalysisComplete.insert(id)
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
        
        notificationCenter.add(request)
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
    /// In-memory cache PDFDocument instancí — sdílí se mezi parserem a PreviewView.
    /// NSCache automaticky uvolní obsah při tlaku na paměť.
    let pdfDocumentCache: NSCache<NSURL, PDFDocument> = {
        let c = NSCache<NSURL, PDFDocument>()
        c.countLimit = 20   // max 20 dokumentů v paměti
        return c
    }()
    private let pdfService = PDFService()
    private let imageService = ImageService()
    private let smartCropService = SmartCropService()
    private let officeConversionService = OfficeConversionService()
    private let blankPageService = BlankPageService()
    
    // Stitch
    @Published var showStitchDialog = false
    @Published var stitchImageFiles: [FileItem] = []

    func openStitchDialog() {
        let images = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        guard images.count >= 2 else {
            logWarning("Select at least 2 images for Stitch")
            return
        }
        guard images.count <= 8 else {
            logWarning("Stitch supports max. 8 images at once")
            return
        }
        stitchImageFiles = images
        showStitchDialog = true
    }

    // Watermark
    @Published var showWatermarkDialog = false

    func openWatermarkDialog() {
        let pdfs = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !pdfs.isEmpty else {
            logWarning("Select at least one PDF to add a watermark")
            return
        }
        showWatermarkDialog = true
    }

    // Image Adjust
    @Published var showImageAdjustDialog = false
    @Published var imageAdjustFiles: [FileItem] = []

    // Resize
    @Published var showResizeDialog = false
    @Published var resizeDialogFiles: [FileItem] = []

    // PDF to Image Export
    @Published var showPDFToImageDialog = false
    @Published var pdfToImageFiles: [FileItem] = []

    func openImageAdjustDialog() {
        let imgs = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        guard !imgs.isEmpty else {
            logWarning("Select at least one image for adjustments")
            return
        }
        imageAdjustFiles = imgs
        showImageAdjustDialog = true
    }

    // Gallery
    @Published var showGalleryDialog = false
    @Published var galleryImageFiles: [FileItem] = []

    func openGalleryDialog() {
        let imgs = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        guard !imgs.isEmpty else {
            logWarning("Select at least one image to create a gallery")
            return
        }
        galleryImageFiles = imgs
        showGalleryDialog = true
    }

    // Collage
    @Published var showCollageDialog = false
    @Published var collageImageFiles: [FileItem] = []

    func openCollageDialog() {
        let imgs = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        guard imgs.count >= 2 else {
            logWarning("Vyber alespoň 2 obrázky pro vytvoření koláže")
            return
        }
        collageImageFiles = imgs
        showCollageDialog = true
    }

    // Background Fix (auto-levels)
    @Published var showBackgroundFixDialog = false
    @Published var backgroundFixFiles: [FileItem] = []

    func openBackgroundFixDialog() {
        let pdfs = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !pdfs.isEmpty else {
            logWarning("Vyber alespoň jeden PDF soubor pro korekci pozadí")
            return
        }
        backgroundFixFiles = pdfs
        showBackgroundFixDialog = true
    }

    // Background Removal
    func removeBackground() {
        let imgs = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        guard !imgs.isEmpty else {
            logWarning("Select at least one image for background removal")
            return
        }
        guard BackgroundRemovalService.visionSupported else {
            logError("Background removal requires macOS 12 or later")
            return
        }
        logInfo("Removing background from \(imgs.count) image(s)…")
        Task {
            var results: [URL] = []
            for img in imgs {
                do {
                    let out = try await Task.detached(priority: .userInitiated) {
                        try BackgroundRemovalService.shared.removeBackground(from: img.url)
                    }.value
                    results.append(out)
                } catch {
                    await MainActor.run {
                        logError("\(img.name): \(error.localizedDescription)")
                    }
                }
            }
            let finished = results
            await MainActor.run {
                if !finished.isEmpty {
                    addFiles(urls: finished, autoSelect: false, markAsConverted: true)
                    logSuccess("Background removed: \(finished.count) file(s) → PNG")
                }
            }
        }
    }

    // Drawings
    @Published var showDrawingsDialog = false

    // Quick Look
    var quickLookFileID: UUID?
    /// Seznam souborů k procházení šipkami v QuickLook (vybrané soubory nebo všechny)
    var quickLookFileIDs: [UUID] = []
    @Published var showInlineQuickLook = false
    @Published var quickLookMode: QuickLookMode = .thumbnails
    @Published var quickLookCurrentPage: Int = 0
    @Published var thumbnailZoom: Double = 1.0 // 0.5 = malé, 1.0 = střední, 2.0 = velké

    func quickLookMoveUp() {
        guard let current = quickLookFileID else { return }
        let pool = quickLookFileIDs.isEmpty ? files.map(\.id) : quickLookFileIDs
        guard let idx = pool.firstIndex(of: current), idx > 0 else { return }
        let prevID = pool[idx - 1]
        quickLookFileID = prevID
        selectedFiles = [prevID]
        // Automaticky nastavit režim podle typu souboru
        if let f = files.first(where: { $0.id == prevID }), f.fileType.isImage {
            quickLookMode = .singlePage
        } else {
            quickLookMode = .thumbnails
        }
        quickLookCurrentPage = 0
        NotificationCenter.default.post(name: .quickLookFileChanged, object: nil)
    }

    func quickLookMoveDown() {
        guard let current = quickLookFileID else { return }
        let pool = quickLookFileIDs.isEmpty ? files.map(\.id) : quickLookFileIDs
        guard let idx = pool.firstIndex(of: current), idx < pool.count - 1 else { return }
        let nextID = pool[idx + 1]
        quickLookFileID = nextID
        selectedFiles = [nextID]
        // Automaticky nastavit režim podle typu souboru
        if let f = files.first(where: { $0.id == nextID }), f.fileType.isImage {
            quickLookMode = .singlePage
        } else {
            quickLookMode = .thumbnails
        }
        quickLookCurrentPage = 0
        NotificationCenter.default.post(name: .quickLookFileChanged, object: nil)
    }

    func openDrawingsDialog() {
        guard !selectedFiles.isEmpty else {
            logWarning("Select files for drawings processing")
            return
        }
        showDrawingsDialog = true
    }

    func impositionPDF() {
        let pdfFiles = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !pdfFiles.isEmpty else {
            logWarning("Select at least one PDF for imposition")
            return
        }
        impositionSourceFile = pdfFiles.first
        showingImpositionDialog = true
    }

    // Tile PDF
    @Published var showTilePDFDialog = false
    @Published var tilePDFFiles: [FileItem] = []

    func tilePDFAction() {
        let selected = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !selected.isEmpty else {
            logWarning("Select at least one PDF file for Tile")
            return
        }
        tilePDFFiles = selected
        showTilePDFDialog = true
    }

    // Expand
    @Published var showExpandDialog = false
    @Published var expandFile: FileItem?

    func expandFileAction() {
        guard let file = getSelectedFile(),
              file.fileType == .pdf || file.fileType.isImage else {
            logWarning("Select one file (PDF or image) for Expand")
            return
        }
        expandFile = file
        showExpandDialog = true
    }

    // Compression state
    @Published var compressionProgress: Double = 0.0
    @Published var compressionMessage = ""
    @Published var compressionResults: [CompressionResult] = []
    
    // PDF Info
    @Published var showPDFInfoWindow = false
    @Published var currentPDFMetadata: PDFMetadata?
    
    // InDesign Import
    @Published var showInDesignImport = false

    func openInDesignImport() {
        guard !selectedFiles.isEmpty else { return }
        showInDesignImport = true
    }

    // Office Import
    @Published var showOfficeImportDialog = false
    @Published var pendingOfficeFiles: [URL] = []
    @Published var selectedImportMethod: ImportMethod = .auto
    
    // Preview Panel
    @Published var showPreview = false {
        didSet {
            UserDefaults.standard.set(showPreview, forKey: UDKeys.showPreview)
        }
    }

    // Printer Panel (left sidebar) - collapsible
    @Published var showPrinterPanel = true {
        didSet {
            UserDefaults.standard.set(showPrinterPanel, forKey: UDKeys.showPrinterPanel)
        }
    }

    // Thumbnail size: 0 = small, 1 = medium, 2 = large
    @Published var thumbnailSize: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(thumbnailSize, forKey: UDKeys.thumbnailSize)
        }
    }

    /// Výška řádku v seznamu souborů dle zvoleného thumbnailSize.
    var fileRowHeight: CGFloat {
        switch Int(thumbnailSize.rounded()) {
        case 0:  return 36
        case 2:  return 72
        default: return 52
        }
    }

    /// Velikost miniatury v řádku souboru dle zvoleného thumbnailSize.
    var fileThumbnailSize: CGFloat {
        switch Int(thumbnailSize.rounded()) {
        case 0:  return 28
        case 2:  return 64
        default: return 44
        }
    }

    // Search
    @Published var searchText: String = ""
    @Published var fileTypeFilter: FileTypeFilter = .all

    // Loading state
    @Published var isLoading = false
    @Published var loadingMessage = ""

    // File list columns & sorting
    @Published var hiddenColumns: Set<FileListColumn> = []
    @Published var fileSortKey: FileSortKey = .name
    @Published var fileSortAscending: Bool = true

    var sortedFiles: [FileItem] {
        let base = filteredFiles
        // Manuální pořadí — zachovej pořadí pole `files`, pouze aplikuj filtry
        guard fileSortKey != .manual else { return base }
        return base.sorted { a, b in
            let result: Bool
            switch fileSortKey {
            case .name:     result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:     result = a.pageSizeString.localizedStandardCompare(b.pageSizeString) == .orderedAscending
            case .kind:     result = a.fileType.rawValue < b.fileType.rawValue
            case .fileSize: result = a.fileSize < b.fileSize
            case .pages:    result = a.pageCount < b.pageCount
            case .colors:   result = a.colorInfo.localizedStandardCompare(b.colorInfo) == .orderedAscending
            case .manual:   result = true   // nikdy sem nedojde — ošetřeno výše
            }
            return fileSortAscending ? result : !result
        }
    }

    /// Přesune soubory v manuálním pořadí (volá SwiftUI `.onMove`).
    /// Indexy odpovídají `sortedFiles` (= `filteredFiles` při manual sortu).
    /// Metoda je bezpečná i při aktivním filtru: přemapuje indexy ze zobrazeného
    /// seznamu na pozice v hlavním poli `files`.
    func moveFiles(from source: IndexSet, to destination: Int) {
        guard fileSortKey == .manual else { return }

        // Zobrazeným souborům odpovídají tyto UUID v daném pořadí
        let displayedIDs = sortedFiles.map(\.id)

        // Rekonstruuj cílový index: kam by v displayedIDs skončil prvek po přesunu
        var reordered = displayedIDs
        reordered.move(fromOffsets: source, toOffset: destination)

        // Přemapuj nové pořadí do hlavního pole `files`.
        // Soubory, které nejsou ve filtru, zůstanou na svých místech.
        var newFiles: [FileItem] = []
        var filteredQueue = reordered.compactMap { id in
            files.first(where: { $0.id == id })
        }
        let filteredIDsSet = Set(displayedIDs)

        for file in files {
            if filteredIDsSet.contains(file.id) {
                // Nahrad prvkem z přeuspořádané fronty
                if let next = filteredQueue.first {
                    newFiles.append(next)
                    filteredQueue.removeFirst()
                }
            } else {
                // Soubory mimo filtr zůstanou na místě
                newFiles.append(file)
            }
        }
        files = newFiles
    }

    private var columnCancellable: AnyCancellable?
    private var sortKeyCancellable: AnyCancellable?
    private var sortAscCancellable: AnyCancellable?

    init() {
        self.showPrinterPanel = UserDefaults.standard.object(forKey: UDKeys.showPrinterPanel) as? Bool ?? true
        self.showPreview = UserDefaults.standard.bool(forKey: UDKeys.showPreview)
        self.thumbnailSize = UserDefaults.standard.object(forKey: UDKeys.thumbnailSize) as? Double ?? 1.0

        // Restore column/sort settings
        if let data = UserDefaults.standard.data(forKey: UDKeys.hiddenColumns),
           let decoded = try? JSONDecoder().decode(Set<FileListColumn>.self, from: data) {
            self.hiddenColumns = decoded
        }
        if let key = UserDefaults.standard.string(forKey: UDKeys.fileSortKey),
           let decoded = FileSortKey(rawValue: key) {
            self.fileSortKey = decoded
        }
        self.fileSortAscending = UserDefaults.standard.object(forKey: UDKeys.fileSortAscending) as? Bool ?? true

        loadExternalApps()

        // Persist column/sort settings via Combine
        columnCancellable = $hiddenColumns.dropFirst().sink { val in
            if let data = try? JSONEncoder().encode(val) {
                UserDefaults.standard.set(data, forKey: UDKeys.hiddenColumns)
            }
        }
        sortKeyCancellable = $fileSortKey.dropFirst().sink { val in
            UserDefaults.standard.set(val.rawValue, forKey: UDKeys.fileSortKey)
        }
        sortAscCancellable = $fileSortAscending.dropFirst().sink { val in
            UserDefaults.standard.set(val, forKey: UDKeys.fileSortAscending)
        }
    }

    // MARK: - External Apps

    private func loadExternalApps() {
        guard let data = UserDefaults.standard.data(forKey: UDKeys.externalApps),
              let apps = try? JSONDecoder().decode([ExternalApp].self, from: data) else { return }
        externalApps = apps
    }

    private func saveExternalApps() {
        guard let data = try? JSONEncoder().encode(externalApps) else { return }
        UserDefaults.standard.set(data, forKey: UDKeys.externalApps)
    }

    func addExternalApp(url: URL) {
        guard url.pathExtension.lowercased() == "app" else {
            logWarning("Select an .app file")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard !externalApps.contains(where: { $0.path == url.path }) else {
            logWarning("App \(name) is already in the list")
            return
        }
        externalApps.append(ExternalApp(id: UUID(), name: name, path: url.path))
        saveExternalApps()
        logSuccess("App added: \(name)")
    }

    func removeExternalApp(id: UUID) {
        guard let name = externalApps.first(where: { $0.id == id })?.name else { return }
        externalApps.removeAll { $0.id == id }
        saveExternalApps()
        logInfo("App removed: \(name)")
    }

    func openSelectedFilesInApp(_ app: ExternalApp) {
        let filesToOpen = files.filter { selectedFiles.contains($0.id) }
        guard !filesToOpen.isEmpty else {
            logWarning("No files selected")
            return
        }
        let urls = filesToOpen.map { $0.url }
        NSWorkspace.shared.open(urls, withApplicationAt: app.url,
                                configuration: .init()) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.logError("Cannot open in \(app.name): \(error.localizedDescription)")
                } else {
                    self.logSuccess("Opened in \(app.name): \(urls.count) file(s)")
                }
            }
        }
    }
    
    // Filtered files based on search text and file type filter
    var filteredFiles: [FileItem] {
        var result = files

        // Textový filtr
        if !searchText.isEmpty {
            result = result.filter { file in
                file.name.localizedCaseInsensitiveContains(searchText) ||
                file.fileType.rawValue.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Filtr podle typu souboru
        switch fileTypeFilter {
        case .all:
            break
        case .pdf:
            result = result.filter { $0.fileType == .pdf }
        case .image:
            result = result.filter { $0.fileType.isImage }
        case .document:
            result = result.filter { $0.fileType.requiresConversion }
        }

        return result
    }
    
    // Allowed file types
    let allowedFileTypes: [UTType] = [
        .pdf,
        .jpeg, .png, .tiff, .bmp, .gif,
        .heic, .webP,
        UTType(filenameExtension: "heif")!,
        UTType(filenameExtension: "dng")!,
        UTType(filenameExtension: "cr2")!,
        UTType(filenameExtension: "cr3")!,
        UTType(filenameExtension: "nef")!,
        UTType(filenameExtension: "arw")!,
        UTType(filenameExtension: "orf")!,
        UTType(filenameExtension: "raf")!,
        UTType(filenameExtension: "rw2")!,
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

    /// Jednotný helper pro dokončení operace: přidá výstupní soubor, zaloguje úspěch a pošle notifikaci.
    /// - Parameters:
    ///   - output: Výstupní URL
    ///   - message: Text do activity logu
    ///   - inputCount: Počet vstupních souborů (pro notifikaci)
    func finishOperation(output: URL, message: String, inputCount: Int = 1) {
        addFiles(urls: [output], autoSelect: true, markAsConverted: true)
        logSuccess(message)
        notifyConversionComplete(fileCount: inputCount, successCount: 1)
    }

    func addFiles(urls: [URL], autoSelect: Bool = false, markAsConverted: Bool = false) {
        // Při přidání souboru vždy zavřít inline QuickLook a vrátit se na list souborů
        if showInlineQuickLook {
            showInlineQuickLook = false
            quickLookMode = .thumbnails
        }

        let expandedURLs = expandURLs(urls)
        let folderCount = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }.count
        if folderCount > 0 {
            logInfo("Adding \(expandedURLs.count) file(s) (from \(folderCount) folder(s))…")
        } else {
            logInfo("Adding \(expandedURLs.count) file(s)…")
        }

        var officeURLs: [URL] = []
        var otherURLs: [URL] = []
        var portfolioEntries: [(url: URL, source: String)] = []

        for url in expandedURLs {
            let fileType = FileType.from(extension: url.pathExtension.lowercased())
            if fileType == .pdf && PDFPortfolioExtractor.isPortfolio(url: url) {
                let portfolioName = url.deletingPathExtension().lastPathComponent
                logInfo("Detected PDF portfolio: \(portfolioName), extracting…")
                let extracted = PDFPortfolioExtractor.extractFiles(from: url)
                if extracted.isEmpty {
                    logWarning("Portfolio \(portfolioName) contains no extractable files, adding as regular PDF")
                    otherURLs.append(url)
                } else {
                    logSuccess("Extracted \(extracted.count) file(s) from portfolio \(portfolioName)")
                    for eURL in extracted {
                        portfolioEntries.append((url: eURL, source: portfolioName))
                    }
                }
            } else if fileType.requiresConversion {
                officeURLs.append(url)
            } else {
                otherURLs.append(url)
            }
        }

        // ── Neoffice soubory — přidej placeholder okamžitě, parsuj na pozadí ──
        let isOutput = autoSelect || markAsConverted

        var newIDs: Set<UUID> = []
        for url in otherURLs {
            let fileType = FileType.from(extension: url.pathExtension.lowercased())
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            var placeholder = FileItem(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                fileType: fileType,
                fileSize: fileSize,
                pageCount: 0,
                pageSize: .zero,
                colorInfo: "…",
                status: .processing
            )
            placeholder.isConverted = isOutput
            files.append(placeholder)
            let placeholderID = placeholder.id
            newIDs.insert(placeholderID)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                guard var parsed = self.fileParser.parseFile(url: url) else {
                    DispatchQueue.main.async {
                        self.files.removeAll { $0.id == placeholderID }
                        self.logError("Cannot load: \(url.lastPathComponent)")
                    }
                    return
                }
                parsed.id          = placeholderID   // zachovat UUID → selection zůstane
                parsed.isConverted = isOutput

                // Fáze 1: zobraz metadata okamžitě
                DispatchQueue.main.async {
                    if let idx = self.files.firstIndex(where: { $0.id == placeholderID }) {
                        self.files[idx] = parsed
                        self.logSuccess("Loaded: \(parsed.name)")
                    }
                }

                // Fáze 2: zajisti thumbnail v disk cache (views načítají přes ThumbnailCache.shared)
                if ThumbnailCache.shared.thumbnail(for: url) == nil {
                    _ = self.fileParser.generateThumbnail(url: url, fileType: parsed.fileType)
                }
            }
        }

        // ── Soubory z PDF portfolia — přidej s portfolioSource ────────────────
        for entry in portfolioEntries {
            let url = entry.url
            let fileType = FileType.from(extension: url.pathExtension.lowercased())

            if fileType.requiresConversion {
                officeURLs.append(url)
                continue
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            var placeholder = FileItem(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                fileType: fileType,
                fileSize: fileSize,
                pageCount: 0,
                pageSize: .zero,
                colorInfo: "…",
                status: .processing
            )
            placeholder.isConverted = isOutput
            placeholder.portfolioSource = entry.source
            files.append(placeholder)
            let placeholderID = placeholder.id
            newIDs.insert(placeholderID)

            let portfolioSrc = entry.source
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                guard var parsed = self.fileParser.parseFile(url: url) else {
                    DispatchQueue.main.async {
                        self.files.removeAll { $0.id == placeholderID }
                        self.logError("Cannot load: \(url.lastPathComponent)")
                    }
                    return
                }
                parsed.id = placeholderID
                parsed.isConverted = isOutput
                parsed.portfolioSource = portfolioSrc

                DispatchQueue.main.async {
                    if let idx = self.files.firstIndex(where: { $0.id == placeholderID }) {
                        self.files[idx] = parsed
                        self.logSuccess("Loaded: \(parsed.name)")
                    }
                }

                // Zajisti thumbnail v disk cache (views načítají přes ThumbnailCache.shared)
                if ThumbnailCache.shared.thumbnail(for: url) == nil {
                    _ = self.fileParser.generateThumbnail(url: url, fileType: parsed.fileType)
                }
            }
        }

        if autoSelect && !newIDs.isEmpty {
            selectedFiles = newIDs
        }

        // ── Office soubory — dialog pro konverzi ──────────────────────────────
        if !officeURLs.isEmpty {
            pendingOfficeFiles = officeURLs
            showOfficeImportDialog = true
            logInfo("\(officeURLs.count) Office file(s) require PDF conversion")
        }
    }
    
    func removeSelectedFiles() {
        let ids = selectedFiles
        cleanupCache(for: ids)
        files.removeAll { ids.contains($0.id) }
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
                logError("Cannot move to trash: \(file.name) – \(error.localizedDescription)")
            }
        }
        cleanupCache(for: ids)
        files.removeAll { ids.contains($0.id) }
        selectedFiles.subtract(ids)
        if successCount > 0 {
            logInfo("Moved to trash: \(successCount) file(s)")
        }
    }
    
    func removeFiles(items: Set<UUID>) {
        cleanupCache(for: items)
        files.removeAll { items.contains($0.id) }
        selectedFiles.subtract(items)
        logInfo("Removed \(items.count) file(s)")
    }
    
    func clearAllFiles() {
        let count = files.count
        pdfMetadataCache.removeAll()
        loadingMetadataIDs.removeAll()
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
                await MainActor.run { [weak self] in
                        guard let self else { return }
                    logSuccess("Print job completed")
                    notifyPrintComplete(
                        fileCount: filesToPrint.count,
                        printerName: selectedPrinter.isEmpty ? "Default Printer" : selectedPrinter
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                        guard let self else { return }
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
                    addFiles(urls: outputFiles, autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to split PDF")
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
                    addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to merge PDFs")
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
                    
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        compressionResults.append(result)
                        compressionProgress = 0.0
                        compressionMessage = ""
                        
                        logSuccess("Compressed PDF: \(String(format: "%.1f", result.savingsPercent))% smaller (\(result.fileSizeFormatted))")
                        addFiles(urls: [outputURL], autoSelect: true)
                        notifyCompressionComplete(originalSize: inputSize, compressedSize: outputSize)
                    }
                } catch {
                    await MainActor.run {
                        logError("Failed to get file sizes: \(error.localizedDescription)")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                        guard let self else { return }
                    compressionProgress = 0.0
                    compressionMessage = ""
                    handleOperationError(error, operationDescription: "Failed to compress PDF")
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
            logWarning("Select one image for MultiCrop")
            return
        }
        logInfo("Opening MultiCrop for: \(selectedFile.name)")
        multiCropFile = selectedFile
        showMultiCropDialog = true
    }

    func openLineArtCropDialog() {
        guard let selectedFile = getSelectedFile(), selectedFile.fileType.isImage else {
            logWarning("Vyberte jeden obraz pro LineArt Crop")
            return
        }
        logInfo("Opening LineArt Crop for: \(selectedFile.name)")
        lineArtCropFile = selectedFile
        showLineArtCropDialog = true
    }

    func openColorPageSelector() {
        let pdfFiles = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !pdfFiles.isEmpty else {
            logWarning("Select at least one PDF file for color page selection")
            return
        }
        logInfo("Opening color page selection for \(pdfFiles.count) file(s): \(pdfFiles.map(\.name).joined(separator: ", "))")
        colorPageSelectorQueue = pdfFiles
        colorPageSelectorFile = pdfFiles[0]
        showColorPageSelector = true
    }

    func openBatchRename() {
        guard !selectedFiles.isEmpty else {
            logWarning("Select files to rename")
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
        logInfo("Selective gray: \(colorCount) color, \(grayCount) gray pages…")
        Task {
            do {
                let outputURL = try await pdfService.convertSelectiveToGray(url: file.url, colorPages: colorPages)
                await MainActor.run {
                    logSuccess("Selective gray done: \(outputURL.lastPathComponent)")
                    addFiles(urls: [outputURL], autoSelect: true)
                    completion()
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Selektivní šedá selhala")
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
                    addFiles(urls: outputURLs, autoSelect: true)
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
                    addFiles(urls: outputURLs, autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to add blank pages")
                }
            }
        }
    }

    func openPDFToImageDialog() {
        let pdfs = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !pdfs.isEmpty else {
            logWarning("Select at least one PDF file to export as images")
            return
        }
        pdfToImageFiles = pdfs
        showPDFToImageDialog = true
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
                    addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to rasterize PDF")
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
                    addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to perform OCR")
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
                    addFiles(urls: imageURLs, autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to extract images")
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
                    addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to convert to gray")
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
                    addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to flatten transparency")
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
                    addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    handleOperationError(error, operationDescription: "Failed to fix PDF")
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
                await MainActor.run { [weak self] in
                        guard let self else { return }
                    logSuccess("Converted images to PDF")
                    addFiles(urls: [outputURL], autoSelect: true)
                    notifyConversionComplete(fileCount: imageFiles.count, successCount: 1)
                }
            } catch {
                await MainActor.run { [weak self] in
                        guard let self else { return }
                    handleOperationError(error, operationDescription: "Failed to convert to PDF")
                    notifyError(title: "Conversion Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    func resizeImage() {
        let imgs = files.filter { selectedFiles.contains($0.id) && $0.fileType.isImage }
        guard !imgs.isEmpty else {
            logWarning("Select at least one image to resize")
            return
        }
        resizeDialogFiles = imgs
        showResizeDialog  = true
    }

    func resizePDF() {
        let pdfs = files.filter { selectedFiles.contains($0.id) && $0.fileType == .pdf }
        guard !pdfs.isEmpty else {
            logWarning("Select at least one PDF file to resize")
            return
        }
        resizeDialogFiles = pdfs
        showResizeDialog  = true
    }

    func resizeFiles() {
        let sel = files.filter { selectedFiles.contains($0.id) }
        guard !sel.isEmpty else {
            logWarning("Select files to resize")
            return
        }
        resizeDialogFiles = sel
        showResizeDialog  = true
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
                            if var newFile = fileParser.parseFile(url: outputURL) {
                                newFile.isConverted = true
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
                    addFiles(urls: extractedURLs, autoSelect: true)
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

        let apiKey = UserDefaults.standard.string(forKey: UDKeys.cloudConvertApiKey) ?? ""
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
                        addFiles(urls: [pdfURL], autoSelect: true)
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
                    self.logError("Not signed in to Google. Sign in via Settings → Google.")
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
                        addFiles(urls: [pdfURL], autoSelect: true)
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
                        addFiles(urls: [pdfURL], autoSelect: true)
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

    /// Otevře soubory ve vybrané externí aplikaci (selectedAppID), nebo v default app.
    func openInSelectedOrDefaultApp(items: Set<UUID>) {
        if let appID = selectedAppID,
           let app = externalApps.first(where: { $0.id == appID }) {
            let urls = files.filter { items.contains($0.id) }.map { $0.url }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app.url,
                                    configuration: .init()) { _, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.logError("Cannot open in \(app.name): \(error.localizedDescription)")
                    }
                }
            }
        } else {
            openInDefaultApp(items: items)
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

    private func cleanupCache(for ids: Set<UUID>) {
        for id in ids {
            pdfMetadataCache.removeValue(forKey: id)
            loadingMetadataIDs.remove(id)
        }
    }

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

    // MARK: - Write Failure Fallback

    /// Zpracuje chybu operace. Pokud jde o selhání zápisu s dostupnými daty,
    /// zobrazí panel "Uložit jako" a nechá uživatele vybrat umístění.
    func handleOperationError(_ error: Error, operationDescription: String) {
        if case PDFError.writeFailedWithFallback(_, let data, let suggestedName) = error {
            logWarning("Write failed – choose a different location for '\(suggestedName)'")
            offerSaveAsDialog(data: data, suggestedName: suggestedName)
        } else {
            logError("\(operationDescription): \(error.localizedDescription)")
        }
    }

    /// Zobrazí macOS dialog "Uložit jako" a uloží data na vybrané místo.
    /// Musí být voláno na hlavním vlákně.
    func offerSaveAsDialog(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType.pdf]
        panel.message = "Původní umístění není přístupné. Vyberte, kam soubor uložit:"
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                DispatchQueue.main.async {
                    self.logSuccess("File saved: \(url.lastPathComponent)")
                    self.addFiles(urls: [url], autoSelect: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.logError("Write to chosen location failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func clearDebugLog() {
        debugMessages.removeAll()
    }

    /// Načte systémové tiskové presety pro vybranou tiskárnu z macOS plistů.
    func loadSystemPresets() {
        guard !selectedPrinter.isEmpty else {
            availableSystemPresets = []
            selectedPreset = nil
            systemPresetsFilePath = nil
            return
        }

        let printer   = selectedPrinter
        let cacheKey  = UDKeys.presetCache(printer: printer)

        // 1. Okamžitě zobraz z cache (bez I/O blokování UI)
        if let data   = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([SystemPrinterPreset].self, from: data) {
            availableSystemPresets = cached
            validateSelectedPreset()
        }

        // 2. Na pozadí načti čerstvá data ze systémového plistu a přeulož cache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = SystemPresetService().loadPresetsWithInfo(for: printer)
            if let data = try? JSONEncoder().encode(result.presets) {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                guard self.selectedPrinter == printer else { return }
                self.availableSystemPresets = result.presets
                self.systemPresetsFilePath = result.foundPath.map { URL(fileURLWithPath: $0) }
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

    /// Smaže systémový preset z plist souboru a znovu načte seznam.
    func deleteSystemPreset(name: String) {
        let printer = selectedPrinter
        let service = SystemPresetService()
        if service.deletePreset(named: name, forPrinter: printer) {
            // Invalidovat cache
            let cacheKey = UDKeys.presetCache(printer: printer)
            UserDefaults.standard.removeObject(forKey: cacheKey)
            if selectedPreset == name { selectedPreset = nil }
            loadSystemPresets()
            logInfo("Preset \"\(name)\" byl smazán")
        } else {
            logError("Nelze smazat preset \"\(name)\"")
        }
    }

    /// Vytiskne soubory na konkrétní tiskárnu (drag & drop z file listu).
    func printFiles(urls: [URL], toPrinter printerName: String) {
        let urlStrings = Set(urls.map { $0.absoluteString })
        var filesToPrint = files.filter { urlStrings.contains($0.url.absoluteString) }
        // Pro URL které nejsou v seznamu (temp PDF ze stránek, externí soubory), parsuj přímo
        if filesToPrint.isEmpty {
            let parser = FileParser()
            filesToPrint = urls.compactMap { parser.parseFile(url: $0) }
        }
        guard !filesToPrint.isEmpty else {
            logWarning("Žádné soubory pro tisk")
            return
        }

        let presetOptions = availableSystemPresets.first(where: { $0.name == selectedPreset })?.lpOptions ?? []
        let settings = PrintSettings(
            printer: printerName,
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

        let filesToPrintFinal = filesToPrint
        logInfo("Tisknu \(filesToPrintFinal.count) soubor(u) na \(printerName)...")

        Task {
            do {
                for file in filesToPrintFinal {
                    try await printService.printFile(file: file, settings: settings)
                    await MainActor.run {
                        updateFileStatus(id: file.id, status: .printed)
                        logSuccess("Vytisknuto: \(file.name)")
                    }
                }
                await MainActor.run { [weak self] in
                        guard let self else { return }
                    logSuccess("Tisk dokončen")
                    notifyPrintComplete(fileCount: filesToPrintFinal.count, printerName: printerName)
                }
            } catch {
                await MainActor.run { [weak self] in
                        guard let self else { return }
                    logError("Tisk selhal: \(error.localizedDescription)")
                    notifyError(title: "Tisk selhal", message: error.localizedDescription)
                }
            }
        }
    }
}

extension Notification.Name {
    static let quickLookFileChanged = Notification.Name("quickLookFileChanged")
    static let quickLookPagePrevious = Notification.Name("quickLookPagePrevious")
    static let quickLookPageNext = Notification.Name("quickLookPageNext")
}
