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
    @State private var isSyncingFromDrag = false
    
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
            .background(DS.Colors.controlBackground)

            Divider()

            // Main content
            HSplitView {
                // Left: Crop controls
                cropControlsPanel
                    .frame(width: 320)

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
            .background(DS.Colors.controlBackground)
        }
        .frame(minWidth: 920, minHeight: 600)
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
                .font(DS.Typography.caption)
                .foregroundColor(.secondary)
                
                Text("\(Int(cropRect.width * 0.352777))×\(Int(cropRect.height * 0.352777)) mm")
                    .font(DS.Typography.caption)
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
                MarginSliderRow(label: "Top:",    value: $topMargin,    maxValue: pageSize.height / 2, onChange: updateCropFromMargins)
                MarginSliderRow(label: "Bottom:", value: $bottomMargin, maxValue: pageSize.height / 2, onChange: updateCropFromMargins)
                MarginSliderRow(label: "Left:",   value: $leftMargin,   maxValue: pageSize.width  / 2, onChange: updateCropFromMargins)
                MarginSliderRow(label: "Right:",  value: $rightMargin,  maxValue: pageSize.width  / 2, onChange: updateCropFromMargins)
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
                        viewSize: geometry.size,
                        onCropChanged: { newRect in
                            updateMarginsFromCrop(newRect)
                        }
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
        guard !isSyncingFromDrag else { return }
        let newWidth = pageSize.width - leftMargin - rightMargin
        let newHeight = pageSize.height - topMargin - bottomMargin

        cropRect = CGRect(
            x: leftMargin,
            y: bottomMargin, // PDF coordinate system
            width: max(50, newWidth),
            height: max(50, newHeight)
        )
    }

    private func updateMarginsFromCrop(_ rect: CGRect) {
        isSyncingFromDrag = true
        leftMargin = max(0, rect.origin.x)
        bottomMargin = max(0, rect.origin.y)
        rightMargin = max(0, pageSize.width - rect.maxX)
        topMargin = max(0, pageSize.height - rect.maxY)
        isSyncingFromDrag = false
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
                    appState.addFiles(urls: [outputURL], autoSelect: true)
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

// MARK: - Image Preview with Crop Overlay (Canvas-based, Photoshop-style)

struct ImagePreviewWithCrop: View {
    let image: NSImage
    @Binding var cropRect: CGRect
    let pageSize: CGSize
    let viewSize: CGSize
    var onCropChanged: ((CGRect) -> Void)? = nil

    // Drag state
    @State private var dragMode: CropDragMode = .none
    @State private var anchorCropRect: CGRect = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var drawNewStart: CGPoint? = nil
    @State private var drawNewCurrent: CGPoint? = nil

    private var displaySize: CGSize {
        let imageAspect = image.size.width / image.size.height
        let viewAspect = viewSize.width / viewSize.height
        if imageAspect > viewAspect {
            return CGSize(width: viewSize.width - 40, height: (viewSize.width - 40) / imageAspect)
        } else {
            return CGSize(width: (viewSize.height - 40) * imageAspect, height: viewSize.height - 40)
        }
    }

    private var imageFrame: CGRect {
        let ds = displaySize
        return CGRect(
            x: (viewSize.width - ds.width) / 2,
            y: (viewSize.height - ds.height) / 2,
            width: ds.width,
            height: ds.height
        )
    }

    private var scale: CGFloat {
        min(displaySize.width / pageSize.width, displaySize.height / pageSize.height)
    }

    /// Convert cropRect (PDF coords, origin bottom-left) to view rect (origin top-left)
    private func cropRectInView() -> CGRect {
        let frame = imageFrame
        let s = scale
        return CGRect(
            x: frame.minX + cropRect.origin.x * s,
            y: frame.minY + (pageSize.height - cropRect.origin.y - cropRect.height) * s,
            width: cropRect.width * s,
            height: cropRect.height * s
        )
    }

    /// Convert a view-space rect to PDF-space cropRect
    private func viewRectToCropRect(_ vr: CGRect) -> CGRect {
        let frame = imageFrame
        let s = scale
        guard s > 0 else { return cropRect }
        let pdfX = (vr.minX - frame.minX) / s
        let pdfW = vr.width / s
        let pdfH = vr.height / s
        let pdfY = pageSize.height - (vr.minY - frame.minY) / s - pdfH
        return CGRect(x: pdfX, y: pdfY, width: pdfW, height: pdfH)
    }

    var body: some View {
        ZStack {
            // Image
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: displaySize.width, height: displaySize.height)

            // Canvas overlay (dark mask, border, grid, handles, draw-new rect)
            Canvas { ctx, size in
                drawOverlay(ctx: &ctx, size: size)
            }

            // Interaction layer
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            if dragMode == .none {
                                handleDragStart(at: v.startLocation)
                            }
                            handleDragChanged(to: v.location)
                        }
                        .onEnded { v in
                            handleDragEnded(at: v.location)
                        }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        cursorForMode(cropHitTest(at: pt)).set()
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drawing

    private func drawOverlay(ctx: inout GraphicsContext, size: CGSize) {
        let frame = imageFrame
        let kept = cropRectInView()

        // Dark overlay with eoFill cutout
        var mask = Path()
        mask.addRect(frame)
        mask.addRect(kept)
        ctx.fill(mask, with: .color(.black.opacity(0.5)), style: .init(eoFill: true))

        // Crop border
        ctx.stroke(Path(kept), with: .color(.white), lineWidth: 1.5)

        // Rule of thirds grid
        let dashes = StrokeStyle(lineWidth: 0.5, dash: [4, 4])
        ctx.stroke(Path { p in
            for i in 1...2 {
                let f = CGFloat(i) / 3.0
                p.move(to: .init(x: kept.minX + kept.width * f, y: kept.minY))
                p.addLine(to: .init(x: kept.minX + kept.width * f, y: kept.maxY))
                p.move(to: .init(x: kept.minX, y: kept.minY + kept.height * f))
                p.addLine(to: .init(x: kept.maxX, y: kept.minY + kept.height * f))
            }
        }, with: .color(.white.opacity(0.4)), style: dashes)

        // 8 handles: corners 8×8, edges 6×6
        let corners: [CGPoint] = [
            CGPoint(x: kept.minX, y: kept.minY),
            CGPoint(x: kept.maxX, y: kept.minY),
            CGPoint(x: kept.minX, y: kept.maxY),
            CGPoint(x: kept.maxX, y: kept.maxY),
        ]
        let edges: [CGPoint] = [
            CGPoint(x: kept.midX, y: kept.minY),
            CGPoint(x: kept.midX, y: kept.maxY),
            CGPoint(x: kept.minX, y: kept.midY),
            CGPoint(x: kept.maxX, y: kept.midY),
        ]
        for c in corners {
            let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.fill(Path(r), with: .color(.white))
            ctx.stroke(Path(r), with: .color(.gray.opacity(0.6)), lineWidth: 1)
        }
        for e in edges {
            let r = CGRect(x: e.x - 3, y: e.y - 3, width: 6, height: 6)
            ctx.fill(Path(r), with: .color(.white))
            ctx.stroke(Path(r), with: .color(.gray.opacity(0.6)), lineWidth: 1)
        }

        // Draw-new rect (yellow dashed)
        if dragMode == .drawNew, let s = drawNewStart, let e = drawNewCurrent {
            let dr = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                            width: abs(e.x - s.x), height: abs(e.y - s.y))
            ctx.stroke(Path(dr), with: .color(.yellow.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            ctx.fill(Path(dr), with: .color(.yellow.opacity(0.12)))
        }
    }

    // MARK: - Hit Testing

    private func cropHitTest(at point: CGPoint) -> CropDragMode {
        let kept = cropRectInView()
        let hs: CGFloat = 12

        let handles: [(CGPoint, CropDragMode)] = [
            (CGPoint(x: kept.minX, y: kept.minY), .resizeTopLeft),
            (CGPoint(x: kept.midX, y: kept.minY), .resizeTop),
            (CGPoint(x: kept.maxX, y: kept.minY), .resizeTopRight),
            (CGPoint(x: kept.maxX, y: kept.midY), .resizeRight),
            (CGPoint(x: kept.maxX, y: kept.maxY), .resizeBottomRight),
            (CGPoint(x: kept.midX, y: kept.maxY), .resizeBottom),
            (CGPoint(x: kept.minX, y: kept.maxY), .resizeBottomLeft),
            (CGPoint(x: kept.minX, y: kept.midY), .resizeLeft),
        ]

        for (hp, mode) in handles {
            if abs(point.x - hp.x) <= hs && abs(point.y - hp.y) <= hs {
                return mode
            }
        }

        if kept.contains(point) { return .move }
        return .drawNew
    }

    // MARK: - Drag Handling (anchor-based)

    private func handleDragStart(at point: CGPoint) {
        let mode = cropHitTest(at: point)
        dragMode = mode
        anchorCropRect = cropRect
        dragStartPoint = point

        if mode == .drawNew {
            drawNewStart = point
            drawNewCurrent = point
        }
    }

    private func handleDragChanged(to point: CGPoint) {
        let s = scale
        guard s > 0 else { return }

        if dragMode == .drawNew {
            drawNewCurrent = point
            return
        }

        // View-space delta from drag start
        let viewDx = point.x - dragStartPoint.x
        let viewDy = point.y - dragStartPoint.y

        // PDF-space delta (Y inverted: view down = PDF Y decrease)
        let pdfDx = viewDx / s
        let pdfDy = -viewDy / s

        var newRect = anchorCropRect

        switch dragMode {
        case .move:
            newRect.origin.x = anchorCropRect.origin.x + pdfDx
            newRect.origin.y = anchorCropRect.origin.y + pdfDy

        // View top = PDF maxY side (height changes, origin stays)
        case .resizeTop:
            newRect.size.height = anchorCropRect.height + pdfDy
        // View bottom = PDF origin.y side
        case .resizeBottom:
            newRect.origin.y = anchorCropRect.origin.y + pdfDy
            newRect.size.height = anchorCropRect.height - pdfDy
        case .resizeLeft:
            newRect.origin.x = anchorCropRect.origin.x + pdfDx
            newRect.size.width = anchorCropRect.width - pdfDx
        case .resizeRight:
            newRect.size.width = anchorCropRect.width + pdfDx

        case .resizeTopLeft:
            newRect.origin.x = anchorCropRect.origin.x + pdfDx
            newRect.size.width = anchorCropRect.width - pdfDx
            newRect.size.height = anchorCropRect.height + pdfDy
        case .resizeTopRight:
            newRect.size.width = anchorCropRect.width + pdfDx
            newRect.size.height = anchorCropRect.height + pdfDy
        case .resizeBottomLeft:
            newRect.origin.x = anchorCropRect.origin.x + pdfDx
            newRect.origin.y = anchorCropRect.origin.y + pdfDy
            newRect.size.width = anchorCropRect.width - pdfDx
            newRect.size.height = anchorCropRect.height - pdfDy
        case .resizeBottomRight:
            newRect.origin.y = anchorCropRect.origin.y + pdfDy
            newRect.size.width = anchorCropRect.width + pdfDx
            newRect.size.height = anchorCropRect.height - pdfDy

        default:
            return
        }

        newRect = enforceConstraints(newRect)
        cropRect = newRect
        onCropChanged?(newRect)
    }

    private func handleDragEnded(at point: CGPoint) {
        if dragMode == .drawNew, let s = drawNewStart {
            let frame = imageFrame

            // Build view-space rect from draw start/end
            let viewRect = CGRect(
                x: min(s.x, point.x),
                y: min(s.y, point.y),
                width: abs(point.x - s.x),
                height: abs(point.y - s.y)
            )

            // Clamp to image frame and require minimum size
            let clampedRect = viewRect.intersection(frame)
            if clampedRect.width > 10, clampedRect.height > 10 {
                var newRect = viewRectToCropRect(clampedRect)
                newRect = enforceConstraints(newRect)
                cropRect = newRect
                onCropChanged?(newRect)
            }

            drawNewStart = nil
            drawNewCurrent = nil
        }
        dragMode = .none
    }

    private func enforceConstraints(_ rect: CGRect) -> CGRect {
        var r = rect

        // Enforce minimum size
        r.size.width = max(50, r.size.width)
        r.size.height = max(50, r.size.height)

        // Clamp to page bounds
        if r.origin.x < 0 {
            r.size.width += r.origin.x
            r.origin.x = 0
        }
        if r.origin.y < 0 {
            r.size.height += r.origin.y
            r.origin.y = 0
        }
        if r.origin.x + r.size.width > pageSize.width {
            r.size.width = pageSize.width - r.origin.x
        }
        if r.origin.y + r.size.height > pageSize.height {
            r.size.height = pageSize.height - r.origin.y
        }

        // Re-enforce minimum after clamping
        r.size.width = max(50, r.size.width)
        r.size.height = max(50, r.size.height)

        return r
    }

    // MARK: - Cursor

    private func cursorForMode(_ mode: CropDragMode) -> NSCursor {
        switch mode {
        case .none:                                      return .arrow
        case .move:                                      return .openHand
        case .resizeTop, .resizeBottom:                  return .resizeUpDown
        case .resizeLeft, .resizeRight:                  return .resizeLeftRight
        case .resizeTopLeft, .resizeBottomRight:         return .crosshair
        case .resizeTopRight, .resizeBottomLeft:         return .crosshair
        case .drawNew:                                   return .crosshair
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

// MARK: - Reusable margin slider row

private struct MarginSliderRow: View {
    let label: String
    @Binding var value: Double
    let maxValue: Double
    let onChange: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 50, alignment: .leading)
            Slider(value: $value, in: 0...max(1, maxValue))
                .onChange(of: value) { _ in onChange() }
            Text("\(Int(value))")
                .frame(width: 30)
        }
    }
}
