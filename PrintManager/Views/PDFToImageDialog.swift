//
//  PDFToImageDialog.swift
//  PrintManager
//
//  Dialog pro export všech stránek PDF do obrazkových souborů.
//  Podporuje formáty JPEG / PNG / TIFF a výběr rozlišení (DPI).
//

import SwiftUI

struct PDFToImageDialog: View {
    @Binding var isPresented: Bool
    let pdfFiles: [FileItem]
    @EnvironmentObject var appState: AppState

    @AppStorage("pdfToImage.format")  private var format: ImageExportFormat = .jpeg
    @AppStorage("pdfToImage.dpi")     private var dpi: Int = 300
    @AppStorage("pdfToImage.quality") private var jpegQuality: Double = 0.9

    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var currentFileIndex = 0
    @State private var errorMsg: String? = nil

    private let dpiOptions = [72, 96, 150, 200, 300, 400, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Nadpis
            Text("Export PDF to Images")
                .font(.title2).bold()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Nastavení
            Form {
                Picker("Format:", selection: $format) {
                    ForEach(ImageExportFormat.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                if format == .jpeg {
                    HStack {
                        Text("Quality:")
                        Slider(value: $jpegQuality, in: 0.5...1.0, step: 0.05)
                        Text("\(Int(jpegQuality * 100))%")
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Picker("Resolution:", selection: $dpi) {
                    ForEach(dpiOptions, id: \.self) { d in
                        Text("\(d) DPI").tag(d)
                    }
                }
            }
            .formStyle(.grouped)

            // Přehled souborů
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pdfFiles) { f in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.richtext")
                            .foregroundColor(.accentColor)
                        Text(f.name)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chybová hláška
            if let err = errorMsg {
                Text(err)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Progress
            if isProcessing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(pdfFiles.count > 1
                         ? "Processing file \(currentFileIndex + 1) of \(pdfFiles.count)…"
                         : "Exporting pages…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Tlačítka
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export Images") { startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isProcessing)
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(isProcessing)
    }

    // MARK: - Export

    private func startExport() {
        isProcessing = true
        errorMsg = nil
        progress = 0
        currentFileIndex = 0
        let service = PDFService()

        Task {
            var allOutputURLs: [URL] = []
            for (idx, file) in pdfFiles.enumerated() {
                await MainActor.run { currentFileIndex = idx }
                do {
                    let urls = try await service.convertToImages(
                        url: file.url,
                        dpi: dpi,
                        format: format,
                        jpegQuality: jpegQuality
                    ) { pageProgress in
                        Task { @MainActor in
                            self.progress = (Double(idx) + pageProgress) / Double(self.pdfFiles.count)
                        }
                    }
                    allOutputURLs.append(contentsOf: urls)
                } catch {
                    await MainActor.run {
                        errorMsg = "Error processing \(file.name): \(error.localizedDescription)"
                        isProcessing = false
                    }
                    return
                }
            }
            await MainActor.run {
                appState.addFiles(urls: allOutputURLs, autoSelect: true)
                appState.logSuccess("Exported \(allOutputURLs.count) image(s) from \(pdfFiles.count) PDF(s)")
                isProcessing = false
                isPresented = false
            }
        }
    }
}
