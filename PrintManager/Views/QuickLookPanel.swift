//
//  QuickLookPanel.swift
//  PrintManager
//
//  Spacebar Quick Look — velký náhled souboru v plovoucím okně.
//  Šipky nahoru/dolů navigují v seznamu, mezerník/Esc zavírá.
//

import SwiftUI
import AppKit
import PDFKit
import Foundation

// MARK: - Controller

final class QuickLookController {
    static let shared = QuickLookController()

    private var panel: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var keyMonitor: Any?
    private weak var appState: AppState?

    // Otevři nebo zavři panel
    func toggle(appState: AppState) {
        if panel?.isVisible == true {
            dismiss()
        } else {
            present(appState: appState)
        }
    }

    func present(appState: AppState) {
        // Nastav quickLookFileID na aktuálně vybraný soubor
        if let firstID = appState.selectedFiles.first {
            appState.quickLookFileID = firstID
        } else if let firstFile = appState.files.first {
            appState.quickLookFileID = firstFile.id
        } else {
            return
        }

        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 980),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Look"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(white: 0.08, alpha: 1) // DS.Colors.darkBackground
        window.minSize = CGSize(width: 360, height: 400)
        window.isReleasedWhenClosed = false
        window.level = .floating

        let rootView = QuickLookView(controller: self)
            .environmentObject(appState)
        let hc = NSHostingController(rootView: AnyView(rootView))
        window.contentView = hc.view
        hosting = hc

        if let main = NSApp.mainWindow {
            window.center()
            // Vycentruj přibližně na střed hlavního okna
            let mf = main.frame
            let pw = window.frame
            window.setFrameOrigin(NSPoint(
                x: mf.midX - pw.width / 2,
                y: mf.midY - pw.height / 2
            ))
        } else {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        panel = window

        // Monitor keyboard events while panel is visible
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            switch event.keyCode {
            case 49: // spacebar - toggle close
                DispatchQueue.main.async { self.dismiss() }
                return nil
            case 53: // Escape - close
                DispatchQueue.main.async { self.dismiss() }
                return nil
            case 126: // arrow up - previous file
                DispatchQueue.main.async { appState.quickLookMoveUp() }
                return nil
            case 125: // arrow down - next file
                DispatchQueue.main.async { appState.quickLookMoveDown() }
                return nil
            case 123: // arrow left - previous page
                NotificationCenter.default.post(name: .quickLookPagePrevious, object: nil)
                return nil
            case 124: // arrow right - next page
                NotificationCenter.default.post(name: .quickLookPageNext, object: nil)
                return nil
            default:
                return event
            }
        }
    }

    func dismiss() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.close()
        panel = nil
        hosting = nil
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI View

struct QuickLookView: View {
    @EnvironmentObject var appState: AppState
    let controller: QuickLookController

    @State private var currentPage: Int = 0
    @State private var fileID: UUID? = nil
    @State private var showThumbnails: Bool = false

    private var file: FileItem? {
        guard let id = fileID else { return nil }
        return appState.files.first(where: { $0.id == id })
    }

    private var fileIndex: Int? {
        guard let id = fileID else { return nil }
        return appState.files.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Horní lišta
            HStack(spacing: DS.Spacing.medium) {
                // Navigace
                Button {
                    appState.quickLookMoveUp()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(DS.Typography.navIcon)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white)
                .disabled(fileIndex == nil || fileIndex == 0)
                .accessibilityLabel("Previous file")

                Button {
                    appState.quickLookMoveDown()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(DS.Typography.navIcon)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white)
                .disabled(fileIndex == nil || fileIndex == appState.files.count - 1)
                .accessibilityLabel("Next file")

                Divider()
                    .frame(height: DS.Spacing.large)
                    .background(Color.white.opacity(0.3))

                // Thumbnail toggle (only for multi-page files)
                if let f = file, f.pageCount > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showThumbnails.toggle()
                        }
                    } label: {
                        Image(systemName: showThumbnails ? "rectangle.stack.fill" : "rectangle.stack")
                            .font(DS.Typography.navIcon)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(showThumbnails ? .white : .white.opacity(0.6))
                    .help("Zobrazit náhledy stránek")
                    .accessibilityLabel("Toggle thumbnails")
                }

                Spacer()

