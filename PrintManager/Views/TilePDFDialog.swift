//
//  TilePDFDialog.swift
//  PrintManager
//
//  Dialog pro funkci Tile PDF — skládání stránek vedle sebe nebo pod sebe.
//

import SwiftUI

struct TilePDFDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    let files: [FileItem]

    @State private var options = TilePDFOptions()
    @State private var isProcessing = false
    @State private var errorMessage: String? = nil

    private var isSingleMode: Bool { files.count == 1 }
    private var effectiveCount: Int { isSingleMode ? options.count : files.count }

    var body: some View {
        VStack(spacing: 0) {

            // ── Záhlaví ──────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSingleMode ? "Tile PDF — opakování" : "Tile PDF — \(files.count) soubory")
                        .font(.headline)
                    Text(fileSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.Colors.windowBackground)

            Divider()

            VStack(alignment: .leading, spacing: 14) {

                // ── Orientace ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("Orientace skládání")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        ForEach(TileDirection.allCases, id: \.self) { dir in
                            DirectionCard(
                                direction: dir,
                                isSelected: options.direction == dir,
                                isSingleMode: isSingleMode,
                                count: effectiveCount
                            )
                            .onTapGesture { options.direction = dir }
                        }
                    }
                }

                Divider()

                // ── Počet kopií (jen single mode) ─────────────────────
                if isSingleMode {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Počet kopií:")
                            .font(.body)
                        Spacer()
                        HStack(spacing: 4) {
                            TextField("", value: $options.count, formatter: countFormatter)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $options.count, in: 2...20)
                                .labelsHidden()
                                .frame(width: 40)
                            Text("×")
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()
                }

                // ── Oddělovač ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("Oddělovač")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        // Mezera
                        HStack(spacing: 8) {
                            Toggle("Mezera", isOn: Binding(
                                get:  { options.spacingMm > 0 },
                                set:  { options.spacingMm = $0 ? 3.0 : 0 }
                            ))
                            .toggleStyle(.checkbox)
                            if options.spacingMm > 0 {
                                HStack(spacing: 3) {
                                    TextField("", value: $options.spacingMm, formatter: mmFormatter)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 54)
                                        .multilineTextAlignment(.trailing)
                                    Stepper("", value: $options.spacingMm, in: 0.5...50, step: 0.5)
                                        .labelsHidden().frame(width: 36)
                                    Text("mm").foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        // Linka
                        HStack(spacing: 8) {
                            Toggle("Linka", isOn: $options.showLine)
                                .toggleStyle(.checkbox)
                            if options.showLine {
                                HStack(spacing: 3) {
                                    TextField("", value: $options.lineWidthPt, formatter: ptFormatter)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 48)
                                        .multilineTextAlignment(.trailing)
                                    Stepper("", value: $options.lineWidthPt, in: 0.1...5, step: 0.1)
                                        .labelsHidden().frame(width: 36)
                                    Text("pt").foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // ── Info o výsledné velikosti ─────────────────────────
                if let sizeText = resultSizeText {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundColor(.accentColor)
                        Text(sizeText).font(.caption).foregroundColor(.secondary)
                    }
                }

                // ── Chybová zpráva ────────────────────────────────────
                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .padding(16)

            Divider()

            // ── Tlačítka ─────────────────────────────────────────────
            HStack {
                Button("Zrušit") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isProcessing {
                    ProgressView().scaleEffect(0.7).padding(.trailing, 6)
                    Text("Zpracovávám…").font(.callout).foregroundColor(.secondary)
                } else {
                    Button("Tile →") { applyTile() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.Colors.controlBackground)
        }
        .frame(width: 440)
    }

    // MARK: - Computed

    private var fileSubtitle: String {
        files.map { $0.name + ".pdf" }.joined(separator: ", ")
    }

    private var resultSizeText: String? {
        guard let ref = files.first, ref.pageSize != .zero else { return nil }
        let ptW = ref.pageSize.width
        let ptH = ref.pageSize.height
        let sp  = options.spacingMm * 2.834645669
        let n   = Double(effectiveCount)

        let (outWmm, outHmm): (Double, Double)
        switch options.direction {
        case .horizontal:
            outWmm = (ptW * n + sp * (n - 1)) / 2.834645669
            outHmm = ptH / 2.834645669
        case .vertical:
            outWmm = ptW / 2.834645669
            outHmm = (ptH * n + sp * (n - 1)) / 2.834645669
        }
        return String(format: "Výsledek: %.0f × %.0f mm  (%d×)", outWmm, outHmm, effectiveCount)
    }

    // MARK: - Akce

    private func applyTile() {
        isProcessing = true
        errorMessage = nil
        let opts   = options
        let copies = files

        Task {
            do {
                let outputURL: URL
                if copies.count == 1 {
                    let url = copies[0].url
                    outputURL = try await Task.detached(priority: .userInitiated) {
                        try TilePDFService.shared.tileSingle(url: url, options: opts)
                    }.value
                } else {
                    let urls = copies.map(\.url)
                    outputURL = try await Task.detached(priority: .userInitiated) {
                        try TilePDFService.shared.tileMultiple(urls: urls, options: opts)
                    }.value
                }
                await MainActor.run {
                    isProcessing = false
                    isPresented  = false
                    appState.logSuccess("Tile hotový: \(outputURL.lastPathComponent)")
                    appState.addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    appState.logError("Tile selhal: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Formatters

    private var countFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .none
        f.minimum = 2; f.maximum = 20; return f
    }
    private var mmFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .decimal
        f.minimumFractionDigits = 1; f.maximumFractionDigits = 1
        f.minimum = 0.5; f.maximum = 50; return f
    }
    private var ptFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .decimal
        f.minimumFractionDigits = 1; f.maximumFractionDigits = 1
        f.minimum = 0.1; f.maximum = 5; return f
    }
}

// MARK: - Direction Card

private struct DirectionCard: View {
    let direction: TileDirection
    let isSelected: Bool
    let isSingleMode: Bool
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            // Vizuální náhled layoutu
            TileLayoutPreview(direction: direction, count: min(count, 4))
                .frame(width: 80, height: 56)

            Text(direction.rawValue)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)

            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1)
        )
        .cornerRadius(8)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private var subtitle: String {
        switch direction {
        case .horizontal: return "šířka × \(count)"
        case .vertical:   return "výška × \(count)"
        }
    }
}

// MARK: - Tile Layout Preview (mini vizualizace)

private struct TileLayoutPreview: View {
    let direction: TileDirection
    let count: Int   // 2–4

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let n = CGFloat(count)

            if direction == .horizontal {
                let slotW = (geo.size.width - spacing * (n - 1)) / n
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 0.5)
                            )
                            .frame(width: slotW)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                let slotH = (geo.size.height - spacing * (n - 1)) / n
                VStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 0.5)
                            )
                            .frame(height: slotH)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
