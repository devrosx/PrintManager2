//
//  MultiCropDialog.swift
//  PrintManager
//
//  Dialog pro rozřezání naskenovaného obrázku na fotografie.
//  Čistá Swift implementace – bez OpenCV.
//
//  Funkce:
//  • Auto-detekce fotografií na skenovaném obrázku
//  • Klik na fotografii → vybrání a zobrazení úchytů
//  • Tahem rohů: volný pohyb rohu
//  • Tahem středu hrany: pohyb kolmo na hranu
//  • ⌘ + tah: zobrazí lupu pro přesné nastavení
//  • Velikost okna se ukládá
//

import SwiftUI
import AppKit

// MARK: - Handle Kind

private enum HandleKind: Equatable {
    case corner(Int)   // 0=TL 1=TR 2=BL 3=BR
    case edge(Int)     // 0=top 1=right 2=bottom 3=left
}

private struct HandleInfo {
    var photoIdx: Int
    var kind: HandleKind
    var startQuad: DetectedQuad
}

// MARK: - DetectedQuad helpers

private extension DetectedQuad {
    var corners: [CGPoint] { [topLeft, topRight, bottomLeft, bottomRight] }

    var edgeMids: [CGPoint] {
        [
            mid(topLeft, topRight),        // 0 top
            mid(topRight, bottomRight),    // 1 right
            mid(bottomLeft, bottomRight),  // 2 bottom
            mid(topLeft, bottomLeft),      // 3 left
        ]
    }

    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    func movingCorner(_ idx: Int, to pt: CGPoint) -> DetectedQuad {
        var tl = topLeft, tr = topRight, bl = bottomLeft, br = bottomRight
        switch idx {
        case 0: tl = pt
        case 1: tr = pt
        case 2: bl = pt
        default: br = pt
        }
        return DetectedQuad(topLeft: tl, topRight: tr, bottomLeft: bl, bottomRight: br)
    }

    func movingEdge(_ idx: Int, delta: CGPoint) -> DetectedQuad {
        func sh(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.x, y: p.y + delta.y) }
        var tl = topLeft, tr = topRight, bl = bottomLeft, br = bottomRight
        switch idx {
        case 0: tl = sh(tl); tr = sh(tr)     // top
        case 1: tr = sh(tr); br = sh(br)     // right
        case 2: bl = sh(bl); br = sh(br)     // bottom
        default: tl = sh(tl); bl = sh(bl)   // left
        }
        return DetectedQuad(topLeft: tl, topRight: tr, bottomLeft: bl, bottomRight: br)
    }

    /// Normalizovaný normálový vektor kolmý na danou hranu (Vision souřadnice, y-nahoru).
    func edgeNormal(_ idx: Int) -> CGPoint {
        let (a, b): (CGPoint, CGPoint)
        switch idx {
        case 0: (a, b) = (topLeft, topRight)
        case 1: (a, b) = (topRight, bottomRight)
        case 2: (a, b) = (bottomLeft, bottomRight)
        default: (a, b) = (topLeft, bottomLeft)
        }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: -dy / len, y: dx / len)
    }
}

// MARK: - Magnifier View

private struct MagnifierView: View {
    let source: NSImage
    let focusNorm: CGPoint  // Vision coords: 0-1, y-up
    let position: CGPoint   // střed lupy v souřadnicích rodiče

    private let diameter: CGFloat = 140
    private let zoom: CGFloat = 4

    private var croppedImage: NSImage {
        let sz = source.size
        // NSImage má y-up stejně jako Vision → přímé mapování
        let cx = focusNorm.x * sz.width
        let cy = focusNorm.y * sz.height
        let visW = diameter / zoom
        let visH = diameter / zoom
        let src = NSRect(
            x: cx - visW / 2, y: cy - visH / 2,
            width: visW, height: visH
        )
        let out = NSImage(size: NSSize(width: diameter, height: diameter))
        out.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: NSSize(width: diameter, height: diameter)),
            from: src, operation: .copy, fraction: 1.0
        )
        out.unlockFocus()
        return out
    }

    var body: some View {
        ZStack {
            Image(nsImage: croppedImage)
                .resizable()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
            // Nitkový kříž
            ZStack {
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 1, height: diameter * 0.55)
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: diameter * 0.55, height: 1)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 2)
        .position(x: position.x, y: position.y)
        .allowsHitTesting(false)
    }
}

