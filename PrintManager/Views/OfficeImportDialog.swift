//
//  OfficeImportDialog.swift
//  PrintManager
//
//  Dialog pro výběr způsobu importu Office dokumentů
//

import SwiftUI

struct OfficeImportDialog: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var googleAuth = GoogleOAuthManager.shared
    @Binding var isPresented: Bool

    @State private var selectedMethod: ImportMethod = .auto

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text("Import Office dokumentů")
                    .font(.headline)
                Spacer()
            }

            Text("Vyberte způsob převodu Office dokumentů do PDF:")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Možnosti
            VStack(spacing: 8) {
                ForEach(ImportMethod.allCases, id: \.self) { method in
                    MethodOptionRow(
                        method: method,
                        isSelected: selectedMethod == method,
                        badge: badge(for: method),
                        onSelect: { selectedMethod = method }
                    )
                }
            }

            // Info k vybrané metodě
            infoRow

            // Chybové hlášení z OAuth
            if let err = googleAuth.authError {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }

            // Google přihlášení — zobrazí se jen pokud je vybraná Google a není přihlášeno
            if selectedMethod == .googleDrive && !googleAuth.isAuthenticated {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Nejste přihlášeni k Google.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if googleAuth.isAuthenticating {
                        ProgressView().controlSize(.small)
                        Text("Čekám na přihlášení...").font(.caption).foregroundColor(.secondary)
                    } else {
                        Button("Přihlásit se") {
                            GoogleOAuthManager.shared.startLogin()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }

            Divider()

            HStack {
                Button("Zrušit") {
                    isPresented = false
                    appState.pendingOfficeFiles.removeAll()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Importovat") {
                    performImport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(importDisabled)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Info row

    @ViewBuilder
    private var infoRow: some View {
        HStack(spacing: 6) {
            switch selectedMethod {
            case .auto:
                Image(systemName: "info.circle").foregroundColor(.blue)
                Text("Nejprve zkusí OpenOffice. Pokud není dostupný, použije CloudConvert.")
            case .openOffice:
                Image(systemName: "desktopcomputer").foregroundColor(.orange)
                Text("Použije OpenOffice/LibreOffice nainstalovaný v počítači. Rychlý, bez internetu.")
            case .cloudConvert:
                Image(systemName: "cloud.fill").foregroundColor(.purple)
                Text("Použije CloudConvert API. Vyžaduje internet a API klíč v Nastavení.")
            case .googleDrive:
                Image(systemName: "g.circle.fill").foregroundColor(.blue)
                Text("Nahraje soubor na Google Drive, exportuje jako PDF a smaže ho. Vyžaduje přihlášení.")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var importDisabled: Bool {
        selectedMethod == .googleDrive && !googleAuth.isAuthenticated
    }

    private func badge(for method: ImportMethod) -> MethodBadge? {
        switch method {
        case .auto:         return nil
        case .openOffice:   return appState.openOfficeAvailable ? .init("Dostupný", .green) : .init("Nenalezen", .secondary)
        case .cloudConvert: return appState.cloudConvertConfigured ? .init("Nakonfig.", .green) : .init("Chybí klíč", .orange)
        case .googleDrive:  return googleAuth.isAuthenticated ? .init("Přihlášen", .green) : .init("Nepřihlášen", .orange)
        }
    }

    // MARK: - Import actions

    private func performImport() {
        isPresented = false
        let files = appState.pendingOfficeFiles
        appState.pendingOfficeFiles.removeAll()

        switch selectedMethod {
        case .auto:
            let service = OfficeConversionService()
            Task {
                if service.isAvailable {
                    await importWithOpenOffice(files: files)
                } else {
                    await importWithCloudConvert(files: files)
                }
            }
        case .openOffice:
            Task { await importWithOpenOffice(files: files) }
        case .cloudConvert:
            Task { await importWithCloudConvert(files: files) }
        case .googleDrive:
            Task { await importWithGoogleDrive(files: files) }
        }
    }

    private func importWithOpenOffice(files: [URL]) async {
        let service = OfficeConversionService()
        guard service.isAvailable else {
            await MainActor.run { appState.logError("OpenOffice/LibreOffice není nainstalován") }
            return
        }
        await MainActor.run { appState.logInfo("Import \(files.count) souborů přes OpenOffice...") }
        for url in files {
            await MainActor.run { appState.logInfo("Konvertuji: \(url.lastPathComponent)") }
            do {
                let pdfURL = try await service.convertToPDF(url: url)
                await MainActor.run {
                    appState.addFiles(urls: [pdfURL])
                    appState.logSuccess("Hotovo: \(pdfURL.lastPathComponent)")
                }
            } catch {
                await MainActor.run { appState.logError("Chyba (\(url.lastPathComponent)): \(error.localizedDescription)") }
            }
        }
    }

    private func importWithCloudConvert(files: [URL]) async {
        let apiKey = UserDefaults.standard.string(forKey: "cloudConvertApiKey") ?? ""
        guard !apiKey.isEmpty else {
            await MainActor.run { appState.logError("CloudConvert API klíč není nastaven. Nastavte v Nastavení → CloudConvert.") }
            return
        }
        let service = CloudConvertService(apiKey: apiKey)
        await MainActor.run { appState.logInfo("Import \(files.count) souborů přes CloudConvert...") }
        for url in files {
            await MainActor.run { appState.logInfo("Nahrávám: \(url.lastPathComponent)") }
            do {
                let pdfURL = try await service.convertToPDF(fileURL: url)
                await MainActor.run {
                    appState.addFiles(urls: [pdfURL])
                    appState.logSuccess("Hotovo: \(pdfURL.lastPathComponent)")
                }
            } catch {
                await MainActor.run { appState.logError("Chyba (\(url.lastPathComponent)): \(error.localizedDescription)") }
            }
        }
    }

    private func importWithGoogleDrive(files: [URL]) async {
        let service = GoogleDocsConversionService()
        await MainActor.run { appState.logInfo("Import \(files.count) souborů přes Google Drive...") }
        for url in files {
            await MainActor.run { appState.logInfo("Nahrávám na Drive: \(url.lastPathComponent)") }
            do {
                let pdfURL = try await service.convertToPDF(fileURL: url)
                await MainActor.run {
                    appState.addFiles(urls: [pdfURL])
                    appState.logSuccess("Hotovo: \(pdfURL.lastPathComponent)")
                }
            } catch {
                await MainActor.run { appState.logError("Chyba (\(url.lastPathComponent)): \(error.localizedDescription)") }
            }
        }
    }
}

// MARK: - Badge model

struct MethodBadge {
    let label: String
    let color: Color
    init(_ label: String, _ color: Color) {
        self.label = label
        self.color = color
    }
}

// MARK: - Method Option Row

struct MethodOptionRow: View {
    let method: ImportMethod
    let isSelected: Bool
    let badge: MethodBadge?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Radio
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.secondary, lineWidth: 2)
                        .frame(width: 20, height: 20)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 12, height: 12)
                    }
                }

                // Ikona
                Image(systemName: method.icon)
                    .font(.title2)
                    .foregroundColor(iconColor)
                    .frame(width: 30)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.rawValue)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(method.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Badge
                if let badge {
                    Text(badge.label)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(badge.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.12))
                        .cornerRadius(5)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        switch method {
        case .auto:         return .blue
        case .openOffice:   return .orange
        case .cloudConvert: return .purple
        case .googleDrive:  return .blue
        }
    }
}

// MARK: - AppState extensions

extension AppState {
    var openOfficeAvailable: Bool {
        OfficeConversionService().isAvailable
    }
    var cloudConvertConfigured: Bool {
        !(UserDefaults.standard.string(forKey: "cloudConvertApiKey") ?? "").isEmpty
    }
}

#Preview {
    OfficeImportDialog(isPresented: .constant(true))
        .environmentObject(AppState())
}
