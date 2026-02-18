//
//  ToolbarView.swift
//  PrintManager
//
//  Modern toolbar with quick actions and search
//

import SwiftUI
import AppKit

struct ModernToolbar: ToolbarContent {
    @EnvironmentObject var appState: AppState
    @Binding var searchText: String
    
    var body: some ToolbarContent {
        // Add Files
        ToolbarItem(placement: .primaryAction) {
            Button(action: {
                appState.showingFilePicker = true
            }) {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add files (⌘O)")
        }
        
        // Print
        ToolbarItem(placement: .primaryAction) {
            Button(action: {
                appState.printSelectedFiles()
            }) {
                Label("Print", systemImage: "printer")
            }
            .disabled(appState.selectedFiles.isEmpty)
            .help("Print selected (⌘P)")
        }
        
        // Separator
        ToolbarItem(placement: .automatic) {
            Divider()
        }
        
        // Search
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search files...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
        
        // PDF Actions
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Combine PDF") { appState.mergePDFs() }
                Button("Split PDF") { appState.splitPDF() }
                Divider()
                Button("Compress PDF") { appState.compressPDF() }
                Button("Rasterize PDF") { appState.rasterizePDF() }
                Divider()
                Button("Add Blank Page to Odd") { appState.addBlankPagesToOddDocuments() }
                Divider()
                Button("PDF Info") { appState.showPDFInfo() }
                Divider()
                Button("Convert to Gray") { appState.convertToGray() }
                Button("Flatten Transparency") { appState.flattenTransparency() }
                Button("Fix PDF") { appState.fixPDF() }
            } label: {
                Label("PDF", systemImage: "doc.fill")
            }
            .disabled(appState.selectedFiles.isEmpty)
        }
        
        // Office Conversion
        ToolbarItem(placement: .automatic) {
            Menu {
                Button {
                    appState.convertOfficeToPDF()
                } label: {
                    Label("Via LibreOffice", systemImage: "desktopcomputer")
                }
                
                Button {
                    appState.convertViaCloudConvert()
                } label: {
                    Label("Via CloudConvert", systemImage: "cloud.fill")
                }
                
                Button {
                    appState.convertViaGoogle()
                } label: {
                    Label("Via Google", systemImage: "g.circle.fill")
                }
            } label: {
                Label("Convert", systemImage: "doc.badge.arrow.up")
            }
            .disabled(!hasSelectedOfficeFiles)
        }
        
        // View Toggle
        ToolbarItem(placement: .automatic) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.showPreview.toggle()
                }
            }) {
                Label(
                    appState.showPreview ? "Hide Preview" : "Show Preview",
                    systemImage: appState.showPreview ? "sidebar.right" : "sidebar.right.on.rectangle"
                )
            }
            .help("Toggle preview panel (⌘I)")
        }
        
        // Settings
        ToolbarItem(placement: .automatic) {
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }) {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }
    
    private var hasSelectedOfficeFiles: Bool {
        appState.files.contains {
            appState.selectedFiles.contains($0.id) && $0.fileType.requiresConversion
        }
    }
}

// MARK: - Toolbar Search Modifier

struct ToolbarSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: "Search files...")
        } else {
            content
                .searchable(text: $text, placement: .toolbar, prompt: "Search files...")
        }
    }
}

extension View {
    func toolbarSearch(text: Binding<String>, isPresented: Binding<Bool>) -> some View {
        modifier(ToolbarSearchModifier(text: text, isPresented: isPresented))
    }
}

// MARK: - Floating Action Button

struct FloatingActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(20)
            .shadow(color: color.opacity(0.4), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar Badge

struct ToolbarBadge: View {
    let count: Int
    let color: Color
    
    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Notification Toast

struct NotificationToast: View {
    let title: String
    let message: String
    let icon: String
    let type: ToastType
    @Binding var isPresented: Bool
    
    enum ToastType {
        case success, error, warning, info
        
        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            case .warning: return .orange
            case .info: return .accentColor
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(type.color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPresented = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(type.color.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    let message: String
    let progress: Double?
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                if let progress = progress {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.2), lineWidth: 8)
                            .frame(width: 80, height: 80)
                        
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: progress)
                        
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                    }
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle())
                }
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            )
        }
    }
}

// MARK: - Keyboard Shortcut Helper

struct KeyboardShortcutHelper: View {
    let shortcut: String
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}