// MARK: - Window autosave

private struct WindowAutoSave: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.setFrameAutosaveName(name) }
    }
}

// MARK: - Interactive Scan View

private struct InteractiveScanView: View {
    let imageURL: URL
    @Binding var photos: [DetectedPhoto]
    @Binding var selectedIdx: Int?
    let visibleCount: Int
    let isDetecting: Bool
    let trimFactor: Double
    let service: MultiCropService

    @State private var nsImage: NSImage?
    @State private var dragging: HandleInfo?
    @State private var dragScreenPos: CGPoint = .zero
    @State private var showMagnifier = false

    private let overlayColors: [Color] = [
        .orange, .blue, .green, .purple, .red, .cyan, .yellow, .mint, .pink, .indigo,
    ]
    private let handleR: CGFloat = 7    // poloměr kreslení
    private let hitR: CGFloat = 16      // poloměr pro zachycení

    var body: some View {
        GeometryReader { geo in
            let imgRect = nsImage.map { fitRect(imgSize: $0.size, in: geo.size) } ?? .zero

            ZStack {
                DS.Colors.windowBackground

                if let img = nsImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)

                    // Quad přehledy (canvas, no hit-testing)
                    Canvas { ctx, _ in
                        drawAllQuads(ctx: ctx, imgRect: imgRect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                    // Průhledná vrstva pro gesta
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(mainGesture(imgRect: imgRect))

                    // Úchyty pro vybraný quad
                    if let idx = selectedIdx, idx < visibleCount, idx < photos.count {
                        handlesLayer(idx: idx, imgRect: imgRect, size: geo.size)
                    }

                    // Rotační tlačítka vedle středových bodů (musí být nad gesture vrstvou)
                    rotationButtonsLayer(imgRect: imgRect, size: geo.size)

                    // Lupa (zobrazena při tahu)
                    if showMagnifier, let img = nsImage {
                        let focusNorm = toNorm(dragScreenPos, imgRect: imgRect)
                        let offset = lupOffset(pos: dragScreenPos, size: geo.size)
                        MagnifierView(
                            source: img,
                            focusNorm: focusNorm,
                            position: CGPoint(
                                x: dragScreenPos.x + offset.x,
                                y: dragScreenPos.y + offset.y
                            )
                        )
                    }
                } else {
                    ProgressView()
                }

                if isDetecting {
                    Color.black.opacity(0.25)
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Detekuji…").font(.caption).foregroundColor(.white)
                    }
                }
            }
        }
        .onAppear {
            nsImage = NSImage(contentsOf: imageURL)
        }
    }

    // MARK: - Souřadnicové pomocné funkce

    func fitRect(imgSize: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / imgSize.width, container.height / imgSize.height)
        let w = imgSize.width * scale, h = imgSize.height * scale
        return CGRect(
            x: (container.width - w) / 2,
            y: (container.height - h) / 2,
            width: w, height: h
        )
    }

    /// Vision (0-1, y-up) → souřadnice SwiftUI view (y-down)
    func toScreen(_ p: CGPoint, imgRect: CGRect) -> CGPoint {
        CGPoint(
            x: imgRect.minX + p.x * imgRect.width,
            y: imgRect.minY + (1 - p.y) * imgRect.height
        )
    }

    /// SwiftUI view souřadnice (y-down) → Vision (0-1, y-up)
    func toNorm(_ p: CGPoint, imgRect: CGRect) -> CGPoint {
        CGPoint(
            x: (p.x - imgRect.minX) / imgRect.width,
            y: 1 - (p.y - imgRect.minY) / imgRect.height
        )
    }

    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    func clamp01(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(1, p.x)), y: max(0, min(1, p.y)))
    }

    /// Posun lupy od kurzoru tak, aby nevylézala z panelu.
    func lupOffset(pos: CGPoint, size: CGSize) -> CGPoint {
        let d: CGFloat = 85
        let right = pos.x + d + 75 < size.width
        let up    = pos.y - d - 75 > 0
        return CGPoint(x: right ? d : -d, y: up ? -d : d)
    }

    // MARK: - Kreslení

    func drawAllQuads(ctx: GraphicsContext, imgRect: CGRect) {
        for (i, photo) in photos.prefix(visibleCount).enumerated() {
            let quad = photo.quad
            let isSelected = selectedIdx == i
            let color = overlayColors[i % overlayColors.count]

            let pts = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
                .map { toScreen($0, imgRect: imgRect) }

            var path = Path()
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()

            ctx.fill(path, with: .color(color.opacity(isSelected ? 0.22 : 0.10)))
            ctx.stroke(
                path,
                with: .color(color.opacity(isSelected ? 1.0 : 0.65)),
                style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, dash: isSelected ? [] : [6, 3])
            )

            // Číslo pro vybraný quad (nevybrané mají číslo v SwiftUI button vrstvě)
            if isSelected {
                let cx = pts.map(\.x).reduce(0, +) / 4
                let cy = pts.map(\.y).reduce(0, +) / 4
                ctx.draw(
                    Text("\(i + 1)").font(.system(size: 14, weight: .bold)).foregroundColor(color),
                    at: CGPoint(x: cx, y: cy), anchor: .center
                )
            }
        }
    }

    @ViewBuilder
    func handlesLayer(idx: Int, imgRect: CGRect, size: CGSize) -> some View {
        let quad = photos[idx].quad
        let color = overlayColors[idx % overlayColors.count]

        ZStack {
            // Rohové úchyty (kruhy)
            ForEach(0..<4, id: \.self) { ci in
                let pt = toScreen(quad.corners[ci], imgRect: imgRect)
                Circle()
                    .fill(Color.white)
                    .frame(width: handleR * 2, height: handleR * 2)
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(pt)
                    .allowsHitTesting(false)
            }

            // Hraniční úchyty (čtverce, pootočené dle orientace hrany)
            ForEach(0..<4, id: \.self) { ei in
                let pt = toScreen(quad.edgeMids[ei], imgRect: imgRect)
                let isHoriz = ei == 0 || ei == 2   // top/bottom → pohyb svisle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(
                        width: isHoriz ? handleR * 2.2 : handleR * 1.2,
                        height: isHoriz ? handleR * 1.2 : handleR * 2.2
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(pt)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Středové body + rotační tlačítka v obrázku

    @ViewBuilder
    func rotationButtonsLayer(imgRect: CGRect, size: CGSize) -> some View {
        let dotD: CGFloat = 22   // průměr středového kruhu
        let btnD: CGFloat = 22   // průměr rotačního tlačítka
        let gap: CGFloat  = 4    // mezera mezi nimi

        ZStack {
            ForEach(Array(photos.prefix(visibleCount).enumerated()), id: \.element.id) { idx, photo in
                let isSelected = selectedIdx == idx
                let center = quadCenter(photo.quad, imgRect: imgRect)
                let color  = overlayColors[idx % overlayColors.count]

                // ── Středový kruh s číslem (klik = výběr) ──────────────────
                Button {
                    selectedIdx = idx
                } label: {
                    ZStack {
                        Circle()
                            .fill(isSelected ? color : color.opacity(0.88))
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: isSelected ? 2 : 1.2)
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: dotD, height: dotD)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .scaleEffect(isSelected ? 1.15 : 1.0)
                }
                .buttonStyle(.borderless)
                .position(x: center.x, y: center.y)

                // ── Rotační tlačítko (klik = otočit CW) ────────────────────
                Button {
                    photos[idx].rotateCW90()
                } label: {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.88))
                        Circle()
                            .stroke(Color.white.opacity(0.75), lineWidth: 1.2)
                        Image(systemName: "rotate.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: btnD, height: btnD)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                }
                .buttonStyle(.borderless)
                .position(x: center.x + dotD / 2 + gap + btnD / 2, y: center.y)
                .help("Otočit 90° CW")
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Gesta

    func mainGesture(imgRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { val in
                dragScreenPos = val.location

                if dragging == nil {
                    // První pohyb – zkus najít úchyt u startovní polohy
                    dragging = findHandle(at: val.startLocation, imgRect: imgRect)
                    guard dragging != nil else { return }
                }

                guard let info = dragging else { return }
                showMagnifier = true

                let normNow   = toNorm(val.location, imgRect: imgRect)
                let normStart = toNorm(val.startLocation, imgRect: imgRect)
                let delta = CGPoint(
                    x: normNow.x - normStart.x,
                    y: normNow.y - normStart.y
                )

                let newQuad: DetectedQuad
                switch info.kind {
                case .corner(let ci):
                    newQuad = info.startQuad.movingCorner(ci, to: clamp01(normNow))
                case .edge(let ei):
                    // Promítni delta na normálu hrany (pohyb kolmo na hranu)
                    let n = info.startQuad.edgeNormal(ei)
                    let proj = delta.x * n.x + delta.y * n.y
                    newQuad = info.startQuad.movingEdge(ei, delta: CGPoint(x: n.x * proj, y: n.y * proj))
                }

                photos[info.photoIdx].quad = newQuad
            }
            .onEnded { val in
                let wasDragging = dragging != nil

                if !wasDragging {
                    // Klik bez tažení → vyber fotografii pod kurzorem
                    let norm = toNorm(val.location, imgRect: imgRect)
                    selectPhotoAt(norm, imgRect: imgRect)
                } else if let info = dragging {
                    // Tažení skončilo → regeneruj ořez s novým quadem
                    let idx = info.photoIdx
                    Task {
                        await regenerateCrop(idx: idx)
                    }
                }

                dragging = nil
                showMagnifier = false
            }
    }

    func findHandle(at screenPt: CGPoint, imgRect: CGRect) -> HandleInfo? {
        guard let idx = selectedIdx, idx < visibleCount, idx < photos.count else { return nil }
        let quad = photos[idx].quad

        // Rohy mají prioritu
        for (ci, cp) in quad.corners.enumerated() {
            if dist(screenPt, toScreen(cp, imgRect: imgRect)) < hitR {
                return HandleInfo(photoIdx: idx, kind: .corner(ci), startQuad: quad)
            }
        }

        // Středy hran
        for (ei, ep) in quad.edgeMids.enumerated() {
            if dist(screenPt, toScreen(ep, imgRect: imgRect)) < hitR {
                return HandleInfo(photoIdx: idx, kind: .edge(ei), startQuad: quad)
            }
        }

        return nil
    }

    func selectPhotoAt(_ normPt: CGPoint, imgRect: CGRect) {
        let screenPt = toScreen(normPt, imgRect: imgRect)

        // Nejdřív zkontroluj klik na středový bod (priorita)
        for (i, photo) in photos.prefix(visibleCount).enumerated() {
            guard i != selectedIdx else { continue }
            let quad = photo.quad
            let center = quadCenter(quad, imgRect: imgRect)
            if dist(screenPt, center) < 16 {
                selectedIdx = i
                return
            }
        }

        // Pak klik na čáru rámečku
        for (i, photo) in photos.prefix(visibleCount).enumerated() {
            guard i != selectedIdx else { continue }
            if nearQuadBorder(photo.quad, screenPt: screenPt, imgRect: imgRect, threshold: 8) {
                selectedIdx = i
                return
            }
        }

        // Nakonec klik kdekoliv uvnitř quadu
        for (i, photo) in photos.prefix(visibleCount).enumerated() {
            if quadContains(photo.quad, point: normPt) {
                selectedIdx = i
                return
            }
        }

        selectedIdx = nil
    }

    func quadCenter(_ quad: DetectedQuad, imgRect: CGRect) -> CGPoint {
        let pts = quad.corners.map { toScreen($0, imgRect: imgRect) }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / 4, y: pts.map(\.y).reduce(0, +) / 4)
    }

    func nearQuadBorder(_ quad: DetectedQuad, screenPt: CGPoint, imgRect: CGRect, threshold: CGFloat) -> Bool {
        let pts = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            .map { toScreen($0, imgRect: imgRect) }
        let edges = [(pts[0], pts[1]), (pts[1], pts[2]), (pts[2], pts[3]), (pts[3], pts[0])]
        for (a, b) in edges {
            if distToSegment(screenPt, a: a, b: b) < threshold { return true }
        }
        return false
    }

    func distToSegment(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    func quadContains(_ quad: DetectedQuad, point: CGPoint) -> Bool {
        let xs = quad.corners.map(\.x)
        let ys = quad.corners.map(\.y)
        return point.x >= (xs.min() ?? 0) && point.x <= (xs.max() ?? 1)
            && point.y >= (ys.min() ?? 0) && point.y <= (ys.max() ?? 1)
    }

    @MainActor
    func regenerateCrop(idx: Int) async {
        guard idx < photos.count else { return }
        let quad = photos[idx].quad
        guard let newImg = try? service.recrop(imageURL: imageURL, quad: quad, trimFactor: trimFactor) else { return }
        photos[idx].croppedImage = newImg
        photos[idx].rotationCCW = 0   // reset rotace po ruční editaci
    }
}

// MARK: - Drop Delegate

private struct PhotoDropDelegate: DropDelegate {
    let target: DetectedPhoto
    @Binding var photos: [DetectedPhoto]
    @Binding var draggedId: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let draggedId,
              let from = photos.firstIndex(where: { $0.id == draggedId }),
              let to   = photos.firstIndex(where: { $0.id == target.id }),
              from != to
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            photos.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool { draggedId = nil; return true }
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
    @State private var selectedIdx: Int? = nil
    @State private var draggedPhotoId: UUID? = nil

    @AppStorage("multiCrop.sensitivity") private var sensitivity = 0.5
    @AppStorage("multiCrop.minSize")     private var minSize     = 0.04
    @AppStorage("multiCrop.maxSize")     private var maxSize     = 0.50
    @AppStorage("multiCrop.trimFactor")  private var trimFactor  = 0.020

    private let service = MultiCropService()

    private var actualCount: Int {
        photoCount > 0 ? min(photoCount, detectedPhotos.count) : detectedPhotos.count
    }
    private var visiblePhotos: [DetectedPhoto] { Array(detectedPhotos.prefix(actualCount)) }

    private var stepperLabel: String {
        if photoCount == 0 { return "Auto (\(detectedPhotos.count))" }
        if photoCount > detectedPhotos.count { return "\(detectedPhotos.count) / \(photoCount)" }
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

                // Levý panel: interaktivní náhled
                InteractiveScanView(
                    imageURL: file.url,
                    photos: $detectedPhotos,
                    selectedIdx: $selectedIdx,
                    visibleCount: actualCount,
                    isDetecting: isDetecting,
                    trimFactor: trimFactor,
                    service: service
                )
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Pravý panel: ovládání + náhledy
                rightPanel
                    .frame(width: 300)
            }
        }
        .background(WindowAutoSave(name: "MultiCropDialog"))
        .frame(
            minWidth: 680, idealWidth: 860, maxWidth: .infinity,
            minHeight: 520, idealHeight: 680, maxHeight: .infinity
        )
        .onAppear { scheduleDetect() }
        .onDisappear {
            detectTask?.cancel()
            detectTask = nil
        }
    }

    // MARK: - Pravý panel

    @ViewBuilder
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    statusRow
                    Divider()

                    sliderRow(
                        label: "Citlivost detekce",
                        leftLabel: "Méně", rightLabel: "Více",
                        value: $sensitivity, range: 0.1...0.9
                    )
                    sliderRow(
                        label: "Min. velikost: \(Int(minSize * 100)) % plochy",
                        leftLabel: "Malé", rightLabel: "Velké",
                        value: $minSize, range: 0.01...0.20
                    )
                    sliderRow(
                        label: "Max. velikost: \(Int(maxSize * 100)) % plochy",
                        leftLabel: "Malé", rightLabel: "Velké",
                        value: $maxSize, range: 0.10...0.85
                    )
                    sliderRow(
                        label: "Ořez okraje: \(String(format: "%.1f", trimFactor * 100)) %",
                        leftLabel: "Méně", rightLabel: "Více",
                        value: $trimFactor, range: 0.002...0.06
                    )

                    countRow
                    Divider()

                    HStack {
                        Text("Náhledy (\(visiblePhotos.count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !visiblePhotos.isEmpty {
                            Spacer()
                            Text("klik = výběr · tah = lupa")
                                .font(.caption2)
                                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        }
                    }

                    if visiblePhotos.isEmpty && !isDetecting {
                        Text("Žádné fotografie.\nZkus zvýšit citlivost nebo upravit min./max. velikost.")
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
                if isSaving { ProgressView().scaleEffect(0.7) }
                Button("Uložit \(actualCount) fotografií") { savePhotos() }
                    .buttonStyle(.borderedProminent)
                    .disabled(visiblePhotos.isEmpty || isDetecting || isSaving)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Photo Grid

    @ViewBuilder
    private var photoGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 84), spacing: 6)],
            spacing: 6
        ) {
            ForEach(Array(detectedPhotos.prefix(actualCount).enumerated()), id: \.element.id) { idx, photo in
                photoThumbnail(photo: photo, idx: idx)
                    .onDrag {
                        draggedPhotoId = photo.id
                        return NSItemProvider(object: photo.id.uuidString as NSString)
                    } preview: {
                        Image(nsImage: photo.displayImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipped()
                            .cornerRadius(DS.Radius.small)
                    }
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
        let isSelected = selectedIdx == idx
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 2) {
                Image(nsImage: photo.displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 84)
                    .clipped()
                    .cornerRadius(DS.Radius.small)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isSelected ? Color.accentColor : Color.accentColor.opacity(0.35),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                Text("\(idx + 1)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .onTapGesture {
                selectedIdx = idx
            }

            Button {
                detectedPhotos[idx].rotateCW90()
            } label: {
                Image(systemName: "rotate.right")
                    .font(DS.Typography.menuChevron)
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

    // MARK: - Ovládací prvky

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            if isDetecting {
                ProgressView().scaleEffect(0.7)
                Text("Detekuji fotografie…").font(.subheadline).foregroundColor(.secondary)
            } else if let err = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(err).font(.caption).foregroundColor(.red)
            } else {
                Image(
                    systemName: detectedPhotos.isEmpty
                        ? "questionmark.circle" : "checkmark.circle.fill"
                )
                .foregroundColor(detectedPhotos.isEmpty ? .secondary : .green)
                Text(
                    detectedPhotos.isEmpty
                        ? "Žádné fotografie nenalezeny"
                        : "Nalezeno \(detectedPhotos.count) fotografií"
                )
                .font(.subheadline)
                .fontWeight(.semibold)
            }
            Spacer()
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func sliderRow(
        label: String, leftLabel: String, rightLabel: String,
        value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text(leftLabel).font(.caption2).foregroundColor(.secondary)
                Slider(value: value, in: range) { editing in
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
                Text("Počet fotografií").font(.caption).foregroundColor(.secondary)
                Text(photoCount == 0 ? "automaticky" : "ručně nastaveno")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if photoCount > 0 {
                Button("Auto") { photoCount = 0 }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
            }
            Stepper(stepperLabel, value: $photoCount, in: 0...20, step: 1)
                .font(.caption)
                .frame(width: 140)
        }
    }

    // MARK: - Detekce

    private func scheduleDetect() {
        detectTask?.cancel()
        detectTask = Task { @MainActor in
            await runDetection()
        }
    }

    @MainActor
    private func runDetection() async {
        isDetecting = true
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
            if photoCount > detectedPhotos.count { photoCount = 0 }
            if let idx = selectedIdx {
                if detectedPhotos.isEmpty { selectedIdx = nil }
                else if idx >= detectedPhotos.count { selectedIdx = detectedPhotos.count - 1 }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            detectedPhotos = []
        }
    }

    // MARK: - Uložení

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
