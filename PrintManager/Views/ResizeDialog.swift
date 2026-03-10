//
//  ResizeDialog.swift
//  PrintManager
//
//  Dialog pro změnu velikosti obrázků (px/mm/cm/in/%) a PDF stránek (mm/cm/in).
//  Proporcionální i neproporcionální scaling, Lanczos interpolace, přednastavené velikosti.
//

import SwiftUI
import AppKit

// MARK: - ViewModel

final class ResizeDialogViewModel: ObservableObject {

    // Data
    let files: [FileItem]
    private(set) var infos: [ResizeFileInfo?] = []

    enum PrimaryField { case width, height }

    // UI stav
    @Published var selectedIndex = 0
    @Published var unit: ResizeUnit = .pixels
    @Published var widthStr  = ""
    @Published var heightStr = ""
    @Published var dpi: Double = 72
    @Published var lockAspect = true
    @Published var stretch = false          // stretch (vs. fit s okraji) pro PDF
    @Published var interpolation: ResizeInterpolation = .lanczos
    private(set) var primaryField: PrimaryField = .width   // která dimenze je "autorita"

    // Progress
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var errorMsg: String? = nil
    @Published var doneCount = 0

    var currentInfo: ResizeFileInfo? { infos.indices.contains(selectedIndex) ? infos[selectedIndex] : nil }

    // Pouze obrázky nebo pouze PDF – nebo mix?
    var hasImages: Bool { files.contains { !($0.fileType == .pdf) } }
    var hasPDFs:   Bool { files.contains {  $0.fileType == .pdf  } }

    init(files: [FileItem]) {
        self.files = files
        infos = files.map { ResizeService.shared.fileInfo(for: $0.url) }
        loadFromCurrentFile()
    }

    // Naplnění polí z aktuálního souboru
    func loadFromCurrentFile() {
        guard let info = currentInfo else { return }
        dpi = info.isPDF ? 72 : max(1, info.dpi)
        applyInfoToFields(info)
    }

    private func applyInfoToFields(_ info: ResizeFileInfo) {
        switch unit {
        case .pixels:
            widthStr  = info.isPDF ? String(format: "%.0f", Double(info.widthPt)  * dpi / 72) : "\(info.widthPx)"
            heightStr = info.isPDF ? String(format: "%.0f", Double(info.heightPt) * dpi / 72) : "\(info.heightPx)"
        case .millimeters:
            widthStr  = String(format: "%.2f", info.widthMM)
            heightStr = String(format: "%.2f", info.heightMM)
        case .centimeters:
            widthStr  = String(format: "%.3f", info.widthMM / 10)
            heightStr = String(format: "%.3f", info.heightMM / 10)
        case .inches:
            widthStr  = String(format: "%.4f", info.widthMM / 25.4)
            heightStr = String(format: "%.4f", info.heightMM / 25.4)
        case .percent:
            widthStr  = "100"
            heightStr = "100"
        }
    }

    // Převod jednotek bez ztráty hodnoty (při přepnutí unit selectoru)
    func changeUnit(to newUnit: ResizeUnit) {
        guard let info = currentInfo else { unit = newUnit; return }
        let wMM: Double
        let hMM: Double
        if let wV = Double(widthStr), let hV = Double(heightStr) {
            wMM = rsToMM(wV, unit: unit, base: info.widthMM,  dpi: dpi)
            hMM = rsToMM(hV, unit: unit, base: info.heightMM, dpi: dpi)
        } else {
            wMM = info.widthMM
            hMM = info.heightMM
        }
        unit = newUnit
        widthStr  = rsFromMM(wMM, to: newUnit, base: info.widthMM,  dpi: dpi)
        heightStr = rsFromMM(hMM, to: newUnit, base: info.heightMM, dpi: dpi)
    }

    // Šířka změněna uživatelem → je primární, přepočítej výšku ze selectedFile
    func onWidthChange(_ val: String) {
        widthStr     = val
        primaryField = .width
        guard lockAspect, let info = currentInfo, let w = Double(val), w > 0 else { return }
        heightStr = formatLinked(w * info.aspectRatio)
    }

