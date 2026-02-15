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

@main
struct PrintManagerApp: App {
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
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files...") {
                    appState.showingFilePicker = true
                }
                .keyboardShortcut("o", modifiers: .command)
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
