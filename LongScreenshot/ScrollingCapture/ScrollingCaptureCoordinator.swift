//
//  ScrollingCaptureCoordinator.swift
//  LongScreenshot
//

import AppKit
import Observation

@MainActor
@Observable
final class ScrollingCaptureCoordinator {
    let store: ScrollingCaptureStore
    let shortcutManager: ScrollingCaptureShortcutManager
    private(set) var saveFolderURL: URL?
    private(set) var saveFolderMessage: String?
    private let overlayController: any ScrollingCaptureOverlayControlling
    private let imageExporter: ScrollingCaptureImageExporter
    private let saveFolderPreferences: ScrollingCaptureSaveFolderPreferences
    private let saveFolderChooser: (URL?) -> URL?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var settledCaptureTask: Task<Void, Never>?
    private let clothesLinePreferences: ClothesLinePreferences
    private let clothesLine: () -> any ClothesLineHanging
    /// Where the capture in progress sits on screen, so the saved image can
    /// fly from there to the clothesline.
    private var activeCaptureRect: CGRect?

    /// Hang each saved capture on the clothesline along the top of the screen.
    var hangsOnClothesLine: Bool {
        didSet {
            clothesLinePreferences.isEnabled = hangsOnClothesLine
            if !hangsOnClothesLine {
                clothesLine().takeEverythingDown()
            }
        }
    }

    private(set) var completedCaptureCount = 0

    init(
        store: ScrollingCaptureStore? = nil,
        shortcutManager: ScrollingCaptureShortcutManager? = nil,
        overlayController: (any ScrollingCaptureOverlayControlling)? = nil,
        saveFolderPreferences: ScrollingCaptureSaveFolderPreferences? = nil,
        imageExporter: ScrollingCaptureImageExporter? = nil,
        saveFolderChooser: ((URL?) -> URL?)? = nil,
        clothesLinePreferences: ClothesLinePreferences = ClothesLinePreferences(),
        clothesLine: (() -> any ClothesLineHanging)? = nil
    ) {
        self.store = store ?? ScrollingCaptureStore(
            captureService: ScreenRegionCaptureService()
        )
        let resolvedShortcutManager = shortcutManager ?? ScrollingCaptureShortcutManager()
        self.shortcutManager = resolvedShortcutManager
        self.overlayController = overlayController ?? ScrollingCaptureOverlayController()
        self.saveFolderChooser = saveFolderChooser ?? Self.presentSaveFolderPanel
        let resolvedSaveFolderPreferences = saveFolderPreferences ?? ScrollingCaptureSaveFolderPreferences()
        self.saveFolderPreferences = resolvedSaveFolderPreferences
        saveFolderURL = try? resolvedSaveFolderPreferences.authorizedFolder()
        self.imageExporter = imageExporter ?? ScrollingCaptureImageExporter(
            saveFolderPreferences: resolvedSaveFolderPreferences
        )
        self.clothesLinePreferences = clothesLinePreferences
        // Resolved lazily: the clothesline puts a window on screen, which only
        // happens once a capture actually hangs.
        self.clothesLine = clothesLine ?? { ClothesLineController.shared }
        hangsOnClothesLine = clothesLinePreferences.isEnabled
        self.store.onProgressChanged = { [weak self] guidance, frameCount, height in
            self?.overlayController.updateCaptureGuidance(
                guidance,
                frameCount: frameCount,
                capturedHeight: height
            )
        }
        self.store.onPreviewChanged = { [weak self] image in
            self?.overlayController.updateCapturePreview(image)
        }
        self.store.onMaximumHeightReached = { [weak self] snapshot in
            self?.stopManualScrollMonitoring()
            self?.exportMaximumHeightCapture(snapshot)
        }
        resolvedShortcutManager.onShortcutPressed = { [weak self] in
            self?.startSelection()
        }
    }

