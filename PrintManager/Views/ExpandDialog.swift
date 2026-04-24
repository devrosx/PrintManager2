//
//  ExpandDialog.swift
//  PrintManager
//
//  Dialog pro funkci Expand — rozšíření okrajů PDF nebo obrázku o zadaný počet mm.
//

import SwiftUI

struct ExpandDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    let file: FileItem

    @State private var expandMm: Double = 3.0
    @State private var fillMode: ExpandFillMode = .edgeFill
    @State private var isProcessing = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {

            // Záhlaví
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expand — Rozšíření okrajů")
                        .font(.headline)
                    Text(file.name + "." + file.fileType.rawValue.lowercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.Colors.windowBackground)

            Divider()

            // Formulář
            VStack(alignment: .leading, spacing: 16) {

                // Popis funkce
                Text("Plátno dokumentu se rozšíří na všech stranách o zadaný počet mm. U vektorového PDF bude vektorová grafika zachována jako vrchní vrstva.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Způsob vyplnění
                VStack(alignment: .leading, spacing: 6) {
                    Text("Způsob vyplnění okrajů:")
                        .font(.body)

                    Picker("", selection: $fillMode) {
                        ForEach(ExpandFillMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(fillMode == .edgeFill
                         ? "Okraj se vyplní opakováním barvy krajního pixelu (vhodné pro dokumenty s jednolitým okrajem)."
                         : "Okraj se vyplní zrcadlovým odrazem obsahu od hrany dokumentu (přirozenější přechod).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Vstup — počet mm
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Rozšíření na každou stranu:")
                        .font(.body)

                    Spacer()

                    HStack(spacing: 4) {
                        TextField("", value: $expandMm, formatter: mmFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)

                        Stepper("", value: $expandMm, in: 0.5...50.0, step: 0.5)
                            .labelsHidden()
                            .frame(width: 40)

                        Text("mm")
                            .foregroundColor(.secondary)
                    }
                }

                // Info o výsledné velikosti
                if let size = resultSizeText {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.accentColor)
                        Text(size)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(16)

            Divider()

            // Tlačítka
            HStack {
                Button("Zrušit") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 6)
                    Text("Zpracovávám…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    Button("Rozšířit") {
                        applyExpand()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(expandMm <= 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.Colors.controlBackground)
        }
        .frame(width: 420)
    }

    // MARK: - Výpočet výsledné velikosti (informativní)

    private var resultSizeText: String? {
        let wMm = file.pageSize.width  / RenderingConstants.pointsPerMillimeter + expandMm * 2
        let hMm = file.pageSize.height / RenderingConstants.pointsPerMillimeter + expandMm * 2
        guard wMm > 0, hMm > 0 else { return nil }
        return String(format: "Výsledná velikost: %.1f × %.1f mm", wMm, hMm)
    }

    // MARK: - Akce

    private func applyExpand() {
        isProcessing = true
        errorMessage = nil
        let url    = file.url
        let expMm  = expandMm
        let mode   = fillMode

        Task {
            do {
                let outputURL = try await Task.detached(priority: .userInitiated) {
                    try ExpandService.shared.expand(url: url, expandMm: expMm, fillMode: mode)
                }.value
                await MainActor.run {
                    isProcessing = false
                    isPresented  = false
                    appState.logSuccess("Expand hotový: \(outputURL.lastPathComponent)")
                    appState.addFiles(urls: [outputURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    appState.logError("Expand selhal: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Formatter

    private var mmFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.minimum = 0.5
        f.maximum = 50.0
        return f
    }
}
