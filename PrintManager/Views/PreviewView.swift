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
            .background(Color(NSColor.controlBackgroundColor))
            
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
                VStack(spacing: 16) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No File Selected")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Select a file to see its preview and details")
                        .font(.caption)
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
    
    var body: some View {
        Group {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: 300)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            loadPreview()
        }
        .onChange(of: currentPage) { _ in
            loadPreview()
        }
    }
    
    private func loadPreview() {
        Task {
            let image = await generatePreview()
            await MainActor.run {
                previewImage = image
            }
        }
    }
    
    private func generatePreview() async -> NSImage? {
        if file.fileType == .pdf {
            return generatePDFPreview()
        } else if file.fileType.isImage {
            return NSImage(contentsOf: file.url)
        }
        return nil
    }
    
    private func generatePDFPreview() -> NSImage? {
        guard let pdfDocument = PDFDocument(url: file.url),
              let page = pdfDocument.page(at: currentPage) else {
            return nil
        }
        
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
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
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

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .bold()
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
                Text("Debug Output")
                    .font(.headline)
                
                Spacer()
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                
                Button(action: { appState.clearDebugLog() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
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
