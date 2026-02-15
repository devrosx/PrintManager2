//
//  CompressionDialog.swift
//  PrintManager
//
//  Dialog for PDF compression settings
//

import SwiftUI

struct CompressionDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    
    @State private var selectedPreset: String = "standard"
    @State private var customQuality: Double = 0.7
    @State private var customImageQuality: Double = 0.5
    @State private var customDPI: Int = 150
    
    @Environment(\.dismiss) private var dismiss
    
    // Advanced options
    @State private var removeMetadata = true
    @State private var compressImages = true
    @State private var downsampleImages = true
    @State private var flattenTransparency = true
    @State private var subsetFonts = true
    @State private var linearize = false
    @State private var optimizeForPrint = false
    @State private var preserveText = true
    
    private let presets: [(name: String, settings: CompressionSettings)] = [
        ("Maximum", CompressionSettings(
            quality: .high,
            imageQuality: .high,
            removeMetadata: false,
            removeBookmarks: false,
            removeThumbnails: false,
            compressFonts: true,
            downsampleImages: false,
            imageDPI: 300,
            dpi: 300,
            compressImages: true,
            flattenTransparency: true,
            subsetFonts: true,
            linearize: false,
            optimizeForPrint: false,
            preserveText: true
        )),
        ("Standard", CompressionSettings(
            quality: .medium,
            imageQuality: .medium,
            removeMetadata: false,
            removeBookmarks: false,
            removeThumbnails: false,
            compressFonts: true,
            downsampleImages: true,
            imageDPI: 150,
            dpi: 150,
            compressImages: true,
            flattenTransparency: true,
            subsetFonts: true,
            linearize: false,
            optimizeForPrint: false,
            preserveText: true
        )),
        ("Web Optimized", CompressionSettings(
            quality: .low,
            imageQuality: .low,
            removeMetadata: true,
            removeBookmarks: true,
            removeThumbnails: true,
            compressFonts: true,
            downsampleImages: true,
            imageDPI: 72,
            dpi: 72,
            compressImages: true,
            flattenTransparency: true,
            subsetFonts: true,
            linearize: false,
            optimizeForPrint: false,
            preserveText: true
        )),
        ("Print Optimized", CompressionSettings(
            quality: .high,
            imageQuality: .high,
            removeMetadata: false,
            removeBookmarks: false,
            removeThumbnails: false,
            compressFonts: true,
            downsampleImages: false,
            imageDPI: 300,
            dpi: 300,
            compressImages: true,
            flattenTransparency: true,
            subsetFonts: true,
            linearize: false,
            optimizeForPrint: false,
            preserveText: true
        )),
        ("Minimal", CompressionSettings(
            quality: .minimal,
            imageQuality: .minimal,
            removeMetadata: true,
            removeBookmarks: true,
            removeThumbnails: true,
            compressFonts: true,
            downsampleImages: true,
            imageDPI: 72,
            dpi: 72,
            compressImages: true,
            flattenTransparency: true,
            subsetFonts: true,
            linearize: false,
            optimizeForPrint: false,
            preserveText: true
        ))
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Compress PDF")
                    .font(.headline)
                Spacer()
                Button("✕") {
                    isPresented = false
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            
            Divider()
            
            // Preset selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Compression Preset")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Picker("Preset", selection: $selectedPreset) {
                    ForEach(presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .onChange(of: selectedPreset) { _ in
                    applyPreset()
                }
            }
            
            // Quality settings
            VStack(alignment: .leading, spacing: 8) {
                Text("Quality Settings")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                VStack(spacing: 12) {
                    // Overall quality
                    HStack {
                        Text("Overall Quality")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(customQuality * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $customQuality, in: 0.1...1.0, step: 0.1)
                        .onChange(of: customQuality) { _ in
                            updateCustomSettings() }
                }
                
                VStack(spacing: 12) {
                    // Image quality
                    HStack {
                        Text("Image Quality")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(customImageQuality * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $customImageQuality, in: 0.1...1.0, step: 0.1)
                        .onChange(of: customImageQuality) { _ in
                            updateCustomSettings() }
                }
                
                VStack(spacing: 8) {
                    HStack {
                        Text("Image DPI")
                            .font(.caption)
                        Spacer()
                        Text("\(customDPI)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(customDPI) },
                        set: { customDPI = Int($0) }
                    ), in: 72...600, step: 50)
                    .onChange(of: customDPI) { _ in
                        updateCustomSettings() }
                }
            }
            
            // Advanced options
            VStack(alignment: .leading, spacing: 8) {
                Text("Advanced Options")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                VStack(spacing: 6) {
                    Toggle("Remove Metadata", isOn: $removeMetadata)
                        .onChange(of: removeMetadata) { _ in updateCustomSettings() }
                    
                    Toggle("Compress Images", isOn: $compressImages)
                        .onChange(of: compressImages) { _ in updateCustomSettings() }
                    
                    Toggle("Downsample Images", isOn: $downsampleImages)
                        .onChange(of: downsampleImages) { _ in updateCustomSettings() }
                    
                    Toggle("Flatten Transparency", isOn: $flattenTransparency)
                        .onChange(of: flattenTransparency) { _ in updateCustomSettings() }
                    
                    Toggle("Subset Fonts", isOn: $subsetFonts)
                        .onChange(of: subsetFonts) { _ in updateCustomSettings() }
                    
                    Toggle("Linearize (Fast Web View)", isOn: $linearize)
                        .onChange(of: linearize) { _ in updateCustomSettings() }
                    
                    Toggle("Optimize for Print", isOn: $optimizeForPrint)
                        .onChange(of: optimizeForPrint) { _ in updateCustomSettings() }
                    
                    Toggle("Preserve Text", isOn: $preserveText)
                        .onChange(of: preserveText) { _ in updateCustomSettings() }
                }
            }
            
            Divider()
            
            // Preview and actions
            VStack(spacing: 8) {
                HStack {
                    Text("Estimated Result")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(appState.compressionSettings.levelDescription())
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Button("Cancel") {
                        isPresented = false
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Compress") {
                        appState.compressPDFWithSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.compressionProgress > 0)
                }
            }
        }
        .padding()
        .frame(width: 400, height: 580)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            // Initialize with current settings
            loadCurrentSettings()
        }
    }
    
    private func applyPreset() {
        guard let presetSettings = presets.first(where: { $0.name == selectedPreset })?.settings else { return }
        
        customQuality = qualityToDouble(presetSettings.quality)
        customImageQuality = imageQualityToDouble(presetSettings.imageQuality)
        customDPI = presetSettings.dpi
        
        removeMetadata = presetSettings.removeMetadata
        compressImages = presetSettings.compressImages
        downsampleImages = presetSettings.downsampleImages
        flattenTransparency = presetSettings.flattenTransparency
        subsetFonts = presetSettings.subsetFonts
        linearize = presetSettings.linearize
        optimizeForPrint = presetSettings.optimizeForPrint
        preserveText = presetSettings.preserveText
        
        updateCustomSettings()
    }
    
    private func updateCustomSettings() {
        appState.compressionSettings = CompressionSettings(
            quality: doubleToQuality(customQuality),
            imageQuality: doubleToImageQuality(customImageQuality),
            removeMetadata: removeMetadata,
            removeBookmarks: false,
            removeThumbnails: false,
            compressFonts: true,
            downsampleImages: downsampleImages,
            imageDPI: customDPI,
            dpi: customDPI,
            compressImages: compressImages,
            flattenTransparency: flattenTransparency,
            subsetFonts: subsetFonts,
            linearize: linearize,
            optimizeForPrint: optimizeForPrint,
            preserveText: preserveText
        )
    }
    
    private func qualityToDouble(_ quality: CompressionSettings.Quality) -> Double {
        switch quality {
        case .veryHigh: return 0.95
        case .high: return 0.9
        case .medium: return 0.7
        case .low: return 0.5
        case .veryLow: return 0.3
        case .minimal: return 0.1
        }
    }
    
    private func imageQualityToDouble(_ quality: CompressionSettings.ImageQuality) -> Double {
        switch quality {
        case .high: return 0.9
        case .medium: return 0.7
        case .low: return 0.5
        case .veryLow: return 0.3
        case .minimal: return 0.1
        }
    }
    
    private func doubleToQuality(_ value: Double) -> CompressionSettings.Quality {
        if value >= 0.8 { return .high }
        if value >= 0.6 { return .medium }
        if value >= 0.4 { return .low }
        return .minimal
    }
    
    private func doubleToImageQuality(_ value: Double) -> CompressionSettings.ImageQuality {
        if value >= 0.8 { return .high }
        if value >= 0.6 { return .medium }
        if value >= 0.4 { return .low }
        return .minimal
    }
    
    private func loadCurrentSettings() {
        let settings = appState.compressionSettings
        
        customQuality = qualityToDouble(settings.quality)
        customImageQuality = imageQualityToDouble(settings.imageQuality)
        customDPI = settings.dpi
        
        removeMetadata = settings.removeMetadata
        compressImages = settings.compressImages
        downsampleImages = settings.downsampleImages
        flattenTransparency = settings.flattenTransparency
        subsetFonts = settings.subsetFonts
        linearize = settings.linearize
        optimizeForPrint = settings.optimizeForPrint
        preserveText = settings.preserveText
        
        // Find matching preset
        for preset in presets {
            if preset.settings.quality == settings.quality &&
               preset.settings.imageQuality == settings.imageQuality &&
               preset.settings.removeMetadata == settings.removeMetadata &&
               preset.settings.compressImages == settings.compressImages &&
               preset.settings.downsampleImages == settings.downsampleImages &&
               preset.settings.flattenTransparency == settings.flattenTransparency &&
               preset.settings.subsetFonts == settings.subsetFonts &&
               preset.settings.linearize == settings.linearize &&
               preset.settings.optimizeForPrint == settings.optimizeForPrint &&
               preset.settings.preserveText == settings.preserveText {
                selectedPreset = preset.name
                break
            }
        }
    }
}

struct CompressionDialog_Previews: PreviewProvider {
    static var previews: some View {
        CompressionDialog(isPresented: .constant(true))
            .environmentObject(AppState())
    }
}