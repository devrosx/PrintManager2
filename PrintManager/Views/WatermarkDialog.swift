//
//  WatermarkDialog.swift
//  PrintManager
//
//  Dialog pro přidání textového vodoznaku na PDF.
//

import SwiftUI
import AppKit

struct WatermarkDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var watermarkText = "DRAFT"
    @State private var fontSize: Double = 72
    @State private var opacity: Double = 0.25
    @State private var angle: Double = -45
    @State private var mode: WatermarkMode = .center
    @State private var selectedColor: Color = .red
    @State private var fontName: String = "Helvetica-Bold"
    @State private var isProcessing = false
    @State private var errorMessage: String?

    // Výběr fontů z dostupných systémových (jen tučné a výrazné)
    private let fonts = ["Helvetica-Bold", "Arial-BoldMT", "TimesNewRomanPS-BoldMT",
                         "CourierNewPS-BoldMT", "Georgia-Bold", "Verdana-Bold"]

    private var selectedFiles: [FileItem] {
        appState.files.filter { appState.selectedFiles.contains($0.id) && $0.fileType == .pdf }
    }

    var body: some View {
        VStack(spacing: 0) {

            // Záhlaví
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vodoznak (Watermark)")
                        .font(.headline)
                    Text(selectedFiles.count == 1
                         ? selectedFiles[0].name
                         : "\(selectedFiles.count) PDF souborů")
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
            .padding(.vertical, 12)
            .background(DS.Colors.windowBackground)

            Divider()

            // Formulář
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Text
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text vodoznaku:").font(.body)
                        TextField("DRAFT, CONFIDENTIAL…", text: $watermarkText)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Vzhled
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vzhled:").font(.body)

                        HStack {
                            Text("Font:").frame(width: 70, alignment: .leading)
                            Picker("", selection: $fontName) {
                                ForEach(fonts, id: \.self) { f in
                                    Text(f).tag(f)
                                }
                            }
                            .labelsHidden()
                        }

                        HStack {
                            Text("Velikost:").frame(width: 70, alignment: .leading)
                            Slider(value: $fontSize, in: 20...200, step: 4)
                            Text("\(Int(fontSize)) pt")
                                .frame(width: 50, alignment: .trailing)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Barva:").frame(width: 70, alignment: .leading)
                            ColorPicker("", selection: $selectedColor)
                                .labelsHidden()
                        }

                        HStack {
                            Text("Průhlednost:").frame(width: 70, alignment: .leading)
                            Slider(value: $opacity, in: 0.05...1.0, step: 0.05)
                            Text("\(Int(opacity * 100)) %")
                                .frame(width: 50, alignment: .trailing)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Pozice
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pozice:").font(.body)
                        Picker("", selection: $mode) {
                            ForEach(WatermarkMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

                    // Úhel
                    HStack {
                        Text("Úhel:").frame(width: 70, alignment: .leading)
                        Slider(value: $angle, in: -90...90, step: 5)
                        Text("\(Int(angle))°")
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }

                    // Náhled textu
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                        Text(watermarkText.isEmpty ? "DRAFT" : watermarkText)
                            .font(.system(size: min(fontSize * 0.3, 36), weight: .bold))
                            .foregroundColor(selectedColor.opacity(opacity))
                            .rotationEffect(.degrees(angle))
                            .lineLimit(1)
                    }
                    .frame(height: 100)

                    if let err = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Tlačítka
            HStack {
                Button("Zrušit") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isProcessing {
                    ProgressView().scaleEffect(0.7).padding(.trailing, 6)
                    Text("Zpracovávám…").font(.callout).foregroundColor(.secondary)
                } else {
                    Button("Přidat vodoznak") { applyWatermark() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(watermarkText.isEmpty || selectedFiles.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.Colors.controlBackground)
        }
        .frame(width: 440)
    }

    // MARK: - Akce

    private func applyWatermark() {
        let nsColor = NSColor(selectedColor).withAlphaComponent(opacity)
        let settings = WatermarkSettings(
            text: watermarkText,
            fontSize: CGFloat(fontSize),
            color: nsColor,
            angle: angle,
            mode: mode,
            fontName: fontName
        )

        let files = selectedFiles
        isProcessing = true
        errorMessage = nil

        Task {
            var results: [URL] = []
            var errors: [String] = []
            for file in files {
                do {
                    let out = try await Task.detached(priority: .userInitiated) {
                        try WatermarkService.shared.addWatermark(to: file.url, settings: settings)
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
                    appState.logSuccess("Vodoznak přidán: \(results.count) soubor(ů)")
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
