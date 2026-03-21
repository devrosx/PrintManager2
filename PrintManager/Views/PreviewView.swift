//
//  PreviewView.swift
//  PrintManager
//
//  Preview panel showing selected file details and preview image
//

import SwiftUI
import PDFKit

struct PreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage: Int = 0
    
    var selectedFile: FileItem? {
        guard appState.selectedFiles.count == 1,
              let selectedId = appState.selectedFiles.first,
              let file = appState.files.first(where: { $0.id == selectedId }) else {
            return nil
        }
        return file
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Preview")
                    .font(.headline)
                
                Spacer()
                
                if let file = selectedFile {
                    Button(action: { quickLook(file) }) {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(DS.Colors.controlBackground)

            Divider()

            if let file = selectedFile {
                // Preview content
                ScrollView {
                    VStack(spacing: 16) {
                        // File name
                        Text(file.name + "." + file.fileType.rawValue.lowercased())
                            .font(.title3)
                            .bold()
                        
                        // Preview image
                        PreviewImageView(file: file, currentPage: $currentPage)
                            .frame(maxHeight: 500)
                        
                        // Page navigation for PDFs
                        if file.fileType == .pdf && file.pageCount > 1 {
                            HStack {
                                Button(action: { if currentPage > 0 { currentPage -= 1 } }) {
                                    Image(systemName: "chevron.left")
                                }
                                .disabled(currentPage == 0)
                                
                                Text("Page \(currentPage + 1) of \(file.pageCount)")
                                    .font(.caption)
                                
                                Button(action: { if currentPage < file.pageCount - 1 { currentPage += 1 } }) {
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(currentPage >= file.pageCount - 1)
                            }
                            .padding(.horizontal)
                        }
                        
                        Divider()
                        
                        // File info
                        FileInfoView(file: file)
                            .padding()
                    }
                    .padding()
                }
            } else {
                // No selection
                VStack(spacing: DS.Spacing.large) {
                    Image(systemName: "questionmark.circle")
                        .font(DS.Typography.largeIcon)
                        .foregroundColor(.secondary)

                    Text("No File Selected")
                        .font(DS.Typography.headline)
                        .foregroundColor(.secondary)

                    Text("Select a file to see its preview and details")
                        .font(DS.Typography.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private func quickLook(_ file: FileItem) {
        NSWorkspace.shared.open(file.url)
    }
}

// MARK: - Preview Image View

struct PreviewImageView: View {
    let file: FileItem
    @Binding var currentPage: Int
    @State private var previewImage: NSImage?
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) {
                        QuickLookController.shared.present(appState: appState)
                    }
                    .contextMenu {
                        previewContextMenu(image: image)
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: 300)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(DS.Radius.medium)
        .onAppear {
            loadPreview()
        }
        .onChange(of: currentPage) { _ in
            loadPreview()
        }
        .onChange(of: file.contentVersion) { _ in
            loadPreview()
        }
    }
    
    private func loadPreview() {
        Task { @MainActor in
            let image = await generatePreview(file: file)
            previewImage = image
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func previewContextMenu(image: NSImage) -> some View {
        PreviewContextMenu(file: file, image: image)
    }

    private func generatePreview(file: FileItem) async -> NSImage? {
        if file.fileType == .pdf {
            return await generatePDFPreview(file: file)
        } else if file.fileType.isImage {
            return NSImage(contentsOf: file.url)
        }
        return nil
    }

    private func generatePDFPreview(file: FileItem) async -> NSImage? {
        let key = file.url as NSURL
        // Použij cached PDFDocument pokud existuje, jinak načti a ulož
        let doc: PDFDocument
        if let cached = appState.pdfDocumentCache.object(forKey: key) {
            doc = cached
        } else {
            guard let loaded = PDFDocument(url: file.url) else { return nil }
            appState.pdfDocumentCache.setObject(loaded, forKey: key)
            doc = loaded
        }
        guard let page = doc.page(at: currentPage) else { return nil }
        return page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
    }
}

// MARK: - File Info View

struct FileInfoView: View {
    let file: FileItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Information")
                .font(.headline)
            
            InfoRow(label: "Type", value: file.fileType.rawValue)
            InfoRow(label: "Size", value: file.pageSizeString)
            InfoRow(label: "File Size", value: file.fileSizeFormatted)
            InfoRow(label: "Pages", value: "\(file.pageCount)")
            InfoRow(label: "Colors", value: file.colorInfo)
            InfoRow(label: "Status", value: file.status.rawValue)
            
            if let fileInfo = getDetailedFileInfo(url: file.url) {
                Divider()
                Text(fileInfo)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(DS.Colors.controlBackground)
        .cornerRadius(DS.Radius.medium)
    }
    
    private func getDetailedFileInfo(url: URL) -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            var info: [String] = []
            
            if let creationDate = attributes[.creationDate] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                info.append("Created: \(formatter.string(from: creationDate))")
            }
            
            if let modificationDate = attributes[.modificationDate] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                info.append("Modified: \(formatter.string(from: modificationDate))")
            }
            
            info.append("Path: \(url.path)")
            
            return info.joined(separator: "\n")
        } catch {
            return nil
        }
    }
}

// MARK: - Shared Preview Context Menu

/// Kontextové menu pro náhled souboru — sdílené mezi PreviewImageView a SinglePagePreview.
/// Přidává `@EnvironmentObject var appState: AppState` interně, takže stačí vložit do `.contextMenu { }`.
struct PreviewContextMenu: View {
    let file: FileItem
    let image: NSImage
    @EnvironmentObject var appState: AppState

    private var isPDF: Bool { file.fileType == .pdf }

    var body: some View {
        // ── Finder / otevřít ─────────────────────────────────
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } label: {
            Label("Zobrazit ve Finderu", systemImage: "folder")
        }

        Button {
            NSWorkspace.shared.open(file.url)
        } label: {
            Label("Otevřít v externím programu", systemImage: "arrow.up.right.square")
        }

        Divider()

        // ── Kopírovat do schránky ─────────────────────────────
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        } label: {
            Label(isPDF ? "Kopírovat stránku jako obrázek" : "Kopírovat obrázek",
                  systemImage: "doc.on.doc")
        }

        Divider()

        // ── PDF-only operace ──────────────────────────────────
        if isPDF {
            Button { appState.mergePDFs() } label: {
                Label("Sloučit PDF", systemImage: "arrow.triangle.merge")
            }
            Button { appState.splitPDF() } label: {
                Label("Rozdělit PDF", systemImage: "scissors")
            }
            Button { appState.tilePDFAction() } label: {
                Label("Tile PDF…", systemImage: "rectangle.split.2x1")
            }

            Divider()

            Button { appState.compressPDF() } label: {
                Label("Komprimovat PDF…", systemImage: "arrow.down.circle")
            }
            Button { appState.rasterizePDF() } label: {
                Label("Rasterizovat PDF", systemImage: "photo")
            }

            Divider()
        }

        // ── Operace společné pro obrázky i PDF ───────────────
        Button { appState.expandFileAction() } label: {
            Label("Expand (Bleed)…", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button { appState.convertToGray() } label: {
            Label("Převést na odstíny šedé", systemImage: "circle.lefthalf.filled")
        }

        // ── Ořez pro obrázky ─────────────────────────────────
        if !isPDF {
            Button {
                appState.cropFile = file
                appState.showCropView = true
            } label: {
                Label("Oříznout…", systemImage: "crop")
            }
        }

        // ── Další PDF operace ─────────────────────────────────
        if isPDF {
            Button { appState.flattenTransparency() } label: {
                Label("Zploštit průhlednost", systemImage: "square.stack")
            }
            Button { appState.fixPDF() } label: {
                Label("Opravit PDF", systemImage: "wrench.and.screwdriver")
            }

            Divider()

            Button { appState.printSelectedFiles() } label: {
                Label("Tisknout…", systemImage: "printer")
            }

            Divider()

            Button { appState.showPDFInfo() } label: {
                Label("PDF Info…", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Debug Output View

struct DebugOutputView: View {
    @EnvironmentObject var appState: AppState
    @State private var autoScroll = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Výstup ladění")
                    .font(.headline)

                Spacer()

                Toggle("Automatické rolování", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                
                Button(action: { appState.clearDebugLog() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(DS.Colors.controlBackground)

            Divider()

            // Debug messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.debugMessages) { message in
                            DebugMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: appState.debugMessages.count) { _ in
                    if autoScroll, let lastMessage = appState.debugMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

struct DebugMessageRow: View {
    let message: DebugMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message.level.prefix)
                .font(.caption)
            
            Text(message.formattedMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(message.level.color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    VStack {
        PreviewView()
            .environmentObject(AppState())
            .frame(height: 400)
        
        DebugOutputView()
            .environmentObject(AppState())
            .frame(height: 200)
    }
}
