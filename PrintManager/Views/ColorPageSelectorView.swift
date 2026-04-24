//
//  ColorPageSelectorView.swift
//  PrintManager
//
//  Zobrazí všechny stránky PDF jako miniatury. Označené stránky zůstanou barevné,
//  neoznačené budou konvertovány na stupně šedi.
//  Podporuje zpracování fronty více PDF souborů za sebou.
//

import SwiftUI
import PDFKit
import AppKit

// MARK: - PreferenceKey pro pozice buněk

private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Main View

struct ColorPageSelectorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let files: [FileItem]

    @State private var currentIndex: Int = 0
    @State private var colorPages: Set<Int> = []
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var pageCount: Int = 0
    @State private var isProcessing = false
    @State private var thumbSize: CGFloat = 120

    // Generace načítání — každý reset ji inkrementuje; closure ignoruje výsledky starší generace
    @State private var loadingGeneration: Int = 0

    // Drag selection
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var dragRect: CGRect? = nil
    @State private var dragInitialSelection: Set<Int> = []
    @State private var dragAdding: Bool = true

    // Aktuálně zobrazovaný soubor
    private var currentFile: FileItem { files[currentIndex] }

    // Počet souborů ve frontě
    private var isMultiFile: Bool { files.count > 1 }

    private var isLastFile: Bool { currentIndex >= files.count - 1 }

    // Adaptivní grid — automaticky přizpůsobí počet sloupců šířce okna
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize + 60), spacing: 10)]
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Horní lišta ───────────────────────────────────────────────
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Vyberte barevné stránky")
                            .font(.headline)
                        // Progress badge — zobrazí se jen při zpracování více souborů
                        if isMultiFile {
                            Text("\(currentIndex + 1) / \(files.count)")
                                .font(DS.Typography.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text(currentFile.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Statistiky
                HStack(spacing: 16) {
                    Label("\(colorPages.count) barevných", systemImage: "photo")
                        .font(DS.Typography.subheadline)
                        .foregroundColor(.accentColor)
                    Label("\(pageCount - colorPages.count) šedých", systemImage: "circle.lefthalf.filled")
                        .font(DS.Typography.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider().frame(height: 20)

                // Hromadný výběr
                Button("Vybrat vše") {
                    colorPages = Set(0..<pageCount)
                }
                .buttonStyle(.bordered)
                .font(DS.Typography.subheadline)

                Button("Zrušit vše") {
                    colorPages = []
                }
                .buttonStyle(.bordered)
                .font(DS.Typography.subheadline)

                Button("Invertovat") {
                    colorPages = Set(0..<pageCount).subtracting(colorPages)
                }
                .buttonStyle(.bordered)
                .font(DS.Typography.subheadline)

                Divider().frame(height: 20)

                // Velikost miniatur
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(DS.Typography.caption2)
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
            .background(DS.Colors.windowBackground)

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
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CellFrameKey.self,
                                    value: [index: geo.frame(in: .named("gridSpace"))]
                                )
                            }
                        )
                    }
                }
                .padding(12)
                .overlay(alignment: .topLeading) {
                    if let rect = dragRect {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 1.5)
                            .background(Color.accentColor.opacity(0.08))
                            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "gridSpace")
                .gesture(
                    DragGesture(minimumDistance: 5, coordinateSpace: .named("gridSpace"))
                        .onChanged { value in updateDragSelection(value: value) }
                        .onEnded { _ in dragRect = nil }
                )
                .onPreferenceChange(CellFrameKey.self) { frames in
                    cellFrames = frames
                }
            }
            .background(DS.Colors.controlBackground)

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
                            .font(DS.Typography.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Popisek tlačítka se mění podle toho, zda je to poslední soubor ve frontě
                Button {
                    apply()
                } label: {
                    if isLastFile {
                        Label("Vybrat barevné stránky", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Potvrdit a pokračovat", systemImage: "arrow.right.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || pageCount == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DS.Colors.windowBackground)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { loadThumbnails() }
    }

    // MARK: - Drag selection

    private func updateDragSelection(value: DragGesture.Value) {
        let rect = CGRect(
            x: min(value.startLocation.x, value.location.x),
            y: min(value.startLocation.y, value.location.y),
            width: abs(value.location.x - value.startLocation.x),
            height: abs(value.location.y - value.startLocation.y)
        )

        // Na začátku dragu ulož aktuální stav a zjisti, zda přidáváme nebo odebíráme
        if dragRect == nil {
            dragInitialSelection = colorPages
            let startCell = cellFrames.first { $0.value.contains(value.startLocation) }
            dragAdding = startCell.map { !colorPages.contains($0.key) } ?? true
        }

        dragRect = rect

        var newSelection = dragInitialSelection
        for (index, frame) in cellFrames {
            if rect.intersects(frame) {
                if dragAdding {
                    newSelection.insert(index)
                } else {
                    newSelection.remove(index)
                }
            }
        }
        colorPages = newSelection
    }

    // MARK: - Načítání miniatur

    /// Načte miniatury stránek pro `currentFile`.
    /// Generace slouží jako levná forma cancellace: pokud se loadingGeneration změní
    /// (tj. byl zavolán reset před dokončením předchozího načítání), closure zahodí výsledek.
    private func loadThumbnails() {
        guard let doc = PDFDocument(url: currentFile.url) else { return }
        pageCount = doc.pageCount

        // Inkrementace generace zneplatní všechny in-flight closure z minulého volání
        loadingGeneration += 1
        let myGeneration = loadingGeneration

        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let size = CGSize(width: 200, height: 280)
                let img = page.thumbnail(of: size, for: .mediaBox)
                DispatchQueue.main.async {
                    // Ignoruj výsledek, pokud byl mezitím zahájen nový reset
                    guard loadingGeneration == myGeneration else { return }
                    thumbnails[i] = img
                }
            }
        }
    }

    // MARK: - Reset stavu při přechodu na nový soubor

    private func resetForNextFile() {
        colorPages = []
        thumbnails = [:]
        pageCount = 0
        dragRect = nil
        cellFrames = [:]
        dragInitialSelection = []
        // loadThumbnails() inkrementuje loadingGeneration — staré closure se ignorují
        loadThumbnails()
    }

    // MARK: - Aplikace a přechod

    private func apply() {
        isProcessing = true
        appState.applySelectiveGray(file: currentFile, colorPages: colorPages) {
            isProcessing = false
            if isLastFile {
                isPresented = false
            } else {
                currentIndex += 1
                resetForNextFile()
            }
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
                .cornerRadius(DS.Radius.small)

                // Šedý překryv u nebarevných stránek
                if !isColor {
                    Rectangle()
                        .fill(Color.gray.opacity(0.55))
                        .aspectRatio(0.707, contentMode: .fit)
                        .cornerRadius(DS.Radius.small)
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
                .font(DS.Typography.caption2)
                .foregroundColor(isColor ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isColor)
    }
}
