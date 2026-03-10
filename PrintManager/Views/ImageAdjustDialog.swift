//
//  ImageAdjustDialog.swift
//  PrintManager
//
//  Dialog pro barevné a tónové korekce obrázků.
//  • Levý sloupec = seznam souborů; náhled zabírá veškerý volný prostor.
//  • Ovládání (dva sloupce) přilepeno ke spodku — žádný scroll.
//  • Spodní lišta: presety + akce v jednom řádku.
//  • Okno je měnitelné a pamatuje si velikost.
//

import SwiftUI
import AppKit

struct ImageAdjustDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let imageFiles: [FileItem]

    // Presety
    @ObservedObject private var presetsStore = ImageAdjustPresetsStore.shared
    @State private var selectedPresetID: UUID? = nil
    @State private var showSavePopover  = false
    @State private var newPresetName    = ""

    // Nastavení a náhled
    @State private var settings      = ImageAdjustSettings()
    @State private var selectedIndex = 0
    @State private var previewImage: NSImage?
    @State private var isRendering   = false
    @State private var renderTask: Task<Void, Never>?

    // Zpracování
    @State private var isProcessing  = false
    @State private var errorMessage: String?

    // Paměť velikosti okna
    @AppStorage("imgAdjW") private var savedW: Double = 800
    @AppStorage("imgAdjH") private var savedH: Double = 660

    var body: some View {
        VStack(spacing: 0) {

            // ── Záhlaví ────────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Úpravy obrazu")
                        .font(.headline)
                    Text(imageFiles.count == 1
                         ? imageFiles[0].name
                         : "\(imageFiles.count) obrázků — stejná nastavení pro všechny")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DS.Colors.windowBackground)

            Divider()

            // ── Náhled + seznam souborů (roztahuje se) ─────────────────
            HStack(spacing: 0) {
                fileListColumn
                Divider()
                previewArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // ── Ovládání — přilepeno ke spodku, bez scrollování ────────
            controlsArea

            Divider()

            // ── Odstranění pozadí ──────────────────────────────────────
            bgRemovalBar

            Divider()

            // ── Spodní lišta: presety + akce ───────────────────────────
            footerBar
        }
        .frame(minWidth: 640, minHeight: 500)
        .frame(idealWidth: savedW, idealHeight: savedH)
        .background(WindowResizeTracker { sz in
            savedW = sz.width
            savedH = sz.height
        })
        .onAppear { scheduleRender() }
    }

    // MARK: - Levý sloupec (soubory)

    private var fileListColumn: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(Array(imageFiles.enumerated()), id: \.element.id) { idx, file in
                    AdjFileRow(file: file, isSelected: idx == selectedIndex)
                        .onTapGesture {
                            selectedIndex = idx
                            scheduleRender()
                        }
                }
            }
            .padding(6)
        }
        .frame(width: 156)
        .background(DS.Colors.controlBackground)
    }

    // MARK: - Náhled

    private var previewArea: some View {
        ZStack {
            // Tmavé pozadí nebo šachovnice (průhlednost) podle režimu
            if settings.removeBG {
                CheckerboardView()
            } else {
                Color(white: 0.12)
            }
            if isRendering {
                VStack(spacing: 8) {
                    ProgressView().colorScheme(.dark)
                    Text("Renderuji…")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            } else if let img = previewImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white.opacity(0.18))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ovládání (dva sloupce, bez ScrollView)

    private var controlsArea: some View {
        HStack(alignment: .top, spacing: 0) {

            // ── Levý sloupec ───────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                ctrlSection("Tón", icon: "sun.max")
                adjRow("Expozice",  $settings.exposure,    -3...3,     "%.1f EV")
                adjRow("Jas",       $settings.brightness,  -0.5...0.5, "%.2f")
                adjRow("Kontrast",  $settings.contrast,    0.5...2.0,  "%.2f")

                ctrlDivider()

                ctrlSection("Rozsah tónů", icon: "circle.lefthalf.filled")
                adjRow("Stíny",     $settings.shadows,     0...1.0,    "%.2f")
                adjRow("Světla",    $settings.highlights,  0...1.0,    "%.2f")
                adjRow("Černý bod", $settings.blackPoint,  0...0.3,    "%.2f")
                adjRow("Bílý bod",  $settings.whitePoint,  0.7...1.0,  "%.2f")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // ── Pravý sloupec ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                ctrlSection("Barvy", icon: "paintpalette")
                adjRow("Sytost",       $settings.saturation,     0...2.0,    "%.2f")
                adjRow("Živost",       $settings.vibrance,       -1...1,     "%.2f")
                adjRow("Odstín",       $settings.hue,            -180...180, "%.0f°")
                adjRow("Teplota",      $settings.temperature,    -3000...3000,"%.0f K")

                ctrlDivider()

                ctrlSection("Detail", icon: "sparkles")
                adjRow("Ostrost",      $settings.sharpness,      0...2.0,    "%.1f")
                adjRow("Rozostření",   $settings.blur,           0...20,     "%.1f px")
                adjRow("Redukce šumu", $settings.noiseReduction, 0...0.10,   "%.3f")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(DS.Colors.controlBackground.opacity(0.4))
    }

    // MARK: - Spodní lišta (presety + akce)

    private var footerBar: some View {
        HStack(spacing: 8) {

            // Preset ikona
            Image(systemName: "dial.medium")
                .foregroundColor(.secondary)
                .font(.caption)

            // Picker presetů
            Group {
                if presetsStore.presets.isEmpty {
                    Text("Žádné presety")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 110, alignment: .leading)
                } else {
                    Picker("", selection: $selectedPresetID) {
                        Text("—").tag(Optional<UUID>(nil))
                        ForEach(presetsStore.presets) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 110)
                    .onChange(of: selectedPresetID) { id in
                        guard let id,
                              let p = presetsStore.presets.first(where: { $0.id == id })
                        else { return }
                        settings = p.settings
                        scheduleRender()
                    }
                }
            }

            // Uložit preset
            Button {
                newPresetName = presetsStore.presets
                    .first(where: { $0.id == selectedPresetID })?.name ?? ""
                showSavePopover = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Uložit aktuální nastavení jako preset")
            .popover(isPresented: $showSavePopover, arrowEdge: .top) {
                savePresetPopover
            }

            // Smazat preset
            Button {
                if let id = selectedPresetID,
                   let p  = presetsStore.presets.first(where: { $0.id == id }) {
                    presetsStore.delete(p)
                    selectedPresetID = nil
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .disabled(selectedPresetID == nil)
            .help("Smazat vybraný preset")

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Reset
            Button {
                settings = ImageAdjustSettings()
                selectedPresetID = nil
                scheduleRender()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(settings.isDefault)
            .help("Resetovat všechna nastavení")

            Spacer()

            // Chybová hláška
            if let err = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(1)
                }
            }

            Button("Zrušit") { isPresented = false }
                .keyboardShortcut(.cancelAction)

            if isProcessing {
                ProgressView().scaleEffect(0.7)
                Text("Zpracovávám…").font(.callout).foregroundColor(.secondary)
            } else {
                let label = settings.removeBG ? "Uložit PNG" : "Uložit kopie"
                Button(label) { applyToAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.isDefault)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(DS.Colors.controlBackground)
    }

    // MARK: - Lišta odstranění pozadí

    private var bgRemovalBar: some View {
        HStack(spacing: 10) {
            Toggle("Odstranit pozadí", isOn: $settings.removeBG)
                .toggleStyle(.checkbox)
                .onChange(of: settings.removeBG) { _ in scheduleRender() }

            if settings.removeBG {
                Picker("", selection: $settings.bgMethod) {
                    ForEach(BGRemovalMethod.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: settings.bgMethod) { _ in scheduleRender() }

                if settings.bgMethod == .colorKey {
                    ColorPicker("", selection: bgKeyColorBinding)
                        .labelsHidden()
                        .frame(width: 28)
                        .help("Barva pozadí k odstranění")

                    Text("Citlivost:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(value: $settings.bgKeyTolerance, in: 0...0.5)
                        .frame(width: 110)
                        .onChange(of: settings.bgKeyTolerance) { _ in scheduleRender() }

                    Text(String(format: "%.2f", settings.bgKeyTolerance))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 32)
                        .foregroundColor(.secondary)

                    // Detekovat barvu z rohů obrázku
                    Button {
                        guard selectedIndex < imageFiles.count,
                              let ci = CIImage(contentsOf: imageFiles[selectedIndex].url)
                        else { return }
                        let (r, g, b) = BackgroundRemovalService.shared.detectBGColor(ci)
                        settings.bgKeyR = Double(r)
                        settings.bgKeyG = Double(g)
                        settings.bgKeyB = Double(b)
                        scheduleRender()
                    } label: {
                        Image(systemName: "eyedropper")
                    }
                    .buttonStyle(.borderless)
                    .help("Automaticky detekovat barvu pozadí z rohů obrázku")
                }

                if settings.bgMethod == .vision && !BackgroundRemovalService.visionSupported {
                    Text("Vyžaduje macOS 12+")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(DS.Colors.controlBackground.opacity(0.5))
        .animation(.easeInOut(duration: 0.15), value: settings.removeBG)
        .animation(.easeInOut(duration: 0.15), value: settings.bgMethod)
    }

    // Binding barvy klíče ↔ Color (přes NSColor pro správný sRGB)
    private var bgKeyColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(red: settings.bgKeyR, green: settings.bgKeyG, blue: settings.bgKeyB)
            },
            set: { newColor in
                if let ns = NSColor(newColor).usingColorSpace(.sRGB) {
                    settings.bgKeyR = Double(ns.redComponent)
                    settings.bgKeyG = Double(ns.greenComponent)
                    settings.bgKeyB = Double(ns.blueComponent)
                    scheduleRender()
                }
            }
        )
    }

    // MARK: - Popover: uložit preset

    private var savePresetPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Název presetu").font(.headline)
            TextField("Název…", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .onSubmit { commitSavePreset() }
            HStack {
                Button("Zrušit") { showSavePopover = false }
                Spacer()
                Button("Uložit") { commitSavePreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func commitSavePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = selectedPresetID,
           var existing = presetsStore.presets.first(where: { $0.id == id }) {
            existing.name = name
            existing.settings = settings
            presetsStore.save(existing)
        } else {
            let p = ImageAdjustPreset(name: name, settings: settings)
            presetsStore.save(p)
            selectedPresetID = p.id
        }
        showSavePopover = false
    }

    // MARK: - Pomocné buildery

    @ViewBuilder
    private func ctrlSection(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
        }
        .padding(.bottom, 5)
        .padding(.top, 3)
    }

    @ViewBuilder
    private func ctrlDivider() -> some View {
        Divider().padding(.vertical, 6)
    }

    @ViewBuilder
    private func adjRow(_ label: String,
                        _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        _ fmt: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _ in scheduleRender() }
            Text(String(format: fmt, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 58, alignment: .trailing)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 3)
    }

    // MARK: - Renderování

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, selectedIndex < imageFiles.count else { return }
            await MainActor.run { isRendering = true }
            let url  = imageFiles[selectedIndex].url
            let snap = settings
            let img  = await Task.detached(priority: .userInitiated) {
                ImageAdjustService.shared.preview(url: url, settings: snap)
            }.value
            await MainActor.run {
                previewImage = img
                isRendering  = false
            }
        }
    }

    // MARK: - Export

    private func applyToAll() {
        let snap  = settings
        let files = imageFiles
        isProcessing = true
        errorMessage = nil
        Task {
            var results: [URL] = []
            var errors:  [String] = []
            for file in files {
                do {
                    let out = try await Task.detached(priority: .userInitiated) {
                        try ImageAdjustService.shared.export(url: file.url, settings: snap)
                    }.value
                    results.append(out)
                } catch {
                    errors.append("\(file.name): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                isProcessing = false
                if !results.isEmpty {
                    appState.addFiles(urls: results, autoSelect: true)
                    appState.logSuccess("Úpravy uloženy: \(results.count) soubor(ů)")
                    isPresented = false
                }
                if let first = errors.first {
                    errorMessage = first
                    appState.logError(first)
                }
            }
        }
    }
}

// MARK: - Řádek souboru

private struct AdjFileRow: View {
    let file: FileItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumb = file.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                        .overlay(Image(systemName: "photo").font(.caption).foregroundColor(.secondary))
                }
            }
            .frame(width: 46, height: 36)
            .cornerRadius(3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(isSelected ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Šachovnicové pozadí (průhlednost)

private struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 11
            for row in 0...Int(ceil(size.height / s)) {
                for col in 0...Int(ceil(size.width / s)) {
                    let light = (row + col) % 2 == 0
                    ctx.fill(
                        Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                        with: .color(light ? Color(white: 0.55) : Color(white: 0.42))
                    )
                }
            }
        }
    }
}

// MARK: - Sledování velikosti okna

private struct WindowResizeTracker: NSViewRepresentable {
    var onResize: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onResize = onResize
    }

    func makeCoordinator() -> Coordinator { Coordinator(onResize: onResize) }

    final class Coordinator: NSObject {
        var onResize: (CGSize) -> Void
        init(onResize: @escaping (CGSize) -> Void) { self.onResize = onResize }

        @objc func windowDidResize(_ note: Notification) {
            guard let w = note.object as? NSWindow else { return }
            DispatchQueue.main.async { self.onResize(w.frame.size) }
        }
    }
}
