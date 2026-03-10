//
//  DesignSystem.swift
//  PrintManager
//
//  Centralized design tokens for consistent UI across all views.
//  Based on Apple HIG guidelines for macOS.
//

import SwiftUI
import AppKit

// MARK: - Design System

/// Centralized design tokens — use `DS.Spacing`, `DS.Radius`, etc.
///
/// Button hierarchy (Apple HIG):
/// - `.borderedProminent` = primary action (Print, Process, Import)
/// - `.bordered` = secondary action (Cancel, Close, navigation)
/// - `.borderless` = tertiary/icon-only (toolbar icons, collapse toggles)
enum DS {

    // MARK: Spacing

    enum Spacing {
        /// 2pt — minimal gap (e.g. between status dot and label)
        static let xxxSmall: CGFloat = 2
        /// 4pt — tight gap (e.g. icon-text in compact rows)
        static let xxSmall: CGFloat = 4
        /// 6pt — small inner padding
        static let xSmall: CGFloat = 6
        /// 8pt — standard small gap
        static let small: CGFloat = 8
        /// 10pt — compact section padding
        static let smallMedium: CGFloat = 10
        /// 12pt — standard medium gap
        static let medium: CGFloat = 12
        /// 16pt — section padding, content insets
        static let large: CGFloat = 16
        /// 20pt — large section gaps
        static let xLarge: CGFloat = 20
        /// 24pt — extra large gaps
        static let xxLarge: CGFloat = 24
    }

    // MARK: Radius

    enum Radius {
        /// 4pt — subtle rounding (badges, small cards)
        static let small: CGFloat = 4
        /// 8pt — standard rounding (cards, panels, dialogs)
        static let medium: CGFloat = 8
        /// 12pt — large rounding (modals, prominent elements)
        static let large: CGFloat = 12
    }

    // MARK: Typography

    /// Semantic font tokens — prefer these over `.system(size:)`.
    enum Typography {
        /// 10pt system — smallest text (metadata values, page numbers)
        static let caption2: Font = .system(size: 10)
        /// 11pt system — secondary info (log, status, filenames in panels)
        static let caption: Font = .system(size: 11)
        /// 12pt — form labels, table text
        static let subheadline: Font = .system(size: 12)
        /// 13pt — body text, dialog content
        static let body: Font = .body
        /// Standard headline
        static let headline: Font = .headline
        /// Monospaced caption for log output
        static let mono: Font = .system(size: 11, design: .monospaced)
        /// Monospaced caption2 for numeric data
        static let monoSmall: Font = .system(size: 10, design: .monospaced)
        /// Large icon placeholder (48pt)
        static let largeIcon: Font = .system(size: 48)
        /// Medium icon (28pt)
        static let mediumIcon: Font = .system(size: 28)
        /// Menu chevron (9pt semibold)
        static let menuChevron: Font = .system(size: 9, weight: .semibold)
        /// Toolbar/navigation icon (13pt semibold)
        static let navIcon: Font = .system(size: 13, weight: .semibold)
        /// Action bar icon (12pt medium)
        static let actionIcon: Font = .system(size: 12, weight: .medium)
        /// Small icon (10pt)
        static let smallIcon: Font = .system(size: 10)
        /// Small semibold label (11pt)
        static let captionSemibold: Font = .system(size: 11, weight: .semibold)
        /// Collapse/expand chevron (10pt semibold)
        static let chevron: Font = .system(size: 10, weight: .semibold)
    }

    // MARK: Colors

    /// Semantic color tokens — prefer these over hardcoded Color(red:green:blue:).
    enum Colors {
        // MARK: Surface colors
        /// Standard control background (NSColor.controlBackgroundColor)
        static let controlBackground = Color(NSColor.controlBackgroundColor)
        /// Window background
        static let windowBackground = Color(NSColor.windowBackgroundColor)
        /// Separator line
        static let separator = Color(NSColor.separatorColor)

        // MARK: Dark panel colors (QuickLook, log)
        /// Dark background for log console and QuickLook panels
        static let darkBackground = Color(white: 0.08)
        /// Slightly lighter dark surface (thumbnails, overlays)
        static let darkSurface = Color(white: 0.12)
        /// Dark surface for selected items
        static let darkSelected = Color(white: 0.30)
        /// Dark surface for unselected items
        static let darkUnselected = Color(white: 0.15)

        // MARK: Log colors
        /// Log info text (green tint)
        static let logInfo = Color(red: 0.4, green: 0.85, blue: 0.4)
        /// Log error text (red tint)
        static let logError = Color(red: 1.0, green: 0.35, blue: 0.35)
        /// Log success
        static let logSuccess = Color.green
        /// Log warning
        static let logWarning = Color.orange

        // MARK: Status
        /// Status success indicator
        static let statusSuccess = Color.green
        /// Status error indicator
        static let statusError = Color.red
    }
}

// MARK: - View Modifiers

extension View {
    /// Standard header padding: horizontal 10, vertical 8
    func headerPadding() -> some View {
        self.padding(.horizontal, DS.Spacing.smallMedium)
            .padding(.vertical, DS.Spacing.small)
    }

    /// Standard section/content padding: horizontal 16, vertical 10
    func sectionPadding() -> some View {
        self.padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.smallMedium)
    }

    /// Compact padding: horizontal 10, vertical 6
    func compactPadding() -> some View {
        self.padding(.horizontal, DS.Spacing.smallMedium)
            .padding(.vertical, DS.Spacing.xSmall)
    }
}

// MARK: - UserDefaults Keys

enum UDKeys {
    static let showPreview = "showPreview"
    static let showPrinterPanel = "showPrinterPanel"
    static let externalApps = "pm.externalApps"
    static let cloudConvertApiKey = "cloudConvertApiKey"
    static let iLovePDFPublicKey = "iLovePDFPublicKey"
    static let hiddenColumns = "pm.hiddenColumns"
    static let fileSortKey = "pm.fileSortKey"
    static let fileSortAscending = "pm.fileSortAscending"
    static func presetCache(printer: String) -> String { "pm.cache.presets.\(printer)" }
}
