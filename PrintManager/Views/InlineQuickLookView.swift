//
//  InlineQuickLookView.swift
//  PrintManager
//
//  Inline QuickLook — zobrazuje náhled přímo v hlavním okně místo listu souborů.
//  Mezerník přepíná mezi seznamem souborů a náhledem.
//  Defaultně zobrazuje thumbnaily všech stránek s možností zoom.
//  Poklepání na thumbnail otevře single-page náhled.
//

import SwiftUI
import AppKit
import PDFKit

// MARK: - Thumbnail Frame Preference Key

struct ThumbnailFrameData: Equatable {
    let pageIndex: Int
    let frame: CGRect
}

struct ThumbnailFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ThumbnailFrameData] = []
    static func reduce(value: inout [ThumbnailFrameData], nextValue: () -> [ThumbnailFrameData]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Inline QuickLook View

struct InlineQuickLookView: View {
    @EnvironmentObject var appState: AppState
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var isLoadingThumbnails = false
    @State private var keyMonitor: Any?
    @State private var selectedPages: Set<Int> = []
    @AppStorage("quickLookShowColorPages") private var showColorPages = false
    @State private var draggedPage: Int? = nil
    @State private var draggedPages: Set<Int> = []
    @State private var pageOrder: [Int] = []
    @State private var lastClickedPage: Int? = nil
    @State private var selectionRectStart: CGPoint? = nil
    @State private var selectionRectCurrent: CGPoint? = nil
    @State private var cardFrames: [ThumbnailFrameData] = []
    @State private var isRubberBanding = false

    private var file: FileItem? {
        guard let id = appState.quickLookFileID else { return nil }
        return appState.files.first(where: { $0.id == id })
    }

    private var fileIndex: Int? {
        guard let id = appState.quickLookFileID else { return nil }
        let pool = appState.quickLookFileIDs.isEmpty ? appState.files.map(\.id) : appState.quickLookFileIDs
        return pool.firstIndex(of: id)
    }

    private var filePoolCount: Int {
        let pool = appState.quickLookFileIDs.isEmpty ? appState.files.map(\.id) : appState.quickLookFileIDs
        return pool.count
    }

    /// Zda je aktuální soubor obrázek s jednou stránkou (nepotřebuje stránkování)
    private var isSingleImage: Bool {
        guard let f = file else { return false }
        return f.fileType.isImage && f.pageCount <= 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Horní lišta
            topBar

            Divider()

            // Hlavní obsah
            if let f = file {
                if appState.quickLookMode == .thumbnails {
                    // Thumbnail grid s zoom sliderem
                    thumbnailGridView(file: f)
                } else {
                    // Single page náhled
                    singlePageView(file: f)
                }
            } else {
                VStack(spacing: DS.Spacing.medium) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(DS.Typography.largeIcon)
                        .foregroundColor(.secondary)
                    Text("Žádný soubor nevybrán")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if let firstID = appState.selectedFiles.first {
                appState.quickLookFileID = firstID
            }
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: appState.quickLookFileID) { newFileID in
            // Reset výběru stránek a pořadí při změně souboru
            selectedPages.removeAll()
            if let f = file {
                pageOrder = Array(0..<f.pageCount)
                // Pokud je barevný mód aktivní, spusť analýzu pro nový soubor
                if showColorPages {
                    appState.loadPDFMetadataIfNeeded(for: f)
                    appState.ensureColorAnalysis(for: f)
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: DS.Spacing.medium) {
            // Navigace mezi soubory
            Button {
                appState.quickLookMoveUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(DS.Typography.navIcon)
            }
            .buttonStyle(.borderless)
            .disabled(fileIndex == nil || fileIndex == 0)
            .accessibilityLabel("Previous file")

            Button {
                appState.quickLookMoveDown()
            } label: {
                Image(systemName: "chevron.down")
                    .font(DS.Typography.navIcon)
            }
            .buttonStyle(.borderless)
            .disabled(fileIndex == nil || fileIndex == filePoolCount - 1)
            .accessibilityLabel("Next file")

            Divider()
                .frame(height: 16)

            // Zpět na thumbnaily (pouze pro PDF s více stránkami, ne pro obrázky)
            if appState.quickLookMode == .singlePage && !isSingleImage {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.quickLookMode = .thumbnails
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xxSmall) {
                        Image(systemName: "rectangle.grid.2x2")
                        Text("Zpět na náhledy")
                    }
                    .font(DS.Typography.subheadline)
                }
                .buttonStyle(.bordered)
            }

            // Počet vybraných stránek (v thumbnail režimu)
            if appState.quickLookMode == .thumbnails && !selectedPages.isEmpty {
                Text("\(selectedPages.count) vybraných stránek")
                    .font(DS.Typography.caption)
                    .foregroundColor(.accentColor)

                Button("Zrušit výběr") {
                    selectedPages.removeAll()
                }
                .buttonStyle(.borderless)
                .font(DS.Typography.caption)
            }

            // Tlačítko pro aplikování změn pořadí
            if appState.quickLookMode == .thumbnails,
               let f = file,
               hasReorderedPages(file: f) {
                Button {
                    applyPageReordering(file: f)
                } label: {
                    HStack(spacing: DS.Spacing.xxSmall) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Použít nové pořadí")
                    }
                    .font(DS.Typography.caption)
                }
                .buttonStyle(.borderedProminent)

                Button("Zrušit") {
                    resetPageOrder(file: f)
                }
                .buttonStyle(.borderless)
                .font(DS.Typography.caption)
            }

            Spacer()

            // Název souboru a pozice
            if let f = file {
                Text(f.name)
                    .font(DS.Typography.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let idx = fileIndex {
                Text("\(idx + 1) / \(filePoolCount)")
                    .font(DS.Typography.caption)
                    .foregroundColor(.secondary)
            }

            // Zavřít QuickLook (mezerník)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.showInlineQuickLook = false
                    appState.quickLookMode = .thumbnails
                }
            } label: {
                HStack(spacing: DS.Spacing.xxSmall) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Zavřít")
                        .font(DS.Typography.caption)
                }
            }
            .buttonStyle(.borderless)
            .help("Zavřít (mezerník)")
            .accessibilityLabel("Close inline Quick Look")
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.smallMedium)
        .background(DS.Colors.controlBackground)
    }

    // MARK: - Thumbnail Grid View

    private func thumbnailGridView(file: FileItem) -> some View {
        VStack(spacing: 0) {
            // Zoom slider
            HStack {
                Text("Velikost náhledů:")
                    .font(DS.Typography.caption)
                    .foregroundColor(.secondary)

                Image(systemName: "minus.magnifyingglass")
                    .font(DS.Typography.smallIcon)
                    .foregroundColor(.secondary)

                Slider(value: $appState.thumbnailZoom, in: 0.5...2.0, step: 0.1)
                    .frame(width: 120)

                Image(systemName: "plus.magnifyingglass")
                    .font(DS.Typography.smallIcon)
                    .foregroundColor(.secondary)

                Spacer()

                // Toggle pro zobrazení barevných stránek (pouze pro PDF)
                if file.fileType == .pdf {
                    Toggle(isOn: $showColorPages) {
                        HStack(spacing: 4) {
                            CMYKBadge(size: 12)
                            Text("Barevné stránky")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(DS.Typography.caption)
                    .onChange(of: showColorPages) { enabled in
                        if enabled {
                            appState.loadPDFMetadataIfNeeded(for: file)
                            appState.ensureColorAnalysis(for: file)
                        }
                    }
                }

                Text("\(file.pageCount) stránek")
                    .font(DS.Typography.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.small)
            .background(DS.Colors.controlBackground)

            Divider()

            // Thumbnail grid
            ScrollViewReader { proxy in
                ScrollView {
                    let baseSize: CGFloat = 100
                    let thumbnailSize = baseSize * appState.thumbnailZoom
                    let columns = [GridItem(.adaptive(minimum: thumbnailSize + 16), spacing: 12)]
                    let colorNums = showColorPages
                        ? (appState.pdfMetadataCache[file.id]?.colorPageNumbers ?? [])
                        : Set<Int>()

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(pageOrder, id: \.self) { pageIndex in
                            ThumbnailCard(
                                file: file,
                                pageIndex: pageIndex,
                                thumbnail: thumbnails[pageIndex],
                                size: thumbnailSize,
                                isSelected: selectedPages.contains(pageIndex),
                                isDragging: draggedPages.contains(pageIndex),
                                isColorPage: colorNums.contains(pageIndex + 1)
                            )
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: ThumbnailFramePreferenceKey.self,
                                    value: [ThumbnailFrameData(pageIndex: pageIndex, frame: geo.frame(in: .named("thumbnailGrid")))]
                                )
                            })
                            .onTapGesture(count: 2) {
                                if selectedPages.isEmpty {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        appState.quickLookCurrentPage = pageIndex
                                        appState.quickLookMode = .singlePage
                                    }
                                }
                            }
                            .onTapGesture(count: 1) {
                                handlePageTap(pageIndex: pageIndex)
                            }
                            .contextMenu {
                                pageContextMenu(for: pageIndex, file: file)
                            }
                            .onDrag {
                                draggedPage = pageIndex
                                let pagesToDrag: [Int]
                                if selectedPages.contains(pageIndex) {
                                    pagesToDrag = Array(selectedPages).sorted()
                                    draggedPages = selectedPages
                                } else {
                                    pagesToDrag = [pageIndex]
                                    draggedPages = [pageIndex]
                                }

                                let provider = NSItemProvider(object: "\(pageIndex)" as NSString)

                                // Registrace PDF pro drag na plochu/Finder
                                if file.fileType == .pdf {
                                    let capturedFile = file
                                    let capturedPages = pagesToDrag
                                    provider.registerFileRepresentation(
                                        forTypeIdentifier: "com.adobe.pdf",
                                        fileOptions: [],
                                        visibility: .all
                                    ) { completion in
                                        DispatchQueue.global(qos: .userInitiated).async {
                                            if let tempURL = try? InlineQuickLookView.makeTempPDF(file: capturedFile, pages: capturedPages) {
                                                completion(tempURL, false, nil)
                                            } else {
                                                completion(nil, false, nil)
                                            }
                                        }
                                        return nil
                                    }
                                }

                                return provider
                            } preview: {
                                DragPreviewBadge(
                                    thumbnail: thumbnails[pageIndex],
                                    count: selectedPages.contains(pageIndex) ? selectedPages.count : 1,
                                    size: thumbnailSize * 0.6
                                )
                            }
                            .onDrop(of: [.text], delegate: PageDropDelegate(
                                destinationPage: pageIndex,
                                pageOrder: $pageOrder,
                                draggedPage: $draggedPage,
                                draggedPages: $draggedPages
                            ))
                            .id(pageIndex)
                        }
                    }
                    .padding(16)
                    .onAppear {
                        if pageOrder.count != file.pageCount {
                            pageOrder = Array(0..<file.pageCount)
                        }
                    }
                    .background(
                        // Pozadí zachytává rubber-band gesture a klik pro zrušení výběru
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named("thumbnailGrid"))
                                    .onChanged { value in
                                        isRubberBanding = true
                                        if selectionRectStart == nil {
                                            selectionRectStart = value.startLocation
                                        }
                                        selectionRectCurrent = value.location

                                        // Živá selekce během tažení
                                        let cmdPressed = NSEvent.modifierFlags.contains(.command)
                                        handleRectangleSelection(selectionRect: currentSelectionRect, commandPressed: cmdPressed)
                                    }
                                    .onEnded { value in
                                        let cmdPressed = NSEvent.modifierFlags.contains(.command)
                                        handleRectangleSelection(selectionRect: currentSelectionRect, commandPressed: cmdPressed)
                                        selectionRectStart = nil
                                        selectionRectCurrent = nil
                                        isRubberBanding = false
                                    }
                            )
                            .onTapGesture {
                                selectedPages.removeAll()
                            }
                    )
                    .overlay(alignment: .topLeading) {
                        // Selection rectangle vizuální overlay
                        if let start = selectionRectStart, let current = selectionRectCurrent {
                            let rect = CGRect(
                                x: min(start.x, current.x),
                                y: min(start.y, current.y),
                                width: abs(current.x - start.x),
                                height: abs(current.y - start.y)
                            )
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.1))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: "thumbnailGrid")
                    .onPreferenceChange(ThumbnailFramePreferenceKey.self) { frames in
                        self.cardFrames = frames
                    }
                }
                .onAppear {
                    loadAllThumbnails(file: file)
                }
                .onChange(of: file.id) { _ in
                    thumbnails.removeAll()
                    loadAllThumbnails(file: file)
                }
            }
        }
    }

    // MARK: - Single Page View

    private func singlePageView(file: FileItem) -> some View {
        VStack(spacing: 0) {
            // Navigace stránek — skrýt pro obrázky s jednou stránkou
            if file.pageCount > 1 {
                HStack(spacing: DS.Spacing.large) {
                    Button {
                        if appState.quickLookCurrentPage > 0 {
                            appState.quickLookCurrentPage -= 1
                        }
                    } label: {
                        Image(systemName: "arrow.left.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.quickLookCurrentPage == 0)
                    .accessibilityLabel("Previous page")

                    Text("Strana \(appState.quickLookCurrentPage + 1) / \(file.pageCount)")
                        .font(.system(size: 13))

                    Button {
                        if appState.quickLookCurrentPage < file.pageCount - 1 {
                            appState.quickLookCurrentPage += 1
                        }
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.quickLookCurrentPage >= file.pageCount - 1)
                    .accessibilityLabel("Next page")
                }
                .padding(.vertical, DS.Spacing.smallMedium)
                .background(DS.Colors.controlBackground)

                Divider()
            }

            // Náhled stránky
            GeometryReader { geometry in
                SinglePagePreview(
                    file: file,
                    currentPage: appState.quickLookCurrentPage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    HStack(spacing: 0) {
                        // Levá polovina - předchozí strana
                        if appState.quickLookCurrentPage > 0 {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.quickLookCurrentPage -= 1
                                }
                        }

                        Spacer()

                        // Pravá polovina - následující strana
                        if appState.quickLookCurrentPage < file.pageCount - 1 {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.quickLookCurrentPage += 1
                                }
                        }
                    }
                )
            }
        }
    }

    // MARK: - Load Thumbnails

    private func loadAllThumbnails(file: FileItem) {
        guard !isLoadingThumbnails else { return }
        isLoadingThumbnails = true

        Task {
            guard let doc = PDFDocument(url: file.url) else {
                await MainActor.run { isLoadingThumbnails = false }
                return
            }

            let thumbSize = CGSize(width: 200, height: 280)
            var localThumbnails: [Int: NSImage] = [:]

            for i in 0..<file.pageCount {
                if let page = doc.page(at: i) {
                    let thumb = page.thumbnail(of: thumbSize, for: .mediaBox)
                    localThumbnails[i] = thumb
                }
            }

            await MainActor.run {
                self.thumbnails = localThumbnails
                self.isLoadingThumbnails = false
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func pageContextMenu(for pageIndex: Int, file: FileItem) -> some View {
        let pagesToProcess = selectedPages.isEmpty ? [pageIndex] : Array(selectedPages).sorted()

        // Invertovat výběr
        Button {
            let allPages = Set(0..<file.pageCount)
            selectedPages = allPages.subtracting(selectedPages.isEmpty ? [pageIndex] : selectedPages)
        } label: {
            Label("Invertovat výběr", systemImage: "arrow.2.squarepath")
        }

        Divider()

        Button {
            rotatePagesClockwise(pages: pagesToProcess, file: file)
        } label: {
            Label("Otočit o 90° vpravo", systemImage: "rotate.right")
        }

        Button {
            rotatePagesCounterClockwise(pages: pagesToProcess, file: file)
        } label: {
            Label("Otočit o 90° vlevo", systemImage: "rotate.left")
        }

        Divider()

        Button {
            printSelectedPages(pages: pagesToProcess, file: file)
        } label: {
            Label("Tisknout stránky", systemImage: "printer")
        }

        Button {
            convertSelectedToGrayscale(pages: pagesToProcess, file: file)
        } label: {
            Label("Převést na stupně šedi", systemImage: "circle.lefthalf.filled")
        }

        Button {
            insertBlankPageAfter(pageIndex: pageIndex, file: file)
        } label: {
            Label("Vložit prázdnou stránku za", systemImage: "plus.rectangle")
        }

        Divider()

        Button {
            extractPages(pages: pagesToProcess, file: file)
        } label: {
            Label("Extrahovat stránky", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            deletePages(pages: pagesToProcess, file: file)
        } label: {
            Label("Smazat stránky", systemImage: "trash")
        }
    }

    // MARK: - Page Operations

    private func rotatePagesClockwise(pages: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }

        let pdfService = PDFService()
        Task {
            do {
                try await pdfService.rotatePages(
                    url: file.url,
                    pageIndices: pages,
                    degrees: 90
                )
                await MainActor.run {
                    refreshCurrentFile(file: file)
                    appState.logSuccess("Stránky otočeny doprava")
                    selectedPages.removeAll()
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba rotace")
                }
            }
        }
    }

    private func rotatePagesCounterClockwise(pages: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }

        let pdfService = PDFService()
        Task {
            do {
                try await pdfService.rotatePages(
                    url: file.url,
                    pageIndices: pages,
                    degrees: -90
                )
                await MainActor.run {
                    refreshCurrentFile(file: file)
                    appState.logSuccess("Stránky otočeny doleva")
                    selectedPages.removeAll()
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba rotace")
                }
            }
        }
    }

    private func extractPages(pages: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }

        let pdfService = PDFService()
        Task {
            do {
                let outputURL = try await pdfService.extractPages(
                    url: file.url,
                    pageIndices: pages
                )
                await MainActor.run {
                    appState.addFiles(urls: [outputURL], autoSelect: true)
                    appState.logSuccess("Stránky extrahovány: \(outputURL.lastPathComponent)")
                    selectedPages.removeAll()
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba extrakce")
                }
            }
        }
    }

    private func deletePages(pages: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }

        let pdfService = PDFService()
        Task {
            do {
                try await pdfService.deletePages(
                    url: file.url,
                    pageIndices: pages
                )
                await MainActor.run {
                    refreshCurrentFile(file: file)
                    appState.logSuccess("Stránky smazány")
                    selectedPages.removeAll()
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba mazání stránek")
                }
            }
        }
    }

    private func printSelectedPages(pages: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }
        Task { @MainActor in
            guard let sourceDoc = PDFDocument(url: file.url) else { return }
            let printDoc = PDFDocument()
            for (newIdx, pageIdx) in pages.enumerated() {
                if let page = sourceDoc.page(at: pageIdx) {
                    printDoc.insert(page, at: newIdx)
                }
            }
            let pi = NSPrintInfo.shared.copy() as! NSPrintInfo
            // Nastav tiskárnu vybranou v levém panelu
            let selectedPrinter = appState.selectedPrinter
            if !selectedPrinter.isEmpty {
                if let p = NSPrinter(name: selectedPrinter) {
                    pi.printer = p
                } else {
                    let lower = selectedPrinter.lowercased()
                    if let match = NSPrinter.printerNames.first(where: { $0.lowercased() == lower }),
                       let p = NSPrinter(name: match) {
                        pi.printer = p
                    }
                }
            }
            guard let op = printDoc.printOperation(for: pi, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
            op.showsPrintPanel = true
            op.showsProgressPanel = true
            // Připojit k oknu — jinak dialog ztratí fokus při kliknutí
            if let window = NSApp.keyWindow {
                op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                op.run()
            }
        }
    }

    private func convertSelectedToGrayscale(pages: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }
        // colorPages = všechny stránky KROMĚ vybraných (vybrané se převedou na šedou)
        let colorPages = Set(0..<file.pageCount).subtracting(Set(pages))
        let originalURL = file.url
        let fileID = file.id
        let pdfService = PDFService()
        Task {
            do {
                let outputURL = try await pdfService.convertSelectiveToGray(url: originalURL, colorPages: colorPages)
                // Přepiš originál výstupním souborem in-place
                try FileManager.default.removeItem(at: originalURL)
                try FileManager.default.moveItem(at: outputURL, to: originalURL)
                await MainActor.run {
                    // Vynuluj starou barevnou analýzu — obsah souboru se změnil
                    appState.resetColorAnalysis(for: fileID)
                    refreshCurrentFile(file: file)
                    appState.logSuccess("Vybrané stránky převedeny na stupně šedi")
                    selectedPages.removeAll()
                    // Pokud je analýza barev zapnutá, spusť ji znovu
                    if showColorPages, let f = self.file {
                        appState.loadPDFMetadataIfNeeded(for: f)
                        appState.ensureColorAnalysis(for: f)
                    }
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba konverze na šedou")
                }
            }
        }
    }

    private func insertBlankPageAfter(pageIndex: Int, file: FileItem) {
        guard file.fileType == .pdf else { return }
        let pdfService = PDFService()
        Task {
            do {
                try await pdfService.insertBlankPage(url: file.url, afterPageIndex: pageIndex)
                await MainActor.run {
                    refreshCurrentFile(file: file)
                    appState.logSuccess("Prázdná stránka vložena za stránku \(pageIndex + 1)")
                    selectedPages.removeAll()
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba vložení prázdné stránky")
                }
            }
        }
    }

    private func reorderPages(newOrder: [Int], file: FileItem) {
        guard file.fileType == .pdf else { return }

        let pdfService = PDFService()
        Task {
            do {
                try await pdfService.reorderPages(
                    url: file.url,
                    newOrder: newOrder
                )
                await MainActor.run {
                    refreshCurrentFile(file: file)
                    appState.logSuccess("Stránky přesunuty")
                    selectedPages.removeAll()
                }
            } catch {
                await MainActor.run {
                    appState.handleOperationError(error, operationDescription: "Chyba přesouvání stránek")
                }
            }
        }
    }

    /// Refresh aktuálního souboru po změně (reload thumbnails, update metadata)
    private func refreshCurrentFile(file: FileItem) {
        // Re-parse soubor pro aktualizaci metadata
        let fileParser = FileParser()
        if var refreshed = fileParser.parseFile(url: file.url) {
            // Zachovat původní UUID a inkrementovat verzi obsahu
            refreshed.id = file.id
            if let index = appState.files.firstIndex(where: { $0.id == file.id }) {
                refreshed.contentVersion = appState.files[index].contentVersion + 1
                appState.files[index] = refreshed
            }

            // Reload thumbnails a reset pageOrder
            thumbnails.removeAll()
            pageOrder = Array(0..<refreshed.pageCount)
            if let f = self.file {
                loadAllThumbnails(file: f)
            }
        }
    }

    // MARK: - Page Reordering Helpers

    private func hasReorderedPages(file: FileItem) -> Bool {
        let originalOrder = Array(0..<file.pageCount)
        return pageOrder != originalOrder
    }

    private func applyPageReordering(file: FileItem) {
        reorderPages(newOrder: pageOrder, file: file)
    }

    private func resetPageOrder(file: FileItem) {
        withAnimation {
            pageOrder = Array(0..<file.pageCount)
        }
    }

    // MARK: - Selection Helpers

    /// Handle tap na stránce — Preview.app styl:
    /// Klik = vyber jen tuto, Cmd+klik = toggle, Shift+klik = range
    private func handlePageTap(pageIndex: Int) {
        let event = NSApp.currentEvent
        let cmdPressed = event?.modifierFlags.contains(.command) ?? false
        let shiftPressed = event?.modifierFlags.contains(.shift) ?? false

        if shiftPressed, let lastPage = lastClickedPage {
            // Shift+klik = range selection
            let range = Set(min(lastPage, pageIndex)...max(lastPage, pageIndex))
            if cmdPressed {
                selectedPages.formUnion(range)
            } else {
                selectedPages = range
            }
        } else if cmdPressed {
            // Cmd+klik = toggle
            if selectedPages.contains(pageIndex) {
                selectedPages.remove(pageIndex)
            } else {
                selectedPages.insert(pageIndex)
            }
        } else {
            // Normální klik = vyber jen tuto stránku
            selectedPages = [pageIndex]
        }

        lastClickedPage = pageIndex
    }

    /// Aktuální selection rect vypočtený ze start/current bodů
    private var currentSelectionRect: CGRect {
        guard let start = selectionRectStart, let current = selectionRectCurrent else {
            return .zero
        }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    /// Handle rectangle selection (lasso) — používá cardFrames z PreferenceKey
    private func handleRectangleSelection(selectionRect: CGRect, commandPressed: Bool) {
        guard selectionRect.width > 2 || selectionRect.height > 2 else { return }

        var newSelection = Set<Int>()
        for cardFrame in cardFrames {
            if selectionRect.intersects(cardFrame.frame) {
                newSelection.insert(cardFrame.pageIndex)
            }
        }

        if commandPressed {
            selectedPages.formSymmetricDifference(newSelection)
        } else {
            selectedPages = newSelection
        }
    }

    // MARK: - Keyboard Monitoring

    private func setupKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard appState.showInlineQuickLook else { return event }

            // Cmd+A - Select all pages (v thumbnail režimu)
            if event.modifierFlags.contains(.command) && event.keyCode == 0 { // 0 = A key
                if appState.quickLookMode == .thumbnails, let f = file {
                    selectedPages = Set(0..<f.pageCount)
                    return nil
                }
            }

            // Delete - smazat vybrané stránky
            if event.keyCode == 51 { // Delete/Backspace
                if appState.quickLookMode == .thumbnails, !selectedPages.isEmpty, let f = file {
                    deletePages(pages: Array(selectedPages).sorted(), file: f)
                    return nil
                }
            }

            switch event.keyCode {
            case 126: // arrow up - předchozí soubor
                appState.quickLookMoveUp()
                return nil
            case 125: // arrow down - další soubor
                appState.quickLookMoveDown()
                return nil
            case 123: // arrow left - předchozí strana (pokud jsme v single page)
                if appState.quickLookMode == .singlePage && appState.quickLookCurrentPage > 0 {
                    appState.quickLookCurrentPage -= 1
                }
                return nil
            case 124: // arrow right - další strana (pokud jsme v single page)
                if appState.quickLookMode == .singlePage,
                   let f = file,
                   appState.quickLookCurrentPage < f.pageCount - 1 {
                    appState.quickLookCurrentPage += 1
                }
                return nil
            case 53: // Escape - zpět na thumbnaily nebo zavřít QuickLook
                if !selectedPages.isEmpty {
                    // Pokud jsou nějaké stránky vybrané, nejprve zruš výběr
                    selectedPages.removeAll()
                } else if appState.quickLookMode == .singlePage && !isSingleImage {
                    // Pro PDF s více stránkami zpět na thumbnails
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.quickLookMode = .thumbnails
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showInlineQuickLook = false
                    }
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Temp PDF pro drag na Finder/plochu

    /// Vytvoří dočasné PDF z vybraných stránek a vrátí jeho URL.
    /// Volá se synchronně na background threadu z registerFileRepresentation.
    static func makeTempPDF(file: FileItem, pages: [Int]) throws -> URL {
        guard let sourceDoc = PDFDocument(url: file.url) else {
            throw CocoaError(.fileReadUnknown)
        }

        let newDoc = PDFDocument()
        for (newIdx, pageIdx) in pages.enumerated() {
            if let page = sourceDoc.page(at: pageIdx) {
                newDoc.insert(page, at: newIdx)
            }
        }

        let pageLabel: String
        if pages.count == 1 {
            pageLabel = "strana\(pages[0] + 1)"
        } else {
            let first = pages.first.map { String($0 + 1) } ?? ""
            let last  = pages.last.map  { String($0 + 1) } ?? ""
            pageLabel = "strany\(first)-\(last)"
        }

        let fileName = "\(file.name)_\(pageLabel).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        guard newDoc.write(to: tempURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return tempURL
    }
}

// MARK: - Page Drop Delegate

struct PageDropDelegate: DropDelegate {
    let destinationPage: Int
    @Binding var pageOrder: [Int]
    @Binding var draggedPage: Int?
    @Binding var draggedPages: Set<Int>

    func performDrop(info: DropInfo) -> Bool {
        draggedPage = nil
        draggedPages.removeAll()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedPage = draggedPage,
              !draggedPages.contains(destinationPage),
              let toIndex = pageOrder.firstIndex(of: destinationPage) else {
            return
        }

        withAnimation(.default) {
            if draggedPages.count > 1 {
                // Multi-page move: odeber všechny tažené stránky a vlož je před/za cíl
                let movingPages = pageOrder.filter { draggedPages.contains($0) }
                pageOrder.removeAll { draggedPages.contains($0) }

                // Najdi novou pozici cíle po odebrání
                if let newToIndex = pageOrder.firstIndex(of: destinationPage) {
                    pageOrder.insert(contentsOf: movingPages, at: newToIndex)
                }
            } else {
                // Single page move
                guard let fromIndex = pageOrder.firstIndex(of: draggedPage) else { return }
                pageOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}

// MARK: - Drag Preview Badge

private struct DragPreviewBadge: View {
    let thumbnail: NSImage?
    let count: Int
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(DS.Colors.controlBackground)
                .overlay(
                    Group {
                        if let thumb = thumbnail {
                            Image(nsImage: thumb)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .padding(3)
                        }
                    }
                )
                .frame(width: size, height: size * 1.4)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(
                        Capsule()
                            .fill(Color.red)
                    )
                    .offset(x: 6, y: -6)
            }
        }
    }
}

// MARK: - Thumbnail Card

private struct ThumbnailCard: View {
    let file: FileItem
    let pageIndex: Int
    let thumbnail: NSImage?
    let size: CGFloat
    let isSelected: Bool
    let isDragging: Bool
    var isColorPage: Bool = false

    var body: some View {
        VStack(spacing: DS.Spacing.xxSmall) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : DS.Colors.controlBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.small)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                   lineWidth: isSelected ? 3 : 1)
                    )

                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                        .opacity(isDragging ? 0.5 : 1.0)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                // Checkmark když je vybraná
                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.accentColor)
                                .background(
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 18, height: 18)
                                )
                                .padding(6)
                        }
                        Spacer()
                    }
                }

                // CMYK badge – pravý dolní roh pro barevné stránky
                if isColorPage {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            CMYKBadge(size: max(14, size * 0.16))
                                .padding(5)
                        }
                    }
                }

                // Indikátor draggingu
                if isDragging {
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .background(Color.accentColor.opacity(0.1))
                }
            }
            .frame(width: size, height: size * 1.4)

            Text("\(pageIndex + 1)")
                .font(DS.Typography.caption2)
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .fontWeight(isSelected ? .semibold : .regular)
        }
        .help("Klik = výběr, Cmd+klik = toggle, Shift+klik = rozsah, Drag = přesun, Poklepání = zobrazení")
    }
}