    // Výška změněna uživatelem → je primární, přepočítej šířku ze selectedFile
    func onHeightChange(_ val: String) {
        heightStr    = val
        primaryField = .height
        guard lockAspect, let info = currentInfo, let h = Double(val), h > 0 else { return }
        widthStr = formatLinked(h / info.aspectRatio)
    }

    private func formatLinked(_ v: Double) -> String {
        switch unit {
        case .pixels:      return String(format: "%.0f", v.rounded())
        case .millimeters: return String(format: "%.2f", v)
        case .centimeters: return String(format: "%.3f", v)
        case .inches:      return String(format: "%.4f", v)
        case .percent:     return String(format: "%.1f", v)
        }
    }

    // Aplikace presetu
    func applyPreset(_ preset: ResizePreset) {
        if preset.isPxPreset {
            unit      = .pixels
            widthStr  = "\(preset.widthPx)"
            heightStr = "\(preset.heightPx)"
        } else {
            unit      = .millimeters
            widthStr  = String(format: "%.2f", preset.widthMM)
            heightStr = String(format: "%.2f", preset.heightMM)
        }
    }

    /// Cílové px pro konkrétní soubor.
    /// Při lockAspect: primární dimenze je fixní (global), druhá se počítá
    /// z **vlastního** aspect ratio tohoto souboru — ne z prvního souboru.
    func targetPx(for info: ResizeFileInfo) -> (Int, Int) {
        switch unit {
        case .percent:
            guard let wPct = Double(widthStr), let hPct = Double(heightStr) else { return (0, 0) }
            let baseW = info.isPDF ? Double(info.widthPt)  * dpi / 72 : Double(info.widthPx)
            let baseH = info.isPDF ? Double(info.heightPt) * dpi / 72 : Double(info.heightPx)
            return (max(1, Int((baseW * wPct / 100).rounded())),
                    max(1, Int((baseH * hPct / 100).rounded())))
        default:
            if lockAspect {
                let ar = info.aspectRatio   // h/w tohoto souboru
                if primaryField == .width {
                    let tw = globalTargetW
                    let th = max(1, Int((Double(tw) * ar).rounded()))
                    return (tw, th)
                } else {
                    let th = globalTargetH
                    let tw = max(1, Int((Double(th) / ar).rounded()))
                    return (tw, th)
                }
            }
            return (globalTargetW, globalTargetH)
        }
    }

    // Globální cíl v px (pro non-% mode)
    var globalTargetW: Int {
        guard let info = currentInfo, let v = Double(widthStr) else { return 0 }
        switch unit {
        case .pixels:      return max(1, Int(v.rounded()))
        case .millimeters: return max(1, Int((v / 25.4 * dpi).rounded()))
        case .centimeters: return max(1, Int((v * 10 / 25.4 * dpi).rounded()))
        case .inches:      return max(1, Int((v * dpi).rounded()))
        case .percent:
            let base = info.isPDF ? Double(info.widthPt) * dpi / 72 : Double(info.widthPx)
            return max(1, Int((base * v / 100).rounded()))
        }
    }

    var globalTargetH: Int {
        guard let info = currentInfo, let v = Double(heightStr) else { return 0 }
        switch unit {
        case .pixels:      return max(1, Int(v.rounded()))
        case .millimeters: return max(1, Int((v / 25.4 * dpi).rounded()))
        case .centimeters: return max(1, Int((v * 10 / 25.4 * dpi).rounded()))
        case .inches:      return max(1, Int((v * dpi).rounded()))
        case .percent:
            let base = info.isPDF ? Double(info.heightPt) * dpi / 72 : Double(info.heightPx)
            return max(1, Int((base * v / 100).rounded()))
        }
    }

    // Validace
    var isValid: Bool { globalTargetW > 0 && globalTargetH > 0 }

