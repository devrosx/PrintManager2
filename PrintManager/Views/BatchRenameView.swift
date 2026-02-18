//
//  BatchRenameView.swift
//  PrintManager
//
//  Hromadné přejmenování vybraných souborů: základ + číslování.
//  Přejmenuje soubory na disku i v seznamu PrintManageru.
//

import SwiftUI

struct BatchRenameView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    // ── Nastavení ─────────────────────────────────────────────────────────
    @State private var baseName: String   = ""
    @State private var separator: String  = "_"
    @State private var padding: Int       = 2      // počet číslic (2 → 01, 3 → 001)
    @State private var startNumber: Int   = 1

    // ── Stav ──────────────────────────────────────────────────────────────
    @State private var isRenaming = false
    @State private var errorMessage: String? = nil

    private var selectedFiles: [FileItem] {
        appState.files.filter { appState.selectedFiles.contains($0.id) }
    }

    private func newName(for file: FileItem, index: Int) -> String {
        let ext = file.fileType.rawValue.lowercased()
        let num = String(format: "%0\(padding)d", startNumber + index)
        let sep = separator == "none" ? "" : separator
        let base = baseName.trimmingCharacters(in: .whitespaces)
        let stem = base.isEmpty ? num : "\(base)\(sep)\(num)"
        return "\(stem).\(ext)"
    }

    // ── Body ──────────────────────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 0) {

            // Záhlaví
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hromadné přejmenování")
                        .font(.headline)
                    Text("\(selectedFiles.count) souborů")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Formulář ──────────────────────────────────────────────────
            Form {
                Section("Vzor názvu") {
                    HStack(spacing: 8) {
                        TextField("Základní název (např. faktura)", text: $baseName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)

                        Picker("", selection: $separator) {
                            Text("_ podtržítko").tag("_")
                            Text("- pomlčka").tag("-")
                            Text("  mezera").tag(" ")
                            Text("bez oddělovače").tag("none")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        .labelsHidden()

                        // Číslování
                        Text(String(format: "%0\(padding)d", startNumber))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50)
                    }

                    HStack(spacing: 20) {
                        Picker("Číslice:", selection: $padding) {
                            Text("1 (1, 2…)").tag(1)
                            Text("2 (01, 02…)").tag(2)
                            Text("3 (001, 002…)").tag(3)
                            Text("4 (0001…)").tag(4)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)

                        Stepper("Start: \(startNumber)", value: $startNumber, in: 0...9999)
                            .frame(width: 160)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // ── Náhled ────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Náhled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(selectedFiles.enumerated()), id: \.element.id) { idx, file in
                            HStack(spacing: 0) {
                                Text(file.name + "." + file.fileType.rawValue.lowercased())
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)

                                Text(newName(for: file, index: idx))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(idx % 2 == 0
                                ? Color(NSColor.controlBackgroundColor)
                                : Color(NSColor.windowBackgroundColor))
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 220)
            }

            Divider()

            // ── Spodní lišta ──────────────────────────────────────────────
            VStack(spacing: 6) {
                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Zrušit") { isPresented = false }
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    if isRenaming {
                        ProgressView().scaleEffect(0.7)
                    }

                    Button {
                        performRename()
                    } label: {
                        Label("Přejmenovat \(selectedFiles.count) souborů", systemImage: "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRenaming || selectedFiles.isEmpty || baseName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 600, minHeight: 380)
    }

    // MARK: - Rename logic

    private func performRename() {
        errorMessage = nil
        isRenaming = true

        let files = selectedFiles
        Task {
            var errors: [String] = []
            var renamedCount = 0

            for (idx, file) in files.enumerated() {
                let newFileName = newName(for: file, index: idx)
                let oldURL = file.url
                let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newFileName)

                if oldURL.lastPathComponent == newFileName { renamedCount += 1; continue }

                if FileManager.default.fileExists(atPath: newURL.path) {
                    errors.append("Soubor již existuje: \(newFileName)")
                    continue
                }

                do {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                    renamedCount += 1
                    // Aktualizovat záznam — zkopírovat existující FileItem, jen změnit URL a name.
                    // NEPARSOVAT znovu (blokuje UI u velkých PDF).
                    let newStem = newURL.deletingPathExtension().lastPathComponent
                    let renamed = FileItem(
                        id: file.id,
                        url: newURL,
                        name: newStem,
                        fileType: file.fileType,
                        fileSize: file.fileSize,
                        pageCount: file.pageCount,
                        pageSize: file.pageSize,
                        colorInfo: file.colorInfo,
                        status: file.status,
                        thumbnail: file.thumbnail
                    )
                    await MainActor.run {
                        appState.replaceFile(renamed)
                    }
                } catch {
                    errors.append("\(file.name): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                isRenaming = false
                if errors.isEmpty {
                    appState.logSuccess("Přejmenováno \(renamedCount) soubor(ů)")
                    isPresented = false
                } else {
                    errorMessage = errors.prefix(3).joined(separator: "\n")
                    appState.logWarning("Přejmenování: \(errors.count) chyb")
                }
            }
        }
    }
}
