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

// MARK: - Controller

final class QuickLookController {
    static let shared = QuickLookController()

    private var panel: NSPanel?
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

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 980),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Quick Look"
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = NSColor(white: 0.08, alpha: 1)
        p.isReleasedWhenClosed = false
        p.minSize = CGSize(width: 360, height: 400)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false

        let rootView = QuickLookView(controller: self)
            .environmentObject(appState)
        let hc = NSHostingController(rootView: AnyView(rootView))
        p.contentView = hc.view
        hosting = hc

        if let main = NSApp.mainWindow {
            p.center()
            // Vycentruj přibližně na střed hlavního okna
            let mf = main.frame
            let pw = p.frame
            p.setFrameOrigin(NSPoint(
                x: mf.midX - pw.width / 2,
                y: mf.midY - pw.height / 2
            ))
        } else {
            p.center()
        }

        p.makeKeyAndOrderFront(nil)
        panel = p

        // Monitorovat klávesy (jen když je panel viditelný)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            switch event.keyCode {
            case 49, 53: // mezerník, Escape
                DispatchQueue.main.async { self.dismiss() }
                return nil
            case 125: // šipka dolů
                DispatchQueue.main.async { appState.quickLookMoveDown() }
                return nil
            case 126: // šipka nahoru
                DispatchQueue.main.async { appState.quickLookMoveUp() }
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
            HStack(spacing: 12) {
                // Navigace
                Button {
                    appState.quickLookMoveUp()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white)
                .disabled(fileIndex == nil || fileIndex == 0)

                Button {
                    appState.quickLookMoveDown()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white)
                .disabled(fileIndex == nil || fileIndex == appState.files.count - 1)

                Divider()
                    .frame(height: 16)
                    .background(Color.white.opacity(0.3))



                Spacer()

                if let idx = fileIndex {
                    Text("\(idx + 1) / \(appState.files.count)")
                        .font(.system(size: 11))
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)   // pod titlebar
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.15))

            // Preview
            if let f = file {
                QuickLookPreviewContent(file: f, currentPage: $currentPage)
                    .id("\(f.id)-\(f.contentVersion)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Stránkování (PDF)
            if let f = file, f.pageCount > 1 {
                Divider()
                    .background(Color.white.opacity(0.15))

                HStack(spacing: 16) {
                    Button {
                        if currentPage > 0 { currentPage -= 1 }
                    } label: {
                        Image(systemName: "arrow.left.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.white.opacity(0.8))
                    .disabled(currentPage == 0)

                    Text("Strana \(currentPage + 1) / \(f.pageCount)")
                        .font(.system(size: 12))
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
                }
                .padding(.vertical, 10)
            }
        }
        .background(Color(NSColor(white: 0.08, alpha: 1)))
        .onAppear {
            fileID = appState.quickLookFileID
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickLookFileChanged)) { _ in
            fileID = appState.quickLookFileID
            currentPage = 0
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
            Color(NSColor(white: 0.08, alpha: 1))

            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
            } else if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .shadow(color: .black.opacity(0.6), radius: 12, x: 0, y: 4)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: file.fileType.icon)
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.3))
                    Text("Náhled nedostupný")
                        .foregroundColor(.white.opacity(0.3))
                        .font(.caption)
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
        Task.detached(priority: .userInitiated) {
            let img = await generatePreview(url: url, fileType: ft, page: page)
            await MainActor.run {
                self.image = img
                self.isLoading = false
            }
        }
    }

    private func generatePreview(url: URL, fileType: FileType, page: Int) async -> NSImage? {
        if fileType == .pdf {
            guard let doc = PDFDocument(url: url),
                  let pdfPage = doc.page(at: page) else { return nil }
            let pts = pdfPage.bounds(for: .mediaBox).size
            let scale: CGFloat = min(2400 / pts.width, 3200 / pts.height, 4)
            let size = CGSize(width: pts.width * scale, height: pts.height * scale)
            guard let ctx = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: scale, y: -scale)
            pdfPage.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            guard let cgImg = ctx.makeImage() else { return nil }
            return NSImage(cgImage: cgImg, size: size)
        } else if fileType.isImage {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
