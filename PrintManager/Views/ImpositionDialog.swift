//
//  ImpositionDialog.swift
//  PrintManager
//
//  Imposition dialog – sheet s live PDF náhledem (stejný vzor jako SmartCrop2Dialog)
//

import SwiftUI
import AppKit
import PDFKit

// Lightweight @unchecked Sendable box – used to ferry [Int:NSImage] across actor boundaries.
private struct _UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// NSViewRepresentable pro spolehlivé ukládání velikosti okna přes NSWindow.didResizeNotification
private struct WindowSizeSaver: NSViewRepresentable {
    var onResize: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onResize = onResize
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if context.coordinator.observedWindow !== window {
                context.coordinator.startObserving(window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        weak var observedWindow: NSWindow?
        private var observer: Any?
        var onResize: ((CGSize) -> Void)?

        func startObserving(_ window: NSWindow) {
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
            observedWindow = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let w = window,
                      let contentSize = w.contentView?.frame.size else { return }
                self?.onResize?(contentSize)
            }
        }

        deinit {
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
        }
    }
}

// MARK: - Dialog View

struct ImpositionDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let sourceFile: FileItem?

    @State private var settings       = ImpositionSettings()
    @State private var isProcessing   = false
    @State private var errorMessage:  String?
    @State private var showError      = false

    // Uložená velikost okna
    @AppStorage("impositionDialogWidth")  private var savedWidth:  Double = 900
    @AppStorage("impositionDialogHeight") private var savedHeight: Double = 640

    // Tiskový okraj z preferencí
    @AppStorage("printerMarginMM") private var printerMarginMM: Double = 5.0
    /// Proporční měřítko ručního rámečku vůči originální straně (v %)
    @State private var frameScalePct: Double = 100
    /// Zamezuje rekurzivní synchronizaci mm ↔ %
    @State private var isSyncingFrame = false

    // Live PDF preview
    @State private var pdfDocument:  PDFDocument?
    @State private var thumbnails:   [Int: NSImage] = [:]
    @State private var thumbTask:    Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            modePickerView
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()

            HSplitView {
                settingsPanel
                    .frame(minWidth: 280, maxWidth: 340)
                    .padding()
                previewPanel
                    .padding()
                    .frame(minWidth: 300)
            }
            .frame(minHeight: 380)

            Divider()
            bottomBar.padding()
        }
        .frame(minWidth: 620, idealWidth: savedWidth,
               maxWidth: .infinity,
               minHeight: 500, idealHeight: savedHeight,
               maxHeight: .infinity)
        .background(
            WindowSizeSaver { size in
                guard size.width > 200, size.height > 200 else { return }
                savedWidth  = Double(size.width)
                savedHeight = Double(size.height)
            }
        )
        .alert("Chyba", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage ?? "Neznámá chyba")
        }
        .onAppear {
            if let url = sourceFile?.url {
                pdfDocument = PDFDocument(url: url)
            }
            // Nastav výchozí okraje z tiskového okraje tiskárny
            let m = printerMarginMM
            settings.margins = ImpositionMargins(top: m, bottom: m, left: m, right: m)
            initializeFrameFromPage()
        }
        .onDisappear {
            thumbTask?.cancel()
        }
        .onChange(of: settings.addFrameBorder)     { _ in refreshThumbnails() }
        .onChange(of: settings.addCropMarks)       { _ in refreshThumbnails() }
        .onChange(of: settings.columns)            { _ in refreshThumbnails() }
        .onChange(of: settings.rows)               { _ in refreshThumbnails() }
        .onChange(of: settings.mode)               { _ in refreshThumbnails() }
        .onChange(of: settings.autoRotate)         { _ in refreshThumbnails() }
        .onChange(of: settings.pdfBox)             { _ in initializeFrameFromPage() }
        .onChange(of: settings.fitToPage)          { _ in refreshThumbnails() }
        .onChange(of: settings.scale)              { _ in refreshThumbnails() }
        .onChange(of: settings.paperSize)          { _ in refreshThumbnails() }
        .onChange(of: settings.customWidth)        { _ in refreshThumbnails() }
        .onChange(of: settings.customHeight)       { _ in refreshThumbnails() }
        .onChange(of: settings.useManualFrameSize) { _ in refreshThumbnails() }
        .onChange(of: settings.gutterH)            { _ in refreshThumbnails() }
        .onChange(of: settings.gutterV)            { _ in refreshThumbnails() }
        .onChange(of: settings.cropInsetMM)        { _ in refreshThumbnails() }
        // Proporční sync: % → mm
        .onChange(of: frameScalePct) { pct in
            guard !isSyncingFrame, let orig = settings.sourcePageSizePt else { return }
            isSyncingFrame = true
            let pt = ImpositionService.shared.mmToPt
            settings.manualFrameWidth  = Double(orig.width  / pt) * pct / 100
            settings.manualFrameHeight = Double(orig.height / pt) * pct / 100
            DispatchQueue.main.async { isSyncingFrame = false }
            refreshThumbnails()
        }
        // Proporční sync: šířka mm → výška mm + %
        .onChange(of: settings.manualFrameWidth) { w in
            guard !isSyncingFrame, let orig = settings.sourcePageSizePt else {
                refreshThumbnails(); return
            }
            isSyncingFrame = true
            let origW = Double(orig.width / ImpositionService.shared.mmToPt)
            if origW > 0 {
                let pct = w / origW * 100
                frameScalePct = pct
                settings.manualFrameHeight = Double(orig.height / ImpositionService.shared.mmToPt) * pct / 100
            }
            DispatchQueue.main.async { isSyncingFrame = false }
            refreshThumbnails()
        }
        // Proporční sync: výška mm → šířka mm + %
        .onChange(of: settings.manualFrameHeight) { h in
            guard !isSyncingFrame, let orig = settings.sourcePageSizePt else {
                refreshThumbnails(); return
            }
            isSyncingFrame = true
            let origH = Double(orig.height / ImpositionService.shared.mmToPt)
            if origH > 0 {
                let pct = h / origH * 100
                frameScalePct = pct
                settings.manualFrameWidth = Double(orig.width / ImpositionService.shared.mmToPt) * pct / 100
            }
            DispatchQueue.main.async { isSyncingFrame = false }
            refreshThumbnails()
        }
    }

    // MARK: - Thumbnail pre-rendering

    private func refreshThumbnails() {
        thumbTask?.cancel()
        guard let doc = pdfDocument else { return }
        let s = effectiveSettings

        thumbTask = Task.detached(priority: .userInitiated) {
            var result: [Int: NSImage] = [:]
            let count = doc.pageCount
            let size  = CGSize(width: 240, height: 340)

            // Vypočítáme frameOv stejnou logikou jako service (1:1 = trim size, manual, nebo auto)
            let mmToPt = ImpositionService.shared.mmToPt
            let frameOv: CGSize?
            if s.useManualFrameSize {
                frameOv = CGSize(width:  CGFloat(s.manualFrameWidth)  * mmToPt,
                                 height: CGFloat(s.manualFrameHeight) * mmToPt)
            } else if !s.fitToPage, let pageSize = s.sourcePageSizePt {
                let crop = CGFloat(s.cropInsetMM) * mmToPt * 2
                frameOv = CGSize(width:  max(1, pageSize.width  - crop),
                                 height: max(1, pageSize.height - crop))
            } else {
                frameOv = nil
            }

            for i in 0..<count {
                if Task.isCancelled { break }
                guard let page = doc.page(at: i) else { continue }

                let pageRect  = page.bounds(for: s.pdfBox.pdfKitBox)
                let sheetSize = ImpositionService.shared.computeSheetSize(settings: s)
                let pos       = i % max(1, s.columns * s.rows)
                let row = pos / s.columns
                let col = pos % s.columns
                let cell = ImpositionService.shared.cellRect(
                    col: col, row: row, cols: s.columns, rows: s.rows,
                    in: sheetSize, margins: s.margins,
                    gutterH: s.gutterH, gutterV: s.gutterV,
                    cellSizeOverride: frameOv
                )

                let fitNormal  = (cell.width > 0 && cell.height > 0)
                    ? min(cell.width / pageRect.width,  cell.height / pageRect.height) : 1
                let fitRotated = (cell.width > 0 && cell.height > 0)
                    ? min(cell.width / pageRect.height, cell.height / pageRect.width)  : 0
                let shouldRotate = s.autoRotate && fitRotated > fitNormal

                let thumb = page.thumbnail(of: size, for: s.pdfBox.pdfKitBox)
                result[i] = shouldRotate ? ImpositionDialog.rotateImage90CCW(thumb) : thumb
            }

            if !Task.isCancelled {
                let box = _UncheckedSendable(result)
                await MainActor.run { thumbnails = box.value }
            }
        }
    }

    /// Načte rozměry první stránky PDF a nastaví je jako výchozí velikost rámečku.
    private func initializeFrameFromPage() {
        guard let page = pdfDocument?.page(at: 0) else {
            refreshThumbnails(); return
        }
        let rect = page.bounds(for: settings.pdfBox.pdfKitBox)
        let pt   = ImpositionService.shared.mmToPt
        isSyncingFrame = true
        settings.sourcePageSizePt  = rect.size
        settings.manualFrameWidth  = Double(rect.width  / pt)
        settings.manualFrameHeight = Double(rect.height / pt)
        frameScalePct = 100
        isSyncingFrame = false
        refreshThumbnails()
    }

    /// Rotate NSImage 90° CCW via CGBitmapContext (thread-safe, no lockFocus).
    private static nonisolated func rotateImage90CCW(_ src: NSImage) -> NSImage {
        guard let cgSrc = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return src }
        let srcW = cgSrc.width;  let srcH = cgSrc.height
        guard let space = cgSrc.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx   = CGContext(data: nil, width: srcH, height: srcW,
                                    bitsPerComponent: min(cgSrc.bitsPerComponent, 8),
                                    bytesPerRow: srcH * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return src }
        ctx.translateBy(x: 0, y: CGFloat(srcW))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        guard let rotated = ctx.makeImage() else { return src }
        return NSImage(cgImage: rotated, size: CGSize(width: srcH, height: srcW))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .font(.title2).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Imposition").font(.headline)
                if let name = sourceFile?.name {
                    Text(name).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let pc = sourceFile?.pageCount, pc > 0 {
                Text("\(pc) stránek").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Mode Picker

    private var modePickerView: some View {
        Picker("Režim", selection: $settings.mode) {
            ForEach(ImpositionMode.allCases) { m in Text(m.rawValue).tag(m) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Output format ──────────────────────────────
                Text("Výstupní formát").font(.subheadline).bold()

                Picker("Papír", selection: $settings.paperSize) {
                    ForEach(ImpositionPaperSize.allCases) { s in Text(s.rawValue).tag(s) }
                }

                if settings.paperSize == .custom {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Šířka (mm)").font(.caption2).foregroundColor(.secondary)
                            TextField("210", value: $settings.customWidth, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                        }
                        Text("×").foregroundColor(.secondary).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Výška (mm)").font(.caption2).foregroundColor(.secondary)
                            TextField("297", value: $settings.customHeight, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Orientace").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $settings.orientation) {
                        ForEach(ImpositionOrientation.allCases) { o in Text(o.rawValue).tag(o) }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(settings.mode == .booklet)
                }

                Divider()

                // ── Grid ───────────────────────────────────────
                Text("Mřížka").font(.subheadline).bold()

                HStack {
                    Text("Sloupce:"); Spacer()
                    Stepper(value: $settings.columns, in: 1...20) {
                        Text("\(settings.columns)").frame(width: 24, alignment: .trailing)
                    }.disabled(settings.mode == .booklet)
                }
                HStack {
                    Text("Řádky:"); Spacer()
                    Stepper(value: $settings.rows, in: 1...20) {
                        Text("\(settings.rows)").frame(width: 24, alignment: .trailing)
                    }.disabled(settings.mode == .booklet)
                }

                Divider()

                // ── Umístění stránek ───────────────────────────
                Text("Umístění stránek").font(.subheadline).bold()

                VStack(alignment: .leading, spacing: 4) {
                    Text("PDF Box").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $settings.pdfBox) {
                        ForEach(ImpositionPDFBox.allCases) { b in Text(b.rawValue).tag(b) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Toggle("Auto-rotate stránek", isOn: $settings.autoRotate)

                Divider()

                // ── Rámeček ────────────────────────────────────
                Text("Rámeček").font(.subheadline).bold()

                // Fit to Frame: obrázek se přizpůsobí buňce mřížky
                Toggle("Fit to Frame (přizpůsobit buňce)", isOn: $settings.fitToPage)
                if settings.fitToPage {
                    HStack {
                        Text("Měřítko fit (%):")
                        Spacer()
                        TextField("", value: $settings.scale, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                } else {
                    // 1:1 — rámeček = přirozená velikost stránky
                    if let pageSize = settings.sourcePageSizePt {
                        let pt = ImpositionService.shared.mmToPt
                        let w  = Int(round(Double(pageSize.width)  / Double(pt)))
                        let h  = Int(round(Double(pageSize.height) / Double(pt)))
                        Text("Rámeček = stránka: \(w) × \(h) mm (1:1)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                // Ruční rámeček: uživatel zadá rozměr v mm nebo %
                Toggle("Nastavit rámeček ručně", isOn: $settings.useManualFrameSize)
                    .disabled(settings.mode == .booklet)

                if settings.useManualFrameSize {
                    // Proporční měřítko (%)
                    HStack {
                        Text("Měřítko:")
                        Spacer()
                        TextField("100", value: $frameScalePct, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 55)
                        Text("%").foregroundColor(.secondary)
                    }
                    // Rozměry v mm (proporčně svázané)
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Šířka (mm)").font(.caption2).foregroundColor(.secondary)
                            TextField("100", value: $settings.manualFrameWidth, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                        }
                        Text("×").foregroundColor(.secondary).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Výška (mm)").font(.caption2).foregroundColor(.secondary)
                            TextField("100", value: $settings.manualFrameHeight, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                        }
                    }
                }

                Divider()

                // ── Margins & gutters ──────────────────────────
                Text("Okraje (mm)").font(.subheadline).bold()

                HStack(spacing: 6) {
                    mmField("Nahoře",  value: $settings.margins.top)
                    mmField("Dole",    value: $settings.margins.bottom)
                    mmField("Vlevo",   value: $settings.margins.left)
                    mmField("Vpravo",  value: $settings.margins.right)
                }

                HStack {
                    Text("Mezera H (mm):"); Spacer()
                    Stepper(value: $settings.gutterH, in: 0...100, step: 0.5) {
                        TextField("", value: $settings.gutterH, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 55)
                    }
                }
                HStack {
                    Text("Mezera V (mm):"); Spacer()
                    Stepper(value: $settings.gutterV, in: 0...100, step: 0.5) {
                        TextField("", value: $settings.gutterV, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 55)
                    }
                }
                HStack {
                    Text("Ořez (mm):"); Spacer()
                    Stepper(value: $settings.cropInsetMM, in: 0...50, step: 0.5) {
                        TextField("", value: $settings.cropInsetMM, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 55)
                    }
                }
                if settings.cropInsetMM > 0 {
                    Text("PDF se ořeže o \(String(format: "%.1f", settings.cropInsetMM)) mm ze všech stran")
                        .font(.caption2).foregroundColor(.orange)
                }

                Divider()

                // ── Crop marks ─────────────────────────────────
                Toggle("Ořezové značky", isOn: $settings.addCropMarks)
                if settings.addCropMarks {
                    HStack {
                        Text("Délka (mm):"); Spacer()
                        Stepper(value: $settings.cropMarkLength, in: 0.5...50, step: 0.5) {
                            TextField("", value: $settings.cropMarkLength, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 50)
                        }
                    }
                    HStack {
                        Text("Odsazení (mm):"); Spacer()
                        Stepper(value: $settings.cropMarkOffset, in: 0...20, step: 0.5) {
                            TextField("", value: $settings.cropMarkOffset, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 50)
                        }
                    }
                }

                Toggle("Linka okolo objektu (0,5 pt šedá)", isOn: $settings.addFrameBorder)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Info helpers

    private var sheetSizeMMString: String {
        let s = ImpositionService.shared.computeSheetSize(settings: effectiveSettings)
        let pt = ImpositionService.shared.mmToPt
        let w = Int(round(s.width  / pt))
        let h = Int(round(s.height / pt))
        return "\(w) × \(h) mm"
    }

    private var pageSizeMMString: String {
        guard let page = pdfDocument?.page(at: 0) else { return "–" }
        let rect = page.bounds(for: effectiveSettings.pdfBox.pdfKitBox)
        let pt = ImpositionService.shared.mmToPt
        let w = Int(round(rect.width  / pt))
        let h = Int(round(rect.height / pt))
        return "\(w) × \(h) mm"
    }

    private var frameSizeMMString: String {
        let eff = effectiveSettings
        let sheetSize = ImpositionService.shared.computeSheetSize(settings: eff)
        let cell = ImpositionService.shared.effectiveCellSize(settings: eff, sheetSize: sheetSize)
        let pt = ImpositionService.shared.mmToPt
        // V 1:1 režimu effectiveCellSize již vrací trim size → neodečítáme znovu.
        // V fitToPage / manual ořez clipuje dovnitř → zobrazíme viditelnou plochu.
        let isOneToOne = !eff.fitToPage && !eff.useManualFrameSize
        let crop = isOneToOne ? CGFloat(0) : CGFloat(eff.cropInsetMM) * pt * 2
        let w = Int(round((cell.width  - crop) / pt))
        let h = Int(round((cell.height - crop) / pt))
        return "\(w) × \(h) mm"
    }

    private var effectiveScaleString: String {
        let eff = effectiveSettings
        guard eff.fitToPage else {
            if eff.useManualFrameSize {
                return String(format: "%.0f%% orig.", frameScalePct)
            }
            return "100% (1:1)"
        }
        guard let page = pdfDocument?.page(at: 0) else { return "Fit \(Int(eff.scale))%" }

        let pageRect = page.bounds(for: eff.pdfBox.pdfKitBox)
        let sheetSize = ImpositionService.shared.computeSheetSize(settings: eff)
        let cell = ImpositionService.shared.cellRect(
            col: 0, row: 0, cols: eff.columns, rows: eff.rows,
            in: sheetSize, margins: eff.margins,
            gutterH: eff.gutterH, gutterV: eff.gutterV
        )
        guard cell.width > 0, cell.height > 0 else { return "Fit \(Int(eff.scale))%" }

        let pageW = pageRect.width; let pageH = pageRect.height
        let fitNormal  = min(cell.width / pageW, cell.height / pageH)
        let fitRotated = min(cell.width / pageH, cell.height / pageW)
        let shouldRotate = eff.autoRotate && fitRotated > fitNormal
        let drawW = shouldRotate ? pageH : pageW
        let drawH = shouldRotate ? pageW : pageH
        let fitScale = min(cell.width / drawW, cell.height / drawH)
        let totalPct = Int(round(fitScale * eff.scale))
        return "Fit → \(totalPct)%"
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        let eff       = effectiveSettings
        let pageCount = sourceFile?.pageCount ?? 0
        let sheets    = ImpositionService.shared.sheetCount(pageCount: pageCount, settings: eff)
        let perSheet  = eff.mode == .booklet ? 2 : eff.columns * eff.rows

        return VStack(spacing: 0) {
            Text("Náhled (1. list)").font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            ImpositionPreviewCanvas(settings: eff, sourcePageCount: pageCount, thumbnails: thumbnails)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Divider().padding(.vertical, 5)
                infoRow("Mřížka",    "\(eff.columns) × \(eff.rows)")
                infoRow("Na list",   "\(perSheet) stránek")
                infoRow("Listů",     "\(sheets)")
                infoRow("List",      sheetSizeMMString)
                infoRow("Strana PDF", pageSizeMMString)
                infoRow("Box",       eff.pdfBox.rawValue)
                infoRow("Měřítko",   effectiveScaleString)
                infoRow("Rámeček",   frameSizeMMString)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if isProcessing {
                ProgressView().scaleEffect(0.8).padding(.trailing, 4)
                Text("Zpracovávám…").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Zrušit") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Vytvořit Imposition") { runImposition() }
                .keyboardShortcut(.defaultAction)
                .disabled(sourceFile == nil || isProcessing)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private var effectiveSettings: ImpositionSettings {
        guard settings.mode == .booklet else { return settings }
        var s = settings; s.columns = 2; s.rows = 1; return s
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label + ":").font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium)
        }
    }

    private func mmField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 52)
        }
    }

    // MARK: - Create Imposition

    private func runImposition() {
        guard let file = sourceFile else { return }
        isProcessing = true; errorMessage = nil
        let s = effectiveSettings; let url = file.url

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try ImpositionService.shared.createImposition(from: url, settings: s)
                DispatchQueue.main.async {
                    isProcessing = false
                    isPresented  = false
                    appState.addFiles(urls: [r.outputURL], autoSelect: true)
                    appState.logSuccess("Imposition vytvořen: \(r.outputURL.lastPathComponent)")
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    showError    = true
                }
            }
        }
    }
}

// MARK: - Live Preview Canvas

struct ImpositionPreviewCanvas: View {
    let settings:        ImpositionSettings
    let sourcePageCount: Int
    let thumbnails:      [Int: NSImage]

    var body: some View {
        Canvas { context, size in
            let pad: CGFloat = 14
            let availW = size.width  - pad * 2
            let availH = size.height - pad * 2
            guard availW > 0, availH > 0 else { return }

            let sheetSize   = ImpositionService.shared.computeSheetSize(settings: settings)
            let aspect      = sheetSize.width / sheetSize.height

            let (drawW, drawH): (CGFloat, CGFloat) = availW / availH > aspect
                ? (availH * aspect, availH)
                : (availW, availW / aspect)

            let ox = pad + (availW - drawW) / 2
            let oy = pad + (availH - drawH) / 2
            let sheetRect = CGRect(x: ox, y: oy, width: drawW, height: drawH)

            // Sheet shadow + background
            context.fill(Path(sheetRect.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.10)))
            context.fill(Path(sheetRect), with: .color(Color(white: 0.9)))
            context.stroke(Path(sheetRect), with: .color(.gray.opacity(0.6)), lineWidth: 1)

            let cols = settings.columns
            let rows = settings.rows
            let sx = drawW / sheetSize.width
            let sy = drawH / sheetSize.height
            let mmToPtCV = ImpositionService.shared.mmToPt
            // V 1:1 režimu je ořez zahrnut v ráměčku (bleed) → canvas crop = 0.
            // V ostatních režimech se zobrazuje clip dovnitř.
            let isOneToOne = !settings.fitToPage && !settings.useManualFrameSize
            let cropInsetCvX = isOneToOne ? CGFloat(0)
                : CGFloat(max(0.0, settings.cropInsetMM)) * mmToPtCV * sx
            let cropInsetCvY = isOneToOne ? CGFloat(0)
                : CGFloat(max(0.0, settings.cropInsetMM)) * mmToPtCV * sy
            let hasCropInset = cropInsetCvX > 0 || cropInsetCvY > 0
            let frameOv: CGSize?
            if settings.useManualFrameSize {
                frameOv = CGSize(width:  CGFloat(settings.manualFrameWidth)  * mmToPtCV,
                                 height: CGFloat(settings.manualFrameHeight) * mmToPtCV)
            } else if !settings.fitToPage, let pageSize = settings.sourcePageSizePt {
                // 1:1: rámeček = trim size (bleed přeteče ven)
                let crop = CGFloat(settings.cropInsetMM) * mmToPtCV * 2
                frameOv = CGSize(width:  max(1, pageSize.width  - crop),
                                 height: max(1, pageSize.height - crop))
            } else {
                frameOv = nil
            }

            // Buňky kreslíme oříznuté na sheet rect — náhled přesně odpovídá PDF výstupu
            context.drawLayer { clipCtx in
                clipCtx.clip(to: Path(sheetRect))

                for row in 0..<rows {
                    for col in 0..<cols {
                        let pos = row * cols + col

                        let realCell = ImpositionService.shared.cellRect(
                            col: col, row: row, cols: cols, rows: rows,
                            in: sheetSize, margins: settings.margins,
                            gutterH: settings.gutterH, gutterV: settings.gutterV,
                            cellSizeOverride: frameOv
                        )
                        let cvX = ox + realCell.minX * sx
                        let cvY = oy + (sheetSize.height - realCell.maxY) * sy   // flip Y
                        let cvW = realCell.width  * sx
                        let cvH = realCell.height * sy
                        let cellCanvas = CGRect(x: cvX, y: cvY, width: cvW, height: cvH)
                        // Vizuální inset: jen pokud je gutter > 0, jinak žádná mezera
                        let visualInsetX: CGFloat = settings.gutterH > 0.01 ? 0.5 : 0
                        let visualInsetY: CGFloat = settings.gutterV > 0.01 ? 0.5 : 0
                        let inner = cellCanvas.insetBy(dx: visualInsetX, dy: visualInsetY)

                        let hasPage = pos < sourcePageCount || settings.mode == .stepRepeat
                        clipCtx.fill(Path(inner), with: .color(hasPage ? .white : Color(white: 0.95)))
                        // Linka okolo objektu: silnější a tmavší když je zapnutá
                        if settings.addFrameBorder {
                            clipCtx.stroke(Path(inner), with: .color(Color(white: 0.5)), lineWidth: 0.75)
                        } else {
                            clipCtx.stroke(Path(inner), with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
                        }

                        // Viditelná plocha po ořezu (záporná mezera)
                        let clipInner = hasCropInset
                            ? inner.insetBy(dx: cropInsetCvX, dy: cropInsetCvY)
                            : inner
                        if hasCropInset && clipInner.width > 2 && clipInner.height > 2 {
                            // Šedá plocha oříznutého okraje
                            clipCtx.fill(Path(inner), with: .color(Color(white: 0.88)))
                            clipCtx.fill(Path(clipInner), with: .color(hasPage ? .white : Color(white: 0.95)))
                            clipCtx.stroke(Path(clipInner), with: .color(.orange.opacity(0.55)), lineWidth: 0.75)
                        }

                        let thumbKey = settings.mode == .stepRepeat ? 0 : pos
                        if hasPage, let thumb = thumbnails[thumbKey] {
                            let ts = thumb.size
                            guard ts.width > 0, ts.height > 0 else { continue }

                            // V 1:1 režimu s ořezem: thumbnail škálujeme vůči plné velikosti PDF
                            // (inner = trim buňka, ale obsah přetéká jako bleed a clipuje se na inner).
                            let thumbScale: CGFloat
                            if isOneToOne && settings.cropInsetMM > 0 {
                                let cropCvX = CGFloat(settings.cropInsetMM) * mmToPtCV * sx
                                let cropCvY = CGFloat(settings.cropInsetMM) * mmToPtCV * sy
                                let fullW = inner.width  + 2 * cropCvX
                                let fullH = inner.height + 2 * cropCvY
                                thumbScale = min(fullW / ts.width, fullH / ts.height)
                            } else {
                                thumbScale = min(inner.width / ts.width, inner.height / ts.height)
                            }
                            let tw = ts.width  * thumbScale
                            let th = ts.height * thumbScale
                            let dr = CGRect(x: inner.midX - tw/2, y: inner.midY - th/2, width: tw, height: th)

                            clipCtx.drawLayer { ctx in
                                ctx.clip(to: Path(clipInner))   // clip na ořezanou plochu
                                ctx.draw(Image(nsImage: thumb), in: dr)
                            }

                            if !settings.fitToPage && !isOneToOne {
                                let overflows = ts.width  * CGFloat(settings.scale/100) * thumbScale > inner.width * 1.02
                                             || ts.height * CGFloat(settings.scale/100) * thumbScale > inner.height * 1.02
                                if overflows {
                                    clipCtx.stroke(Path(inner), with: .color(.orange.opacity(0.7)), lineWidth: 1.5)
                                }
                            }
                        } else if hasPage {
                            let lbl = Text("\(pos + 1)")
                                .font(.system(size: max(7, min(cvW, cvH) * 0.28), weight: .medium))
                                .foregroundColor(.secondary)
                            clipCtx.draw(lbl, at: CGPoint(x: inner.midX, y: inner.midY))
                        }

                        if hasPage && cvW > 28 {
                            let badge = Text("\(pos + 1)")
                                .font(.system(size: max(6, min(cvW, cvH) * 0.14)))
                                .foregroundColor(Color(white: 0.45))
                            clipCtx.draw(badge,
                                         at: CGPoint(x: inner.maxX - 3, y: inner.maxY - 3),
                                         anchor: .bottomTrailing)
                        }
                    }
                }
            }

            // Crop mark indicators – pouze po vnějším obvodu celé kompozice
            if settings.addCropMarks {
                // Sesbírej unikátní X a Y pozice – při záporné mezeře použij inset pozice
                var cxSet = Set<CGFloat>()
                var cySet = Set<CGFloat>()
                for row in 0..<rows {
                    for col in 0..<cols {
                        let rc = ImpositionService.shared.cellRect(
                            col: col, row: row, cols: cols, rows: rows,
                            in: sheetSize, margins: settings.margins,
                            gutterH: settings.gutterH, gutterV: settings.gutterV,
                            cellSizeOverride: frameOv
                        )
                        // flip Y: pdf minY→canvas maxY, pdf maxY→canvas minY
                        let cvXmin = ox + rc.minX * sx + cropInsetCvX
                        let cvXmax = ox + rc.maxX * sx - cropInsetCvX
                        let cvYmin = oy + (sheetSize.height - rc.maxY) * sy + cropInsetCvY  // canvas top
                        let cvYmax = oy + (sheetSize.height - rc.minY) * sy - cropInsetCvY  // canvas bottom
                        cxSet.insert(cvXmin); cxSet.insert(cvXmax)
                        cySet.insert(cvYmin); cySet.insert(cvYmax)
                    }
                }
                let cxSorted = cxSet.sorted()
                let cySorted = cySet.sorted()
                let cxL = cxSorted.first!;  let cxR = cxSorted.last!
                let cyT = cySorted.first!;  let cyB = cySorted.last!

                let len: CGFloat = min(drawW, drawH) * 0.04
                let off: CGFloat = 2.0

                var p = Path()

                // Levá strana – vodorovné čáry jdoucí doleva pro každou Y pozici
                for y in cySorted {
                    let l = min(len, max(0, cxL - ox - off))
                    if l > 0 {
                        p.move(to: CGPoint(x: cxL - off, y: y))
                        p.addLine(to: CGPoint(x: cxL - off - l, y: y))
                    }
                }
                // Pravá strana – vodorovné čáry jdoucí doprava
                for y in cySorted {
                    let l = min(len, max(0, (ox + drawW) - cxR - off))
                    if l > 0 {
                        p.move(to: CGPoint(x: cxR + off, y: y))
                        p.addLine(to: CGPoint(x: cxR + off + l, y: y))
                    }
                }
                // Horní strana – svislé čáry jdoucí nahoru (canvas: menší Y)
                for x in cxSorted {
                    let l = min(len, max(0, cyT - oy - off))
                    if l > 0 {
                        p.move(to: CGPoint(x: x, y: cyT - off))
                        p.addLine(to: CGPoint(x: x, y: cyT - off - l))
                    }
                }
                // Dolní strana – svislé čáry jdoucí dolů (canvas: větší Y)
                for x in cxSorted {
                    let l = min(len, max(0, (oy + drawH) - cyB - off))
                    if l > 0 {
                        p.move(to: CGPoint(x: x, y: cyB + off))
                        p.addLine(to: CGPoint(x: x, y: cyB + off + l))
                    }
                }
                context.stroke(p, with: .color(.black.opacity(0.8)), lineWidth: 0.75)
            }
        }
        .animation(.easeInOut(duration: 0.1), value: settings.columns)
        .animation(.easeInOut(duration: 0.1), value: settings.rows)
        .animation(.easeInOut(duration: 0.1), value: settings.mode.rawValue)
        .animation(.easeInOut(duration: 0.1), value: settings.fitToPage)
    }
}