                if let f = file {
                    Text(f.name)
                        .font(DS.Typography.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let idx = fileIndex {
                    Text("\(idx + 1) / \(appState.files.count)")
                        .font(DS.Typography.caption)
                        .foregroundColor(.white.opacity(0.5))
                }

                Button {
                    controller.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Quick Look")
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.top, 44)   // pod titlebar
            .padding(.bottom, DS.Spacing.smallMedium)

            Divider()
                .background(Color.white.opacity(0.15))

            // Hlavní obsah
            if let f = file {
                if showThumbnails && f.pageCount > 1 {
                    // Režim thumbnailů
                    QuickLookThumbnailsView(
                        file: f,
                        currentPage: $currentPage,
                        showThumbnails: $showThumbnails
                    )
                } else {
                    // Normální náhled s navigací klikáním
                    GeometryReader { geometry in
                        QuickLookPreviewContent(file: f, currentPage: $currentPage)
                            .id("\(f.id)-\(f.contentVersion)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(
                                HStack {
                                    // Levá polovina - předchozí strana
                                    if currentPage > 0 {
                                        Color.clear
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    currentPage -= 1
                                                }
                                            }
                                            .gesture(
                                                DragGesture(minimumDistance: 50)
                                                    .onEnded { value in
                                                        if value.translation.width > 30 {
                                                            withAnimation {
                                                                currentPage -= 1
                                                            }
                                                        }
                                                    }
                                            )
                                    }

                                    Spacer()

                                    // Pravá polovina - následující strana
                                    if currentPage < f.pageCount - 1 {
                                        Color.clear
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    currentPage += 1
                                                }
                                            }
                                            .gesture(
                                                DragGesture(minimumDistance: 50)
                                                    .onEnded { value in
                                                        if value.translation.width < -30 {
                                                            withAnimation {
                                                                currentPage += 1
                                                            }
                                                        }
                                                    }
                                            )
                                    }
                                }
                            )
                    }
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Stránkování (PDF)
            if let f = file, f.pageCount > 1 {
                Divider()
                    .background(Color.white.opacity(0.15))

                HStack(spacing: DS.Spacing.large) {
                    Button {
                        if currentPage > 0 { currentPage -= 1 }
                    } label: {
                        Image(systemName: "arrow.left.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.white.opacity(0.8))
                    .disabled(currentPage == 0)
                    .accessibilityLabel("Previous page")

                    Text("Strana \(currentPage + 1) / \(f.pageCount)")
                        .font(DS.Typography.subheadline)
                        .foregroundColor(.white.opacity(0.6))

                    Button {
                        if currentPage < f.pageCount - 1 { currentPage += 1 }
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.white.opacity(0.8))
                    .disabled(currentPage >= f.pageCount - 1)
                    .accessibilityLabel("Next page")
                }
                .padding(.vertical, DS.Spacing.smallMedium)
            }
        }
        .background(DS.Colors.darkBackground)
        .onAppear {
            fileID = appState.quickLookFileID
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickLookFileChanged)) { _ in
            fileID = appState.quickLookFileID
            currentPage = 0
            showThumbnails = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickLookPagePrevious)) { _ in
            if currentPage > 0 {
                withAnimation(.easeInOut(duration: 0.15)) { currentPage -= 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickLookPageNext)) { _ in
            if let f = file, currentPage < f.pageCount - 1 {
                withAnimation(.easeInOut(duration: 0.15)) { currentPage += 1 }
            }
        }
    }
}

// MARK: - Thumbnails View

private struct QuickLookThumbnailsView: View {
    let file: FileItem
    @Binding var currentPage: Int
    @Binding var showThumbnails: Bool
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var isLoading = true

    private let thumbnailSize: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            // Zpět na náhled
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showThumbnails = false
                    }
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Zpět na náhled")
                        .font(DS.Typography.subheadline)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white.opacity(0.8))
                .padding(.leading, DS.Spacing.small)

                Spacer()
            }
            .padding(.vertical, 8)
            .background(DS.Colors.darkSurface)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize + 16))], spacing: 12) {
                        ForEach(0..<file.pageCount, id: \.self) { pageIndex in
                            ThumbnailItem(
                                file: file,
                                pageIndex: pageIndex,
                                thumbnail: thumbnails[pageIndex],
                                isSelected: pageIndex == currentPage,
                                size: thumbnailSize
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    currentPage = pageIndex
                                    showThumbnails = false
                                }
                            }
                            .id(pageIndex)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    loadAllThumbnails()
                    // Scroll to current page
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation {
                            proxy.scrollTo(currentPage, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func loadAllThumbnails() {
        Task {
            guard let doc = PDFDocument(url: file.url) else {
                await MainActor.run { isLoading = false }
                return
            }
            let maxThumbnails = min(file.pageCount, 20)
            let thumbSize = CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)

            // Sequential loading to avoid Sendable issues with NSImage
            for i in 0..<maxThumbnails {
                if let page = doc.page(at: i) {
                    let thumb = page.thumbnail(of: thumbSize, for: .mediaBox)
                    await MainActor.run {
                        thumbnails[i] = thumb
                    }
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }
}

private struct ThumbnailItem: View {
    let file: FileItem
    let pageIndex: Int
    let thumbnail: NSImage?
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(isSelected ? DS.Colors.darkSelected : DS.Colors.darkUnselected)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.small)
                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                    )

                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .frame(width: size, height: size * 1.3)

            Text("\(pageIndex + 1)")
                .font(DS.Typography.caption2)
                .foregroundColor(.white.opacity(isSelected ? 1 : 0.5))
        }
    }
}

