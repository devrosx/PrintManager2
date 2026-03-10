//
//  StitchDialog.swift
//  PrintManager
//
//  Dialog pro panorama stitch obrázků. Používá Apple Vision — nepotřebuje Python.
//

import SwiftUI

struct StitchDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let imageFiles: [FileItem]

    @State private var previewImage: NSImage?
    @State private var isLoadingPreview = false
    @State private var isStitching = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {

            // Záhlaví
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stitch — Spojení obrázků")
                        .font(.headline)
                    Text("\(imageFiles.count) obrázků ke spojení")
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

            // Pás náhledů vstupních obrázků
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(imageFiles.enumerated()), id: \.element.id) { idx, file in
                        VStack(spacing: 3) {
                            Group {
                                if let thumb = file.thumbnail {
                                    Image(nsImage: thumb)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.1)
                                }
                            }
                            .frame(width: 72, height: 54)
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25)))

                            Text("\(idx + 1)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if idx < imageFiles.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 14)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(DS.Colors.controlBackground)

            Divider()

            // Oblast náhledu výsledku
            ZStack {
                Color.secondary.opacity(0.05)

                if isLoadingPreview {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Generuji náhled…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let preview = previewImage {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(6)
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("Klikni 'Nahled' pro zobrazeni vysledku")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minHeight: 200)

            Divider()

            // Chyba
            if let err = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            // Info
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text("Obrázky musí mít překrývající se oblast (doporučeno 30–50 %). Používá Apple Vision – nevyžaduje Python ani OpenCV. Pořadí = pořadí souborů v listu.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Tlačítka
            HStack {
                Button("Zrušit") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Náhled") { runPreview() }
                    .disabled(isLoadingPreview || isStitching || imageFiles.count < 2)

                if isStitching {
                    ProgressView().scaleEffect(0.7).padding(.leading, 4)
                    Text("Zpracovávám…").font(.callout).foregroundColor(.secondary)
                } else {
                    Button("Spojit") { runStitch() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(imageFiles.count < 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.Colors.controlBackground)
        }
        .frame(width: 480)
    }

    // MARK: - Akce

    private func runPreview() {
        let urls = imageFiles.map(\.url)
        isLoadingPreview = true
        errorMessage = nil
        previewImage = nil

        Task {
            do {
                let img = try await NativeStitchService.shared.preview(urls: urls)
                await MainActor.run {
                    isLoadingPreview = false
                    previewImage = img
                }
            } catch {
                await MainActor.run {
                    isLoadingPreview = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runStitch() {
        let urls = imageFiles.map(\.url)
        isStitching = true
        errorMessage = nil

        Task {
            do {
                let outURL = try await NativeStitchService.shared.stitch(urls: urls)
                await MainActor.run {
                    isStitching = false
                    isPresented = false
                    appState.logSuccess("Stitch hotový: \(outURL.lastPathComponent)")
                    appState.addFiles(urls: [outURL], autoSelect: true)
                }
            } catch {
                await MainActor.run {
                    isStitching = false
                    errorMessage = error.localizedDescription
                    appState.logError("Stitch selhal: \(error.localizedDescription)")
                }
            }
        }
    }
}
