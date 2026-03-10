//
//  DrawingsDialog.swift
//  PrintManager
//
//  Dialog for batch processing of scanned technical drawings.
//  Interactive preview allows drawing crop and OCR regions directly on the image.
//

import SwiftUI
import AppKit

// MARK: - Helper Functions

/// Calculate the frame where an image is actually displayed (aspect-fit) within a container.
private func imageDisplayFrame(container: CGSize, imageSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
        return CGRect(origin: .zero, size: container)
    }
    let imgAR  = imageSize.width  / imageSize.height
    let contAR = container.width  / container.height
    let (dw, dh): (CGFloat, CGFloat) = imgAR > contAR
        ? (container.width,  container.width  / imgAR)
        : (container.height * imgAR, container.height)
    return CGRect(x: (container.width  - dw) / 2,
                  y: (container.height - dh) / 2,
                  width: dw, height: dh)
}

// MARK: - DrawingsDialog

struct DrawingsDialog: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = DrawingsDialogViewModel()

    private var selectedFiles: [FileItem] {
        viewModel.selectedFiles(from: appState)
    }

    private var activeFile: FileItem? {
        viewModel.activeFile(from: appState)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                fileList.frame(minWidth: 185, idealWidth: 205, maxWidth: 245)
                VStack(spacing: 0) {
                    previewPane.frame(minHeight: 200, idealHeight: 300)
                    Divider()
                    settingsPane
                }
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, maxWidth: .infinity,
               minHeight: 680, idealHeight: 840, maxHeight: .infinity)
        .onAppear {
            viewModel.initialize(with: appState)
        }
        .onChange(of: viewModel.settings) { _ in
            viewModel.schedulePreviewUpdate(appState: appState)
        }
        .onChange(of: viewModel.activeFileID) { _ in
            viewModel.onFileChanged(appState: appState)
        }
        .onChange(of: viewModel.settings.applyDeskew) { enabled in
            if enabled {
                viewModel.startAngleDetection(appState: appState)
            } else {
                viewModel.stopAngleDetection()
            }
        }
        .onChange(of: viewModel.settings.applyCrop) { enabled in
            if enabled && viewModel.settings.cropMode == .autoDetect {
                viewModel.startAutoCropDetection(appState: appState)
            }
        }
        .onChange(of: viewModel.settings.cropMode) { mode in
            if viewModel.settings.applyCrop && mode == .autoDetect {
                viewModel.startAutoCropDetection(appState: appState)
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: DS.Spacing.medium) {
            Image(systemName: "pencil.and.ruler").font(.title2).foregroundColor(.accentColor)
            Text("Zpracování výkresů").font(DS.Typography.headline)
            Spacer()
            if viewModel.isProcessing {
                ProgressView().scaleEffect(0.7)
                Text("Zpracovávám…").foregroundColor(.secondary).font(.subheadline)
            } else {
                Text("\(selectedFiles.count) soubor(ů)").foregroundColor(.secondary).font(.subheadline)
            }
            Spacer()
            Button("Zpracovat vše") {
                viewModel.processAll(appState: appState) {
                    isPresented = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isProcessing || selectedFiles.isEmpty)
            Button("Zavřít") { isPresented = false }.buttonStyle(.bordered)
        }
        .padding(.horizontal, DS.Spacing.large).padding(.vertical, DS.Spacing.smallMedium)
    }

    // MARK: File list

    private var fileList: some View {
        VStack(spacing: 0) {
            fileListHeader
            Divider()
            fileListContent
        }
        .background(DS.Colors.controlBackground)
    }

    private var fileListHeader: some View {
        Text("Soubory").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compactPadding()
            .background(DS.Colors.controlBackground)
    }

    private var fileListContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(selectedFiles) { file in
                    let isActive = file.id == (viewModel.activeFileID ?? selectedFiles.first?.id)
                    DrawingsFileRow(file: file, isActive: isActive)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.activeFileID = file.id }
                    Divider()
                }
            }
        }
    }

    // MARK: Preview pane with interactive overlays

    private var previewPane: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            if viewModel.isLoadingPreview {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.previewMode == .ocrDraw ? "Nakresli oblast OCR…" : "Načítám náhled…")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else if let img = viewModel.previewImage {
                GeometryReader { geo in
                    let imgFrame = imageDisplayFrame(container: geo.size, imageSize: viewModel.imageNaturalSize)
                    let interactiveCrop = viewModel.isInteractiveCropActive
                    let hasInteraction = interactiveCrop || viewModel.previewMode != .none
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Canvas { ctx, _ in
                            drawOverlay(ctx: &ctx, imgFrame: imgFrame)
                        }

                        if hasInteraction {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 2)
                                        .onChanged { v in
                                            if interactiveCrop && viewModel.previewMode == .none {
                                                if viewModel.cropDragMode == .none {
                                                    viewModel.handleCropDragStart(at: v.startLocation, imgFrame: imgFrame)
                                                }
                                                viewModel.handleCropDragChanged(to: v.location, imgFrame: imgFrame)
                                            } else {
                                                // OCR draw mode
                                                if viewModel.dragStart == nil { viewModel.dragStart = v.startLocation }
                                                viewModel.dragCurrent = v.location
                                            }
                                        }
                                        .onEnded { v in
                                            if interactiveCrop && viewModel.previewMode == .none {
                                                viewModel.handleCropDragEnded(at: v.location, imgFrame: imgFrame)
                                            } else {
                                                viewModel.commitDrag(start: viewModel.dragStart, end: v.location, imgFrame: imgFrame)
                                                viewModel.dragStart = nil; viewModel.dragCurrent = nil
                                            }
                                        }
                                )
                        }
                    }
                    .onContinuousHover { phase in
                        guard interactiveCrop, viewModel.previewMode == .none else {
                            NSCursor.arrow.set()
                            return
                        }
                        switch phase {
                        case .active(let pt):
                            let mode = viewModel.cropCursorMode(at: pt, imgFrame: imgFrame)
                            cursorForCropMode(mode).set()
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
                    .cursor(viewModel.previewMode == .ocrDraw ? .crosshair : .arrow)
                }
                .onAppear { viewModel.imageNaturalSize = img.size }
                .onChange(of: viewModel.previewImage) { ni in viewModel.imageNaturalSize = ni?.size ?? .zero }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: selectedFiles.isEmpty ? "tray" : "doc.richtext")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text(selectedFiles.isEmpty ? "Žádné soubory" : "Vyberte soubor vlevo")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            if viewModel.previewMode == .ocrDraw {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "hand.draw")
                        Text("Táhni pro definici oblasti OCR — Esc pro zrušení")
                        .font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(DS.Radius.small)
                    .padding(.bottom, DS.Spacing.small)
                }
                .onExitCommand { viewModel.previewMode = .none; viewModel.dragStart = nil; viewModel.dragCurrent = nil }
            }
        }
    }

    /// Map CropDragMode to appropriate NSCursor
    private func cursorForCropMode(_ mode: CropDragMode) -> NSCursor {
        switch mode {
        case .none:                          return .arrow
        case .move:                          return .openHand
        case .resizeTop, .resizeBottom:      return .resizeUpDown
        case .resizeLeft, .resizeRight:      return .resizeLeftRight
        case .resizeTopLeft, .resizeBottomRight:
            return NSCursor(image: NSCursor.arrow.image, hotSpot: .zero) // diagonal NWSE — fallback to crosshair
        case .resizeTopRight, .resizeBottomLeft:
            return NSCursor(image: NSCursor.arrow.image, hotSpot: .zero) // diagonal NESW — fallback to crosshair
        case .drawNew:                       return .crosshair
        }
    }

    /// Draw overlays into Canvas — crop, auto-crop detection, OCR region, drag-rect.
    private func drawOverlay(ctx: inout GraphicsContext, imgFrame: CGRect) {
        // 1. Manual crop margins — interactive Photoshop-style crop
        if viewModel.settings.applyCrop, viewModel.settings.cropMode == .manualMargins {
            let kept = viewModel.currentCropRect(in: imgFrame)

            // Dark overlay outside crop
            var mask = Path(); mask.addRect(imgFrame); mask.addRect(kept)
            ctx.fill(mask, with: .color(.black.opacity(0.5)), style: .init(eoFill: true))

            // Crop border
            ctx.stroke(Path(kept), with: .color(.white), lineWidth: 1.5)

            // Rule of thirds grid
            let dashes = StrokeStyle(lineWidth: 0.5, dash: [4, 4])
            ctx.stroke(Path { p in
                p.move(to: .init(x: kept.minX + kept.width/3, y: kept.minY))
                p.addLine(to: .init(x: kept.minX + kept.width/3, y: kept.maxY))
                p.move(to: .init(x: kept.minX + 2*kept.width/3, y: kept.minY))
                p.addLine(to: .init(x: kept.minX + 2*kept.width/3, y: kept.maxY))
                p.move(to: .init(x: kept.minX, y: kept.minY + kept.height/3))
                p.addLine(to: .init(x: kept.maxX, y: kept.minY + kept.height/3))
                p.move(to: .init(x: kept.minX, y: kept.minY + 2*kept.height/3))
                p.addLine(to: .init(x: kept.maxX, y: kept.minY + 2*kept.height/3))
            }, with: .color(.white.opacity(0.4)), style: dashes)

            // 8 drag handles: 4 corners (8×8) + 4 edge midpoints (6×6)
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
        }

        // 2. Auto-crop detected rectangle
        if viewModel.settings.applyCrop, viewModel.settings.cropMode == .autoDetect {
            if viewModel.isDetectingCrop {
                // waiting
            } else if let r = viewModel.detectedCropRect {
                let detected = CGRect(
                    x: imgFrame.minX + r.minX * imgFrame.width,
                    y: imgFrame.minY + r.minY * imgFrame.height,
                    width: r.width * imgFrame.width,
                    height: r.height * imgFrame.height
                )
                ctx.stroke(Path(detected), with: .color(.green.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                var mask = Path(); mask.addRect(imgFrame); mask.addRect(detected)
                ctx.fill(mask, with: .color(.black.opacity(0.3)), style: .init(eoFill: true))
            }
        }

        // 3. OCR region
        if viewModel.settings.applyOCR && viewModel.settings.ocrUseCustomRegion {
            let ocrRect = CGRect(
                x: imgFrame.minX + viewModel.settings.ocrRegionLeft   * imgFrame.width,
                y: imgFrame.minY + viewModel.settings.ocrRegionTop    * imgFrame.height,
                width: viewModel.settings.ocrRegionWidth  * imgFrame.width,
                height: viewModel.settings.ocrRegionHeight * imgFrame.height
            )
            ctx.stroke(Path(ocrRect), with: .color(.blue.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            ctx.fill(Path(ocrRect), with: .color(.blue.opacity(0.07)))
        }

        // 4. Currently drawn drag-rect (OCR draw or crop drawNew)
        if let s = viewModel.dragStart, let e = viewModel.dragCurrent {
            let dr = CGRect(x: min(s.x,e.x), y: min(s.y,e.y),
                            width: abs(e.x-s.x), height: abs(e.y-s.y))
            let col: Color = viewModel.previewMode == .ocrDraw ? .blue : .yellow
            ctx.stroke(Path(dr), with: .color(col.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            ctx.fill(Path(dr), with: .color(col.opacity(0.12)))
        }
    }


    // MARK: Settings pane

    private var settingsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {

                // Threshold and contrast
                DisclosureToggleSection(title: "Práh a kontrast", icon: "circle.lefthalf.filled",
                                        isEnabled: $viewModel.settings.applyThreshold) {
                    HStack {
                        Text("Režim"); Spacer()
                        Picker("", selection: $viewModel.settings.thresholdMode) {
                            Text("Automaticky").tag(ThresholdMode.auto)
                            Text("Ručně").tag(ThresholdMode.manual)
                        }
                        .pickerStyle(.segmented).frame(width: 190)
                    }
                    if viewModel.settings.thresholdMode == .manual {
                        LabeledSlider(label: "Práh", value: $viewModel.settings.thresholdValue, range: 0...1, format: "%.2f")
                    }
                    LabeledSlider(label: "Jas",      value: $viewModel.settings.brightnessBoost, range: -0.5...0.5, format: "%+.2f")
                    LabeledSlider(label: "Kontrast", value: $viewModel.settings.contrastBoost,   range: 0...1,      format: "%.2f")
                }

                // Crop
                DisclosureToggleSection(title: "Ořez", icon: "crop", isEnabled: $viewModel.settings.applyCrop) {
                    HStack {
                        Text("Metoda"); Spacer()
                        Picker("", selection: $viewModel.settings.cropMode) {
                            ForEach(CropMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 210)
                    }

                    if viewModel.settings.cropMode == .autoDetect {
                        HStack {
                            Text("Citlivost").font(.caption)
                            Slider(value: $viewModel.settings.cropSensitivity, in: 0...1)
                            Text(String(format: "%.0f%%", viewModel.settings.cropSensitivity * 100))
                                .font(.caption).monospacedDigit()
                                .frame(width: 35)
                        }

                        HStack(spacing: 6) {
                            if viewModel.isDetectingCrop {
                                ProgressView().scaleEffect(0.7)
                                Text("Detekuji hrany…").foregroundColor(.secondary)
                            } else if viewModel.detectedCropRect != nil {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Obdélník nalezen — zobrazen v náhledu zeleně")
                            } else {
                                Image(systemName: "xmark.circle").foregroundColor(.orange)
                                Text("Obdélník nenalezen").foregroundColor(.secondary)
                            }
                        }
                        .font(.caption)
                        Button("Znovu detekovat") { viewModel.startAutoCropDetection(appState: appState) }
                            .disabled(viewModel.isDetectingCrop || activeFile == nil)

                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledSlider(label: "Horní", value: $viewModel.settings.cropTopMargin,    range: 0...0.49, format: "%.0f%%", mult: 100)
                                LabeledSlider(label: "Dolní", value: $viewModel.settings.cropBottomMargin, range: 0...0.49, format: "%.0f%%", mult: 100)
                                LabeledSlider(label: "Levý",  value: $viewModel.settings.cropLeftMargin,   range: 0...0.49, format: "%.0f%%", mult: 100)
                                LabeledSlider(label: "Pravý", value: $viewModel.settings.cropRightMargin,  range: 0...0.49, format: "%.0f%%", mult: 100)
                            }
                        }
                        Text("Táhni za úchyty v náhledu pro úpravu ořezu")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                // Deskew
                DisclosureToggleSection(title: "Narovnání (Deskew)", icon: "perspective",
                                        isEnabled: $viewModel.settings.applyDeskew) {
                    if viewModel.isDetectingAngle {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("Detekuji úhel…").foregroundColor(.secondary) }
                    } else if let a = viewModel.detectedAngle {
                        HStack(spacing: 6) {
                            Image(systemName: abs(a) < 0.3 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(abs(a) < 0.3 ? .green : .orange)
                            Text("Detekovaný úhel: \(String(format: "%.1f", a))°")
                                .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        Text("Úhel bude detekován při zpracování.").foregroundColor(.secondary).font(.caption)
                    }
                    Toggle("Oříznout černé rohy po narovnání", isOn: $viewModel.settings.deskewWithCrop)
                }

                // Rotation
                DisclosureToggleSection(title: "Otočení", icon: "rotate.right", isEnabled: $viewModel.settings.applyRotation) {
                    HStack {
                        Text("Směr"); Spacer()
                        Picker("", selection: $viewModel.settings.rotationSteps) {
                            Text("↺ 90° CCW").tag(-1); Text("180°").tag(2); Text("↻ 90° CW").tag(1)
                        }
                        .pickerStyle(.segmented).frame(width: 230)
                    }
                }

                // Alignment to paper format
                DisclosureToggleSection(title: "Zarovnání na formát", icon: "doc.richtext",
                                        isEnabled: $viewModel.settings.applyAlignment) {
                    HStack {
                        Text("Formát"); Spacer()
                        Picker("", selection: $viewModel.settings.alignmentFormat) {
                            ForEach(PaperFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 110)
                    }
                    HStack {
                        Text("Režim"); Spacer()
                        Picker("", selection: $viewModel.settings.alignmentMode) {
                            ForEach(AlignmentMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 150)
                    }
                }

                // Color conversion
                DisclosureToggleSection(title: "Převod barev", icon: "paintpalette",
                                        isEnabled: $viewModel.settings.applyColorConversion) {
                    HStack {
                        Text("Výstup"); Spacer()
                        Picker("", selection: $viewModel.settings.colorMode) {
                            ForEach(ColorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 270)
                    }
                }

                // Noise reduction
                DisclosureToggleSection(title: "Odstranění šumu", icon: "wand.and.sparkles",
                                        isEnabled: $viewModel.settings.applyNoiseReduction) {
                    LabeledSlider(label: "Intenzita", value: $viewModel.settings.noiseLevel,    range: 0...0.1, format: "%.3f")
                    LabeledSlider(label: "Ostrost",   value: $viewModel.settings.noiseSharpness, range: 0...2,   format: "%.2f")
                }

                // OCR stamp
                DisclosureToggleSection(title: "OCR razítko", icon: "text.viewfinder",
                                        isEnabled: $viewModel.settings.applyOCR) {
                    Toggle("Vlastní oblast", isOn: $viewModel.settings.ocrUseCustomRegion)
                    if viewModel.settings.ocrUseCustomRegion {
                        HStack(spacing: 8) {
                            Button(viewModel.previewMode == .ocrDraw ? "Kreslím… (Esc)" : "Nakreslit oblast na obrázku") {
                                if viewModel.previewMode == .ocrDraw { viewModel.previewMode = .none } else { viewModel.previewMode = .ocrDraw }
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(viewModel.previewMode == .ocrDraw ? .orange : .accentColor)

                            Button("Reset") {
                                viewModel.settings.ocrRegionLeft = 0.75; viewModel.settings.ocrRegionTop = 0.75
                                viewModel.settings.ocrRegionWidth = 0.25; viewModel.settings.ocrRegionHeight = 0.25
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Oblast: \(Int(viewModel.settings.ocrRegionLeft*100))% zleva, "
                             + "\(Int(viewModel.settings.ocrRegionTop*100))% shora, "
                             + "\(Int(viewModel.settings.ocrRegionWidth*100))×\(Int(viewModel.settings.ocrRegionHeight*100))%")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("Výchozí: pravý dolní roh (25×25 %)").font(.caption).foregroundColor(.secondary)
                    }

                    Button(viewModel.isOCRRunning ? "Čtu text…" : "Načíst text z označené oblasti") { viewModel.runOCR(appState: appState) }
                        .disabled(viewModel.isOCRRunning || activeFile == nil)

                    if !viewModel.ocrText.isEmpty {
                        TextEditor(text: $viewModel.ocrText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 55, maxHeight: 90)
                            .border(Color(NSColor.separatorColor))
                        Button("Přejmenovat soubor dle textu") { viewModel.renameActiveFile(appState: appState) }
                            .disabled(viewModel.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(10)
        }
    }
}

// MARK: - DrawingsFileRow

private struct DrawingsFileRow: View {
    let file: FileItem; let isActive: Bool
    var body: some View {
        HStack(spacing: 8) {
            if let t = file.thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34).cornerRadius(DS.Radius.small)
            } else {
                Image(systemName: file.fileType.icon).foregroundColor(file.fileType.listColor)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.caption).lineLimit(2)
                Text(file.fileSizeFormatted).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if isActive { Image(systemName: "chevron.right").foregroundColor(.accentColor).font(.caption.weight(.semibold)) }
        }
        .compactPadding()
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}
