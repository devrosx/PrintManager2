//
//  DrawingsDialogViewModel.swift
//  PrintManager
//
//  View model for DrawingsDialog - handles state and business logic
//

import Foundation
import SwiftUI
import AppKit

/// View model managing state and operations for the drawings processing dialog
@MainActor
class DrawingsDialogViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var settings = DrawingsSettings()
    @Published var activeFileID: UUID? = nil
    @Published var previewImage: NSImage? = nil
    @Published var imageNaturalSize: CGSize = .zero
    @Published var isLoadingPreview = false
    @Published var isProcessing = false

    // Deskew state
    @Published var detectedAngle: Double? = nil
    @Published var isDetectingAngle = false

    // Crop state
    @Published var detectedCropRect: CGRect? = nil
    @Published var isDetectingCrop = false

    // OCR state
    @Published var ocrText = ""
    @Published var isOCRRunning = false

    // Drawing state
    @Published var previewMode: PreviewMode = .none
    @Published var dragStart: CGPoint? = nil
    @Published var dragCurrent: CGPoint? = nil

    // Interactive crop state
    @Published var cropDragMode: CropDragMode = .none
    var dragAnchorMargins: (top: Double, bottom: Double, left: Double, right: Double) = (0, 0, 0, 0)
    var dragStartPoint: CGPoint = .zero

    // MARK: - Private Properties

    private let service = DrawingsService()
    private var previewTask: Task<Void, Never>? = nil
    private var deskewTask: Task<Void, Never>? = nil

    // MARK: - Computed Properties

    func selectedFiles(from appState: AppState) -> [FileItem] {
        appState.files.filter { appState.selectedFiles.contains($0.id) }
    }

    func activeFile(from appState: AppState) -> FileItem? {
        let files = selectedFiles(from: appState)
        guard let id = activeFileID else { return files.first }
        return files.first { $0.id == id } ?? files.first
    }

    // MARK: - Initialization

    func initialize(with appState: AppState) {
        activeFileID = selectedFiles(from: appState).first?.id
        schedulePreviewUpdate(appState: appState)
    }

    // MARK: - Preview Management

    func schedulePreviewUpdate(appState: AppState) {
        previewTask?.cancel()

        guard let file = activeFile(from: appState) else {
            isLoadingPreview = false
            previewImage = nil
            return
        }

        isLoadingPreview = true
        previewTask = Task {
            do {
                try await Task.sleep(nanoseconds: RenderingConstants.Timing.previewDebounce)
                guard !Task.isCancelled else {
                    isLoadingPreview = false
                    return
                }

                let img = try await service.previewImage(
                    url: file.url,
                    settings: settings,
                    maxSize: RenderingConstants.PreviewSize.standardPreview
                )

                if !Task.isCancelled {
                    previewImage = img
                    isLoadingPreview = false
                }
            } catch is CancellationError {
                isLoadingPreview = false
            } catch {
                previewImage = nil
                isLoadingPreview = false
            }
        }
    }

    func onFileChanged(appState: AppState) {
        detectedAngle = nil
        detectedCropRect = nil
        ocrText = ""
        schedulePreviewUpdate(appState: appState)

        if settings.applyDeskew {
            startAngleDetection(appState: appState)
        }

        if settings.applyCrop && settings.cropMode == .autoDetect {
            startAutoCropDetection(appState: appState)
        }
    }

    // MARK: - Deskew Detection

    func startAngleDetection(appState: AppState) {
        deskewTask?.cancel()

        guard let file = activeFile(from: appState) else { return }

        detectedAngle = nil
        isDetectingAngle = true

        deskewTask = Task {
            defer { isDetectingAngle = false }

            guard !Task.isCancelled,
                  let cgImage = await ImageLoadingService.loadCGImage(from: file.url, respectOrientation: false) else {
                detectedAngle = 0.0
                return
            }

            let angle = (try? await service.detectDeskewAngle(cgImage: cgImage)) ?? 0.0

            if !Task.isCancelled {
                detectedAngle = angle
            }
        }
    }

    func stopAngleDetection() {
        deskewTask?.cancel()
        detectedAngle = nil
        isDetectingAngle = false
    }

    // MARK: - Auto-Crop Detection

    func startAutoCropDetection(appState: AppState) {
        guard let file = activeFile(from: appState) else { return }

        detectedCropRect = nil
        isDetectingCrop = true

        Task {
            guard let cgImage = await ImageLoadingService.loadCGImage(from: file.url, respectOrientation: false) else {
                isDetectingCrop = false
                return
            }

            let rect = await service.detectDocumentRect(cgImage: cgImage)
            detectedCropRect = rect
            isDetectingCrop = false
        }
    }

    // MARK: - OCR

    func runOCR(appState: AppState) {
        guard let file = activeFile(from: appState) else { return }

        isOCRRunning = true
        ocrText = ""

        Task {
            do {
                guard let cgImage = await ImageLoadingService.loadCGImage(from: file.url, respectOrientation: false) else {
                    isOCRRunning = false
                    return
                }

                let roi: CGRect? = settings.ocrUseCustomRegion
                    ? CGRect(
                        x: settings.ocrRegionLeft,
                        y: settings.ocrRegionTop,
                        width: settings.ocrRegionWidth,
                        height: settings.ocrRegionHeight
                      )
                    : nil

                let text = try await service.ocrBottomRight(cgImage: cgImage, regionOfInterest: roi)
                ocrText = text
                isOCRRunning = false
            } catch {
                isOCRRunning = false
                appState.logError("OCR selhalo: \(error.localizedDescription)")
            }
        }
    }

    func renameActiveFile(appState: AppState) {
        guard let file = activeFile(from: appState) else { return }

        let name = ocrText
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") ?? ""

        guard !name.isEmpty else { return }

        appState.renameFile(file, to: name)
        appState.logSuccess("Přejmenováno: \(name)")
    }

    // MARK: - Drag Handling

    func commitDrag(start: CGPoint?, end: CGPoint, imgFrame: CGRect) {
        guard let s = start else { return }

        // Normalize to image coordinates (0-1), clamp to image bounds
        func norm(_ v: CGFloat, origin: CGFloat, size: CGFloat) -> Double {
            Double(Swift.max(0, Swift.min(1, (v - origin) / size)))
        }

        let nx1 = norm(Swift.min(s.x, end.x), origin: imgFrame.minX, size: imgFrame.width)
        let nx2 = norm(Swift.max(s.x, end.x), origin: imgFrame.minX, size: imgFrame.width)
        let ny1 = norm(Swift.min(s.y, end.y), origin: imgFrame.minY, size: imgFrame.height)
        let ny2 = norm(Swift.max(s.y, end.y), origin: imgFrame.minY, size: imgFrame.height)

        // Require minimum size
        guard nx2 - nx1 > 0.02, ny2 - ny1 > 0.02 else {
            previewMode = .none
            return
        }

        switch previewMode {
        case .ocrDraw:
            settings.ocrRegionLeft    = nx1
            settings.ocrRegionTop     = ny1
            settings.ocrRegionWidth   = nx2 - nx1
            settings.ocrRegionHeight  = ny2 - ny1
            settings.ocrUseCustomRegion = true
            previewMode = .none

        default:
            break
        }
    }

    // MARK: - Interactive Crop Handling

    /// Determine what the user clicked on: handle, inside crop, or outside
    func handleCropDragStart(at point: CGPoint, imgFrame: CGRect) {
        let cropRect = currentCropRect(in: imgFrame)
        let handleSize: CGFloat = 12

        // 8 handle points: corners + edge midpoints
        let handles: [(CGPoint, CropDragMode)] = [
            (CGPoint(x: cropRect.minX, y: cropRect.minY), .resizeTopLeft),
            (CGPoint(x: cropRect.midX, y: cropRect.minY), .resizeTop),
            (CGPoint(x: cropRect.maxX, y: cropRect.minY), .resizeTopRight),
            (CGPoint(x: cropRect.maxX, y: cropRect.midY), .resizeRight),
            (CGPoint(x: cropRect.maxX, y: cropRect.maxY), .resizeBottomRight),
            (CGPoint(x: cropRect.midX, y: cropRect.maxY), .resizeBottom),
            (CGPoint(x: cropRect.minX, y: cropRect.maxY), .resizeBottomLeft),
            (CGPoint(x: cropRect.minX, y: cropRect.midY), .resizeLeft),
        ]

        for (hp, mode) in handles {
            if abs(point.x - hp.x) <= handleSize && abs(point.y - hp.y) <= handleSize {
                cropDragMode = mode
                dragStartPoint = point
                dragAnchorMargins = (settings.cropTopMargin, settings.cropBottomMargin,
                                     settings.cropLeftMargin, settings.cropRightMargin)
                return
            }
        }

        if cropRect.contains(point) {
            cropDragMode = .move
            dragStartPoint = point
            dragAnchorMargins = (settings.cropTopMargin, settings.cropBottomMargin,
                                 settings.cropLeftMargin, settings.cropRightMargin)
        } else {
            cropDragMode = .drawNew
            dragStart = point
            dragCurrent = point
        }
    }

    /// Update margins based on drag mode and current position
    func handleCropDragChanged(to point: CGPoint, imgFrame: CGRect) {
        guard imgFrame.width > 0, imgFrame.height > 0 else { return }

        if cropDragMode == .drawNew {
            dragCurrent = point
            return
        }

        let dx = (point.x - dragStartPoint.x) / imgFrame.width
        let dy = (point.y - dragStartPoint.y) / imgFrame.height
        let anchor = dragAnchorMargins

        let clamp: (Double) -> Double = { max(0, min(0.49, $0)) }

        switch cropDragMode {
        case .resizeTopLeft:
            settings.cropLeftMargin = clamp(anchor.left + dx)
            settings.cropTopMargin  = clamp(anchor.top + dy)
        case .resizeTop:
            settings.cropTopMargin = clamp(anchor.top + dy)
        case .resizeTopRight:
            settings.cropRightMargin = clamp(anchor.right - dx)
            settings.cropTopMargin   = clamp(anchor.top + dy)
        case .resizeRight:
            settings.cropRightMargin = clamp(anchor.right - dx)
        case .resizeBottomRight:
            settings.cropRightMargin  = clamp(anchor.right - dx)
            settings.cropBottomMargin = clamp(anchor.bottom - dy)
        case .resizeBottom:
            settings.cropBottomMargin = clamp(anchor.bottom - dy)
        case .resizeBottomLeft:
            settings.cropLeftMargin   = clamp(anchor.left + dx)
            settings.cropBottomMargin = clamp(anchor.bottom - dy)
        case .resizeLeft:
            settings.cropLeftMargin = clamp(anchor.left + dx)
        case .move:
            let newLeft   = anchor.left + dx
            let newRight  = anchor.right - dx
            let newTop    = anchor.top + dy
            let newBottom = anchor.bottom - dy
            // Only apply if within bounds
            if newLeft >= 0, newRight >= 0, newLeft + newRight < 1 {
                settings.cropLeftMargin  = newLeft
                settings.cropRightMargin = newRight
            }
            if newTop >= 0, newBottom >= 0, newTop + newBottom < 1 {
                settings.cropTopMargin    = newTop
                settings.cropBottomMargin = newBottom
            }
        default:
            break
        }
    }

    /// Finish the drag interaction
    func handleCropDragEnded(at point: CGPoint, imgFrame: CGRect) {
        if cropDragMode == .drawNew, let s = dragStart {
            // Normalize to image coordinates (0-1)
            func norm(_ v: CGFloat, origin: CGFloat, size: CGFloat) -> Double {
                Double(Swift.max(0, Swift.min(1, (v - origin) / size)))
            }
            let nx1 = norm(Swift.min(s.x, point.x), origin: imgFrame.minX, size: imgFrame.width)
            let nx2 = norm(Swift.max(s.x, point.x), origin: imgFrame.minX, size: imgFrame.width)
            let ny1 = norm(Swift.min(s.y, point.y), origin: imgFrame.minY, size: imgFrame.height)
            let ny2 = norm(Swift.max(s.y, point.y), origin: imgFrame.minY, size: imgFrame.height)

            if nx2 - nx1 > 0.02, ny2 - ny1 > 0.02 {
                settings.cropLeftMargin   = nx1
                settings.cropTopMargin    = ny1
                settings.cropRightMargin  = 1 - nx2
                settings.cropBottomMargin = 1 - ny2
            }
            dragStart = nil
            dragCurrent = nil
        }
        cropDragMode = .none
    }

    /// Hit-test to determine cursor style for a given point
    func cropCursorMode(at point: CGPoint, imgFrame: CGRect) -> CropDragMode {
        let cropRect = currentCropRect(in: imgFrame)
        let handleSize: CGFloat = 12

        let handles: [(CGPoint, CropDragMode)] = [
            (CGPoint(x: cropRect.minX, y: cropRect.minY), .resizeTopLeft),
            (CGPoint(x: cropRect.midX, y: cropRect.minY), .resizeTop),
            (CGPoint(x: cropRect.maxX, y: cropRect.minY), .resizeTopRight),
            (CGPoint(x: cropRect.maxX, y: cropRect.midY), .resizeRight),
            (CGPoint(x: cropRect.maxX, y: cropRect.maxY), .resizeBottomRight),
            (CGPoint(x: cropRect.midX, y: cropRect.maxY), .resizeBottom),
            (CGPoint(x: cropRect.minX, y: cropRect.maxY), .resizeBottomLeft),
            (CGPoint(x: cropRect.minX, y: cropRect.midY), .resizeLeft),
        ]

        for (hp, mode) in handles {
            if abs(point.x - hp.x) <= handleSize && abs(point.y - hp.y) <= handleSize {
                return mode
            }
        }

        if cropRect.contains(point) {
            return .move
        }

        return .drawNew
    }

    /// Compute the current crop rectangle in view coordinates
    func currentCropRect(in imgFrame: CGRect) -> CGRect {
        CGRect(
            x: imgFrame.minX + settings.cropLeftMargin * imgFrame.width,
            y: imgFrame.minY + settings.cropTopMargin * imgFrame.height,
            width:  imgFrame.width  * (1 - settings.cropLeftMargin - settings.cropRightMargin),
            height: imgFrame.height * (1 - settings.cropTopMargin  - settings.cropBottomMargin)
        )
    }

    /// Whether interactive crop mode is active
    var isInteractiveCropActive: Bool {
        settings.applyCrop && settings.cropMode == .manualMargins
    }

    // MARK: - Batch Processing

    func processAll(appState: AppState, onComplete: @escaping () -> Void) {
        let files = selectedFiles(from: appState)
        guard !files.isEmpty else { return }

        isProcessing = true
        appState.logInfo("Začínám zpracování \(files.count) výkres(ů)…")

        Task {
            for (i, file) in files.enumerated() {
                appState.logInfo("Výkres \(i+1)/\(files.count): \(file.name)")

                do {
                    try await service.process(url: file.url, settings: settings)

                    // Update file content version to trigger preview reload
                    if let idx = appState.files.firstIndex(where: { $0.id == file.id }) {
                        appState.files[idx].contentVersion += 1
                    }
                } catch {
                    appState.logError("Chyba (\(file.name)): \(error.localizedDescription)")
                }
            }

            isProcessing = false
            appState.logSuccess("Zpracování výkresů dokončeno")
            onComplete()
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        previewTask?.cancel()
        deskewTask?.cancel()
    }
}

// MARK: - Preview Mode Enum

/// Interaction mode for the preview panel
enum PreviewMode: Equatable {
    case none        // View only
    case ocrDraw     // Drawing OCR region
}

/// Drag mode for interactive crop tool
enum CropDragMode {
    case none
    case move
    case resizeTopLeft, resizeTop, resizeTopRight
    case resizeRight
    case resizeBottomRight, resizeBottom, resizeBottomLeft
    case resizeLeft
    case drawNew
}
