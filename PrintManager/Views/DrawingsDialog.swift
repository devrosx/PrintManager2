//
//  DrawingsDialog.swift
//  PrintManager
//
//  Dialog pro hromadné zpracování naskenovaných technických výkresů.
//  Preview je interaktivní — lze nakreslit ořez i oblast pro OCR přímo na obrázku.
//

import SwiftUI
import AppKit

// MARK: - Režim interakce s náhledem

private enum PreviewMode: Equatable {
    case none           // jen zobrazení
    case cropDraw       // kreslení ořezu tažením
    case ocrDraw        // kreslení oblasti OCR tažením
}

// MARK: - Pomocná funkce pro výpočet rámce obrázku

/// Vrátí CGRect, ve kterém je obrázek skutečně zobrazen (aspect-fit) v zadaném kontejneru.
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

    @State private var settings        = DrawingsSettings()
    @State private var activeFileID: UUID? = nil
    @State private var previewImage: NSImage? = nil
    @State private var imageNaturalSize: CGSize = .zero
    @State private var isLoadingPreview = false
    @State private var previewTask: Task<Void, Never>? = nil
    @State private var deskewTask: Task<Void, Never>? = nil
    @State private var isProcessing    = false
    @State private var detectedAngle: Double? = nil
    @State private var isDetectingAngle = false
    @State private var detectedCropRect: CGRect? = nil   // normalized top-left
    @State private var isDetectingCrop  = false
    @State private var ocrText = ""
    @State private var isOCRRunning = false
    @State private var previewMode: PreviewMode = .none
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    private let service = DrawingsService()

    private var selectedFiles: [FileItem] {
        appState.files.filter { appState.selectedFiles.contains($0.id) }
    }
    private var activeFile: FileItem? {
        guard let id = activeFileID else { return selectedFiles.first }
        return selectedFiles.first { $0.id == id } ?? selectedFiles.first
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
            activeFileID = selectedFiles.first?.id
            schedulePreviewUpdate()
        }
        .onChange(of: settings)      { _ in schedulePreviewUpdate() }
        .onChange(of: activeFileID)  { _ in onFileChanged() }
        .onChange(of: settings.applyDeskew) { e in
            if e { startAngleDetection() } else { deskewTask?.cancel(); detectedAngle = nil; isDetectingAngle = false }
        }
        .onChange(of: settings.applyCrop) { e in
            if e && settings.cropMode == .autoDetect { startAutoCropDetection() }
        }
        .onChange(of: settings.cropMode) { m in
            if settings.applyCrop && m == .autoDetect { startAutoCropDetection() }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.and.ruler").font(.title2).foregroundColor(.accentColor)
            Text("Zpracování výkresů").font(.headline)
            Spacer()
            if isProcessing {
                ProgressView().scaleEffect(0.7)
                Text("Zpracovávám…").foregroundColor(.secondary).font(.subheadline)
            } else {
                Text("\(selectedFiles.count) soubor(ů)").foregroundColor(.secondary).font(.subheadline)
            }
            Spacer()
            Button("Zpracovat vše") { processAll() }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || selectedFiles.isEmpty)
            Button("Zavřít") { isPresented = false }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Seznam souborů

    private var fileList: some View {
        VStack(spacing: 0) {
            Text("Soubory").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(selectedFiles) { file in
                        DrawingsFileRow(file: file,
                                        isActive: file.id == (activeFileID ?? selectedFiles.first?.id))
                        .contentShape(Rectangle())
                        .onTapGesture { activeFileID = file.id }
                        Divider()
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Náhledová plocha s interaktivními překryvy

    private var previewPane: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            if isLoadingPreview {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(previewMode == .cropDraw ? "Nakresli ořez na obrázku…"
                         : previewMode == .ocrDraw ? "Nakresli oblast OCR…"
                         : "Načítám náhled…")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else if let img = previewImage {
                GeometryReader { geo in
                    let imgFrame = imageDisplayFrame(container: geo.size, imageSize: imageNaturalSize)
                    ZStack(alignment: .topLeading) {
                        // ── Obrázek ──────────────────────────────────────────
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // ── Canvas s překryvy ─────────────────────────────────
                        Canvas { ctx, _ in
                            drawOverlay(ctx: &ctx, imgFrame: imgFrame)
                        }

                        // ── Drag gesta (pouze v aktivním režimu) ──────────────
                        if previewMode != .none {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 2)
                                        .onChanged { v in
                                            if dragStart == nil { dragStart = v.startLocation }
                                            dragCurrent = v.location
                                        }
                                        .onEnded { v in
                                            commitDrag(start: dragStart, end: v.location, imgFrame: imgFrame)
                                            dragStart = nil; dragCurrent = nil
                                        }
                                )
                        }
                    }
                    // Kurzor mění tvar při kreslení
                    .cursor(previewMode != .none ? .crosshair : .arrow)
                }
                .onAppear { imageNaturalSize = img.size }
                .onChange(of: previewImage) { ni in imageNaturalSize = ni?.size ?? .zero }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: selectedFiles.isEmpty ? "tray" : "doc.richtext")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text(selectedFiles.isEmpty ? "Žádné soubory" : "Vyberte soubor vlevo")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Nápověda při aktivním kreslení
            if previewMode != .none {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "hand.draw")
                        Text(previewMode == .cropDraw
                             ? "Táhni pro definici ořezu — Esc pro zrušení"
                             : "Táhni pro definici oblasti OCR — Esc pro zrušení")
                        .font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(6)
                    .padding(.bottom, 8)
                }
                .onExitCommand { previewMode = .none; dragStart = nil; dragCurrent = nil }
            }
        }
    }

    /// Kreslí překryvy do Canvas — crop, auto-crop detekce, OCR oblast, drag-rect.
    private func drawOverlay(ctx: inout GraphicsContext, imgFrame: CGRect) {
        // 1. Manuální ořez
        if settings.applyCrop, settings.cropMode == .manualMargins {
            let kept = CGRect(
                x: imgFrame.minX + settings.cropLeftMargin   * imgFrame.width,
                y: imgFrame.minY + settings.cropTopMargin    * imgFrame.height,
                width:  imgFrame.width  * (1 - settings.cropLeftMargin - settings.cropRightMargin),
                height: imgFrame.height * (1 - settings.cropTopMargin  - settings.cropBottomMargin)
            )
            // Tmavé okraje
            var mask = Path(); mask.addRect(imgFrame); mask.addRect(kept)
            ctx.fill(mask, with: .color(.black.opacity(0.45)), style: .init(eoFill: true))
            // Bílý rámeček + pravidlo třetin
            ctx.stroke(Path(kept), with: .color(.white), lineWidth: 1.5)
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
            // Rohové úchyty (L-tvar)
            for corner in cornerHandlePoints(of: kept) {
                ctx.stroke(Path(CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)),
                           with: .color(.white), lineWidth: 2)
            }
        }

        // 2. Auto-crop detekovaný obdélník
        if settings.applyCrop, settings.cropMode == .autoDetect {
            if isDetectingCrop {
                // nic
            } else if let r = detectedCropRect {
                let detected = CGRect(
                    x: imgFrame.minX + r.minX * imgFrame.width,
                    y: imgFrame.minY + r.minY * imgFrame.height,
                    width: r.width * imgFrame.width,
                    height: r.height * imgFrame.height
                )
                ctx.stroke(Path(detected), with: .color(.green.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                // Tmavé okraje
                var mask = Path(); mask.addRect(imgFrame); mask.addRect(detected)
                ctx.fill(mask, with: .color(.black.opacity(0.3)), style: .init(eoFill: true))
            }
        }

        // 3. OCR oblast
        if settings.applyOCR && settings.ocrUseCustomRegion {
            let ocrRect = CGRect(
                x: imgFrame.minX + settings.ocrRegionLeft   * imgFrame.width,
                y: imgFrame.minY + settings.ocrRegionTop    * imgFrame.height,
                width: settings.ocrRegionWidth  * imgFrame.width,
                height: settings.ocrRegionHeight * imgFrame.height
            )
            ctx.stroke(Path(ocrRect), with: .color(.blue.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            ctx.fill(Path(ocrRect), with: .color(.blue.opacity(0.07)))
        }

        // 4. Drag-rect aktuálně kreslený
        if let s = dragStart, let e = dragCurrent {
            let dr = CGRect(x: min(s.x,e.x), y: min(s.y,e.y),
                            width: abs(e.x-s.x), height: abs(e.y-s.y))
            let col: Color = previewMode == .ocrDraw ? .blue : .yellow
            ctx.stroke(Path(dr), with: .color(col.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            ctx.fill(Path(dr), with: .color(col.opacity(0.08)))
        }
    }

    private func cornerHandlePoints(of r: CGRect) -> [CGPoint] {
        [r.origin, CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    // MARK: Nastavení (sekce)

    private var settingsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {

                // Práh a kontrast
                DisclosureToggleSection(title: "Práh a kontrast", icon: "circle.lefthalf.filled",
                                        isEnabled: $settings.applyThreshold) {
                    HStack {
                        Text("Režim"); Spacer()
                        Picker("", selection: $settings.thresholdMode) {
                            Text("Automaticky").tag(ThresholdMode.auto)
                            Text("Ručně").tag(ThresholdMode.manual)
                        }
                        .pickerStyle(.segmented).frame(width: 190)
                    }
                    if settings.thresholdMode == .manual {
                        LabeledSlider(label: "Práh", value: $settings.thresholdValue, range: 0...1, format: "%.2f")
                    }
                    LabeledSlider(label: "Jas",      value: $settings.brightnessBoost, range: -0.5...0.5, format: "%+.2f")
                    LabeledSlider(label: "Kontrast", value: $settings.contrastBoost,   range: 0...1,      format: "%.2f")
                }

                // Ořez
                DisclosureToggleSection(title: "Ořez", icon: "crop", isEnabled: $settings.applyCrop) {
                    HStack {
                        Text("Metoda"); Spacer()
                        Picker("", selection: $settings.cropMode) {
                            ForEach(CropMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 210)
                    }

                    if settings.cropMode == .autoDetect {
                        // Stav detekce
                        HStack(spacing: 6) {
                            if isDetectingCrop {
                                ProgressView().scaleEffect(0.7)
                                Text("Detekuji hrany…").foregroundColor(.secondary)
                            } else if detectedCropRect != nil {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Obdélník nalezen — zobrazen v náhledu zeleně")
                            } else {
                                Image(systemName: "xmark.circle").foregroundColor(.orange)
                                Text("Obdélník nenalezen").foregroundColor(.secondary)
                            }
                        }
                        .font(.caption)
                        Button("Znovu detekovat") { startAutoCropDetection() }
                            .disabled(isDetectingCrop || activeFile == nil)

                    } else {
                        // Manuální — slidery + tlačítko pro kreslení
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledSlider(label: "Horní", value: $settings.cropTopMargin,    range: 0...0.49, format: "%.0f%%", mult: 100)
                                LabeledSlider(label: "Dolní", value: $settings.cropBottomMargin, range: 0...0.49, format: "%.0f%%", mult: 100)
                                LabeledSlider(label: "Levý",  value: $settings.cropLeftMargin,   range: 0...0.49, format: "%.0f%%", mult: 100)
                                LabeledSlider(label: "Pravý", value: $settings.cropRightMargin,  range: 0...0.49, format: "%.0f%%", mult: 100)
                            }
                        }
                        Button(previewMode == .cropDraw ? "Kreslím… (Esc pro zrušení)" : "Nakreslit ořez na obrázku") {
                            if previewMode == .cropDraw { previewMode = .none } else { previewMode = .cropDraw }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(previewMode == .cropDraw ? .orange : .accentColor)
                    }
                }

                // Narovnání (Deskew)
                DisclosureToggleSection(title: "Narovnání (Deskew)", icon: "perspective",
                                        isEnabled: $settings.applyDeskew) {
                    if isDetectingAngle {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("Detekuji úhel…").foregroundColor(.secondary) }
                    } else if let a = detectedAngle {
                        HStack(spacing: 6) {
                            Image(systemName: abs(a) < 0.3 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(abs(a) < 0.3 ? .green : .orange)
                            Text("Detekovaný úhel: \(String(format: "%.1f", a))°")
                                .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        Text("Úhel bude detekován při zpracování.").foregroundColor(.secondary).font(.caption)
                    }
                    Toggle("Oříznout černé rohy po narovnání", isOn: $settings.deskewWithCrop)
                }

                // Otočení
                DisclosureToggleSection(title: "Otočení", icon: "rotate.right", isEnabled: $settings.applyRotation) {
                    HStack {
                        Text("Směr"); Spacer()
                        Picker("", selection: $settings.rotationSteps) {
                            Text("↺ 90° CCW").tag(-1); Text("180°").tag(2); Text("↻ 90° CW").tag(1)
                        }
                        .pickerStyle(.segmented).frame(width: 230)
                    }
                }

                // Zarovnání na formát
                DisclosureToggleSection(title: "Zarovnání na formát", icon: "doc.richtext",
                                        isEnabled: $settings.applyAlignment) {
                    HStack {
                        Text("Formát"); Spacer()
                        Picker("", selection: $settings.alignmentFormat) {
                            ForEach(PaperFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 110)
                    }
                    HStack {
                        Text("Režim"); Spacer()
                        Picker("", selection: $settings.alignmentMode) {
                            ForEach(AlignmentMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 150)
                    }
                }

                // Převod barev
                DisclosureToggleSection(title: "Převod barev", icon: "paintpalette",
                                        isEnabled: $settings.applyColorConversion) {
                    HStack {
                        Text("Výstup"); Spacer()
                        Picker("", selection: $settings.colorMode) {
                            ForEach(ColorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 270)
                    }
                }

                // Odstranění šumu
                DisclosureToggleSection(title: "Odstranění šumu", icon: "wand.and.sparkles",
                                        isEnabled: $settings.applyNoiseReduction) {
                    LabeledSlider(label: "Intenzita", value: $settings.noiseLevel,    range: 0...0.1, format: "%.3f")
                    LabeledSlider(label: "Ostrost",   value: $settings.noiseSharpness, range: 0...2,   format: "%.2f")
                }

                // OCR razítko
                DisclosureToggleSection(title: "OCR razítko", icon: "text.viewfinder",
                                        isEnabled: $settings.applyOCR) {
                    // Oblast
                    Toggle("Vlastní oblast", isOn: $settings.ocrUseCustomRegion)
                    if settings.ocrUseCustomRegion {
                        HStack(spacing: 8) {
                            Button(previewMode == .ocrDraw ? "Kreslím… (Esc)" : "Nakreslit oblast na obrázku") {
                                if previewMode == .ocrDraw { previewMode = .none } else { previewMode = .ocrDraw }
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(previewMode == .ocrDraw ? .orange : .accentColor)

                            Button("Reset") {
                                settings.ocrRegionLeft = 0.75; settings.ocrRegionTop = 0.75
                                settings.ocrRegionWidth = 0.25; settings.ocrRegionHeight = 0.25
                            }
                            .buttonStyle(.bordered)
                        }
                        // Mini-indikátor aktuální oblasti
                        Text("Oblast: \(Int(settings.ocrRegionLeft*100))% zleva, "
                             + "\(Int(settings.ocrRegionTop*100))% shora, "
                             + "\(Int(settings.ocrRegionWidth*100))×\(Int(settings.ocrRegionHeight*100))%")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("Výchozí: pravý dolní roh (25×25 %)").font(.caption).foregroundColor(.secondary)
                    }

                    // OCR akce
                    Button(isOCRRunning ? "Čtu text…" : "Načíst text z označené oblasti") { runOCR() }
                        .disabled(isOCRRunning || activeFile == nil)

                    if !ocrText.isEmpty {
                        TextEditor(text: $ocrText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 55, maxHeight: 90)
                            .border(Color(NSColor.separatorColor))
                        Button("Přejmenovat soubor dle textu") { renameActiveFile() }
                            .disabled(ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(10)
        }
    }

    // MARK: Commit drag

    private func commitDrag(start: CGPoint?, end: CGPoint, imgFrame: CGRect) {
        guard let s = start else { return }
        // Normalizace do image coordinates (0-1), oříznutí na hranice obrázku
        func norm(_ v: CGFloat, origin: CGFloat, size: CGFloat) -> Double {
            Double(Swift.max(0, Swift.min(1, (v - origin) / size)))
        }
        let nx1 = norm(Swift.min(s.x, end.x), origin: imgFrame.minX, size: imgFrame.width)
        let nx2 = norm(Swift.max(s.x, end.x), origin: imgFrame.minX, size: imgFrame.width)
        let ny1 = norm(Swift.min(s.y, end.y), origin: imgFrame.minY, size: imgFrame.height)
        let ny2 = norm(Swift.max(s.y, end.y), origin: imgFrame.minY, size: imgFrame.height)
        guard nx2 - nx1 > 0.02, ny2 - ny1 > 0.02 else { previewMode = .none; return }

        switch previewMode {
        case .cropDraw:
            settings.cropLeftMargin   = nx1
            settings.cropTopMargin    = ny1
            settings.cropRightMargin  = 1 - nx2
            settings.cropBottomMargin = 1 - ny2
            previewMode = .none
        case .ocrDraw:
            settings.ocrRegionLeft    = nx1
            settings.ocrRegionTop     = ny1
            settings.ocrRegionWidth   = nx2 - nx1
            settings.ocrRegionHeight  = ny2 - ny1
            settings.ocrUseCustomRegion = true
            previewMode = .none
        default: break
        }
    }

    // MARK: Live preview

    private func schedulePreviewUpdate() {
        previewTask?.cancel()
        guard let file = activeFile else { isLoadingPreview = false; previewImage = nil; return }
        isLoadingPreview = true
        previewTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { await MainActor.run { isLoadingPreview = false }; return }
                let img = try await service.previewImage(url: file.url, settings: settings,
                                                         maxSize: CGSize(width: 1600, height: 1600))
                await MainActor.run { previewImage = img; isLoadingPreview = false }
            } catch is CancellationError {
                await MainActor.run { isLoadingPreview = false }
            } catch {
                await MainActor.run { previewImage = nil; isLoadingPreview = false }
            }
        }
    }

    private func onFileChanged() {
        detectedAngle = nil; detectedCropRect = nil; ocrText = ""
        schedulePreviewUpdate()
        if settings.applyDeskew { startAngleDetection() }
        if settings.applyCrop && settings.cropMode == .autoDetect { startAutoCropDetection() }
    }

    // MARK: Detekce úhlu

    private func startAngleDetection() {
        deskewTask?.cancel()
        guard let file = activeFile else { return }
        detectedAngle = nil; isDetectingAngle = true
        deskewTask = Task {
            defer { Task { await MainActor.run { isDetectingAngle = false } } }
            guard !Task.isCancelled,
                  let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                await MainActor.run { detectedAngle = 0.0 }; return
            }
            let angle = (try? await service.detectDeskewAngle(cgImage: cg)) ?? 0.0
            await MainActor.run { if !Task.isCancelled { detectedAngle = angle } }
        }
    }

    // MARK: Auto-crop detekce

    private func startAutoCropDetection() {
        guard let file = activeFile else { return }
        detectedCropRect = nil; isDetectingCrop = true
        Task {
            guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                await MainActor.run { isDetectingCrop = false }; return
            }
            let rect = await service.detectDocumentRect(cgImage: cg)
            await MainActor.run { detectedCropRect = rect; isDetectingCrop = false }
        }
    }

    // MARK: OCR

    private func runOCR() {
        guard let file = activeFile else { return }
        isOCRRunning = true; ocrText = ""
        Task {
            do {
                guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                      let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    await MainActor.run { isOCRRunning = false }; return
                }
                let roi: CGRect? = settings.ocrUseCustomRegion
                    ? CGRect(x: settings.ocrRegionLeft,  y: settings.ocrRegionTop,
                             width: settings.ocrRegionWidth, height: settings.ocrRegionHeight)
                    : nil
                let text = try await service.ocrBottomRight(cgImage: cg, regionOfInterest: roi)
                await MainActor.run { ocrText = text; isOCRRunning = false }
            } catch {
                await MainActor.run {
                    isOCRRunning = false
                    appState.logError("OCR selhalo: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Přejmenování

    private func renameActiveFile() {
        guard let file = activeFile else { return }
        let name = ocrText.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") ?? ""
        guard !name.isEmpty else { return }
        appState.renameFile(file, to: name)
        appState.logSuccess("Přejmenováno: \(name)")
    }

    // MARK: Hromadné zpracování

    private func processAll() {
        let files = selectedFiles; guard !files.isEmpty else { return }
        isProcessing = true
        appState.logInfo("Začínám zpracování \(files.count) výkres(ů)…")
        Task {
            for (i, file) in files.enumerated() {
                await MainActor.run { appState.logInfo("Výkres \(i+1)/\(files.count): \(file.name)") }
                do {
                    try await service.process(url: file.url, settings: settings)
                    await MainActor.run {
                        if let idx = appState.files.firstIndex(where: { $0.id == file.id }) {
                            appState.files[idx].contentVersion += 1
                        }
                    }
                } catch {
                    await MainActor.run { appState.logError("Chyba (\(file.name)): \(error.localizedDescription)") }
                }
            }
            await MainActor.run { isProcessing = false; appState.logSuccess("Zpracování výkresů dokončeno"); isPresented = false }
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
                    .frame(width: 34, height: 34).cornerRadius(3)
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
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}

// MARK: - DisclosureToggleSection

struct DisclosureToggleSection<Content: View>: View {
    let title: String; let icon: String
    @Binding var isEnabled: Bool
    @State private var isExpanded = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Toggle("", isOn: $isEnabled).toggleStyle(.checkbox).labelsHidden()
                    .padding(.leading, 10).padding(.trailing, 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon).foregroundColor(isEnabled ? .accentColor : .secondary).frame(width: 16)
                        Text(title).font(.system(.body, weight: .medium))
                            .foregroundColor(isEnabled ? .primary : .secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: isExpanded)
                    }
                    .padding(.trailing, 10).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                Divider().padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .opacity(isEnabled ? 1.0 : 0.45)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                    isEnabled ? Color.accentColor.opacity(0.35) : Color(NSColor.separatorColor),
                    lineWidth: isEnabled ? 1.0 : 0.5))
        )
        .onChange(of: isEnabled) { e in
            if e, !isExpanded { withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true } }
        }
    }
}

// MARK: - LabeledSlider

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var mult: Double = 1.0

    var body: some View {
        HStack {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value * mult))
                .font(.system(.caption, design: .monospaced)).frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Cursor helper

private struct CursorModifier: ViewModifier {
    let cursor: NSCursor
    func body(content: Content) -> some View {
        content.onHover { inside in inside ? cursor.push() : NSCursor.pop() }
    }
}
private extension View {
    func cursor(_ c: NSCursor) -> some View { modifier(CursorModifier(cursor: c)) }
}
