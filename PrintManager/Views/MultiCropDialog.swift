//
//  MultiCropDialog.swift
//  PrintManager
//
//  Dialog pro rozřezání naskenovaného obrázku na jednotlivé fotografie.
//  Detekce pomocí Vision, perspektivní korekce přes CoreImage.
//

import SwiftUI
import AppKit

// MARK: - Drop Delegate (přesun náhledů v gridu)

private struct PhotoDropDelegate: DropDelegate {
    let target: DetectedPhoto
    @Binding var photos: [DetectedPhoto]
    @Binding var draggedId: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId,
              let from = photos.firstIndex(where: { $0.id == draggedId }),
              let to   = photos.firstIndex(where: { $0.id == target.id }),
              from != to
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            photos.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedId = nil
        return true
    }
}

// MARK: - Main Dialog

struct MultiCropDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let file: FileItem

    @State private var detectedPhotos: [DetectedPhoto] = []
    @State private var isDetecting    = false
    @State private var isSaving       = false
    @State private var photoCount     = 0
    @State private var errorMessage: String?
    @State private var detectTask: Task<Void, Never>?
    @State private var selectedCropIdx: Int? = nil
    @State private var leftMode: LeftPanelMode = .segment
    @State private var draggedPhotoId: UUID? = nil

    enum LeftPanelMode { case segment, crop }

    // Persistentní nastavení
    @AppStorage("multiCrop.sensitivity")  private var sensitivity  = 0.5
    @AppStorage("multiCrop.minSize")      private var minSize      = 0.04
    @AppStorage("multiCrop.maxSize")      private var maxSize      = 0.50
    @AppStorage("multiCrop.trimFactor")   private var trimFactor   = 0.020

    private let service = MultiCropService()

    private var actualCount: Int {
        photoCount > 0 ? min(photoCount, detectedPhotos.count) : detectedPhotos.count
    }
    // Slice viditelných fotek – MUTABLE přes binding níže
    private var visiblePhotos: [DetectedPhoto] { Array(detectedPhotos.prefix(actualCount)) }
    private var visibleQuads: [DetectedQuad] { visiblePhotos.map(\.quad) }

    /// Popisek stepperu — jasně informuje kdy je nastaveno více než bylo nalezeno
    private var stepperLabel: String {
        if photoCount == 0 { return "Auto (\(detectedPhotos.count))" }
        if photoCount > detectedPhotos.count {
            return "\(detectedPhotos.count) / \(photoCount)"   // nalezeno/požadováno
        }
        return "\(photoCount)"
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Hlavička ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("MultiCrop")
                    .font(.headline)
                Text("— rozřezání naskenovaného obrázku")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // ── Obsah ─────────────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 0) {

                // Levý panel: obrazová část + přepínač dole
                VStack(spacing: 0) {

                    Group {
                        if leftMode == .segment {
                            ScanPreviewPanel(imageURL: file.url,
                                             quads: visibleQuads,
                                             isDetecting: isDetecting)
                        } else {
                            ZStack {
                                Color(NSColor.windowBackgroundColor)
                                if let idx = selectedCropIdx, idx < visiblePhotos.count {
                                    Image(nsImage: visiblePhotos[idx].displayImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .padding(8)
                                } else {
                                    VStack(spacing: 8) {
                                        Image(systemName: "hand.tap")
                                            .font(.system(size: 28))
                                            .foregroundColor(.secondary)
                                        Text("Vyber fotografii vpravo")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    HStack(spacing: 0) {
                        panelModeButton(title: "Segment",
                                        icon: "rectangle.dashed",
                                        mode: .segment)
                        Divider().frame(width: 1, height: 28)
                        panelModeButton(title: "Ořez okraje",
                                        icon: "crop",
                                        mode: .crop)
                    }
                    .frame(height: 30)
                    .background(Color(NSColor.controlBackgroundColor))
                }
                .frame(minWidth: 280, maxWidth: .infinity)

                Divider()

                // Pravý panel: ovládání + náhledy
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {

                            statusRow

                            Divider()

                            sliderRow(
                                label: "Citlivost detekce",
                                leftLabel: "Méně",
                                rightLabel: "Více",
                                value: $sensitivity,
                                range: 0.1...0.9
                            )

                            sliderRow(
                                label: "Min. velikost fotografie: \(Int(minSize * 100)) % plochy",
                                leftLabel: "Malé",
                                rightLabel: "Velké",
                                value: $minSize,
                                range: 0.01...0.20
                            )

                            sliderRow(
                                label: "Max. velikost fotografie: \(Int(maxSize * 100)) % plochy",
                                leftLabel: "Malé",
                                rightLabel: "Velké",
                                value: $maxSize,
                                range: 0.10...0.85
                            )

                            sliderRow(
                                label: "Ořez okraje: \(String(format: "%.1f", trimFactor * 100)) %",
                                leftLabel: "Méně",
                                rightLabel: "Více",
                                value: $trimFactor,
                                range: 0.002...0.06,
                                onEditing: { editing in
                                    if editing && !visiblePhotos.isEmpty {
                                        if selectedCropIdx == nil { selectedCropIdx = 0 }
                                        leftMode = .crop
                                    }
                                }
                            )

                            countRow

                            Divider()

                            // Náhledy oříznutých fotografií
                            HStack {
                                Text("Náhledy (\(visiblePhotos.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if !visiblePhotos.isEmpty {
                                    Spacer()
                                    Text("Táhni pro přesunutí · ⟳ = otočit CW")
                                        .font(.caption2)
                                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                }
                            }

                            if visiblePhotos.isEmpty && !isDetecting {
                                Text("Žádné fotografie.\nZkus zvýšit citlivost nebo\nupravit min./max. velikost.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            } else {
                                photoGrid
                            }
                        }
                        .padding(12)
                    }

                    Divider()

                    HStack {
                        Button("Zrušit") { isPresented = false }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        if isSaving {
                            ProgressView().scaleEffect(0.7)
                        }
                        Button("Uložit \(actualCount) fotografií") { savePhotos() }
                            .buttonStyle(.borderedProminent)
                            .disabled(visiblePhotos.isEmpty || isDetecting || isSaving)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(width: 320)
            }
        }
        .frame(minWidth: 640, idealWidth: 760,
               maxWidth: .infinity,
               minHeight: 500, idealHeight: 640,
               maxHeight: .infinity)
        .onAppear { scheduleDetect() }
        .onDisappear {
            detectTask?.cancel()
            detectTask = nil
            isDetecting = false
        }
    }

    // MARK: - Photo Grid (drag-and-drop reorder)

    @ViewBuilder
    private var photoGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 88), spacing: 6)],
            spacing: 6
        ) {
            ForEach(Array(detectedPhotos.prefix(actualCount).enumerated()),
                    id: \.element.id) { idx, photo in
                photoThumbnail(photo: photo, idx: idx)
                    // Drag source
                    .onDrag {
                        draggedPhotoId = photo.id
                        return NSItemProvider(object: photo.id.uuidString as NSString)
                    } preview: {
                        Image(nsImage: photo.displayImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 88, height: 88)
                            .clipped()
                            .cornerRadius(6)
                    }
                    // Drop target pro přeskupení
                    .onDrop(
                        of: [.text],
                        delegate: PhotoDropDelegate(
                            target: photo,
                            photos: $detectedPhotos,
                            draggedId: $draggedPhotoId
                        )
                    )
                    .opacity(draggedPhotoId == photo.id ? 0.45 : 1.0)
            }
        }
    }

    @ViewBuilder
    private func photoThumbnail(photo: DetectedPhoto, idx: Int) -> some View {
        let isSelected = selectedCropIdx == idx
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 2) {
                Image(nsImage: photo.displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 88, height: 88)
                    .clipped()
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isSelected
                                    ? Color.accentColor
                                    : Color.accentColor.opacity(0.35),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                Text("\(idx + 1)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .onTapGesture {
                selectedCropIdx = idx
                leftMode = .crop
            }

            // Tlačítko rotace (CW 90°)
            Button {
                detectedPhotos[idx].rotateCW90()
                // Obnoví preview vlevo pokud je vybraný
                if selectedCropIdx == idx { leftMode = .crop }
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(3)
                    .background(Color.black.opacity(0.5))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.borderless)
            .offset(x: -2, y: 2)
            .help("Otočit 90° CW")
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            if isDetecting {
                ProgressView().scaleEffect(0.7)
                Text("Detekuji fotografie…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if let err = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Image(systemName: detectedPhotos.isEmpty ? "questionmark.circle" : "checkmark.circle.fill")
                    .foregroundColor(detectedPhotos.isEmpty ? .secondary : .green)
                Text(detectedPhotos.isEmpty
                     ? "Žádné fotografie nenalezeny"
                     : "Nalezeno \(detectedPhotos.count) fotografií")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Spacer()
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func sliderRow(label: String, leftLabel: String, rightLabel: String,
                           value: Binding<Double>, range: ClosedRange<Double>,
                           onEditing: ((Bool) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text(leftLabel).font(.caption2).foregroundColor(.secondary)
                Slider(value: value, in: range) { editing in
                    onEditing?(editing)
                    if !editing { scheduleDetect() }
                }
                Text(rightLabel).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var countRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Počet fotografií")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(photoCount == 0 ? "automaticky" : "ručně nastaveno")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if photoCount > 0 {
                Button("Auto") { photoCount = 0 }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
            }
            Stepper(
                stepperLabel,
                value: $photoCount,
                in: 0...20,   // max 20 — vždy lze zvýšit bez ohledu na detekci
                step: 1
            )
            .font(.caption)
            .frame(width: 140)
        }
    }

    @ViewBuilder
    private func panelModeButton(title: String, icon: String, mode: LeftPanelMode) -> some View {
        Button {
            leftMode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundColor(leftMode == mode ? .accentColor : .secondary)
        .background(leftMode == mode ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    // MARK: - Detection

    private func scheduleDetect(delay: UInt64 = 0) {
        detectTask?.cancel()
        detectTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            await runDetection()
        }
    }

    @MainActor
    private func runDetection() async {
        isDetecting  = true
        errorMessage = nil
        defer { isDetecting = false }
        do {
            let photos = try await service.detect(
                imageURL: file.url,
                sensitivity: Float(sensitivity),
                minRelativeSize: Float(minSize),
                maxRelativeSize: Float(maxSize),
                maxCount: 20,
                trimFactor: trimFactor
            )
            guard !Task.isCancelled else { return }
            detectedPhotos = photos
            // Oprav photoCount pokud přesahuje nově detekovaný počet
            if photoCount > detectedPhotos.count { photoCount = 0 }
            if let idx = selectedCropIdx {
                if detectedPhotos.isEmpty { selectedCropIdx = nil }
                else if idx >= detectedPhotos.count { selectedCropIdx = detectedPhotos.count - 1 }
            }
        } catch is CancellationError {
            // Tichý exit — dialog byl zavřen
        } catch {
            errorMessage   = error.localizedDescription
            detectedPhotos = []
        }
    }

    // MARK: - Save

    private func savePhotos() {
        let photos = visiblePhotos
        isSaving = true
        Task {
            do {
                let urls = try service.save(photos, basedOn: file.url)
                await MainActor.run {
                    isSaving = false
                    isPresented = false
                    let countBefore = appState.files.count
                    appState.addFiles(urls: urls)
                    let newIds = Set(appState.files.dropFirst(countBefore).map(\.id))
                    if !newIds.isEmpty { appState.selectedFiles = newIds }
                    appState.logSuccess("MultiCrop: uloženo \(urls.count) fotografií z \(file.name)")
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Scan Preview Panel

struct ScanPreviewPanel: View {
    let imageURL: URL
    let quads: [DetectedQuad]
    let isDetecting: Bool

    @State private var nsImage: NSImage?

    private let overlayColors: [Color] = [
        .orange, .blue, .green, .purple, .red, .cyan, .yellow, .mint, .pink, .indigo
    ]

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            if let img = nsImage {
                GeometryReader { geo in
                    let imgSize  = img.size
                    let scale    = min(geo.size.width / imgSize.width, geo.size.height / imgSize.height)
                    let scaledW  = imgSize.width  * scale
                    let scaledH  = imgSize.height * scale
                    let offX     = (geo.size.width  - scaledW) / 2
                    let offY     = (geo.size.height - scaledH) / 2

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)

                        Canvas { ctx, size in
                            for (i, quad) in quads.enumerated() {
                                let pts: [CGPoint] = [quad.topLeft, quad.topRight,
                                                      quad.bottomRight, quad.bottomLeft].map { p in
                                    CGPoint(x: offX + p.x * scaledW,
                                            y: offY + (1 - p.y) * scaledH)
                                }
                                var path = Path()
                                path.move(to: pts[0])
                                pts.dropFirst().forEach { path.addLine(to: $0) }
                                path.closeSubpath()

                                let col = overlayColors[i % overlayColors.count]
                                ctx.fill(path,   with: .color(col.opacity(0.18)))
                                ctx.stroke(path, with: .color(col), lineWidth: 2)

                                let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
                                let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
                                ctx.draw(
                                    Text("\(i + 1)")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(col),
                                    at: CGPoint(x: cx, y: cy),
                                    anchor: .center
                                )
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                    }
                }
            } else {
                ProgressView()
            }

            if isDetecting {
                Color.black.opacity(0.25)
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Detekuji…")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear { nsImage = NSImage(contentsOf: imageURL) }
    }
}