// MARK: - Preview Content (high quality)

private struct QuickLookPreviewContent: View {
    let file: FileItem
    @Binding var currentPage: Int
    @State private var image: NSImage? = nil
    @State private var isLoading = false

    var body: some View {
        ZStack {
            DS.Colors.darkBackground

            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
            } else if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(DS.Spacing.medium)
                    .shadow(color: .black.opacity(0.6), radius: 12, x: 0, y: 4)
            } else {
                VStack(spacing: DS.Spacing.small) {
                    Image(systemName: file.fileType.icon)
                        .font(DS.Typography.largeIcon)
                        .foregroundColor(.white.opacity(0.3))
                    Text("Náhled nedostupný")
                        .foregroundColor(.white.opacity(0.3))
                        .font(DS.Typography.caption)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: currentPage) { _ in load() }
    }

    private func load() {
        isLoading = true
        image = nil
        let url = file.url
        let ft = file.fileType
        let page = currentPage

        Task {
            let previewImage = await generatePreview(url: url, fileType: ft, page: page)
            await MainActor.run {
                if let nsImage = previewImage {
                    var rect = NSRect.zero
                    if let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil), cgImage.width > 0, cgImage.height > 0 {
                        self.image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                    } else {
                        self.image = nil
                    }
                } else {
                    self.image = nil
                }
                self.isLoading = false
            }
        }
    }

    private func generatePreview(url: URL, fileType: FileType, page: Int) async -> NSImage? {
        if fileType == .pdf {
            guard let doc = PDFDocument(url: url),
                  let pdfPage = doc.page(at: page) else { return nil }
            return pdfPage.thumbnail(of: CGSize(width: 2400, height: 3200), for: .mediaBox)
        } else if fileType.isImage {
            return loadImageWithOrientation(url: url)
        }
        return nil
    }

    private func loadImageWithOrientation(url: URL) -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return NSImage(contentsOf: url)
        }

        // Get EXIF orientation
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let tiffProperties = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var orientation: Int32 = 1
        if let tiffOrient = tiffProperties?[kCGImagePropertyTIFFOrientation] as? Int32 {
            orientation = tiffOrient
        }

        // Apply orientation if needed
        if orientation > 1 {
            guard let orientedImage = applyOrientation(cgImage: cgImage, orientation: Int(orientation)) else {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            return NSImage(cgImage: orientedImage, size: NSSize(width: orientedImage.width, height: orientedImage.height))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func applyOrientation(cgImage: CGImage, orientation: Int) -> CGImage? {
        var transform = CGAffineTransform.identity

        switch orientation {
        case 2: transform = transform.translatedBy(x: CGFloat(cgImage.width), y: 0).scaledBy(x: -1, y: 1)
        case 3: transform = transform.translatedBy(x: CGFloat(cgImage.width), y: CGFloat(cgImage.height)).rotated(by: .pi)
        case 4: transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.height)).scaledBy(x: 1, y: -1)
        case 5: transform = transform.translatedBy(x: CGFloat(cgImage.height), y: 0).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 6: transform = transform.translatedBy(x: CGFloat(cgImage.height), y: 0).rotated(by: .pi / 2)
        case 7: transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.width)).rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        case 8: transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.width)).rotated(by: -.pi / 2)
        default: return cgImage
        }

        let width = orientation >= 5 && orientation <= 8 ? cgImage.height : cgImage.width
        let height = orientation >= 5 && orientation <= 8 ? cgImage.width : cgImage.height

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: cgImage.bitmapInfo.rawValue) else {
            return nil
        }

        ctx.concatenate(transform)
        let drawRect = orientation >= 5 && orientation <= 8
            ? CGRect(x: 0, y: 0, width: cgImage.height, height: cgImage.width)
            : CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        ctx.draw(cgImage, in: drawRect)

        return ctx.makeImage()
    }
}
