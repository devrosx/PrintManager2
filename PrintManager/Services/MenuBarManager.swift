//
//  MenuBarManager.swift
//  PrintManager
//
//  Menu bar extra for quick access to common actions
//

import SwiftUI
import AppKit

class MenuBarManager: NSObject, ObservableObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    
    @Published var isShown = false
    
    private override init() {
        super.init()
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Print Manager")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 400)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView()
                .environmentObject(AppState())
        )
    }
    
    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            isShown = true
        }
    }
    
    func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            isShown = true
        }
    }
    
    func hidePopover() {
        popover?.performClose(nil)
        isShown = false
    }
}

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingFilePicker = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "printer.fill")
                    .foregroundColor(.accentColor)
                Text("Print Manager")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Quick Actions
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Add Files Section
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Add Files", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Button(action: {
                            appState.showingFilePicker = true
                        }) {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                Text("Add Files...")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Divider()
                    
                    // Recent Files
                    if !appState.files.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent Files")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            ForEach(appState.files.prefix(5)) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: file.fileType.icon)
                                        .foregroundColor(.secondary)
                                    Text(file.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .font(.caption)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.selectedFiles = [file.id]
                                }
                            }
                        }
                        
                        Divider()
                    }
                    
                    // Quick Print
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Quick Print", systemImage: "print.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Button(action: {
                            appState.printSelectedFiles()
                            MenuBarManager.shared.hidePopover()
                        }) {
                            HStack {
                                Image(systemName: "printer")
                                Text("Print Selected")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.selectedFiles.isEmpty)
                    }
                    
                    Divider()
                    
                    // Statistics
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Statistics")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            StatBox(title: "Files", value: "\(appState.files.count)", icon: "doc.fill")
                            StatBox(title: "Pages", value: "\(totalPages)", icon: "doc.on.doc.fill")
                            StatBox(title: "Selected", value: "\(appState.selectedFiles.count)", icon: "checkmark.circle.fill")
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.link)
                
                Spacer()
                
                Text("\(appState.files.count) files")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 280, height: 380)
    }
    
    private var totalPages: Int {
        appState.files.reduce(0) { $0 + $1.pageCount }
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}