    func startSelection() {
        guard store.phase != .capturing, store.phase != .processing else {
            return
        }

        store.cancelCapture()
        overlayController.presentSelection { [weak self] selection in
            guard let self, let selection else {
                return
            }
            self.activeCaptureRect = ScrollingCaptureOverlayController.screenRect(for: selection)
            Task { @MainActor in
                do {
                    try await self.store.beginCapture(selection: selection)
                    guard self.store.phase == .capturing else {
                        return
                    }
                    self.overlayController.presentCaptureGuidance(
                        for: selection,
                        guidance: self.store.captureGuidance,
                        frameCount: self.store.capturedFrameCount,
                        capturedHeight: self.store.capturedHeight
                    )
                    self.overlayController.presentCaptureControls(
                        onDone: { [weak self] in
                            self?.finishCapture()
                        },
                        onCancel: { [weak self] in
                            self?.cancelCapture()
                        }
                    )
                    self.startManualScrollMonitoring()
                } catch {
                    // The store exposes the localized error in its message.
                }
            }
        }
    }

    func finishCapture() {
        stopManualScrollMonitoring()
        store.finishCapture { [weak self] snapshot in
            guard let self, let snapshot else {
                return
            }
            self.export(snapshot)
        }
    }

    func cancelCapture() {
        stopManualScrollMonitoring()
        overlayController.dismissAll()
        store.cancelCapture()
    }

    private func startManualScrollMonitoring() {
        stopManualScrollMonitoring()
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.recordScrollActivity()
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.recordScrollActivity()
            return event
        }
    }

    private func stopManualScrollMonitoring() {
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        settledCaptureTask?.cancel()
        settledCaptureTask = nil
    }

    private func recordScrollActivity() {
        store.captureAfterScrollActivity()
        settledCaptureTask?.cancel()
        settledCaptureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            self?.store.captureAfterScrollActivity()
        }
    }

    func chooseSaveFolder() {
        _ = requestSaveFolderAuthorization()
    }

    var saveFolderDisplayName: String {
        saveFolderURL?.path ?? String(localized: "Not selected")
    }

    private func ensureSaveFolderAuthorization() -> Bool {
        if saveFolderURL != nil {
            return true
        }
        return requestSaveFolderAuthorization()
    }

    private static func presentSaveFolderPanel(startingAt currentFolder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentFolder
        panel.message = String(localized: "Choose where Long Screenshot saves scrolling screenshots.")
        panel.prompt = String(localized: "Allow Save Access")

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }

    private func requestSaveFolderAuthorization() -> Bool {
        guard let folder = saveFolderChooser(saveFolderURL) else {
            return false
        }

        do {
            try saveFolderPreferences.save(folder: folder)
            saveFolderURL = folder
            saveFolderMessage = nil
            return true
        } catch {
            saveFolderMessage = String(localized: "Could not authorize the selected save folder: \(error.localizedDescription)")
            return false
        }
    }

    private func exportMaximumHeightCapture(_ snapshot: ScrollingCaptureArtifact) {
        overlayController.dismissAll()
        export(snapshot, isPartial: true)
    }

    private func export(
        _ snapshot: ScrollingCaptureArtifact,
        isPartial: Bool = false
    ) {
        guard ensureSaveFolderAuthorization() else {
            // Without a destination nothing will ever read these tiles again, so
            // release the disk they occupy instead of stranding them in /tmp.
            snapshot.removeTemporaryFiles()
            store.completeExport(message: String(localized: "Scrolling screenshot was not saved because no save folder was selected."))
            overlayController.dismissAll()
            return
        }
        let imageExporter = imageExporter

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try imageExporter.save(artifact: snapshot) }
            DispatchQueue.main.async {
                self?.finishExport(result, isPartial: isPartial)
            }
        }
    }

    private func finishExport(_ result: Result<URL, Error>, isPartial: Bool) {
        switch result {
        case .success(let url):
            completedCaptureCount += 1
            if hangsOnClothesLine, let saveFolderURL {
                clothesLine().hang(url, scope: saveFolderURL, from: activeCaptureRect)
            }
            // Whole sentences rather than a prefix plus a path: word order
            // differs between languages, so the path has to sit inside the
            // translation instead of being glued onto the end of it.
            let folder = url.deletingLastPathComponent().path
            let file = url.lastPathComponent
            store.completeExport(
                message: isPartial
                    ? String(localized: "Saved the partial scrolling capture at its maximum height to \(folder): \(file)")
                    : String(localized: "Saved scrolling capture to \(folder): \(file)")
            )
        case .failure(let error):
            store.completeExport(message: String(localized: "Could not save scrolling capture: \(error.localizedDescription)"))
        }
        activeCaptureRect = nil
        overlayController.dismissAll()
        NSApp.activate(ignoringOtherApps: true)
    }
}