// MARK: - CMYK Badge

private struct CMYKBadge: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    stops: [
                        .init(color: Color(red: 0, green: 0.8, blue: 0.8),   location: 0.00),  // Cyan
                        .init(color: Color(red: 0.9, green: 0, blue: 0.6),   location: 0.25),  // Magenta
                        .init(color: Color(red: 1.0, green: 0.9, blue: 0),   location: 0.50),  // Yellow
                        .init(color: Color(red: 0.1, green: 0.1, blue: 0.1), location: 0.75),  // Key (Black)
                        .init(color: Color(red: 0, green: 0.8, blue: 0.8),   location: 1.00),  // Cyan (wrap)
                    ],
                    center: .center
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: size * 0.1)
            )
            .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
    }
}

// MARK: - Single Page Preview

private struct SinglePagePreview: View {
    let file: FileItem
    let currentPage: Int
    @State private var image: NSImage? = nil
    @State private var isLoading = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
            } else if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
                    .contextMenu {
                        PreviewContextMenu(file: file, image: img)
                    }
            } else {
                VStack(spacing: DS.Spacing.small) {
                    Image(systemName: file.fileType.icon)
                        .font(DS.Typography.largeIcon)
                        .foregroundColor(.secondary)
                    Text("Náhled nedostupný")
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: currentPage) { _ in load() }
        .onChange(of: file.id) { _ in load() }
    }

    private func load() {
        isLoading = true
        image = nil
        let url = file.url
        let ft = file.fileType
        let page = currentPage

        Task {
            let cgImageData = await generatePreviewCGImage(url: url, fileType: ft, page: page)
            await MainActor.run {
                if let (cgImage, size) = cgImageData {
                    self.image = NSImage(cgImage: cgImage, size: size)
                } else {
                    self.image = nil
                }
                self.isLoading = false
            }
        }
    }

    private func generatePreviewCGImage(url: URL, fileType: FileType, page: Int) async -> (CGImage, NSSize)? {
        if fileType == .pdf {
            guard let doc = PDFDocument(url: url),
                  let pdfPage = doc.page(at: page) else { return nil }
            let thumbSize = CGSize(width: 2400, height: 3200)
            let nsImage = pdfPage.thumbnail(of: thumbSize, for: .mediaBox)
            var rect = NSRect.zero
            guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  cgImage.width > 0, cgImage.height > 0 else { return nil }
            let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            return (cgImage, size)
        } else if fileType.isImage {
            return loadImageWithOrientationCG(url: url)
        }
        return nil
    }

    private func loadImageWithOrientationCG(url: URL) -> (CGImage, NSSize)? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            // Fallback: try to load NSImage and extract CGImage
            guard let nsImage = NSImage(contentsOf: url) else { return nil }
            var rect = NSRect.zero
            guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return (cg, NSSize(width: cg.width, height: cg.height))
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let tiffProperties = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var orientation: Int32 = 1
        if let tiffOrient = tiffProperties?[kCGImagePropertyTIFFOrientation] as? Int32 {
            orientation = tiffOrient
        }

        if orientation > 1 {
            if let orientedImage = applyOrientation(cgImage: cgImage, orientation: Int(orientation)) {
                return (orientedImage, NSSize(width: orientedImage.width, height: orientedImage.height))
            }
        }

        return (cgImage, NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func applyOrientation(cgImage: CGImage, orientation: Int) -> CGImage? {
        var transform = CGAffineTransform.identity

        switch orientation {
        case 2: transform = transform.translatedBy(x: CGFloat(cgImage.width), y: 0).scaledBy(x: -1, y: 1)
        case 3: transform = transform.translatedBy(x: CGFloat(cgImage.width), y: CGFloat(cgImage.height)).rotated(by: .pi)
        case 4: transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.height)).scaledBy(x: 1, y: -1)
        case 5: transform = transform.translatedBy(x: CGFloat(cgImage.height), y: 0).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 6: transform = transform.translatedBy(x: CGFloat(cgImage.height), y: 0).rotated(by: .pi / 2)
        case 7: transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.width)).rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        case 8: transform = transform.translatedBy(x: 0, y: CGFloat(cgImage.width)).rotated(by: -.pi / 2)
        default: return cgImage
        }

        let width = orientation >= 5 && orientation <= 8 ? cgImage.height : cgImage.width
        let height = orientation >= 5 && orientation <= 8 ? cgImage.width : cgImage.height

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0,
                                   space: colorSpace, bitmapInfo: cgImage.bitmapInfo.rawValue) else {
            return nil
        }

        ctx.concatenate(transform)
        let drawRect = orientation >= 5 && orientation <= 8
            ? CGRect(x: 0, y: 0, width: cgImage.height, height: cgImage.width)
            : CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        ctx.draw(cgImage, in: drawRect)

        return ctx.makeImage()
    }
}
