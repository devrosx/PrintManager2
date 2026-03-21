//
//  GalleryDialog.swift
//  PrintManager
//
//  Náhled zobrazuje skutečnou stránku (bílé pozadí) s obrázky
//  rozloženými dle nastavení.
//  Interakce rámečku:
//    • Klik  → aktivuje rámeček, zobrazí se posuvník zoomu uprostřed
//    • Tažení → posun výřezu (jen v ose kde obrázek přesahuje → nikdy bílé místo)
//    • Posuvník → přiblížení výřezu
//

import SwiftUI
import AppKit

// MARK: - Layout helper

struct GalleryLayout {
    let cols:    Int
    let rows:    Int
    let perPage: Int
    let frameW:  Double   // mm – šířka obrázkové plochy
    let frameH:  Double   // mm – výška obrázkové plochy
    let labelH:  Double   // mm – výška oblasti popisku (0 = bez popisku)
    let paperW:  Double   // mm
    let paperH:  Double   // mm
    let mL:      Double
    let mT:      Double
    let gH:      Double
    let gV:      Double

    /// Celková výška buňky (obrázek + popisek)
    var cellH: Double { frameH + labelH }

    init(settings: GallerySettings, imageCount: Int = 0) {
        let paper = settings.effectivePaperMM
        paperW = paper.width;  paperH = paper.height
        gH = settings.gutterH;  gV = settings.gutterV
        let lH = settings.effectiveLabelHeightMM
        labelH = lH

        // Při centrování ignorujeme okraje pro výpočet počtu sloupců/řádků
        let usableW = settings.centerOnPage
            ? paper.width
            : paper.width  - settings.marginLeft - settings.marginRight
        let usableH = settings.centerOnPage
            ? paper.height
            : paper.height - settings.marginTop - settings.marginBottom

        let c: Int; let r: Int; let fw: Double; let fh: Double
        if settings.fillPageEvenly && imageCount > 0 {
            (c, r, fw, fh) = GalleryLayout.fillLayout(
                count: imageCount, usableW: usableW, usableH: usableH,
                gH: gH, gV: gV, labelH: lH)
        } else if let fmm = settings.effectiveFrameMM {
            fw = fmm.width;  fh = fmm.height
            c  = max(1, Int((usableW + gH) / (fmm.width  + gH)))
            r  = max(1, Int((usableH + gV) / (fmm.height + lH + gV)))
        } else {
            fw = usableW;  fh = max(1, usableH - lH)
            c  = 1;  r  = 1
        }
        cols = c; rows = r; frameW = fw; frameH = fh
        perPage = max(1, c * r)

        // Výpočet levého/horního okraje: buď nastavení, nebo vystředění mřížky
        if settings.centerOnPage {
            let gridW = Double(c) * fw + Double(max(0, c - 1)) * gH
            let gridH = Double(r) * (fh + lH) + Double(max(0, r - 1)) * gV
            mL = (paper.width  - gridW) / 2
            mT = (paper.height - gridH) / 2
        } else {
            mL = settings.marginLeft
            mT = settings.marginTop
        }
    }

    /// Vypočítá optimální cols × rows tak, aby N obrázků co nejlépe vyplnilo stránku.
    static func fillLayout(count N: Int, usableW: Double, usableH: Double,
                           gH: Double, gV: Double, labelH: Double = 0) -> (Int, Int, Double, Double) {
        guard N > 0 else { return (1, 1, usableW, max(1, usableH - labelH)) }
        if N == 1   { return (1, 1, usableW, max(1, usableH - labelH)) }
        var bestCols = 1, bestRows = N, bestScore = Double.greatestFiniteMagnitude
        for c in 1...N {
            let r   = Int(ceil(Double(N) / Double(c)))
            let fw  = (usableW - Double(c - 1) * gH) / Double(c)
            let fh  = (usableH - Double(r - 1) * gV) / Double(r) - labelH
            guard fw > 1, fh > 1 else { continue }
            let waste       = Double(c * r - N)
            let aspectDiff  = abs(fw / fh - usableW / usableH)
            let score       = waste * 8.0 + aspectDiff
            if score < bestScore { bestScore = score; bestCols = c; bestRows = r }
        }
        let fw = (usableW - Double(bestCols - 1) * gH) / Double(bestCols)
        let fh = (usableH - Double(bestRows - 1) * gV) / Double(bestRows) - labelH
        return (bestCols, bestRows, fw, max(1, fh))
    }

    func pageCount(imageCount: Int) -> Int {
        max(1, Int(ceil(Double(imageCount) / Double(perPage))))
    }

    func imageIndices(onPage page: Int, imageCount: Int) -> [Int] {
        let start = page * perPage, end = min(start + perPage, imageCount)
        guard start < imageCount else { return [] }
        return Array(start..<end)
    }

    /// Obrázkový rámeček v bodech (preview px), scale = px/mm. Krok řádku = cellH + gV.
    func cellRectPx(localIndex: Int, scale: CGFloat) -> CGRect {
        let col = localIndex % cols, row = localIndex / cols
        let x = (mL + Double(col) * (frameW + gH)) * scale
        let y = (mT + Double(row) * (cellH  + gV)) * scale
        return CGRect(x: x, y: y, width: frameW * scale, height: frameH * scale)
    }

    /// Oblast popisku těsně pod obrázkovým rámečkem (nil když jsou popisky vypnuté).
    func labelRectPx(localIndex: Int, scale: CGFloat) -> CGRect? {
        guard labelH > 0 else { return nil }
        let img = cellRectPx(localIndex: localIndex, scale: scale)
        return CGRect(x: img.minX, y: img.maxY, width: img.width, height: CGFloat(labelH) * scale)
    }
}

// MARK: - Main Dialog

