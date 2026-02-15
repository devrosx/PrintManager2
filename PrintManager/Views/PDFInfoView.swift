//
//  PDFInfoView.swift
//  PrintManager
//
//  PDF Information window showing detailed metadata
//

import SwiftUI

struct PDFInfoView: View {
    @Binding var isPresented: Bool
    let metadata: PDFMetadata
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundColor(.red)
                
                Text("PDF Information")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Basic Info Section
                    InfoSection(title: "Basic Information", icon: "doc.text") {
                        PDFInfoRow(label: "Title", value: metadata.title ?? "-")
                        PDFInfoRow(label: "Author", value: metadata.author ?? "-")
                        PDFInfoRow(label: "Subject", value: metadata.subject ?? "-")
                        PDFInfoRow(label: "Creator", value: metadata.creator ?? "-")
                        PDFInfoRow(label: "Producer", value: metadata.producer ?? "-")
                    }
                    
                    // File Info Section
                    InfoSection(title: "File Information", icon: "externaldrive.fill") {
                        PDFInfoRow(label: "Pages", value: "\(metadata.pageCount)")
                        PDFInfoRow(label: "PDF Version", value: metadata.pdfVersion)
                        PDFInfoRow(label: "File Size", value: metadata.fileSizeFormatted)
                        PDFInfoRow(label: "Page Size", value: metadata.pageSizeFormatted)
                    }
                    
                    // Dates Section
                    InfoSection(title: "Dates", icon: "calendar") {
                        PDFInfoRow(label: "Created", value: metadata.creationDateFormatted ?? "Unknown")
                        PDFInfoRow(label: "Modified", value: metadata.modificationDateFormatted ?? "Unknown")
                    }
                    
                    // Properties Section
                    InfoSection(title: "Properties", icon: "gearshape.fill") {
                        PDFInfoRow(label: "Encryption", value: metadata.isEncrypted ? "Yes" : "No")
                        PDFInfoRow(label: "Linearized", value: metadata.isLinearized ? "Yes" : "No")
                        PDFInfoRow(label: "Compression", value: metadata.compressionInfo)
                        PDFInfoRow(label: "Features", value: metadata.featuresString)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Copy to Clipboard") {
                    copyToClipboard()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 450, height: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func copyToClipboard() {
        var text = "PDF Information\n"
        text += "==============\n\n"
        text += "Title: \(metadata.title ?? "-")\n"
        text += "Author: \(metadata.author ?? "-")\n"
        text += "Subject: \(metadata.subject ?? "-")\n"
        text += "Creator: \(metadata.creator ?? "-")\n"
        text += "Producer: \(metadata.producer ?? "-")\n\n"
        text += "Pages: \(metadata.pageCount)\n"
        text += "PDF Version: \(metadata.pdfVersion)\n"
        text += "File Size: \(metadata.fileSizeFormatted)\n"
        text += "Page Size: \(metadata.pageSizeFormatted)\n\n"
        text += "Created: \(metadata.creationDateFormatted ?? "Unknown")\n"
        text += "Modified: \(metadata.modificationDateFormatted ?? "Unknown")\n\n"
        text += "Encryption: \(metadata.isEncrypted ? "Yes" : "No")\n"
        text += "Linearized: \(metadata.isLinearized ? "Yes" : "No")\n"
        text += "Compression: \(metadata.compressionInfo)\n"
        text += "Features: \(metadata.featuresString)\n"
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Info Section

struct InfoSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

// MARK: - PDF Info Row

struct PDFInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontWeight(value == "-" ? .regular : .medium)
                .foregroundColor(value == "-" ? .secondary : .primary)
                .lineLimit(2)
        }
    }
}

#Preview {
    PDFInfoView(
        isPresented: .constant(true),
        metadata: PDFMetadata(
            title: "Sample Document",
            author: "John Doe",
            subject: "Test Document",
            creator: "Microsoft Word",
            producer: "Adobe PDF Library",
            creationDate: Date(),
            modificationDate: Date(),
            version: "1.5",
            pageCount: 10,
            isEncrypted: false,
            isLinearized: true,
            containsOutlines: true,
            containsAnnotations: true,
            containsForms: false,
            pageSize: CGSize(width: 595, height: 842),
            fileSize: 1024000
        )
    )
}
