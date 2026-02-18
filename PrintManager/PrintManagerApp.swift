//
//  PrintManagerApp.swift
//  PrintManager
//
//  A comprehensive PDF and image printing manager for macOS
//  Features:
//  - Fast printing of PDF and image files (LP command)
//  - Debug text window with information
//  - Preview window with page preview and detailed info
//  - Basic printing settings (format, collating, fit to page, two-sided, copies)
//  - PDF operations (split, merge, compress, view, rasterize, crop, OCR)
//  - PDF info display (pages, colors, file size, name, size)
//  - Format conversion to PDF (OpenOffice, CloudConvert)
//  - Extract images from PDF without resampling
//  - Image operations (OCR, convert to PDF, resize, rotate, invert)
//  - Identify and extract images within images
//  - Modern macOS UI with notifications, drag & drop
//

import SwiftUI
import AppKit
import UserNotifications
import Carbon

// MARK: - App Delegate (drag & drop na ikonu Docku)

class AppDelegate: NSObject, NSApplicationDelegate {

    // Callback nastavený z .onAppear. Pokud přijdou soubory dříve (cold launch),
    // uloží se do pendingURLs a doručí se při nastavení callbacku.
    var onOpenFiles: (([URL]) -> Void)? {
        didSet { deliverPending() }
    }
    private var pendingURLs: [URL] = []

    // Registrace AE handleru PŘED SwiftUI — zabrání otevření nového okna
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    // Hlavní handler — zachytí drag na ikonu i „Otevřít v..." z Finderu
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor,
                                   replyEvent: NSAppleEventDescriptor) {
        let urls = extractFileURLs(from: event)
        deliver(urls)
        bringMainWindowToFront()
    }

    // Záloha pro případ, že SwiftUI zavolá tuto metodu přímo
    func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
        bringMainWindowToFront()
    }

    // MARK: - Helpers

    private func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            if let handler = self.onOpenFiles {
                handler(urls)
            } else {
                self.pendingURLs.append(contentsOf: urls)
            }
        }
    }

    private func deliverPending() {
        guard let handler = onOpenFiles, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        handler(urls)
    }

    private func bringMainWindowToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.isVisible && !$0.isMiniaturized }?
                .makeKeyAndOrderFront(nil)
        }
    }

    /// Extrahuje file:// URL z Apple Event descriptoru (seznam i jeden soubor)
    private func extractFileURLs(from event: NSAppleEventDescriptor) -> [URL] {
        guard let params = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            return []
        }
        let count = params.numberOfItems
        let items: [NSAppleEventDescriptor] = count > 0
            ? (1...count).compactMap { params.atIndex($0) }
            : [params]
        return items.compactMap { $0.asFileURL() }
    }
}

private extension NSAppleEventDescriptor {
    /// Převede descriptor na URL souboru (typeFileURL → file://…)
    func asFileURL() -> URL? {
        guard let d = coerce(toDescriptorType: DescType(typeFileURL)) else { return nil }
        let data = d.data
        // data je UTF-8 file:// URL, může mít trailing null
        var bytes = [UInt8](data)
        if bytes.last == 0 { bytes.removeLast() }
        guard let str = String(bytes: bytes, encoding: .utf8) else { return nil }
        return URL(string: str) ?? URL(fileURLWithPath: str)
    }
}

@main
struct PrintManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @State private var searchText = ""

    init() {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1200, minHeight: 800)
                .onAppear {
                    appDelegate.onOpenFiles = { urls in
                        appState.addFiles(urls: urls)
                    }
                }
                // Pokud SwiftUI přesto otevře nové okno, zavřeme ho a zaměříme první
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification)
                ) { _ in
                    let visible = NSApp.windows.filter { $0.isVisible && !$0.isSheet && !$0.isMiniaturized }
                    if visible.count > 1 {
                        visible.dropFirst().forEach { $0.close() }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files...") {
                    appState.showingFilePicker = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .undoRedo) {
                Button("Rename Selected…") {
                    appState.openBatchRename()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState.selectedFiles.isEmpty)
            }

            CommandMenu("File Operations") {
                Button("Clear All") {
                    appState.clearAllFiles()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Remove Selected") {
                    appState.removeSelectedFiles()
                }
                .keyboardShortcut(.delete, modifiers: .command)

                Divider()

                Button("Print Selected") {
                    appState.printSelectedFiles()
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            
            CommandMenu("PDF Operations") {
                Button("Split PDF") {
                    appState.splitPDF()
                }
                
                Button("Merge PDFs") {
                    appState.mergePDFs()
                }
                
                Button("Compress PDF") {
                    appState.compressPDF()
                }
                
                Divider()
                
                Button("OCR PDF") {
                    appState.ocrPDF()
                }
                
                Button("Crop PDF") {
                    appState.cropPDF()
                }
                
                Button("Smart Crop") {
                    appState.smartCropFiles()
                }
                
                Button("Rasterize PDF") {
                    appState.rasterizePDF()
                }
            }
            
            CommandMenu("Image Operations") {
                Button("Convert to PDF") {
                    appState.convertImageToPDF()
                }
                
                Button("Resize Image") {
                    appState.resizeImage()
                }
                
                Button("Rotate Image") {
                    appState.rotateImage()
                }
                
                Button("Invert Colors") {
                    appState.invertImage()
                }
                
                Divider()
                
                Button("Extract Images from PDF") {
                    appState.extractImagesFromPDF()
                }
                
                Button("Detect & Extract Sub-Images") {
                    appState.detectAndExtractImages()
                }
            }
            
            CommandMenu("View") {
                Button("Toggle Preview") {
                    withAnimation {
                        appState.showPreview.toggle()
                    }
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
