//
//  CropView.swift
//  PrintManager
//
//  Interactive crop view for PDF and image files with live preview
//

import SwiftUI
import PDFKit

// MARK: - Crop View (Main Entry Point)

struct CropView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    let file: FileItem
    @State private var cropRect: CGRect
    @State private var currentPage: Int = 0
    @State private var isProcessing = false
    
    // Crop settings
    @State private var applyToAllPages: Bool = true
    @State private var cropMode: CropMode = .margins
    @State private var pdfBoxMode: PDFBoxMode = .media
    
    enum CropMode: String, CaseIterable {
        case margins = "Custom Margins"
        case preset = "Preset Size"
        case pdfBox = "PDF Box"
    }
    
    enum PDFBoxMode: String, CaseIterable {
        case media = "Media Box"
        case crop = "Crop Box"
        case bleed = "Bleed Box"
        case trim = "Trim Box"
        case art = "Art Box"
    }
    
    // Preset margins (in points)
    @State private var topMargin: Double = 36
    @State private var bottomMargin: Double = 36
    @State private var leftMargin: Double = 36
    @State private var rightMargin: Double = 36
    
    // Preset sizes
    @State private var selectedPreset: CropPreset = .a4
    
    enum CropPreset: String, CaseIterable {
        case a4 = "A4"
        case a5 = "A5"
        case a3 = "A3"
        case letter = "Letter"
        case legal = "Legal"
        
        var size: CGSize {
            switch self {
            case .a4: return CGSize(width: 595.28, height: 841.89)
            case .a5: return CGSize(width: 419.53, height: 595.28)
            case .a3: return CGSize(width: 841.89, height: 1190.55)
            case .letter: return CGSize(width: 612, height: 792)
            case .legal: return CGSize(width: 612, height: 1008)
            }
        }
    }
    
    // PDF document for multi-page handling
    private var pdfDocument: PDFDocument? {
        file.fileType == .pdf ? PDFDocument(url: file.url) : nil
    }
    
    private var pageSize: CGSize {
        if let pdf = pdfDocument, let page = pdf.page(at: currentPage) {
            return page.bounds(for: .mediaBox).size
        }
        if let image = NSImage(contentsOf: file.url) {
            return image.size
        }
        return CGSize(width: 612, height: 792)
    }
    
    init(file: FileItem) {
        self.file = file
        let size = file.pageSize
        self._cropRect = State(initialValue: CGRect(origin: .zero, size: size))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Crop: \(file.name)")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Main content
            HSplitView {
                // Left: Crop controls
                cropControlsPanel
                    .frame(width: 200)
                
                // Center: Preview
                cropPreviewPanel
                    .frame(minWidth: 400)
                
                // Right: Page navigation (for PDFs)
                if file.fileType == .pdf && (pdfDocument?.pageCount ?? 0) > 1 {
                    pageNavigationPanel
                        .frame(width: 120)
                }
            }
            
            Divider()
            
            // Footer with actions
            HStack {
                Toggle("Apply to all pages", isOn: $applyToAllPages)
                    .disabled(file.fileType != .pdf)
                
                Spacer()
                
                Button("Reset") {
                    resetCropRect()
                }
                
                Button("Apply") {
                    applyCrop()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    // MARK: - Crop Controls Panel
    
    private var cropControlsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Crop Mode")
                .font(.headline)
            
            Picker("", selection: $cropMode) {
                ForEach(CropMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            
            Divider()
            
            if cropMode == .margins {
                marginControls
            } else if cropMode == .preset {
                presetControls
            } else {
                pdfBoxControls
            }
            
            Divider()
            
            // Crop info
            VStack(alignment: .leading, spacing: 4) {
                Text("Crop Area")
                    .font(.headline)
                
                Group {
                    Text("X: \(Int(cropRect.origin.x)) pt")
                    Text("Y: \(Int(cropRect.origin.y)) pt")
                    Text("Width: \(Int(cropRect.width)) pt")
                    Text("Height: \(Int(cropRect.height)) pt")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                
                Text("\(Int(cropRect.width * 0.352777))×\(Int(cropRect.height * 0.352777)) mm")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private var marginControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Margins (points)")
                .font(.subheadline)
            
            VStack(spacing: 8) {
                HStack {
                    Text("Top:")
                        .frame(width: 50, alignment: .leading)
                    Slider(value: $topMargin, in: 0...pageSize.height/2)
                        .onChange(of: topMargin) { _ in updateCropFromMargins() }
                    Text("\(Int(topMargin))")
                        .frame(width: 30)
                }
                
                HStack {
                    Text("Bottom:")
                        .frame(width: 50, alignment: .leading)
                    Slider(value: $bottomMargin, in: 0...pageSize.height/2)
                        .onChange(of: bottomMargin) { _ in updateCropFromMargins() }
                    Text("\(Int(bottomMargin))")
                        .frame(width: 30)
                }
                
                HStack {
                    Text("Left:")
                        .frame(width: 50, alignment: .leading)
                    Slider(value: $leftMargin, in: 0...pageSize.width/2)
                        .onChange(of: leftMargin) { _ in updateCropFromMargins() }
                    Text("\(Int(leftMargin))")
                        .frame(width: 30)
                }
                
                HStack {
                    Text("Right:")
                        .frame(width: 50, alignment: .leading)
                    Slider(value: $rightMargin, in: 0...pageSize.width/2)
                        .onChange(of: rightMargin) { _ in updateCropFromMargins() }
                    Text("\(Int(rightMargin))")
                        .frame(width: 30)
                }
            }
            
            // Quick preset buttons
            HStack(spacing: 4) {
                Button("0mm") {
                    setMargins(top: 0, bottom: 0, left: 0, right: 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("10mm") {
                    let pts: Double = 10.0 / 0.352777
                    setMargins(top: pts, bottom: pts, left: pts, right: pts)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("20mm") {
                    let pts: Double = 20.0 / 0.352777
                    setMargins(top: pts, bottom: pts, left: pts, right: pts)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("30mm") {
                    let pts: Double = 30.0 / 0.352777
                    setMargins(top: pts, bottom: pts, left: pts, right: pts)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset Size")
                .font(.subheadline)
            
            Picker("", selection: $selectedPreset) {
                ForEach(CropPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()
            
            // Centering options
            Toggle("Center on page", isOn: .constant(true))
            
            // Fit mode
            Text("Fit Mode")
                .font(.caption)
            
            HStack(spacing: 4) {
                Button("Fill") {
                    fitPresetToPage(fill: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Fit") {
                    fitPresetToPage(fill: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    private var pdfBoxControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PDF Box Type")
                .font(.subheadline)
            
            Picker("", selection: $pdfBoxMode) {
                ForEach(PDFBoxMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            
            // Box info
            VStack(alignment: .leading, spacing: 4) {
                Text("Box Information")
                    .font(.caption)
                
                Text(boxDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            
            // Apply box button
            Button("Apply PDF Box") {
                applyPDFBox()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isPDFBoxAvailable)
            
            // Reset to media box
            Button("Reset to Media Box") {
                pdfBoxMode = .media
                applyPDFBox()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            // Box availability info
            if !isPDFBoxAvailable {
                Text("Selected box not available on this page")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
    }
    
    private var isPDFBoxAvailable: Bool {
        guard let pdf = pdfDocument,
              let page = pdf.page(at: currentPage) else {
            return false
        }
        
        let boxRect: CGRect
        switch pdfBoxMode {
        case .media:
            boxRect = page.bounds(for: .mediaBox)
        case .crop:
            boxRect = page.bounds(for: .cropBox)
        case .bleed:
            boxRect = page.bounds(for: .bleedBox)
        case .trim:
            boxRect = page.bounds(for: .trimBox)
        case .art:
            boxRect = page.bounds(for: .artBox)
        }
        
        // Check if box is defined (non-zero size)
        return boxRect.width > 0 && boxRect.height > 0
    }
    
    private var boxDescription: String {
        switch pdfBoxMode {
        case .media:
            return "Media Box: Defines the full size of the page including any printable area."
        case .crop:
            return "Crop Box: Defines the region to which the page contents are clipped when displayed or printed."
        case .bleed:
            return "Bleed Box: Defines the region to which the page contents need to be clipped when output in a production environment."
        case .trim:
            return "Trim Box: Defines the intended dimensions of the page after trimming."
        case .art:
            return "Art Box: Defines the extent of the page's meaningful content."
        }
    }
    
    // MARK: - Preview Panel
    
    private var cropPreviewPanel: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color(NSColor.textBackgroundColor)
                
                // Page preview with crop overlay
                if let image = loadPreviewImage() {
                    ImagePreviewWithCrop(
                        image: image,
                        cropRect: $cropRect,
                        pageSize: pageSize,
                        viewSize: geometry.size
                    )
                } else {
                    ProgressView()
                }
                
                // Loading overlay
                if isProcessing {
                    Color.black.opacity(0.3)
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Processing...")
                            .foregroundColor(.white)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }
    
    // MARK: - Page Navigation Panel
    
    private var pageNavigationPanel: some View {
        VStack(spacing: 8) {
            Text("Pages")
                .font(.caption)
            
            if let pageCount = pdfDocument?.pageCount {
                Text("\(currentPage + 1)/\(pageCount)")
                    .font(.caption)
            }
            
            Divider()
            
            if let pageCount = pdfDocument?.pageCount {
                VStack(spacing: 8) {
                    // Page number input
                    HStack {
                        Text("Page:")
                            .font(.caption)
                        Spacer()
                        TextField("1", value: Binding(
                            get: { Double(currentPage + 1) },
                            set: { newValue in
                                let page = max(0, min(pageCount - 1, Int(newValue) - 1))
                                currentPage = page
                                if !applyToAllPages {
                                    loadPageCropRect(page)
                                } else {
                                    // Auto-apply current PDF box to new page
                                    applyPDFBox()
                                }
                            }
                        ), format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 60)
                    }
                    
                    // Stepper for navigation
                    Stepper("Navigate", value: Binding(
                        get: { Double(currentPage + 1) },
                        set: { newValue in
                            let page = max(0, min(pageCount - 1, Int(newValue) - 1))
                            currentPage = page
                            if !applyToAllPages {
                                loadPageCropRect(page)
                            }
                        }
                    ), in: 1...Double(pageCount))
                    .labelsHidden()
                    
                    // Quick navigation buttons
                    HStack(spacing: 4) {
                        Button("First") {
                            currentPage = 0
                            if !applyToAllPages {
                                loadPageCropRect(0)
                            } else {
                                // Auto-apply current PDF box to new page
                                applyPDFBox()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Prev") {
                            if currentPage > 0 {
                                currentPage -= 1
                                if !applyToAllPages {
                                    loadPageCropRect(currentPage)
                                } else {
                                    // Auto-apply current PDF box to new page
                                    applyPDFBox()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Next") {
                            if currentPage < (pageCount - 1) {
                                currentPage += 1
                                if !applyToAllPages {
                                    loadPageCropRect(currentPage)
                                } else {
                                    // Auto-apply current PDF box to new page
                                    applyPDFBox()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Last") {
                            currentPage = pageCount - 1
                            if !applyToAllPages {
                                loadPageCropRect(pageCount - 1)
                            } else {
                                // Auto-apply current PDF box to new page
                                applyPDFBox()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Helper Methods
    
    private func loadPreviewImage() -> NSImage? {
        if file.fileType == .pdf {
            guard let pdf = pdfDocument,
                  let page = pdf.page(at: currentPage) else {
                return nil
            }
            // Pro větší stránky použijeme menší náhled pro lepší výkon a zobrazení
            let maxSize = CGSize(width: 800, height: 1100)
            return page.thumbnail(of: maxSize, for: .mediaBox)
        } else if file.fileType.isImage {
            return NSImage(contentsOf: file.url)
        }
        return nil
    }
    
    private func updateCropFromMargins() {
        let newWidth = pageSize.width - leftMargin - rightMargin
        let newHeight = pageSize.height - topMargin - bottomMargin
        
        cropRect = CGRect(
            x: leftMargin,
            y: bottomMargin, // PDF coordinate system
            width: max(50, newWidth),
            height: max(50, newHeight)
        )
    }
    
    private func setMargins(top: Double, bottom: Double, left: Double, right: Double) {
        topMargin = top
        bottomMargin = bottom
        leftMargin = left
        rightMargin = right
        updateCropFromMargins()
    }
    
    private func resetCropRect() {
        cropRect = CGRect(origin: .zero, size: pageSize)
        setMargins(top: 36, bottom: 36, left: 36, right: 36)
    }
    
    private func fitPresetToPage(fill: Bool) {
        let presetSize = selectedPreset.size
        let pageAspect = pageSize.width / pageSize.height
        let presetAspect = presetSize.width / presetSize.height
        
        var newSize: CGSize
        var newOrigin: CGPoint
        
        if fill {
            // Fill mode: preset covers the entire page
            if pageAspect > presetAspect {
                newSize = CGSize(
                    width: pageSize.width,
                    height: pageSize.width / presetAspect
                )
            } else {
                newSize = CGSize(
                    width: pageSize.height * presetAspect,
                    height: pageSize.height
                )
            }
        } else {
            // Fit mode: preset fits within page
            if pageAspect > presetAspect {
                newSize = CGSize(
                    width: pageSize.height * presetAspect,
                    height: pageSize.height
                )
            } else {
                newSize = CGSize(
                    width: pageSize.width,
                    height: pageSize.width / presetAspect
                )
            }
        }
        
        newOrigin = CGPoint(
            x: (pageSize.width - newSize.width) / 2,
            y: (pageSize.height - newSize.height) / 2
        )
        
        cropRect = CGRect(origin: newOrigin, size: newSize)
    }
    
    private func loadPageCropRect(_ page: Int) {
        // For now, reset to default
        // In a full implementation, you'd store crop rects per page
        resetCropRect()
    }
    
    private func applyPDFBox() {
        guard let pdf = pdfDocument,
              let page = pdf.page(at: currentPage) else {
            return
        }
        
        let boxRect: CGRect
        switch pdfBoxMode {
        case .media:
            boxRect = page.bounds(for: .mediaBox)
        case .crop:
            boxRect = page.bounds(for: .cropBox)
        case .bleed:
            boxRect = page.bounds(for: .bleedBox)
        case .trim:
            boxRect = page.bounds(for: .trimBox)
        case .art:
            boxRect = page.bounds(for: .artBox)
        }
        
        // Convert PDF coordinates to crop coordinates
        // PDF origin is bottom-left, crop origin is top-left
        let cropOrigin = CGPoint(
            x: boxRect.origin.x,
            y: pageSize.height - boxRect.origin.y - boxRect.height
        )
        
        cropRect = CGRect(
            origin: cropOrigin,
            size: boxRect.size
        )
    }
    
    private func applyCrop() {
        isProcessing = true
        
        Task {
            do {
                let outputURL: URL
                
                if file.fileType == .pdf {
                    outputURL = try await cropPDF()
                } else if file.fileType.isImage {
                    outputURL = try await cropImage()
                } else {
                    throw CropError.unsupportedFormat
                }
                
                await MainActor.run {
                    isProcessing = false
                    appState.addFiles(urls: [outputURL])
                    appState.logSuccess("Cropped: \(file.name) → \(outputURL.lastPathComponent)")
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    appState.logError("Crop failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func cropPDF() async throws -> URL {
        guard let pdf = pdfDocument else {
            throw CropError.invalidFile
        }
        
        let outputURL = file.url.deletingLastPathComponent()
            .appendingPathComponent(file.url.deletingPathExtension().lastPathComponent + "_cropped")
            .appendingPathExtension("pdf")
        
        // Convert crop rect from view coordinates to PDF coordinates
        let pdfCropRect = CGRect(
            x: cropRect.origin.x,
            y: pageSize.height - cropRect.origin.y - cropRect.height,
            width: cropRect.width,
            height: cropRect.height
        )
        
        if applyToAllPages {
            // Apply to all pages
            for pageIndex in 0..<pdf.pageCount {
                guard let page = pdf.page(at: pageIndex) else { continue }
                
                // Apply crop based on selected box mode
                switch pdfBoxMode {
                case .media:
                    page.setBounds(pdfCropRect, for: .mediaBox)
                case .crop:
                    page.setBounds(pdfCropRect, for: .cropBox)
                case .bleed:
                    page.setBounds(pdfCropRect, for: .bleedBox)
                case .trim:
                    page.setBounds(pdfCropRect, for: .trimBox)
                case .art:
                    page.setBounds(pdfCropRect, for: .artBox)
                }
            }
        } else {
            // Apply to current page only
            guard let page = pdf.page(at: currentPage) else {
                throw CropError.invalidPage
            }
            
            // Apply crop based on selected box mode
            switch pdfBoxMode {
            case .media:
                page.setBounds(pdfCropRect, for: .mediaBox)
            case .crop:
                page.setBounds(pdfCropRect, for: .cropBox)
            case .bleed:
                page.setBounds(pdfCropRect, for: .bleedBox)
            case .trim:
                page.setBounds(pdfCropRect, for: .trimBox)
            case .art:
                page.setBounds(pdfCropRect, for: .artBox)
            }
        }
        
        pdf.write(to: outputURL)
        return outputURL
    }
    
    private func cropImage() async throws -> URL {
        guard let image = NSImage(contentsOf: file.url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CropError.invalidFile
        }
        
        // Calculate scale factor between view and actual image
        let scaleX = CGFloat(cgImage.width) / pageSize.width
        let scaleY = CGFloat(cgImage.height) / pageSize.height
        
        // Convert crop rect to image coordinates
        let imageCropRect = CGRect(
            x: cropRect.origin.x * scaleX,
            y: (pageSize.height - cropRect.origin.y - cropRect.height) * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        )
        
        guard let croppedCGImage = cgImage.cropping(to: imageCropRect) else {
            throw CropError.cropFailed
        }
        
        let croppedImage = NSImage(
            cgImage: croppedCGImage,
            size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height)
        )
        
        let outputURL = file.url.deletingLastPathComponent()
            .appendingPathComponent(file.url.deletingPathExtension().lastPathComponent + "_cropped")
            .appendingPathExtension(file.url.pathExtension)
        
        try saveImage(croppedImage, to: outputURL)
        return outputURL
    }
    
    private func saveImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            throw CropError.saveFailed
        }
        
        let fileType: NSBitmapImageRep.FileType
        switch url.pathExtension.lowercased() {
        case "png":
            fileType = .png
        case "jpg", "jpeg":
            fileType = .jpeg
        default:
            fileType = .png
        }
        
        guard let data = bitmapRep.representation(using: fileType, properties: [:]) else {
            throw CropError.saveFailed
        }
        
        try data.write(to: url)
    }
}

// MARK: - Image Preview with Crop Overlay

struct ImagePreviewWithCrop: View {
    let image: NSImage
    @Binding var cropRect: CGRect
    let pageSize: CGSize
    let viewSize: CGSize
    
    @State private var isDragging = false
    @State private var dragStart: CGPoint = .zero
    @State private var dragMode: DragMode = .none
    
    enum DragMode {
        case none
        case move
        case resizeTopLeft
        case resizeTopRight
        case resizeBottomLeft
        case resizeBottomRight
        case resizeTop
        case resizeBottom
        case resizeLeft
        case resizeRight
    }
    
    private var displaySize: CGSize {
        let imageAspect = image.size.width / image.size.height
        let viewAspect = viewSize.width / viewSize.height
        
        if imageAspect > viewAspect {
            return CGSize(
                width: viewSize.width - 40,
                height: (viewSize.width - 40) / imageAspect
            )
        } else {
            return CGSize(
                width: (viewSize.height - 40) * imageAspect,
                height: viewSize.height - 40
            )
        }
    }
    
    private var displayOffset: CGPoint {
        CGPoint(
            x: (viewSize.width - displaySize.width) / 2,
            y: (viewSize.height - displaySize.height) / 2
        )
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Image
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displaySize.width, height: displaySize.height)
                
                // Crop overlay
                CropOverlayView(
                    cropRect: $cropRect,
                    pageSize: pageSize,
                    displaySize: displaySize,
                    displayOffset: displayOffset,
                    isDragging: $isDragging,
                    dragStart: $dragStart,
                    dragMode: $dragMode
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Crop Overlay View

struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let pageSize: CGSize
    let displaySize: CGSize
    let displayOffset: CGPoint
    @Binding var isDragging: Bool
    @Binding var dragStart: CGPoint
    @Binding var dragMode: ImagePreviewWithCrop.DragMode
    
    // Handle size
    private let handleSize: CGFloat = 10
    
    var body: some View {
        let scaleX = displaySize.width / pageSize.width
        let scaleY = displaySize.height / pageSize.height
        let scale = min(scaleX, scaleY)
        
        let scaledRect = CGRect(
            x: displayOffset.x + cropRect.origin.x * scale,
            y: displayOffset.y + (pageSize.height - cropRect.origin.y - cropRect.height) * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        )
        
        ZStack {
            // Darkened area outside crop
            CropMaskView(cropRect: scaledRect, displaySize: displaySize, displayOffset: displayOffset)
            
            // Crop border
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.blue, lineWidth: 2)
                .frame(width: scaledRect.width, height: scaledRect.height)
                .position(x: scaledRect.midX, y: scaledRect.midY)
            
            // Rule of thirds grid
            GridLinesView(rect: scaledRect)
            
            // Resize handles
            ForEach(Array(cornersAndEdges().enumerated()), id: \.offset) { index, item in
                Group {
                    if item.isCorner {
                        handleView
                    } else {
                        edgeHandleView
                    }
                }
                .position(item.position)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStart = value.startLocation
                            }
                            handleDrag(handle: item.handle, delta: value.translation, scale: scale)
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragMode = .none
                        }
                )
            }
            
            // Move gesture for entire crop area
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.clear)
                .frame(width: scaledRect.width, height: scaledRect.height)
                .position(x: scaledRect.midX, y: scaledRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStart = value.startLocation
                            }
                            let deltaX = value.translation.width / scale
                            let deltaY = -value.translation.height / scale
                            moveCrop(x: deltaX, y: deltaY)
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
        }
    }
    
    private struct Handle: Identifiable {
        let id = UUID()
        let handle: HandleType
        let position: CGPoint
    }
    
    private enum HandleType {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }
    
    private func cornersAndEdges() -> [(handle: HandleType, position: CGPoint, isCorner: Bool)] {
        let rect = currentScaledRect()
        
        return [
            (handle: .topLeft, position: CGPoint(x: rect.minX, y: rect.minY), isCorner: true),
            (handle: .topRight, position: CGPoint(x: rect.maxX, y: rect.minY), isCorner: true),
            (handle: .bottomLeft, position: CGPoint(x: rect.minX, y: rect.maxY), isCorner: true),
            (handle: .bottomRight, position: CGPoint(x: rect.maxX, y: rect.maxY), isCorner: true),
            (handle: .top, position: CGPoint(x: rect.midX, y: rect.minY), isCorner: false),
            (handle: .bottom, position: CGPoint(x: rect.midX, y: rect.maxY), isCorner: false),
            (handle: .left, position: CGPoint(x: rect.minX, y: rect.midY), isCorner: false),
            (handle: .right, position: CGPoint(x: rect.maxX, y: rect.midY), isCorner: false)
        ]
    }
    
    private var handleView: some View {
        Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
    }
    
    private var edgeHandleView: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.blue, lineWidth: 2))
    }
    
    private func currentScaledRect() -> CGRect {
        let scaleX = displaySize.width / pageSize.width
        let scaleY = displaySize.height / pageSize.height
        let scale = min(scaleX, scaleY)
        
        return CGRect(
            x: displayOffset.x + cropRect.origin.x * scale,
            y: displayOffset.y + (pageSize.height - cropRect.origin.y - cropRect.height) * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        )
    }
    
    private func handleDrag(handle: HandleType, delta: CGSize, scale: CGFloat) {
        let deltaX = delta.width / scale
        let deltaY = -delta.height / scale // Flip Y for PDF coordinates
        
        switch handle {
        case .topLeft:
            cropRect.origin.x += deltaX
            cropRect.size.width -= deltaX
            cropRect.size.height += deltaY
        case .topRight:
            cropRect.size.width += deltaX
            cropRect.size.height += deltaY
        case .bottomLeft:
            cropRect.origin.x += deltaX
            cropRect.origin.y += deltaY
            cropRect.size.width -= deltaX
            cropRect.size.height -= deltaY
        case .bottomRight:
            cropRect.origin.y += deltaY
            cropRect.size.width += deltaX
            cropRect.size.height -= deltaY
        case .top:
            cropRect.size.height += deltaY
        case .bottom:
            cropRect.origin.y += deltaY
            cropRect.size.height -= deltaY
        case .left:
            cropRect.origin.x += deltaX
            cropRect.size.width -= deltaX
        case .right:
            cropRect.size.width += deltaX
        }
        
        // Enforce minimum size
        cropRect.size.width = max(50, cropRect.size.width)
        cropRect.size.height = max(50, cropRect.size.height)
        
        // Keep within bounds
        if cropRect.origin.x < 0 {
            cropRect.size.width += cropRect.origin.x
            cropRect.origin.x = 0
        }
        if cropRect.origin.y < 0 {
            cropRect.size.height += cropRect.origin.y
            cropRect.origin.y = 0
        }
        if cropRect.origin.x + cropRect.size.width > pageSize.width {
            cropRect.size.width = pageSize.width - cropRect.origin.x
        }
        if cropRect.origin.y + cropRect.size.height > pageSize.height {
            cropRect.size.height = pageSize.height - cropRect.origin.y
        }
    }
    
    private func moveCrop(x: CGFloat, y: CGFloat) {
        cropRect.origin.x = max(0, min(pageSize.width - cropRect.size.width, cropRect.origin.x + x))
        cropRect.origin.y = max(0, min(pageSize.height - cropRect.size.height, cropRect.origin.y + y))
    }
}

// MARK: - Crop Mask View

struct CropMaskView: View {
    let cropRect: CGRect
    let displaySize: CGSize
    let displayOffset: CGPoint
    
    var body: some View {
        Canvas { context, size in
            let overlayPath = Path(CGRect(origin: .zero, size: size))
            context.fill(overlayPath, with: .color(.black.opacity(0.5)))
            
            let clearPath = Path(roundedRect: cropRect, cornerRadius: 2)
            context.fill(clearPath, with: .color(.clear))
            
            context.stroke(clearPath, with: .color(.blue), lineWidth: 2)
        }
    }
}

// MARK: - Grid Lines View

struct GridLinesView: View {
    let rect: CGRect
    
    var body: some View {
        Canvas { context, _ in
            let thirdWidth = rect.width / 3.0
            let thirdHeight = rect.height / 3.0
            
            for i in 1...2 {
                let x = rect.minX + thirdWidth * CGFloat(i)
                var path = Path()
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
            }
            
            for i in 1...2 {
                let y = rect.minY + thirdHeight * CGFloat(i)
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Crop Errors

enum CropError: LocalizedError {
    case invalidFile
    case invalidPage
    case unsupportedFormat
    case cropFailed
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Invalid file"
        case .invalidPage:
            return "Invalid page"
        case .unsupportedFormat:
            return "Unsupported file format"
        case .cropFailed:
            return "Crop operation failed"
        case .saveFailed:
            return "Failed to save cropped file"
        }
    }
}
