//
//  InDesignImportDialog.swift
//  PrintManager
//
//  Dialog pro import vybraných souborů do Adobe InDesign.
//

import SwiftUI
import AppKit

struct InDesignImportDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    let files: [FileItem]

    // MARK: - Settings (AppStorage pro persistenci)

    @AppStorage("indesign.autoPageSize")   private var autoPageSize   = true
    @AppStorage("indesign.pageWidth")      private var pageWidth      = 210.0
    @AppStorage("indesign.pageHeight")     private var pageHeight     = 297.0
    @AppStorage("indesign.bleedLinked")    private var bleedLinked    = true
    @AppStorage("indesign.bleedAll")       private var bleedAll       = 3.0
    @AppStorage("indesign.bleedTop")       private var bleedTop       = 3.0
    @AppStorage("indesign.bleedBottom")    private var bleedBottom    = 3.0
    @AppStorage("indesign.bleedLeft")      private var bleedLeft      = 3.0
    @AppStorage("indesign.bleedRight")     private var bleedRight     = 3.0
    @AppStorage("indesign.marginLinked")   private var marginLinked   = true
    @AppStorage("indesign.marginAll")      private var marginAll      = 0.0
    @AppStorage("indesign.marginTop")      private var marginTop      = 0.0
    @AppStorage("indesign.marginBottom")   private var marginBottom   = 0.0
    @AppStorage("indesign.marginLeft")     private var marginLeft     = 0.0
    @AppStorage("indesign.marginRight")    private var marginRight    = 0.0
    @AppStorage("indesign.fit")            private var fitRaw         = InDesignFit.fillProportionally.rawValue
    @AppStorage("indesign.useExisting")    private var useExistingDoc = false
    @AppStorage("indesign.facingPages")    private var facingPages    = false
    @AppStorage("indesign.pdfCrop")        private var pdfCropRaw     = PDFCropOption.bleedBox.rawValue
    @AppStorage("indesign.pdfTransparent") private var pdfTransparent = false
    @AppStorage("indesign.pdfPageRange")   private var pdfPageRange   = ""  // "" = All

    @State private var fileInfos: [InDesignFileInfo] = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private let service = InDesignService()

    private var fit: Binding<InDesignFit> {
        Binding(get: { InDesignFit(rawValue: fitRaw) ?? .fillProportionally },
                set: { fitRaw = $0.rawValue })
    }
    private var pdfCrop: Binding<PDFCropOption> {
        Binding(get: { PDFCropOption(rawValue: pdfCropRaw) ?? .bleedBox },
                set: { pdfCropRaw = $0.rawValue })
    }

    private var detectedSize: CGSize? { fileInfos.first?.detectedSize }
    private var hasPDF: Bool { fileInfos.contains { $0.url.pathExtension.lowercased() == "pdf" } }

    private var settings: InDesignImportSettings {
        InDesignImportSettings(
            autoPageSize: autoPageSize,
            pageWidth: pageWidth, pageHeight: pageHeight,
            bleedLinked: bleedLinked, bleedAll: bleedAll,
            bleedTop: bleedTop, bleedBottom: bleedBottom,
            bleedLeft: bleedLeft, bleedRight: bleedRight,
            marginLinked: marginLinked, marginAll: marginAll,
            marginTop: marginTop, marginBottom: marginBottom,
            marginLeft: marginLeft, marginRight: marginRight,
            fit: fit.wrappedValue,
            useExistingDoc: useExistingDoc,
            facingPages: facingPages,
            pdfCropTo: pdfCrop.wrappedValue,
            pdfTransparentBg: pdfTransparent,
            pdfPageFilter: parsePageRange(pdfPageRange)
        )
    }

    /// Parsuje "1-3, 5, 7" → [1,2,3,5,7]. Prázdný string → [] (= všechny stránky).
    private func parsePageRange(_ range: String) -> [Int] {
        guard !range.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var pages = Set<Int>()
        for part in range.components(separatedBy: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.contains("-") {
                let bounds = t.components(separatedBy: "-")
                if let a = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                   let b = Int((bounds.last ?? "").trimmingCharacters(in: .whitespaces)), a <= b {
                    (a...b).forEach { pages.insert($0) }
                }
            } else if let n = Int(t) { pages.insert(n) }
        }
        return pages.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Hlavička ──────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Import to InDesign")
                        .font(.headline)
                    Text("\(files.count) \(files.count == 1 ? "soubor" : files.count < 5 ? "soubory" : "souborů")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // ── Obsah ──────────────────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // Soubory
                    fileListSection

                    Divider()

                    // Dokument
                    documentSection

                    Divider()

                    // Stránka
                    pageSizeSection

                    Divider()

                    // Spadávka
                    bleedSection

                    Divider()

                    // Marginy
                    marginSection

                    Divider()

                    // Přizpůsobení
                    fitSection

                    // PDF Options (jen pokud jsou vybrány PDF soubory)
                    if hasPDF {
                        Divider()
                        pdfOptionsSection
                    }
                }
                .padding(20)
            }

            Divider()

            // ── Patička ───────────────────────────────────────────────────────
            VStack(spacing: 6) {
                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let status = statusMessage {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if !service.isAvailable() {
                        Label("InDesign nenalezen", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button("Zrušit") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    if isImporting { ProgressView().scaleEffect(0.75) }
                    Button("Importovat do InDesign") { doImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting || files.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 500, idealWidth: 540, maxWidth: 600,
               minHeight: 500, idealHeight: 640, maxHeight: 800)
        .onAppear { loadFileInfos() }
    }

    // MARK: - Sekce: Soubory

    @ViewBuilder
    private var fileListSection: some View {
        sectionHeader("Soubory", icon: "doc.on.doc")

        VStack(spacing: 3) {
            ForEach(fileInfos, id: \.url) { fi in
                HStack(spacing: 8) {
                    Image(systemName: fileIcon(fi.url))
                        .foregroundColor(.accentColor)
                        .frame(width: 16)
                    Text(fi.url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    if fi.pageCount > 1 {
                        Text("\(fi.pageCount) stran")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(3)
                    }
                    if let sz = fi.detectedSize {
                        Text(String(format: "%.0f × %.0f mm", sz.width, sz.height))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(DS.Colors.controlBackground)
        .cornerRadius(DS.Radius.small)
    }

    // MARK: - Sekce: Dokument

    @ViewBuilder
    private var documentSection: some View {
        sectionHeader("Dokument", icon: "doc.badge.plus")

        HStack(spacing: 16) {
            Button {
                useExistingDoc = false
            } label: {
                Label("Nový dokument",
                      systemImage: useExistingDoc ? "circle" : "circle.inset.filled")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundColor(useExistingDoc ? .secondary : .primary)

            Button {
                useExistingDoc = true
            } label: {
                Label("Přidat do otevřeného",
                      systemImage: useExistingDoc ? "circle.inset.filled" : "circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundColor(useExistingDoc ? .primary : .secondary)
        }

        Toggle(isOn: $facingPages) {
            Text("Facing Pages (protilehlé stránky)")
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .disabled(useExistingDoc)
    }

    // MARK: - Sekce: Stránka

    @ViewBuilder
    private var pageSizeSection: some View {
        sectionHeader("Velikost stránky", icon: "rectangle.portrait")

        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automaticky z souboru", isOn: $autoPageSize)
                .font(.caption)
                .onChange(of: autoPageSize) { on in
                    if on, let sz = detectedSize {
                        pageWidth  = sz.width
                        pageHeight = sz.height
                    }
                }

            if !autoPageSize {
                HStack(spacing: 12) {
                    mmField("Šířka", value: $pageWidth)
                    mmField("Výška", value: $pageHeight)
                    Divider().frame(height: 24)
                    Button("A4") { pageWidth = 210; pageHeight = 297 }
                        .font(.caption).buttonStyle(.bordered)
                    Button("A3") { pageWidth = 297; pageHeight = 420 }
                        .font(.caption).buttonStyle(.bordered)
                    Button("⇄") {
                        swap(&pageWidth, &pageHeight)
                    }
                    .font(.caption).buttonStyle(.bordered)
                    .help("Otočit na šířku / výšku")
                }
            } else if let sz = detectedSize {
                Text(String(format: "Detekováno: %.1f × %.1f mm", sz.width, sz.height))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Sekce: Spadávka

    @ViewBuilder
    private var bleedSection: some View {
        HStack {
            sectionHeader("Spadávka (bleed)", icon: "crop")
            Spacer()
            Toggle("", isOn: $bleedLinked)
                .toggleStyle(.checkbox)
                .help("Všechny strany stejně")
            Text("vázat").font(.caption2).foregroundColor(.secondary)
        }

        if bleedLinked {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .foregroundColor(.secondary).frame(width: 16)
                mmField("Všechny strany", value: $bleedAll)
                    .onChange(of: bleedAll) { v in
                        bleedTop = v; bleedBottom = v; bleedLeft = v; bleedRight = v
                    }
            }
        } else {
            trblFields(
                top: $bleedTop, right: $bleedRight,
                bottom: $bleedBottom, left: $bleedLeft
            )
        }
    }

    // MARK: - Sekce: Marginy

    @ViewBuilder
    private var marginSection: some View {
        HStack {
            sectionHeader("Marginy", icon: "rectangle.inset.filled")
            Spacer()
            Toggle("", isOn: $marginLinked)
                .toggleStyle(.checkbox)
                .help("Všechny strany stejně")
            Text("vázat").font(.caption2).foregroundColor(.secondary)
        }

        if marginLinked {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .foregroundColor(.secondary).frame(width: 16)
                mmField("Všechny strany", value: $marginAll)
                    .onChange(of: marginAll) { v in
                        marginTop = v; marginBottom = v; marginLeft = v; marginRight = v
                    }
            }
        } else {
            trblFields(
                top: $marginTop, right: $marginRight,
                bottom: $marginBottom, left: $marginLeft
            )
        }
    }

    // MARK: - Sekce: Přizpůsobení

    @ViewBuilder
    private var fitSection: some View {
        sectionHeader("Přizpůsobení obsahu", icon: "arrow.up.left.and.arrow.down.right")

        HStack(spacing: 8) {
            ForEach(InDesignFit.allCases) { option in
                fitButton(option)
            }
        }
    }

    // MARK: - Sekce: PDF Options

    @ViewBuilder
    private var pdfOptionsSection: some View {
        sectionHeader("PDF Options", icon: "doc.richtext")

        // Crop to
        HStack(spacing: 10) {
            Text("Crop to")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Picker("", selection: pdfCrop) {
                ForEach(PDFCropOption.allCases) { opt in
                    Text(boxLabel(opt)).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 230)
        }

        // Pages
        VStack(alignment: .leading, spacing: 6) {
            Text("Stránky")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button {
                    pdfPageRange = ""
                } label: {
                    Label("Všechny", systemImage: pdfPageRange.isEmpty ? "circle.inset.filled" : "circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(pdfPageRange.isEmpty ? .primary : .secondary)

                Button {
                    if pdfPageRange.isEmpty { pdfPageRange = "1" }
                } label: {
                    Label("Rozsah:", systemImage: pdfPageRange.isEmpty ? "circle" : "circle.inset.filled")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(pdfPageRange.isEmpty ? .secondary : .primary)

                if !pdfPageRange.isEmpty {
                    TextField("např. 1-3, 5", text: $pdfPageRange)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .font(.caption)
                    let parsed = parsePageRange(pdfPageRange)
                    if !parsed.isEmpty {
                        Text("(\(parsed.count) stran)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }

        // Transparent background
        Toggle(isOn: $pdfTransparent) {
            Text("Průhledné pozadí")
                .font(.caption)
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private func fitButton(_ option: InDesignFit) -> some View {
        let isSelected = fit.wrappedValue == option
        Button {
            fit.wrappedValue = option
        } label: {
            VStack(spacing: 4) {
                Image(systemName: option.icon)
                    .font(.system(size: 16))
                Text(option.label)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : DS.Colors.controlBackground)
            .cornerRadius(DS.Radius.small)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.borderless)
        .foregroundColor(isSelected ? .accentColor : .primary)
        .help(option.label)
    }

    // MARK: - Pomocné view buildy

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func mmField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField("", value: value, formatter: mmFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Text("mm").font(.caption2).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func trblFields(
        top: Binding<Double>, right: Binding<Double>,
        bottom: Binding<Double>, left: Binding<Double>
    ) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("Nahoře").font(.caption2).foregroundColor(.secondary)
                TextField("", value: top, formatter: mmFormatter)
                    .textFieldStyle(.roundedBorder).frame(width: 58)
            }
            VStack(spacing: 4) {
                Text("Vpravo").font(.caption2).foregroundColor(.secondary)
                TextField("", value: right, formatter: mmFormatter)
                    .textFieldStyle(.roundedBorder).frame(width: 58)
            }
            VStack(spacing: 4) {
                Text("Dole").font(.caption2).foregroundColor(.secondary)
                TextField("", value: bottom, formatter: mmFormatter)
                    .textFieldStyle(.roundedBorder).frame(width: 58)
            }
            VStack(spacing: 4) {
                Text("Vlevo").font(.caption2).foregroundColor(.secondary)
                TextField("", value: left, formatter: mmFormatter)
                    .textFieldStyle(.roundedBorder).frame(width: 58)
            }
        }
    }

    private var mmFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.minimum = 0
        return f
    }

    private func boxLabel(_ opt: PDFCropOption) -> String {
        guard let sz = fileInfos.first?.pdfBoxSizes[opt] else {
            return "\(opt.label) (—)"
        }
        return String(format: "%@ (%.0f × %.0f mm)", opt.label, sz.width, sz.height)
    }

    private func fileIcon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif", "heic":
            return "photo"
        default: return "doc"
        }
    }

    // MARK: - Load file infos

    private func loadFileInfos() {
        fileInfos = files.map { service.detectFileInfo(url: $0.url) }
        if autoPageSize, let sz = fileInfos.first?.detectedSize {
            pageWidth  = sz.width
            pageHeight = sz.height
        }
    }

    // MARK: - Import

    private func doImport() {
        isImporting   = true
        errorMessage  = nil
        statusMessage = nil

        let infos = fileInfos
        let s     = settings

        Task {
            do {
                try await service.import(files: infos, settings: s)
                await MainActor.run {
                    isImporting   = false
                    statusMessage = "Importováno \(infos.count) souborů do InDesign."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isPresented = false
                    }
                }
            } catch {
                await MainActor.run {
                    isImporting  = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
