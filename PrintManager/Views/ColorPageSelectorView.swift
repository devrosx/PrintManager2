//
//  ColorPageSelectorView.swift
//  PrintManager
//
//  Zobrazí všechny stránky PDF jako miniatury. Označené stránky zůstanou barevné,
//  neoznačené budou konvertovány na stupně šedi.
//

import SwiftUI
import PDFKit
import AppKit

// MARK: - Main View

struct ColorPageSelectorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let file: FileItem

    @State private var colorPages: Set<Int> = []   // 0-based indexy stránek, které ZŮSTANOU barevné
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var pageCount: Int = 0
    @State private var isProcessing = false
    @State private var thumbSize: CGFloat = 120

    // Adaptivní grid — automaticky přizpůsobí počet sloupců šířce okna
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize + 60), spacing: 10)]
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Horní lišta ───────────────────────────────────────────────
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vyberte barevné stránky")
                        .font(.headline)
                    Text(file.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Statistiky
                HStack(spacing: 16) {
                    Label("\(colorPages.count) barevných", systemImage: "photo")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Label("\(pageCount - colorPages.count) šedých", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Divider().frame(height: 20)

                // Hromadný výběr
                Button("Vybrat vše") {
                    colorPages = Set(0..<pageCount)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))

                Button("Zrušit vše") {
                    colorPages = []
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))

                Divider().frame(height: 20)

                // Velikost miniatur
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(value: $thumbSize, in: 80...200, step: 10)
                        .frame(width: 80)
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Grid miniatur ─────────────────────────────────────────────
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        PageThumbCell(
                            pageIndex: index,
                            thumbnail: thumbnails[index],
                            isColor: colorPages.contains(index)
                        )
                        .onTapGesture {
                            if colorPages.contains(index) {
                                colorPages.remove(index)
                            } else {
                                colorPages.insert(index)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Dolní lišta ───────────────────────────────────────────────
            HStack {
                Button("Zrušit") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isProcessing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Zpracovávám stránky…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    apply()
                } label: {
                    Label("Vybrat barevné stránky", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || pageCount == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { loadThumbnails() }
    }

    // MARK: - Private

    private func loadThumbnails() {
        guard let doc = PDFDocument(url: file.url) else { return }
        pageCount = doc.pageCount

        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let size = CGSize(width: 200, height: 280)
                let img = page.thumbnail(of: size, for: .mediaBox)
                DispatchQueue.main.async {
                    thumbnails[i] = img
                }
            }
        }
    }

    private func apply() {
        isProcessing = true
        appState.applySelectiveGray(file: file, colorPages: colorPages) {
            isProcessing = false
            isPresented = false
        }
    }
}

// MARK: - Page Thumbnail Cell

struct PageThumbCell: View {
    let pageIndex: Int
    let thumbnail: NSImage?
    let isColor: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                // Náhled stránky
                Group {
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                            .aspectRatio(0.707, contentMode: .fit)
                            .overlay(
                                ProgressView().scaleEffect(0.6)
                            )
                    }
                }
                .cornerRadius(4)

                // Šedý překryv u nebarevných stránek
                if !isColor {
                    Rectangle()
                        .fill(Color.gray.opacity(0.55))
                        .aspectRatio(0.707, contentMode: .fit)
                        .cornerRadius(4)
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(0.707, contentMode: .fit)
                }

                // Zaškrtnutí u barevných stránek
                if isColor {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isColor ? Color.accentColor : Color.gray.opacity(0.3),
                        lineWidth: isColor ? 2.5 : 1
                    )
            )

            Text("Str. \(pageIndex + 1)")
                .font(.system(size: 10))
                .foregroundColor(isColor ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isColor)
    }
}