struct GalleryDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let imageFiles: [FileItem]

    // Settings (persisted)
    @AppStorage("gallery.paperSize")     private var paperSizeRaw:   String = GalleryPaperSize.a4.rawValue
    @AppStorage("gallery.orientation")  private var orientationRaw:  String = GalleryOrientation.portrait.rawValue
    @AppStorage("gallery.customPaperW") private var customPaperW:    Double = 210
    @AppStorage("gallery.customPaperH") private var customPaperH:    Double = 297
    @AppStorage("gallery.frameSize")    private var frameSizeRaw:    String = GalleryFrameSize.s10x15.rawValue
    @AppStorage("gallery.customFrameW") private var customFrameW:    Double = 100
    @AppStorage("gallery.customFrameH") private var customFrameH:    Double = 150
    @AppStorage("gallery.marginTop")    private var marginTop:       Double = 10
    @AppStorage("gallery.marginBottom") private var marginBottom:    Double = 10
    @AppStorage("gallery.marginLeft")   private var marginLeft:      Double = 10
    @AppStorage("gallery.marginRight")  private var marginRight:     Double = 10
    @AppStorage("gallery.gutterH")      private var gutterH:         Double = 5
    @AppStorage("gallery.gutterV")      private var gutterV:         Double = 5
    @AppStorage("gallery.centerOnPage") private var centerOnPage:    Bool   = false
    @AppStorage("gallery.cropMarks")    private var addCropMarks:    Bool   = false
    @AppStorage("gallery.cropMarkLen")  private var cropMarkLen:     Double = 5
    @AppStorage("gallery.cropMarkOff")  private var cropMarkOff:     Double = 2
    @AppStorage("gallery.cropMarkW")    private var cropMarkW:       Double = 0.25
    @AppStorage("gallery.frameBorder")  private var addFrameBorder:  Bool   = false
    @AppStorage("gallery.borderWidth")  private var borderWidth:     Double = 0.5
    @AppStorage("gallery.fillPage")     private var fillPageEvenly:  Bool   = false
    @AppStorage("gallery.autoFill")     private var autoFillPage:    Bool   = false
    @AppStorage("gallery.showLabel")    private var showImageLabel:  Bool   = false
    @AppStorage("gallery.labelInside")  private var labelInside:     Bool   = false
    @AppStorage("gallery.labelFont")    private var labelFontName:   String = "Helvetica Neue"
    @AppStorage("gallery.labelSize")    private var labelFontSize:   Double = 9
    @AppStorage("gallery.labelAlign")   private var labelAlignRaw:   String = GalleryLabelAlignment.center.rawValue
    @AppStorage("gallery.resample")     private var resampleImages:  Bool   = true
    @AppStorage("gallery.imageEffect")  private var imageEffectRaw:  String = GalleryImageEffect.none.rawValue
    @AppStorage("gallery.featherEdges")  private var featherEdges:   Bool   = false
    @AppStorage("gallery.featherAmount") private var featherAmount:  Double = 20.0
    @AppStorage("gallery.roundCorners")  private var roundCorners:   Bool   = false
    @AppStorage("gallery.cornerRadius")  private var cornerRadius:   Double = 5.0
    @AppStorage("gallery.shadow")       private var addFrameShadow:  Bool   = false
    @AppStorage("gallery.shadowX")      private var shadowOffsetX:   Double = 2.0
    @AppStorage("gallery.shadowY")      private var shadowOffsetY:   Double = 2.0
    @AppStorage("gallery.shadowBlur")   private var shadowBlur:      Double = 3.0
    @AppStorage("gallery.shadowOp")     private var shadowOpacity:   Double = 50.0

    @State private var labelColor:          Color  = .black
    @State private var labelBackground:     Color  = .clear
    @State private var borderColor:         Color  = .black
    @State private var pageBackground:      Color  = .white
    @State private var shadowColor:         Color  = .black
    @State private var duotoneShadow:       Color  = Color(red: 0.04, green: 0.18, blue: 0.42)
    @State private var duotoneHighlight:    Color  = Color(red: 1.00, green: 0.60, blue: 0.15)

    // Předvolby
    @State private var presets:           [GalleryPresetData] = []
    @State private var selectedPresetID:  UUID?               = nil
    @State private var showSaveSheet:     Bool                = false
    @State private var newPresetName:     String              = ""

    @State private var imageStates:      [GalleryImageState] = []
    @State private var isProcessing:     Bool   = false
    @State private var progress:         Double = 0
    @State private var isIDProcessing:   Bool   = false
    @State private var errorMessage:     String?
    @State private var showError:        Bool   = false
    @State private var activeID:     UUID?
    @State private var previewPage:  Int    = 0

    @AppStorage("galleryDialogWidth")  private var savedWidth:  Double = 1020
    @AppStorage("galleryDialogHeight") private var savedHeight: Double = 700

    private var paperSize:      GalleryPaperSize      { GalleryPaperSize(rawValue: paperSizeRaw)         ?? .a4 }
    private var orientation:    GalleryOrientation    { GalleryOrientation(rawValue: orientationRaw)     ?? .portrait }
    private var frameSize:      GalleryFrameSize      { GalleryFrameSize(rawValue: frameSizeRaw)         ?? .s10x15 }
    private var labelAlignment: GalleryLabelAlignment { GalleryLabelAlignment(rawValue: labelAlignRaw)   ?? .center }
    private var imageEffect:    GalleryImageEffect    { GalleryImageEffect(rawValue: imageEffectRaw)     ?? .none   }

    private var settings: GallerySettings {
        GallerySettings(
            paperSize: paperSize, orientation: orientation,
            customPaperW: customPaperW, customPaperH: customPaperH,
            frameSize: frameSize, customFrameW: customFrameW, customFrameH: customFrameH,
            marginTop: marginTop, marginBottom: marginBottom,
            marginLeft: marginLeft, marginRight: marginRight,
            gutterH: gutterH, gutterV: gutterV,
            centerOnPage: centerOnPage,
            addCropMarks: addCropMarks, cropMarkLength: cropMarkLen,
            cropMarkOffset: cropMarkOff, cropMarkWidth: cropMarkW,
            addFrameBorder: addFrameBorder, frameBorderWidth: borderWidth,
            frameBorderColor: borderColor,
            pageBackgroundColor: pageBackground,
            addFrameShadow: addFrameShadow,
            shadowOffsetX: shadowOffsetX, shadowOffsetY: shadowOffsetY,
            shadowBlur: shadowBlur, shadowOpacity: shadowOpacity,
            shadowColor: shadowColor,
            fillPageEvenly: fillPageEvenly,
            autoFillPage: autoFillPage,
            showImageLabel: showImageLabel, labelInside: labelInside,
            labelFontName: labelFontName, labelFontSize: labelFontSize,
            labelColor: labelColor, labelBackground: labelBackground,
            labelAlignment: labelAlignment,
            imageEffect: imageEffect,
            duotoneShadowColor: duotoneShadow, duotoneHighlightColor: duotoneHighlight,
            featherEdges: featherEdges, featherAmount: featherAmount,
            roundCorners: roundCorners, cornerRadius: cornerRadius,
            resampleImages: resampleImages
        )
    }

    private var layout: GalleryLayout { GalleryLayout(settings: settings, imageCount: imageStates.count) }

    /// Pole obrázků doplněné kopiemi tak, aby byly vyplněny všechny buňky na každé stránce.
    /// Kopie cyklicky opakují originály; pokud je autoFillPage vypnuté, vrátí originál.
    private var effectiveImageStates: [GalleryImageState] {
        guard autoFillPage && !imageStates.isEmpty else { return imageStates }
        let perPage = layout.perPage
        let pages   = max(1, Int(ceil(Double(imageStates.count) / Double(perPage))))
        let needed  = pages * perPage
        guard needed > imageStates.count else { return imageStates }
        var result  = imageStates
        var i       = 0
        while result.count < needed {
            let src  = imageStates[i % imageStates.count]
            var copy = GalleryImageState(id: UUID(), url: src.url)
            copy.panOffset     = src.panOffset
            copy.zoom          = src.zoom
            copy.pixelSize     = src.pixelSize
            copy.dpi           = src.dpi
            copy.fitMode       = src.fitMode
            copy.fitBackground = src.fitBackground
            copy.extraRotation = src.extraRotation
            result.append(copy)
            i += 1
        }
        return result
    }

    /// Binding na effectiveImageStates: čtení vrátí kopie, zápis se propaguje jen do originálů (UUID shoda).
    private var effectiveStatesBinding: Binding<[GalleryImageState]> {
        Binding(
            get: { effectiveImageStates },
            set: { newStates in
                for newState in newStates {
                    if let idx = imageStates.firstIndex(where: { $0.id == newState.id }) {
                        imageStates[idx] = newState
                    }
                }
            }
        )
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            HSplitView {
                settingsPanel.frame(minWidth: 280, maxWidth: 320).padding()
                previewPanel
            }
            Divider()
            footerView
        }
        .frame(minWidth: 820, idealWidth: savedWidth,
               minHeight: 580, idealHeight: savedHeight)
        .background(WindowSizeSaverGallery { size in
            savedWidth  = size.width
            savedHeight = size.height
        })
        .onAppear { loadImageStates(); loadPresets() }
        .onChange(of: paperSizeRaw)   { _ in clampPreviewPage() }
        .onChange(of: orientationRaw) { _ in clampPreviewPage() }
        .onChange(of: frameSizeRaw)   { _ in clampPreviewPage() }
        .onChange(of: customFrameW)   { _ in clampPreviewPage() }
        .onChange(of: customFrameH)   { _ in clampPreviewPage() }
        .onChange(of: fillPageEvenly)  { _ in clampPreviewPage() }
        .onChange(of: autoFillPage)    { _ in clampPreviewPage() }
        .alert("Chyba", isPresented: $showError) { Button("OK") {} }
            message: { Text(errorMessage ?? "") }
    }

    // MARK: Header / Footer

    private var headerView: some View {
        HStack {
            Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundColor(.accentColor)
            Text("Vytvořit galerii").font(.headline)
            Spacer()
            Text("\(imageFiles.count) obrázků").font(.subheadline).foregroundColor(.secondary)
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }.buttonStyle(.borderless)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var footerView: some View {
        HStack {
            Button("Zrušit") { isPresented = false }.buttonStyle(.bordered)
            Spacer()
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100)) %").font(.caption).foregroundColor(.secondary)
                }
            }
            if isIDProcessing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Otvírám InDesign…").font(.caption).foregroundColor(.secondary)
                }
            }
            Button {
                createInDesignGallery()
            } label: {
                Label("Vytvořit InDesign galerii", systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing || isIDProcessing || imageStates.isEmpty)
            .help("Vytvoří InDesign dokument se stejným rozložením (každý obrázek jako samostatný objekt)")

            Button("Vytvořit galerii") { createGallery() }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || isIDProcessing || imageStates.isEmpty)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Section divider helper

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(.secondary)
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 0.5)
        }
        .padding(.top, 4)
    }

    // MARK: Settings Panel

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {

                // ── Předvolby ───────────────────────────────────────────────
                GroupBox("Předvolby") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Menu {
                                if presets.isEmpty {
                                    Text("Žádné předvolby").foregroundColor(.secondary)
                                } else {
                                    ForEach(presets) { preset in
                                        Button {
                                            applyPreset(preset)
                                            selectedPresetID = preset.id
                                        } label: {
                                            HStack {
                                                Text(preset.name)
                                                if selectedPresetID == preset.id {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    let name = presets.first(where: { $0.id == selectedPresetID })?.name ?? "— vybrat —"
                                    Text(name).font(.caption)
                                    Image(systemName: "chevron.down").font(.caption2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .menuStyle(.borderlessButton)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                        }

                        HStack(spacing: 6) {
                            // Uložit jako… / Přepsat
                            if showSaveSheet {
                                TextField("Název předvolby", text: $newPresetName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                Button("Uložit") {
                                    guard !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                    savePresetAs(name: newPresetName.trimmingCharacters(in: .whitespaces))
                                    showSaveSheet = false; newPresetName = ""
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                Button("Zrušit") { showSaveSheet = false; newPresetName = "" }
                                    .buttonStyle(.borderless).controlSize(.small)
                            } else {
                                if let selID = selectedPresetID, presets.contains(where: { $0.id == selID }) {
                                    Button("Přepsat") { overwritePreset(id: selID) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                                Button("Uložit jako…") {
                                    let baseName = presets.first(where: { $0.id == selectedPresetID })?.name ?? ""
                                    newPresetName = baseName
                                    showSaveSheet = true
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                if let selID = selectedPresetID, presets.contains(where: { $0.id == selID }) {
                                    Button(role: .destructive) { deletePreset(id: selID) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless).controlSize(.small)
                                    .help("Smazat vybranou předvolbu")
                                }
                            }
                            Spacer()
                        }
                    }.padding(.vertical, 4)
                }

                sectionHeader("ROZVRŽENÍ")

                GroupBox("Papír") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Formát", selection: Binding(
                            get: { paperSize }, set: { paperSizeRaw = $0.rawValue }
                        )) {
                            // A-série
                            Text(GalleryPaperSize.a8.rawValue).tag(GalleryPaperSize.a8)
                            Text(GalleryPaperSize.a7.rawValue).tag(GalleryPaperSize.a7)
                            Text(GalleryPaperSize.a6.rawValue).tag(GalleryPaperSize.a6)
                            Text(GalleryPaperSize.a5.rawValue).tag(GalleryPaperSize.a5)
                            Text(GalleryPaperSize.a4.rawValue).tag(GalleryPaperSize.a4)
                            Text(GalleryPaperSize.a3.rawValue).tag(GalleryPaperSize.a3)
                            Divider()
                            // Ostatní standardní
                            Text(GalleryPaperSize.sra4.rawValue).tag(GalleryPaperSize.sra4)
                            Text(GalleryPaperSize.sra3.rawValue).tag(GalleryPaperSize.sra3)
                            Text(GalleryPaperSize.p480x320.rawValue).tag(GalleryPaperSize.p480x320)
                            Text(GalleryPaperSize.letter.rawValue).tag(GalleryPaperSize.letter)
                            Text(GalleryPaperSize.postcard.rawValue).tag(GalleryPaperSize.postcard)
                            Divider()
                            Text(GalleryPaperSize.custom.rawValue).tag(GalleryPaperSize.custom)
                        }
                        if paperSize == .custom {
                            HStack(spacing: 4) {
                                Text("Š").frame(width: 14)
                                TextField("", value: $customPaperW, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 54)
                                Text("V").frame(width: 14)
                                TextField("", value: $customPaperH, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 54)
                                Text("mm").foregroundColor(.secondary)
                            }
                        }
                        Picker("Orientace", selection: Binding(
                            get: { orientation }, set: { orientationRaw = $0.rawValue }
                        )) { ForEach(GalleryOrientation.allCases) { Text($0.rawValue).tag($0) } }
                    }.padding(.vertical, 4)
                }

                GroupBox("Velikost obrázku") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Vyplnit stránku rovnoměrně", isOn: $fillPageEvenly)
                            .help("Automaticky rozloží obrázky do mřížky, která rovnoměrně vyplní stránku")
                        Toggle("Doplnit kopie pro plné stránky", isOn: $autoFillPage)
                            .help("Cyklicky opakuje obrázky, dokud nejsou vyplněny všechny buňky na každé stránce")
                        if !fillPageEvenly {
                            Picker("Rámeček", selection: Binding(
                                get: { frameSize }, set: { frameSizeRaw = $0.rawValue }
                            )) {
                                Text(GalleryFrameSize.fill.rawValue).tag(GalleryFrameSize.fill)
                                Divider()
                                // Foto formáty
                                Text(GalleryFrameSize.s9x13.rawValue).tag(GalleryFrameSize.s9x13)
                                Text(GalleryFrameSize.s10x15.rawValue).tag(GalleryFrameSize.s10x15)
                                Text(GalleryFrameSize.s13x18.rawValue).tag(GalleryFrameSize.s13x18)
                                Text(GalleryFrameSize.s15x21.rawValue).tag(GalleryFrameSize.s15x21)
                                Text(GalleryFrameSize.s20x30.rawValue).tag(GalleryFrameSize.s20x30)
                                Text(GalleryFrameSize.square10.rawValue).tag(GalleryFrameSize.square10)
                                Text(GalleryFrameSize.square15.rawValue).tag(GalleryFrameSize.square15)
                                Divider()
                                // A-série
                                Text(GalleryFrameSize.a8.rawValue).tag(GalleryFrameSize.a8)
                                Text(GalleryFrameSize.a7.rawValue).tag(GalleryFrameSize.a7)
                                Text(GalleryFrameSize.a6.rawValue).tag(GalleryFrameSize.a6)
                                Text(GalleryFrameSize.a5.rawValue).tag(GalleryFrameSize.a5)
                                Text(GalleryFrameSize.a4.rawValue).tag(GalleryFrameSize.a4)
                                Text(GalleryFrameSize.a3.rawValue).tag(GalleryFrameSize.a3)
                                Divider()
                                // Ostatní standardní
                                Text(GalleryFrameSize.sra4.rawValue).tag(GalleryFrameSize.sra4)
                                Text(GalleryFrameSize.sra3.rawValue).tag(GalleryFrameSize.sra3)
                                Text(GalleryFrameSize.p480x320.rawValue).tag(GalleryFrameSize.p480x320)
                                Text(GalleryFrameSize.letter.rawValue).tag(GalleryFrameSize.letter)
                                Text(GalleryFrameSize.postcard.rawValue).tag(GalleryFrameSize.postcard)
                                Divider()
                                Text(GalleryFrameSize.custom.rawValue).tag(GalleryFrameSize.custom)
                            }
                            if frameSize == .custom {
                                HStack(spacing: 4) {
                                    Text("Š").frame(width: 14)
                                    TextField("", value: $customFrameW, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 54)
                                    Text("V").frame(width: 14)
                                    TextField("", value: $customFrameH, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 54)
                                    Text("mm").foregroundColor(.secondary)
                                }
                            }
                        } else {
                            // Informace o vypočteném layoutu
                            let l = layout
                            Text("\(l.cols) × \(l.rows) — \(String(format: "%.1f", l.frameW)) × \(String(format: "%.1f", l.frameH)) mm")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 4)
                }

                GroupBox("Okraje a mezery (mm)") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("T").frame(width: 14)
                            TextField("", value: $marginTop, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 44)
                            Text("B").frame(width: 14)
                            TextField("", value: $marginBottom, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 44)
                            Text("L").frame(width: 14)
                            TextField("", value: $marginLeft, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 44)
                            Text("R").frame(width: 14)
                            TextField("", value: $marginRight, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 44)
                        }
                        HStack(spacing: 4) {
                            Text("Mezera H").frame(width: 60, alignment: .leading)
                            TextField("", value: $gutterH, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 44)
                            Text("V").frame(width: 14)
                            TextField("", value: $gutterV, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 44)
                            Text("mm").foregroundColor(.secondary)
                        }
                        Divider()
                        Toggle("Vystředit mřížku na stránce", isOn: $centerOnPage)
                            .help("Ignoruje okraje a vystředí obrázky přesně na střed stránky")
                    }.padding(.vertical, 4)
                }

                GroupBox("Ořezové značky") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Přidat ořezové značky", isOn: $addCropMarks)
                        if addCropMarks {
                            HStack(spacing: 4) {
                                Text("Délka").frame(width: 52, alignment: .leading)
                                TextField("", value: $cropMarkLen, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("mm").foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Offset").frame(width: 52, alignment: .leading)
                                TextField("", value: $cropMarkOff, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("mm").foregroundColor(.secondary)
                            }
                        }
                    }.padding(.vertical, 4)
                }

                sectionHeader("VZHLED RÁMEČKU")

                GroupBox("Kulaté rohy") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Zakulatit rohy", isOn: $roundCorners)
                        if roundCorners {
                            HStack(spacing: 4) {
                                Text("Rádius").frame(width: 70, alignment: .leading)
                                Slider(value: $cornerRadius, in: 1...30)
                                    .frame(width: 80)
                                TextField("", value: $cornerRadius, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("mm").foregroundColor(.secondary)
                            }
                        }
                    }.padding(.vertical, 4)
                }

                GroupBox("Linka okolo obrázku") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Přidat linku", isOn: $addFrameBorder)
                        if addFrameBorder {
                            HStack(spacing: 4) {
                                Text("Tloušťka").frame(width: 70, alignment: .leading)
                                TextField("", value: $borderWidth, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("pt").foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Barva").frame(width: 70, alignment: .leading)
                                ColorPicker("", selection: $borderColor, supportsOpacity: false)
                                    .labelsHidden().frame(width: 28, height: 24)
                            }
                        }
                    }.padding(.vertical, 4)
                }

                sectionHeader("STRÁNKA")

                GroupBox("Pozadí stránky") {
                    HStack(spacing: 8) {
                        Text("Barva pozadí").foregroundColor(.secondary).font(.caption)
                        ColorPicker("", selection: $pageBackground, supportsOpacity: false)
                            .labelsHidden().frame(width: 28, height: 24)
                        Button("Bílá") { pageBackground = .white }
                            .buttonStyle(.borderless).font(.caption).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                }

                sectionHeader("EFEKTY")

                GroupBox("Efekt obrázku") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: Binding(
                            get: { imageEffect },
                            set: { imageEffectRaw = $0.rawValue }
                        )) {
                            ForEach(GalleryImageEffect.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()

                        if imageEffect == .duotone {
                            HStack(spacing: 6) {
                                Text("Stíny").frame(width: 52, alignment: .leading)
                                    .foregroundColor(.secondary).font(.caption)
                                ColorPicker("", selection: $duotoneShadow, supportsOpacity: false)
                                    .labelsHidden().frame(width: 28, height: 24)
                                Spacer()
                                // Předdefinované páry
                                Menu {
                                    Button("Teal / Orange")   { duotoneShadow = Color(red: 0.04, green: 0.28, blue: 0.38); duotoneHighlight = Color(red: 1.00, green: 0.60, blue: 0.15) }
                                    Button("Navy / Gold")     { duotoneShadow = Color(red: 0.04, green: 0.10, blue: 0.35); duotoneHighlight = Color(red: 0.95, green: 0.78, blue: 0.10) }
                                    Button("Purple / Peach")  { duotoneShadow = Color(red: 0.30, green: 0.05, blue: 0.45); duotoneHighlight = Color(red: 1.00, green: 0.75, blue: 0.65) }
                                    Button("Forest / Sand")   { duotoneShadow = Color(red: 0.10, green: 0.28, blue: 0.15); duotoneHighlight = Color(red: 0.92, green: 0.82, blue: 0.62) }
                                    Button("Midnight / Pink") { duotoneShadow = Color(red: 0.06, green: 0.06, blue: 0.22); duotoneHighlight = Color(red: 1.00, green: 0.55, blue: 0.75) }
                                    Button("Charcoal / Ice")  { duotoneShadow = Color(red: 0.12, green: 0.12, blue: 0.14); duotoneHighlight = Color(red: 0.78, green: 0.93, blue: 1.00) }
                                } label: {
                                    Image(systemName: "swatchpalette")
                                        .foregroundColor(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 24)
                                .help("Předdefinované kombinace barev")
                            }
                            HStack(spacing: 6) {
                                Text("Světla").frame(width: 52, alignment: .leading)
                                    .foregroundColor(.secondary).font(.caption)
                                ColorPicker("", selection: $duotoneHighlight, supportsOpacity: false)
                                    .labelsHidden().frame(width: 28, height: 24)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Stín za obrázkem") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Přidat stín", isOn: $addFrameShadow)
                        if addFrameShadow {
                            HStack(spacing: 4) {
                                Text("Posun X").frame(width: 70, alignment: .leading)
                                TextField("", value: $shadowOffsetX, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("mm").foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Posun Y").frame(width: 70, alignment: .leading)
                                TextField("", value: $shadowOffsetY, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("mm").foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Rozptyl").frame(width: 70, alignment: .leading)
                                TextField("", value: $shadowBlur, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("mm").foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Krytí").frame(width: 70, alignment: .leading)
                                Slider(value: $shadowOpacity, in: 0...100)
                                    .frame(width: 80)
                                Text("\(Int(shadowOpacity)) %")
                                    .foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                            }
                            HStack(spacing: 4) {
                                Text("Barva").frame(width: 70, alignment: .leading)
                                ColorPicker("", selection: $shadowColor, supportsOpacity: false)
                                    .labelsHidden().frame(width: 28, height: 24)
                            }
                        }
                    }.padding(.vertical, 4)
                }

                GroupBox("Prolnutí krajů") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Prolnout do ztracena", isOn: $featherEdges)
                        if featherEdges {
                            HStack(spacing: 4) {
                                Text("Intenzita").frame(width: 70, alignment: .leading)
                                Slider(value: $featherAmount, in: 1...50)
                                    .frame(width: 80)
                                Text("\(Int(featherAmount)) %")
                                    .foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                            }
                            Text("Barva prolnutí = pozadí stránky")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 4)
                }

                sectionHeader("POPISEK")

                GroupBox("Text pod obrázkem") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Zobrazit název souboru", isOn: $showImageLabel)
                        if showImageLabel {
                            Toggle("Uvnitř obrázku (překryt dole)", isOn: $labelInside)
                                .help("Popisek se zobrazí přes spodní část obrázku – nepřidává extra prostor")
                            // Font — výběr ze všech systémových písem
                            HStack(spacing: 4) {
                                Text("Font").frame(width: 70, alignment: .leading)
                                FontPickerButton(fontName: $labelFontName)
                            }
                            // Velikost
                            HStack(spacing: 4) {
                                Text("Velikost").frame(width: 70, alignment: .leading)
                                TextField("", value: $labelFontSize, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                                Text("pt").foregroundColor(.secondary)
                            }
                            // Zarovnání
                            Picker("Zarovnání", selection: Binding(
                                get: { labelAlignment },
                                set: { labelAlignRaw = $0.rawValue }
                            )) {
                                ForEach(GalleryLabelAlignment.allCases) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            // Barvy
                            HStack(spacing: 10) {
                                HStack(spacing: 4) {
                                    Text("Text").foregroundColor(.secondary).font(.caption)
                                    ColorPicker("", selection: $labelColor, supportsOpacity: false)
                                        .labelsHidden().frame(width: 28, height: 24)
                                }
                                HStack(spacing: 4) {
                                    Text("Pozadí").foregroundColor(.secondary).font(.caption)
                                    ColorPicker("", selection: $labelBackground, supportsOpacity: true)
                                        .labelsHidden().frame(width: 28, height: 24)
                                }
                            }
                            let lh = settings.labelAreaHeightMM
                            Text(labelInside
                                 ? "Výška pruhu: \(String(format: "%.1f", lh)) mm (uvnitř)"
                                 : "Výška oblasti: \(String(format: "%.1f", lh)) mm (pod obrázkem)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 4)
                }

                sectionHeader("EXPORT")

                GroupBox("Při ukládání") {
                    Toggle("Převzorkovat obrázky", isOn: $resampleImages).padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 0) {
            // Toolbar nad náhledem
            HStack(spacing: 10) {
                let total = layout.pageCount(imageCount: effectiveImageStates.count)
                Text("Strana \(previewPage + 1) / \(total)")
                    .font(.caption).foregroundColor(.secondary)
                Button { if previewPage > 0 { previewPage -= 1 } } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(previewPage == 0).buttonStyle(.borderless)
                Button { if previewPage < total - 1 { previewPage += 1 } } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(previewPage >= total - 1).buttonStyle(.borderless)
                Divider().frame(height: 16)
                Toggle("Fit vše", isOn: Binding(
                    get: { !imageStates.isEmpty && imageStates.allSatisfy { $0.fitMode } },
                    set: { fitAll in
                        for i in imageStates.indices {
                            imageStates[i].fitMode = fitAll
                            if fitAll {
                                imageStates[i].panOffset = .zero
                                imageStates[i].zoom      = 1.0
                            }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Přepnout všechny rámečky mezi Fill (ořez) a Fit (celý obrázek)")
                Spacer()
                if activeID != nil {
                    Text("Táhni obr. pro posun výřezu")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("Klikni na rámeček pro úpravu")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Stránka
            GeometryReader { geo in
                GalleryPagePreview(
                    layout: layout,
                    settings: settings,
                    imageStates: effectiveStatesBinding,
                    activeID: $activeID,
                    page: previewPage,
                    availableSize: geo.size,
                    onDuplicateImage: { id in
                        // Jde přímo do originálního imageStates – obchází effectiveStatesBinding
                        guard let idx = imageStates.firstIndex(where: { $0.id == id }) else { return }
                        let src = imageStates[idx]
                        var copy = GalleryImageState(id: UUID(), url: src.url)
                        copy.panOffset = src.panOffset; copy.zoom = src.zoom
                        copy.pixelSize = src.pixelSize; copy.dpi  = src.dpi
                        copy.fitMode   = src.fitMode;   copy.fitBackground = src.fitBackground
                        copy.extraRotation = src.extraRotation
                        imageStates.insert(copy, at: idx + 1)
                    },
                    onRemoveImage: { id in
                        imageStates.removeAll { $0.id == id }
                        if activeID == id { activeID = nil }
                    }
                )
            }
            .background(Color(NSColor.underPageBackgroundColor))
            // Klik mimo rámeček zruší výběr
            .onTapGesture { activeID = nil }
        }
    }

    // MARK: Helpers

    private func clampPreviewPage() {
        let total = layout.pageCount(imageCount: effectiveImageStates.count)
        if previewPage >= total { previewPage = max(0, total - 1) }
    }

    private func loadImageStates() {
        imageStates = imageFiles.map { file in
            let info = GalleryService.shared.imageInfo(url: file.url)
            var state = GalleryImageState(id: file.id, url: file.url)
            state.pixelSize = info.pixelSize; state.dpi = info.dpi
            return state
        }
    }

    private func createGallery() {
        let name     = imageFiles.first.map { $0.url.deletingPathExtension().lastPathComponent } ?? "Gallery"
        let firstURL = imageFiles.first?.url
        isProcessing = true; progress = 0
        let snap = effectiveImageStates, s = settings

        Task.detached(priority: .userInitiated) {
            do {
                let outURL = try GalleryService.shared.createGallery(
                    images: snap, settings: s, outputName: name
                ) { p in DispatchQueue.main.async { progress = p } }

                let dir = firstURL?.deletingLastPathComponent()
                    ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory())
                let destURL = dir.appendingPathComponent("\(name)_gallery.pdf")
                try? FileManager.default.removeItem(at: destURL)
                try  FileManager.default.moveItem(at: outURL, to: destURL)

                await MainActor.run {
                    isProcessing = false
                    appState.addFiles(urls: [destURL], autoSelect: true, markAsConverted: true)
                    isPresented  = false
                    appState.logSuccess("Galerie vytvořena: \(destURL.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    isProcessing = false; errorMessage = error.localizedDescription; showError = true
                }
            }
        }
    }

    // MARK: Preset helpers

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: "gallery.presets"),
              let decoded = try? JSONDecoder().decode([GalleryPresetData].self, from: data)
        else { presets = []; return }
        presets = decoded
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "gallery.presets")
        }
    }

    private func savePresetAs(name: String) {
        var p = collectPreset(name: name)
        // Pokud existuje preset se stejným názvem, přepíšeme ho
        if let idx = presets.firstIndex(where: { $0.name == name }) {
            p.id = presets[idx].id
            presets[idx] = p
        } else {
            presets.append(p)
        }
        selectedPresetID = p.id
        persistPresets()
    }

    private func overwritePreset(id: UUID) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        var p = collectPreset(name: presets[idx].name)
        p.id = id
        presets[idx] = p
        persistPresets()
    }

    private func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedPresetID == id { selectedPresetID = nil }
        persistPresets()
    }

    private func collectPreset(name: String) -> GalleryPresetData {
        var p = GalleryPresetData(name: name)
        p.paperSizeRaw   = paperSizeRaw;    p.orientationRaw = orientationRaw
        p.customPaperW   = customPaperW;    p.customPaperH   = customPaperH
        p.frameSizeRaw   = frameSizeRaw
        p.customFrameW   = customFrameW;    p.customFrameH   = customFrameH
        p.marginTop      = marginTop;       p.marginBottom   = marginBottom
        p.marginLeft     = marginLeft;      p.marginRight    = marginRight
        p.gutterH        = gutterH;         p.gutterV        = gutterV
        p.centerOnPage   = centerOnPage
        p.addCropMarks   = addCropMarks
        p.cropMarkLen    = cropMarkLen;     p.cropMarkOff    = cropMarkOff
        p.cropMarkW      = cropMarkW
        p.addFrameBorder = addFrameBorder;  p.borderWidth    = borderWidth
        p.borderColorHex = galleryColorToHex(borderColor)
        p.addFrameShadow = addFrameShadow
        p.shadowOffsetX  = shadowOffsetX;   p.shadowOffsetY  = shadowOffsetY
        p.shadowBlur     = shadowBlur;      p.shadowOpacity  = shadowOpacity
        p.shadowColorHex = galleryColorToHex(shadowColor)
        p.pageBackgroundHex = galleryColorToHex(pageBackground)
        p.fillPageEvenly = fillPageEvenly;  p.autoFillPage   = autoFillPage
        p.showImageLabel = showImageLabel;  p.labelInside    = labelInside
        p.labelFontName  = labelFontName;   p.labelFontSize  = labelFontSize
        p.labelAlignRaw  = labelAlignRaw
        p.labelColorHex      = galleryColorToHex(labelColor)
        p.labelBackgroundHex = galleryColorToHex(labelBackground)
        p.imageEffectRaw      = imageEffectRaw
        p.duotoneShadowHex    = galleryColorToHex(duotoneShadow)
        p.duotoneHighlightHex = galleryColorToHex(duotoneHighlight)
        p.featherEdges   = featherEdges;    p.featherAmount  = featherAmount
        p.roundCorners   = roundCorners;    p.cornerRadius   = cornerRadius
        p.resampleImages = resampleImages
        return p
    }

    private func applyPreset(_ p: GalleryPresetData) {
        paperSizeRaw   = p.paperSizeRaw;    orientationRaw = p.orientationRaw
        customPaperW   = p.customPaperW;    customPaperH   = p.customPaperH
        frameSizeRaw   = p.frameSizeRaw
        customFrameW   = p.customFrameW;    customFrameH   = p.customFrameH
        marginTop      = p.marginTop;       marginBottom   = p.marginBottom
        marginLeft     = p.marginLeft;      marginRight    = p.marginRight
        gutterH        = p.gutterH;         gutterV        = p.gutterV
        centerOnPage   = p.centerOnPage
        addCropMarks   = p.addCropMarks
        cropMarkLen    = p.cropMarkLen;     cropMarkOff    = p.cropMarkOff
        cropMarkW      = p.cropMarkW
        addFrameBorder = p.addFrameBorder;  borderWidth    = p.borderWidth
        borderColor    = galleryColorFromHex(p.borderColorHex)
        addFrameShadow = p.addFrameShadow
        shadowOffsetX  = p.shadowOffsetX;   shadowOffsetY  = p.shadowOffsetY
        shadowBlur     = p.shadowBlur;      shadowOpacity  = p.shadowOpacity
        shadowColor    = galleryColorFromHex(p.shadowColorHex)
        pageBackground = galleryColorFromHex(p.pageBackgroundHex)
        fillPageEvenly = p.fillPageEvenly;  autoFillPage   = p.autoFillPage
        showImageLabel = p.showImageLabel;  labelInside    = p.labelInside
        labelFontName  = p.labelFontName;   labelFontSize  = p.labelFontSize
        labelAlignRaw  = p.labelAlignRaw
        labelColor     = galleryColorFromHex(p.labelColorHex)
        labelBackground = galleryColorFromHex(p.labelBackgroundHex)
        imageEffectRaw    = p.imageEffectRaw
        duotoneShadow     = galleryColorFromHex(p.duotoneShadowHex)
        duotoneHighlight  = galleryColorFromHex(p.duotoneHighlightHex)
        featherEdges  = p.featherEdges;    featherAmount  = p.featherAmount
        roundCorners  = p.roundCorners;    cornerRadius   = p.cornerRadius
        resampleImages = p.resampleImages
    }

    private func createInDesignGallery() {
        let name = imageFiles.first.map { $0.url.deletingPathExtension().lastPathComponent } ?? "Gallery"
        isIDProcessing = true
        let snap = effectiveImageStates, s = settings

        Task {
            do {
                try await GalleryInDesignService.shared.createGallery(
                    images: snap, settings: s, outputName: name
                )
                await MainActor.run {
                    isIDProcessing = false
                    appState.logSuccess("InDesign galerie otevřena v InDesignu (\(name)_gallery)")
                }
            } catch {
                await MainActor.run {
                    isIDProcessing = false
                    errorMessage = error.localizedDescription
                    showError    = true
                }
            }
        }
    }
}

// MARK: - Page Preview

struct GalleryPagePreview: View {
    let layout:        GalleryLayout
    let settings:      GallerySettings
    @Binding var imageStates: [GalleryImageState]
    @Binding var activeID:    UUID?
    let page:          Int
    let availableSize: CGSize
    var onDuplicateImage: (UUID) -> Void = { _ in }
    var onRemoveImage:    (UUID) -> Void = { _ in }

    // Inline editace popisku
    @State private var editingLabelID:    UUID?   = nil
    @State private var editingLabelText:  String  = ""
    @FocusState private var labelFocused: Bool

    private var scale: CGFloat {
        let sx = availableSize.width  * 0.88 / CGFloat(layout.paperW)
        let sy = availableSize.height * 0.88 / CGFloat(layout.paperH)
        return min(sx, sy)
    }

    private var pageW: CGFloat { CGFloat(layout.paperW) * scale }
    private var pageH: CGFloat { CGFloat(layout.paperH) * scale }

    var body: some View {
        let indices = layout.imageIndices(onPage: page, imageCount: imageStates.count)
        // UUID jako stabilní identita – ForEach nereusuje view pro jiný obrázek po vložení kopie
        let entries = indices.enumerated().map {
            (stateID: imageStates[$0.element].id, localIdx: $0.offset, globalIdx: $0.element)
        }

        ZStack {
            // Pozadí stránky
            Rectangle()
                .fill(settings.pageBackgroundColor)
                .frame(width: pageW, height: pageH)
                .shadow(color: .black.opacity(0.25), radius: 6, x: 3, y: 3)
                .overlay(alignment: .topLeading) {
                    // Rámečky obrázků
                    ZStack(alignment: .topLeading) {
                        ForEach(entries, id: \.stateID) { entry in
                            let rect = layout.cellRectPx(localIndex: entry.localIdx, scale: scale)
                            GalleryFrameView(
                                // Binding přes UUID – odolný vůči posunutí indexů po vložení
                                state: Binding(
                                    get: {
                                        imageStates.first(where: { $0.id == entry.stateID })
                                            ?? imageStates[entry.globalIdx]
                                    },
                                    set: { newVal in
                                        if let idx = imageStates.firstIndex(where: { $0.id == entry.stateID }) {
                                            imageStates[idx] = newVal
                                        }
                                    }
                                ),
                                isActive: activeID == entry.stateID,
                                frameSize: rect.size,
                                onActivate: {
                                    activeID = (activeID == entry.stateID) ? nil : entry.stateID
                                },
                                onDuplicate: { sourceID in onDuplicateImage(sourceID) },
                                onRemove:    { sourceID in onRemoveImage(sourceID) },
                                showLabelEdit: settings.showImageLabel,
                                onEditLabel: {
                                    let lbl = imageStates[entry.globalIdx].displayLabel
                                    editingLabelID   = entry.stateID
                                    editingLabelText = lbl
                                    DispatchQueue.main.async { labelFocused = true }
                                },
                                borderEnabled: settings.addFrameBorder,
                                borderWidth:   settings.frameBorderWidth,
                                borderColor:   settings.frameBorderColor,
                                shadowEnabled: settings.addFrameShadow,
                                shadowOffsetX: settings.shadowOffsetX * Double(scale),
                                shadowOffsetY: settings.shadowOffsetY * Double(scale),
                                shadowBlurPx:  settings.shadowBlur    * Double(scale),
                                shadowOpacity: settings.shadowOpacity / 100.0,
                                shadowColor:     settings.shadowColor,
                                imageEffect:       settings.imageEffect,
                                duotoneShadow:     settings.duotoneShadowColor,
                                duotoneHighlight:  settings.duotoneHighlightColor,
                                featherEdges:      settings.featherEdges,
                                featherAmount:     settings.featherAmount,
                                featherBackground: settings.pageBackgroundColor,
                                cornerRadiusPx:    settings.roundCorners ? settings.cornerRadius * Double(scale) : 0
                            )
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(true)
                        }
                    }
                    .frame(width: pageW, height: pageH, alignment: .topLeading)
                    // Ořezové značky
                    .overlay(alignment: .topLeading) {
                        if settings.addCropMarks {
                            ZStack(alignment: .topLeading) {
                                ForEach(Array(indices.enumerated()), id: \.offset) { localIdx, _ in
                                    CropMarkOverlay(rect: layout.cellRectPx(localIndex: localIdx, scale: scale),
                                                    markLen: 5, offset: 2)
                                }
                            }
                            .frame(width: pageW, height: pageH, alignment: .topLeading)
                        }
                    }
                    // Popisky (pod obrázkem nebo uvnitř) — kliknutím vstup do editace
                    .overlay(alignment: .topLeading) {
                        if settings.showImageLabel {
                            ZStack(alignment: .topLeading) {
                                ForEach(Array(entries.enumerated()), id: \.element.stateID) { _, entry in
                                    let imgRect  = layout.cellRectPx(localIndex: entry.localIdx, scale: scale)
                                    let lh       = CGFloat(settings.labelAreaHeightMM) * scale
                                    let lRect: CGRect = settings.labelInside
                                        ? CGRect(x: imgRect.minX, y: imgRect.maxY - lh,
                                                 width: imgRect.width, height: lh)
                                        : (layout.labelRectPx(localIndex: entry.localIdx, scale: scale)
                                           ?? CGRect(x: imgRect.minX, y: imgRect.maxY,
                                                     width: imgRect.width, height: lh))
                                    let currentLabel = imageStates[entry.globalIdx].displayLabel
                                    let displaySize  = CGFloat(settings.labelFontSize) * scale / 2.834645669
                                    let isEditing    = editingLabelID == entry.stateID

                                    if isEditing {
                                        // Inline textové pole
                                        TextField("", text: $editingLabelText)
                                            .font(.custom(settings.labelFontName, size: displaySize))
                                            .multilineTextAlignment(settings.labelAlignment.textAlignment)
                                            .textFieldStyle(.plain)
                                            .padding(.horizontal, 2)
                                            .frame(width: lRect.width, height: lRect.height)
                                            .background(settings.labelBackground.opacity(0.95))
                                            .foregroundColor(settings.labelColor)
                                            .overlay(RoundedRectangle(cornerRadius: 2)
                                                .stroke(Color.accentColor, lineWidth: 1))
                                            .offset(x: lRect.minX, y: lRect.minY)
                                            .focused($labelFocused)
                                            .onSubmit { commitLabelEdit(entry.stateID) }
                                            .onExitCommand { commitLabelEdit(nil) }
                                            .onChange(of: labelFocused) { focused in
                                                if !focused { commitLabelEdit(editingLabelID) }
                                            }
                                    } else {
                                        // Zobrazení
                                        Text(currentLabel)
                                            .font(.custom(settings.labelFontName, size: displaySize))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.5)
                                            .frame(width: lRect.width, height: lRect.height,
                                                   alignment: settings.labelAlignment.swiftUIAlignment)
                                            .background(settings.labelBackground)
                                            .foregroundColor(settings.labelColor)
                                            .offset(x: lRect.minX, y: lRect.minY)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                            .frame(width: pageW, height: pageH, alignment: .topLeading)
                        }
                    }
                }
        }
        .frame(width: pageW, height: pageH)
        .position(x: availableSize.width / 2, y: availableSize.height / 2)
    }

    /// Uloží editovaný popisek a opustí editační režim.
    private func commitLabelEdit(_ id: UUID?) {
        if let editID = editingLabelID,
           let idx = imageStates.firstIndex(where: { $0.id == editID }) {
            var arr = imageStates
            arr[idx].customLabel = editingLabelText.isEmpty ? nil : editingLabelText
            imageStates = arr
        }
        editingLabelID = nil
    }
}

// MARK: - Font Picker Popover

struct FontPickerButton: View {
    @Binding var fontName: String
    @State private var showPicker = false
    @State private var search:    String = ""

    private var allFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
    }
    private var filtered: [String] {
        search.isEmpty ? allFamilies
            : allFamilies.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Button {
            search = ""
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(fontName)
                    .font(.custom(fontName, size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Hledat písmo…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                Divider()
                ScrollViewReader { proxy in
                    List(filtered, id: \.self) { name in
                        Button {
                            fontName = name
                            showPicker = false
                        } label: {
                            HStack {
                                Text(name)
                                    .font(.custom(name, size: 14))
                                    .lineLimit(1)
                                Spacer()
                                if name == fontName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .font(.caption)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(name)
                    }
                    .frame(height: 300)
                    .onAppear {
                        if filtered.contains(fontName) {
                            proxy.scrollTo(fontName, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 240)
        }
    }
}

// MARK: - Frame View

// MARK: - Effect view modifier (náhled)

private struct GalleryEffectModifier: ViewModifier {
    let effect: GalleryImageEffect
    var duotoneShadow:    Color = Color(red: 0.04, green: 0.18, blue: 0.42)
    var duotoneHighlight: Color = Color(red: 1.00, green: 0.60, blue: 0.15)

    func body(content: Content) -> some View {
        content
            .grayscale(grayscaleAmount)
            .saturation(saturationAmount)
            .contrast(contrastAmount)
            .brightness(brightnessAmount)
            .colorMultiply(tintColor)
    }

    private var grayscaleAmount: Double {
        switch effect {
        case .grayscale: return 1.0
        case .sepia:     return 1.0
        case .oldPhoto:  return 0.85
        case .duotone:   return 1.0
        default:         return 0.0
        }
    }
    private var saturationAmount: Double {
        switch effect {
        case .vivid:  return 1.6
        case .faded:  return 0.65
        default:      return 1.0
        }
    }
    private var contrastAmount: Double {
        switch effect {
        case .vivid:    return 1.1
        case .faded:    return 0.82
        case .oldPhoto: return 0.88
        default:        return 1.0
        }
    }
    private var brightnessAmount: Double {
        switch effect {
        case .faded:    return 0.05
        case .oldPhoto: return -0.02
        default:        return 0.0
        }
    }
    private var tintColor: Color {
        switch effect {
        case .sepia:    return Color(red: 1.0,  green: 0.86, blue: 0.65)
        case .oldPhoto: return Color(red: 1.05, green: 0.90, blue: 0.70)
        case .coolTone: return Color(red: 0.84, green: 0.93, blue: 1.12)
        case .duotone:  return duotoneHighlight   // přibližný náhled světel
        default:        return .white
        }
    }
}

// MARK: - Frame View

struct GalleryFrameView: View {
    @Binding var state: GalleryImageState
    let isActive:  Bool
    let frameSize: CGSize
    var onActivate:   () -> Void      = { }
    var onDuplicate:  (UUID) -> Void = { _ in }
    var onRemove:     (UUID) -> Void = { _ in }
    var showLabelEdit: Bool          = false
    var onEditLabel:  () -> Void     = { }
    var borderEnabled: Bool  = false
    var borderWidth:   Double = 0.5
    var borderColor:   Color  = .black
    var shadowEnabled: Bool  = false
    var shadowOffsetX: Double = 2.0   // screen px
    var shadowOffsetY: Double = 2.0   // screen px
    var shadowBlurPx:  Double = 3.0   // screen px
    var shadowOpacity: Double = 0.5
    var shadowColor:   Color  = .black
    var imageEffect:        GalleryImageEffect = .none
    var duotoneShadow:      Color  = Color(red: 0.04, green: 0.18, blue: 0.42)
    var duotoneHighlight:   Color  = Color(red: 1.00, green: 0.60, blue: 0.15)
    var featherEdges:       Bool   = false
    var featherAmount:      Double = 20.0  // % šířky/výšky
    var featherBackground:  Color  = .white
    var cornerRadiusPx:     Double = 0  // screen px, 0 = bez zakulacení

    @State private var lastPan:    CGSize  = .zero
    @State private var loadedImg:  NSImage? = nil

    // MARK: Layout maths

    /// Přirozená velikost obrázku (z NSImage)
    private var natural: CGSize { loadedImg?.size ?? CGSize(width: 1, height: 1) }

    /// Automatická rotace: portrait obrázek do landscape rámečku nebo naopak
    private var autoRotDeg: Double {
        let imgLand  = natural.width  > natural.height
        let cellLand = frameSize.width > frameSize.height
        return (imgLand != cellLand) ? 90 : 0
    }

    /// Celková vizuální rotace (auto + manuální kroky po 90°)
    private var totalRotDeg: Double {
        (autoRotDeg + Double(state.extraRotation)).truncatingRemainder(dividingBy: 360)
    }

    /// Rotace 90° nebo 270° prohodí šířku a výšku efektivního rozměru
    private var rotSwapsDims: Bool { Int(totalRotDeg) % 180 != 0 }

    /// Efektivní rozměry obrázku v souřadnicích rámečku (po rotaci)
    private var effective: CGSize {
        rotSwapsDims
            ? CGSize(width: natural.height, height: natural.width)
            : natural
    }

    /// Základní měřítko pro zoom=1:
    ///   fill (výchozí) – obrázek pokryje celý rámeček (ořez), žádné bílé místo
    ///   fit            – obrázek se vejde celý do rámečku (bílé místo možné)
    private var baseScale: CGFloat {
        guard effective.width > 0, effective.height > 0 else { return 1 }
        if state.fitMode {
            return min(frameSize.width / effective.width, frameSize.height / effective.height)
        } else {
            return max(frameSize.width / effective.width, frameSize.height / effective.height)
        }
    }

    /// Vykreslená velikost v souřadnicích rámečku při aktuálním zoomu
    private var rendered: CGSize {
        let s = baseScale * CGFloat(state.zoom)
        return CGSize(width: effective.width * s, height: effective.height * s)
    }

    /// Maximální posun v každé ose (half of overflow) — nikdy záporné
    private var maxPan: CGSize {
        CGSize(
            width:  max(0, (rendered.width  - frameSize.width)  / 2),
            height: max(0, (rendered.height - frameSize.height) / 2)
        )
    }

    /// Ořeže pan tak, aby obrázek nikdy nevytvořil bílé místo (screen-space)
    private func clamped(_ pan: CGSize) -> CGSize {
        let m = maxPan
        return CGSize(
            width:  m.width  > 0 ? max(-m.width,  min(m.width,  pan.width))  : 0,
            height: m.height > 0 ? max(-m.height, min(m.height, pan.height)) : 0
        )
    }

    /// Zobrazovací posun v screen pixelech z normalizovaného panOffset (frakce × maxPan)
    private var screenPanOffset: CGSize {
        let m = maxPan
        return CGSize(width: state.panOffset.width * m.width,
                      height: state.panOffset.height * m.height)
    }

    /// Převede screen-space posun na normalizovaný (frakce maxPanu, rozsah ±1)
    private func normalizedPan(fromScreen screenPan: CGSize) -> CGSize {
        let m = maxPan
        return CGSize(
            width:  m.width  > 0 ? max(-1, min(1, screenPan.width  / m.width))  : 0,
            height: m.height > 0 ? max(-1, min(1, screenPan.height / m.height)) : 0
        )
    }

    /// Podíl obrázku skrytý ořezem (0 = nic, 1 = vše). Relevantní jen ve fill módu.
    private var hiddenFraction: Double {
        guard !state.fitMode else { return 0 }
        let r = rendered
        let f = frameSize
        if r.width <= f.width && r.height <= f.height { return 0 }
        let visible = min(r.width, f.width) * min(r.height, f.height)
        let total   = r.width * r.height
        return max(0, 1.0 - Double(visible / total))
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // V fit módu použij zvolenou barvu pozadí, jinak šedé
            state.fitMode ? state.fitBackground : Color.gray.opacity(0.10)

            if let img = loadedImg {
                let s = baseScale * CGFloat(state.zoom)
                // Jednotný přístup: frame na přirozené rozměry, pak rotationEffect (layout rect se nemění)
                Image(nsImage: img)
                    .resizable()
                    .frame(width: natural.width * s, height: natural.height * s)
                    .rotationEffect(.degrees(totalRotDeg))
                    .offset(screenPanOffset)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadiusPx))
        .overlay {
            if featherEdges && featherAmount > 0 {
                let f = featherAmount / 100.0
                ZStack {
                    // levý okraj
                    LinearGradient(colors: [featherBackground, .clear],
                                   startPoint: .leading,
                                   endPoint:   UnitPoint(x: f, y: 0.5))
                    // pravý okraj
                    LinearGradient(colors: [.clear, featherBackground],
                                   startPoint: UnitPoint(x: 1 - f, y: 0.5),
                                   endPoint:   .trailing)
                    // horní okraj
                    LinearGradient(colors: [featherBackground, .clear],
                                   startPoint: .top,
                                   endPoint:   UnitPoint(x: 0.5, y: f))
                    // dolní okraj
                    LinearGradient(colors: [.clear, featherBackground],
                                   startPoint: UnitPoint(x: 0.5, y: 1 - f),
                                   endPoint:   .bottom)
                }
                .allowsHitTesting(false)
            }
        }
        .modifier(GalleryEffectModifier(
            effect: imageEffect,
            duotoneShadow: duotoneShadow,
            duotoneHighlight: duotoneHighlight
        ))
        // Stín za rámečkem
        .shadow(
            color: shadowEnabled ? shadowColor.opacity(shadowOpacity) : .clear,
            radius: CGFloat(shadowBlurPx / 2),
            x: CGFloat(shadowOffsetX),
            y: CGFloat(shadowOffsetY)
        )
        // Linka okolo rámečku z nastavení (addFrameBorder)
        .overlay(alignment: .center) {
            if borderEnabled {
                RoundedRectangle(cornerRadius: cornerRadiusPx)
                    .stroke(borderColor, lineWidth: CGFloat(borderWidth))
            }
        }
        // Selection indicator (nad linkou nastavení)
        .overlay(
            Rectangle().stroke(
                isActive ? Color.accentColor : Color.clear,
                lineWidth: isActive ? 2 : 0
            )
        )
        // Vizualizace přesahu: šedý průhledný overlay na ořezaných částech obrázku
        .overlay(alignment: .center) {
            if isActive && !state.fitMode, let img = loadedImg,
               rendered.width > frameSize.width + 1 || rendered.height > frameSize.height + 1 {
                let s   = baseScale * CGFloat(state.zoom)
                let spx = screenPanOffset
                ZStack {
                    // Celý obrázek bez ořezu
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: natural.width * s, height: natural.height * s)
                        .rotationEffect(.degrees(totalRotDeg))
                        .offset(spx)
                    // „Okno" rámečku – průhledné dírkování, aby se přesah zobrazil jen vně
                    Rectangle()
                        .frame(width: frameSize.width, height: frameSize.height)
                        .blendMode(.destinationOut)
                }
                .opacity(0.3)
                .compositingGroup()
                .allowsHitTesting(false)
            }
        }
        // Transparentní tap vrstva — aktivuje rámeček (pod sliderem a tlačítky)
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onActivate() }
        }
        // Posuvník zoomu — nad tap vrstvou, takže slider interakce nejsou blokované
        .overlay(alignment: .center) {
            if isActive && !state.fitMode {
                GalleryZoomSlider(zoom: Binding(
                    get: { state.zoom },
                    set: { z in
                        state.zoom = z
                        // panOffset je normalizovaná frakce → vždy platná; jen přepočteme lastPan
                        lastPan = screenPanOffset
                    }
                ))
            }
        }
        // Tlačítka — vždy viditelná v pravém horním rohu
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                // Barva pozadí — jen v fit módu
                if state.fitMode {
                    ColorPicker("", selection: $state.fitBackground, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 20, height: 20)
                        .help("Barva pozadí rámečku")
                }
                // Výstraha: velký ořez (> 15 % obrázku schováno)
                if hiddenFraction > 0.15 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.yellow)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.45)))
                        .help("Ořezáno \(Int(hiddenFraction * 100)) % obrázku")
                }
                // Rotace o 90° CW
                frameIconButton(
                    icon: "rotate.right",
                    tinted: false,
                    help: "Otočit o 90° doprava"
                ) {
                    state.extraRotation = (state.extraRotation + 90) % 360
                    state.panOffset = .zero
                    lastPan         = .zero
                }
                // Editovat popisek — jen když je popisek zapnutý
                if showLabelEdit {
                    frameIconButton(
                        icon: "character.cursor.ibeam",
                        tinted: false,
                        help: "Upravit text popisku"
                    ) {
                        onEditLabel()
                    }
                }
                // Odebrat obrázek z galerie
                frameIconButton(
                    icon: "minus.square",
                    tinted: false,
                    help: "Odebrat obrázek z galerie"
                ) {
                    onRemove(state.id)
                }
                // Duplikovat obrázek
                frameIconButton(
                    icon: "plus.square.on.square",
                    tinted: false,
                    help: "Duplikovat obrázek v galerii"
                ) {
                    onDuplicate(state.id)
                }
                // Fit / Fill toggle
                frameIconButton(
                    icon: state.fitMode
                        ? "arrow.up.left.and.arrow.down.right"
                        : "arrow.down.right.and.arrow.up.left",
                    tinted: state.fitMode,
                    help: state.fitMode ? "Přepnout na Fill (vyplnit rámeček)" : "Přepnout na Fit (celý obrázek)"
                ) {
                    state.fitMode.toggle()
                    state.panOffset = .zero
                    state.zoom      = 1.0
                    lastPan         = .zero
                }
            }
            .padding(4)
            .allowsHitTesting(true)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { val in
                    guard !state.fitMode else { return }
                    let proposed = CGSize(
                        width:  lastPan.width  + val.translation.width,
                        height: lastPan.height + val.translation.height
                    )
                    state.panOffset = normalizedPan(fromScreen: clamped(proposed))
                }
                .onEnded { _ in lastPan = screenPanOffset }
        )
        .onAppear { loadThumbnail() }
    }

    /// Malé ikonové tlačítko pro overlay rámečku
    private func frameIconButton(
        icon: String, tinted: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tinted ? Color.accentColor.opacity(0.85) : Color.black.opacity(0.45))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func loadThumbnail() {
        let url = state.url
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            // Omezená velikost pro náhled (max 1200 px)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceShouldCache: false
            ]
            let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
            let nsImg = cgImg.map { NSImage(cgImage: $0, size: .zero) }
            DispatchQueue.main.async { loadedImg = nsImg }
        }
    }
}

