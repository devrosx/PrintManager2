//
//  SharedUIComponents.swift
//  PrintManager
//
//  Reusable UI components shared across views
//

import SwiftUI
import AppKit

// MARK: - LabeledSlider

/// A slider with a label and formatted value display
struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var mult: Double = 1.0

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 72, alignment: .leading)

            Slider(value: $value, in: range)

            Text(String(format: format, value * mult))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - InfoRow

/// A row displaying a label-value pair for file information
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

// MARK: - DisclosureToggleSection

/// A collapsible section with a toggle switch and expandable content
struct DisclosureToggleSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isEnabled: Bool
    @State private var isExpanded = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Header with toggle and disclosure
            HStack(spacing: 0) {
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.leading, 10)
                    .padding(.trailing, 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundColor(isEnabled ? .accentColor : .secondary)
                            .frame(width: 16)

                        Text(title)
                            .font(.system(.body, weight: .medium))
                            .foregroundColor(isEnabled ? .primary : .secondary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: isExpanded)
                    }
                    .padding(.trailing, 10)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Expandable content
            if isExpanded {
                Divider()
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .opacity(isEnabled ? 1.0 : 0.45)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium)
                .fill(DS.Colors.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.medium)
                        .stroke(
                            isEnabled ? Color.accentColor.opacity(0.35) : DS.Colors.separator,
                            lineWidth: isEnabled ? 1.0 : 0.5
                        )
                )
        )
        .onChange(of: isEnabled) { enabled in
            if enabled, !isExpanded {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded = true
                }
            }
        }
    }
}

// MARK: - StatusIndicator

/// Accessible status indicator with icon + text (replaces color-only Circle indicators)
struct StatusIndicator: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: DS.Spacing.xxSmall) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .foregroundColor(color)
        }
        .font(DS.Typography.caption2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text)")
    }
}

// MARK: - SectionHeader

/// Standard section header with title and optional trailing content
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(DS.Typography.captionSemibold)
                .foregroundColor(.secondary)
            Spacer()
            trailing()
        }
        .headerPadding()
    }
}

// MARK: - Cursor Modifier

/// Custom cursor modifier for SwiftUI views
private struct CursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    /// Apply a custom cursor to this view
    /// - Parameter cursor: The NSCursor to display when hovering
    /// - Returns: Modified view with cursor behavior
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}

// MARK: - Preview

#Preview("LabeledSlider") {
    VStack {
        LabeledSlider(
            label: "Threshold",
            value: .constant(0.5),
            range: 0...1,
            format: "%.2f"
        )

        LabeledSlider(
            label: "Percentage",
            value: .constant(0.75),
            range: 0...1,
            format: "%.0f%%",
            mult: 100
        )
    }
    .padding()
}

#Preview("InfoRow") {
    VStack {
        InfoRow(label: "Type", value: "PDF")
        InfoRow(label: "Size", value: "A4")
        InfoRow(label: "Pages", value: "5")
    }
    .padding()
}

#Preview("DisclosureToggleSection") {
    DisclosureToggleSection(
        title: "Threshold Settings",
        icon: "circle.lefthalf.filled",
        isEnabled: .constant(true)
    ) {
        Text("Content goes here")
        LabeledSlider(label: "Value", value: .constant(0.5), range: 0...1, format: "%.2f")
    }
    .padding()
}

// MARK: - Shared Menu Actions
// Sdílené @ViewBuilder funkce použitelné v toolbar Menu, .contextMenu i CommandMenu

@ViewBuilder
func pdfActionsMenuContent(_ appState: AppState) -> some View {
    Button("Combine PDF")           { appState.mergePDFs() }
    Button("Split PDF")             { appState.splitPDF() }
    Button("Tile PDF…")             { appState.tilePDFAction() }
    Divider()
    Button("OCR PDF")               { appState.ocrPDF() }
    Divider()
    Button("Compress PDF")          { appState.compressPDF() }
    Button("Rasterize PDF")         { appState.rasterizePDF() }
    Button("Resize PDF…")           { appState.resizePDF() }
    Divider()
    Button("Crop PDF/Image")        { appState.cropPDF() }
    Button("Smart Crop")            { appState.smartCropFiles() }
    Divider()
    Button("Choose Color Pages")    { appState.openColorPageSelector() }
    Divider()
    Button("Add Blank Page to Odd") { appState.addBlankPagesToOddDocuments() }
    Divider()
    Button("Imposition…")           { appState.impositionPDF() }
    Divider()
    Button("Expand (Bleed)…")       { appState.expandFileAction() }
    Divider()
    Button("Watermark…")            { appState.openWatermarkDialog() }
    Divider()
    Button("PDF Info")              { appState.showPDFInfo() }
}

@ViewBuilder
func imageActionsMenuContent(_ appState: AppState) -> some View {
    Button("Convert to PDF")              { appState.convertImageToPDF() }
    Divider()
    Button("Crop Image")                  { appState.cropPDF() }
    Button("Smart Crop")                  { appState.smartCropFiles() }
    Button("MultiCrop")                   { appState.openMultiCrop() }
    Divider()
    Button("Expand (Bleed)…")             { appState.expandFileAction() }
    Divider()
    Button("Convert to Gray")             { appState.convertToGray() }
    Divider()
    Button("Resize Image…")               { appState.resizeImage() }
    Button("Rotate Image")                { appState.rotateImage() }
    Divider()
    if appState.files.filter({ appState.selectedFiles.contains($0.id) && $0.fileType == .pdf }).count >= 1 {
        Button("Extract Images from PDF") { appState.extractImagesFromPDF() }
    }
    Button("Detect & Extract Sub-Images") { appState.detectAndExtractImages() }
    Divider()
    Button("Adjust Image…")               { appState.openImageAdjustDialog() }
    if appState.files.filter({ appState.selectedFiles.contains($0.id) && $0.fileType.isImage }).count >= 2 {
        Button("Stitch (Panorama)…")      { appState.openStitchDialog() }
    }
    Divider()
    Button("Create Gallery…")             { appState.openGalleryDialog() }
}