    var targetSummary: String {
        guard isValid else { return "—" }
        if lockAspect && files.count > 1 && unit != .percent {
            let dim  = primaryField == .width
                     ? "\(globalTargetW) px šířka" : "\(globalTargetH) px výška"
            return "\(dim) · výška per-soubor (vlastní poměr stran)"
        }
        let tw = globalTargetW; let th = globalTargetH
        let tmm_w = Double(tw) / dpi * 25.4
        let tmm_h = Double(th) / dpi * 25.4
        return String(format: "%d × %d px  (%.1f × %.1f mm)", tw, th, tmm_w, tmm_h)
    }

    // MARK: - Akce

    func resize(onFileDone: @escaping (URL) -> Void, completion: @escaping (Int) -> Void) {
        guard isValid else { errorMsg = "Zadejte platné rozměry."; return }
        isProcessing = true
        progress = 0
        doneCount = 0
        errorMsg  = nil

        let filesToProcess  = files
        let infosSnap       = infos
        let interpSnap      = interpolation
        let stretchSnap     = stretch
        let dpiSnap         = dpi
        let globalW         = globalTargetW
        let globalH         = globalTargetH
        let lockSnap        = lockAspect
        let primarySnap     = primaryField
        let unitSnap        = unit
        let wStr            = widthStr
        let hStr            = heightStr

        Task {
            var ok = 0
            for (i, file) in filesToProcess.enumerated() {
                guard let inf = infosSnap[i] else { continue }
                let (tw, th): (Int, Int)
                switch unitSnap {
                case .percent:
                    let wPct = Double(wStr) ?? 100
                    let hPct = Double(hStr) ?? 100
                    let bw   = inf.isPDF ? Double(inf.widthPt)  * dpiSnap / 72 : Double(inf.widthPx)
                    let bh   = inf.isPDF ? Double(inf.heightPt) * dpiSnap / 72 : Double(inf.heightPx)
                    tw = max(1, Int((bw * wPct / 100).rounded()))
                    th = max(1, Int((bh * hPct / 100).rounded()))
                default:
                    if lockSnap {
                        let ar = inf.aspectRatio
                        if primarySnap == .width {
                            tw = globalW
                            th = max(1, Int((Double(globalW) * ar).rounded()))
                        } else {
                            th = globalH
                            tw = max(1, Int((Double(globalH) / ar).rounded()))
                        }
                    } else {
                        tw = globalW
                        th = globalH
                    }
                }
                let wPt = CGFloat(tw) * 72.0 / CGFloat(dpiSnap)
                let hPt = CGFloat(th) * 72.0 / CGFloat(dpiSnap)

                do {
                    let outURL: URL
                    if file.fileType == .pdf {
                        outURL = try ResizeService.shared.resizePDF(
                            url: file.url, toPointWidth: wPt, height: hPt,
                            stretch: stretchSnap, overwrite: false)
                    } else {
                        outURL = try ResizeService.shared.resizeImage(
                            url: file.url, toPixelWidth: tw, height: th,
                            interpolation: interpSnap, overwrite: false)
                    }
                    ok += 1
                    let captured = outURL
                    await MainActor.run { onFileDone(captured) }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run { self.errorMsg = msg }
                }
                await MainActor.run {
                    self.progress = Double(i + 1) / Double(filesToProcess.count)
                }
            }
            let finalOk = ok
            await MainActor.run {
                self.isProcessing = false
                self.doneCount    = finalOk
                completion(finalOk)
            }
        }
    }
}

// MARK: - Dialog View

struct ResizeDialog: View {
    @Binding var isPresented: Bool
    @StateObject private var vm: ResizeDialogViewModel