// MARK: - Zoom Slider

/// Posuvník zoomu, který se zobrazí uprostřed aktivního rámečku.
struct GalleryZoomSlider: View {
    @Binding var zoom: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Slider(value: $zoom, in: 1.0...5.0)
                    .frame(width: 110)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(String(format: "%.1f×", zoom))
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Crop mark overlay

struct CropMarkOverlay: View {
    let rect:    CGRect
    let markLen: CGFloat
    let offset:  CGFloat

    var body: some View {
        Canvas { ctx, _ in ctx.stroke(marks(), with: .color(.gray.opacity(0.55)), lineWidth: 0.5) }
            .frame(width: rect.maxX + markLen + offset + 4,
                   height: rect.maxY + markLen + offset + 4)
    }

    private func marks() -> Path {
        var p = Path()
        for (pt, flip) in [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: -1, y: -1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x:  1, y: -1)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: -1, y:  1)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x:  1, y:  1)),
        ] {
            p.move(to:    CGPoint(x: pt.x + flip.x * offset, y: pt.y))
            p.addLine(to: CGPoint(x: pt.x + flip.x * (offset + markLen), y: pt.y))
            p.move(to:    CGPoint(x: pt.x, y: pt.y + flip.y * offset))
            p.addLine(to: CGPoint(x: pt.x, y: pt.y + flip.y * (offset + markLen)))
        }
        return p
    }
}

// MARK: - Scroll wheel (pro zoom kolečkem myši mimo slider)

struct ScrollWheelModifier: ViewModifier {
    let handler: (Double) -> Void
    func body(content: Content) -> some View {
        content.background(ScrollWheelView(handler: handler))
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let handler: (Double) -> Void
    func makeNSView(context: Context) -> _ScrollWheelNSView {
        let v = _ScrollWheelNSView(); v.handler = handler; return v
    }
    func updateNSView(_ v: _ScrollWheelNSView, context: Context) { v.handler = handler }
}

class _ScrollWheelNSView: NSView {
    var handler: ((Double) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) { handler?(Double(event.deltaY)) }
}

extension View {
    func onScrollWheel(_ handler: @escaping (Double) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

// MARK: - Window Size Saver

private struct WindowSizeSaverGallery: NSViewRepresentable {
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
                guard let w = window, let s = w.contentView?.frame.size else { return }
                self?.onResize?(s)
            }
        }
        deinit { if let obs = observer { NotificationCenter.default.removeObserver(obs) } }
    }
}