    init(isPresented: Binding<Bool>, files: [FileItem]) {
        _isPresented = isPresented
        _vm = StateObject(wrappedValue: ResizeDialogViewModel(files: files))
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────
            HStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundColor(.accentColor)
                Text("Změna velikosti")
                    .font(.headline)
                Spacer()
                Text("\(vm.files.count) soubor\(vm.files.count == 1 ? "" : "ů")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // ── Tělo ────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 0) {

                // Levý panel: seznam souborů
                fileListPanel
                    .frame(width: 180)

                Divider()

                // Pravý panel: ovládání
                controlsPanel
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // ── Footer ──────────────────────────────────────────────
            footerBar
        }
        .frame(width: 760, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - File list panel

    private var fileListPanel: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { vm.selectedIndex },
                set: { vm.selectedIndex = $0 }   // jen aktualizuje info label, ne vstupní pole
            )) {
                ForEach(vm.files.indices, id: \.self) { i in
                    fileRow(vm.files[i], info: vm.infos[i])
                        .tag(i)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private func fileRow(_ file: FileItem, info: ResizeFileInfo?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name)
                .font(.system(size: 11))
                .lineLimit(2)
            if let info {
                Text(info.isPDF
                     ? String(format: "%.0f × %.0f mm", info.widthMM, info.heightMM)
                     : "\(info.widthPx) × \(info.heightPx) px")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Controls panel

    private var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Aktuální velikost
                if let info = vm.currentInfo {
                    HStack {
                        Image(systemName: info.isPDF ? "doc.richtext" : "photo")
                            .foregroundColor(.secondary)
                        Text(info.sizeLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }

                // ── Jednotky ──────────────────────────────────────
                SectionHeader("Jednotky")
                Picker("", selection: Binding(
                    get: { vm.unit },
                    set: { vm.changeUnit(to: $0) }
                )) {
                    ForEach(ResizeUnit.allCases) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // ── Rozměry ───────────────────────────────────────
                SectionHeader("Cílová velikost")
                HStack(spacing: 8) {
                    labeledField("Šířka",  text: Binding(
                        get: { vm.widthStr },
                        set: { vm.onWidthChange($0) }
                    ), unit: vm.unit.rawValue)

                    // Lock button
                    Button {
                        vm.lockAspect.toggle()
                    } label: {
                        Image(systemName: vm.lockAspect ? "lock.fill" : "lock.open")
                            .foregroundColor(vm.lockAspect ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                    .help(vm.lockAspect ? "Zamčený poměr stran" : "Odemčený poměr stran")

                    labeledField("Výška", text: Binding(
                        get: { vm.heightStr },
                        set: { vm.onHeightChange($0) }
                    ), unit: vm.unit.rawValue)
                }

                // DPI (viditelné pro mm/cm/in)
                if vm.unit != .pixels && vm.unit != .percent {
                    HStack(spacing: 8) {
                        Text("DPI")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .leading)
                        TextField("", value: $vm.dpi, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("(pro přepočet px ↔ fyzické jednotky)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Stretch (pro PDF, jen při odemčeném poměru)
                if vm.hasPDFs && !vm.lockAspect {
                    Toggle("Roztáhnout na přesný rozměr (PDF)", isOn: $vm.stretch)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                // Cíl v px (info)
                HStack {
                    Text("→")
                        .foregroundColor(.secondary)
                    Text(vm.targetSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(vm.isValid ? .primary : .red)
                }

                // ── Přednastavené velikosti ───────────────────────
                SectionHeader("Papírové formáty")
                presetChips(ResizePreset.paperPresets)

                SectionHeader("Rozlišení obrazovky")
                presetChips(ResizePreset.screenPresets)

                // ── Interpolace ───────────────────────────────────
                if vm.hasImages {
                    SectionHeader("Interpolace (obrázky)")
                    Picker("", selection: $vm.interpolation) {
                        ForEach(ResizeInterpolation.allCases) { i in
                            Text(i.rawValue).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Error
                if let err = vm.errorMsg {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func presetChips(_ presets: [ResizePreset]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(presets) { preset in
                Button(preset.name) {
                    vm.applyPreset(preset)
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button("Zrušit") { isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if vm.isProcessing {
                HStack(spacing: 8) {
                    ProgressView(value: vm.progress)
                        .frame(width: 120)
                    Text("\(Int(vm.progress * 100)) %")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                vm.resize(onFileDone: { _ in }) { count in
                    if count > 0 { isPresented = false }
                }
            } label: {
                Label("Změnit velikost", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.isValid || vm.isProcessing)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - FlowLayout (wrap chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Chip button style

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed
                          ? Color.accentColor.opacity(0.2)
                          : Color(nsColor: .controlColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            )
            .foregroundColor(.primary)
    }
}
