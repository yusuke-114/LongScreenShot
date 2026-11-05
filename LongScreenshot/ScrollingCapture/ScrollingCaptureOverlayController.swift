//
//  ScrollingCaptureOverlayController.swift
//  LongScreenshot
//

import AppKit
import Carbon
import CoreGraphics

@MainActor
protocol ScrollingCaptureOverlayControlling: AnyObject {
    func presentSelection(completion: @escaping (ScrollingCaptureSelection?) -> Void)
    func presentCaptureControls(onDone: @escaping () -> Void, onCancel: @escaping () -> Void)
    func presentCaptureGuidance(
        for selection: ScrollingCaptureSelection,
        guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    )
    func updateCaptureGuidance(
        _ guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    )
    func updateCapturePreview(_ image: CGImage)
    func dismissAll()
}

@MainActor
final class ScrollingCaptureOverlayController: NSObject, ScrollingCaptureOverlayControlling {
    private var selectionPanels: [NSPanel] = []
    private var selectionActionPanel: NSPanel?
    private var captureControlsPanel: NSPanel?
    private var captureBorderPanel: NSPanel?
    private var captureGuidancePanel: NSPanel?
    private var captureGuidanceView: CapturePreviewView?
    private var processingIndicatorPanel: NSPanel?
    private var processingIndicatorCloseButton: NSButton?
    private var processingIndicatorRevealTask: DispatchWorkItem?
    private var activeCaptureRect: CGRect?
    private var activeCaptureScreen: NSScreen?
    private let hotKeyRegistrar: any GlobalHotKeyRegistering
    private var escapeRegistration: (any GlobalHotKeyRegistration)?
    private let dustOverlay = DustDissolveOverlay()
    private var pendingSelection: ScrollingCaptureSelection?
    private var selectionCompletion: ((ScrollingCaptureSelection?) -> Void)?
    private var doneAction: (() -> Void)?
    private var cancelAction: (() -> Void)?

    /// Esc is the one key every capture tool cancels on. None of these panels
    /// ever becomes key - they are borderless and non-activating so the app
    /// being captured keeps focus - so a plain `keyDown` never reaches us.
    /// Esc is held as a global hot key instead, and only while choosing the
    /// region: once the capture runs the user is working in the captured app,
    /// which needs its own Esc, and one stray press would throw the capture
    /// away. Cancel stays a button there.
    static let escapeShortcut = ScrollingCaptureShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    init(hotKeyRegistrar: (any GlobalHotKeyRegistering)? = nil) {
        self.hotKeyRegistrar = hotKeyRegistrar ?? CarbonGlobalHotKeyRegistrar.shared
        super.init()
    }

    func presentSelection(completion: @escaping (ScrollingCaptureSelection?) -> Void) {
        dismissAll()
        // `dismissAll` deliberately leaves a dissolve running - it fires while
        // the export is still going. Starting a new capture is the one moment
        // stale particles would sit on top of live UI, so clear them here.
        dustOverlay.cancel()
        selectionCompletion = completion

        for screen in NSScreen.screens {
            let panel = overlayPanel(frame: screen.frame)
            let overlay = SelectionOverlayView(frame: panel.contentView?.bounds ?? .zero)
            overlay.onSelection = { [weak self, weak screen] rect in
                guard let self, let screen else {
                    return
                }
                self.prepareSelection(rect, on: screen)
            }
            panel.contentView = overlay
            panel.orderFrontRegardless()
            selectionPanels.append(panel)
        }
        beginEscapeHandling { [weak self] in
            self?.completeSelection(nil)
        }
    }

    func presentCaptureControls(onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        dismissCaptureControls()
        doneAction = onDone
        cancelAction = onCancel

        let panel = makeCaptureControlsPanel()
        panel.setFrameOrigin(captureControlsOrigin(for: panel.frame.size))
        panel.orderFrontRegardless()
        captureControlsPanel = panel
    }

    func presentCaptureGuidance(
        for selection: ScrollingCaptureSelection,
        guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    ) {
        dismissCaptureGuidance()
        guard let selectionRect = Self.screenRect(for: selection),
              let screen = Self.screen(for: selection) else {
            return
        }
        activeCaptureRect = selectionRect
        activeCaptureScreen = screen

        // -4 rather than -2: the 3pt stroke starts at the panel's edge, so a 2pt
        // outset left one point of blue sitting inside the captured region. It
        // never showed while the panel was hidden from screen capture, but with
        // recording on it landed in every frame and stitched into a ladder.
        let border = overlayPanel(frame: selectionRect.insetBy(dx: -4, dy: -4))
        border.ignoresMouseEvents = true
        border.contentView = CaptureBorderView(frame: border.contentView?.bounds ?? .zero)
        border.orderFrontRegardless()
        captureBorderPanel = border

        let panel = overlayPanel(
            frame: CGRect(x: 0, y: 0, width: 200, height: 240)
        )
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let view = CapturePreviewView(frame: panel.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        view.updateProgress(guidance, frameCount: frameCount, capturedHeight: capturedHeight)
        panel.contentView = view
        panel.setFrameOrigin(guidanceOrigin(for: selectionRect, on: screen, size: panel.frame.size))
        panel.orderFrontRegardless()
        captureGuidancePanel = panel
        captureGuidanceView = view
    }

    func updateCaptureGuidance(
        _ guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    ) {
        captureGuidanceView?.updateProgress(
            guidance,
            frameCount: frameCount,
            capturedHeight: capturedHeight
        )
    }

    func updateCapturePreview(_ image: CGImage) {
        captureGuidanceView?.updatePreview(image)
    }

    func dismissAll() {
        selectionPanels.forEach { $0.orderOut(nil) }
        selectionPanels.removeAll()
        selectionActionPanel?.orderOut(nil)
        selectionActionPanel = nil
        endEscapeHandling()
        dismissCaptureControls()
        dismissCaptureGuidance()
        dismissProcessingIndicator()
        activeCaptureRect = nil
        activeCaptureScreen = nil
        pendingSelection = nil
        selectionCompletion = nil
    }

    private func prepareSelection(_ pointRect: CGRect, on screen: NSScreen) {
        let minimumVisionDimension = CGFloat(84)
        let minimumSelectionDimension = minimumVisionDimension / screen.backingScaleFactor
        guard pointRect.width >= minimumSelectionDimension,
              pointRect.height >= minimumSelectionDimension,
              let displayNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return
        }

        let sourceRect = CGRect(
            x: pointRect.minX,
            y: screen.frame.height - pointRect.maxY,
            width: pointRect.width,
            height: pointRect.height
        ).integral
        pendingSelection = ScrollingCaptureSelection(
            displayID: CGDirectDisplayID(displayNumber.uint32Value),
            sourceRect: sourceRect,
            backingScale: screen.backingScaleFactor
        )

        selectionActionPanel?.orderOut(nil)
        let panel = makeSelectionConfirmationPanel()
        panel.setFrameOrigin(
            selectionConfirmationOrigin(for: pointRect, on: screen, size: panel.frame.size)
        )
        panel.orderFrontRegardless()
        selectionActionPanel = panel
    }

    @objc private func startCapture() {
        completeSelection(pendingSelection)
    }

    @objc private func cancelSelection() {
        completeSelection(nil)
    }

    @objc private func finishCapture() {
        dismissCaptureControls()
        dissolveCaptureGuidance()
        presentProcessingIndicator()
        doneAction?()
        doneAction = nil
        cancelAction = nil
    }

    @objc private func cancelCapture() {
        dismissCaptureControls()
        cancelAction?()
        doneAction = nil
        cancelAction = nil
    }

    private func completeSelection(_ selection: ScrollingCaptureSelection?) {
        // Dropped even when a capture follows: starting it can fail, and a
        // leftover registration would keep eating Esc system-wide.
        endEscapeHandling()
        selectionPanels.forEach { $0.orderOut(nil) }
        selectionPanels.removeAll()
        selectionActionPanel?.orderOut(nil)
        selectionActionPanel = nil
        pendingSelection = nil

        let completion = selectionCompletion
        selectionCompletion = nil
        completion?(selection)
    }

    private func dismissCaptureControls() {
        captureControlsPanel?.orderOut(nil)
        captureControlsPanel = nil
    }

    private func beginEscapeHandling(_ action: @escaping () -> Void) {
        endEscapeHandling()
        // If another app already holds bare Esc, the buttons still work.
        escapeRegistration = try? hotKeyRegistrar.register(Self.escapeShortcut, onPress: action)
    }

    private func endEscapeHandling() {
        escapeRegistration?.invalidate()
        escapeRegistration = nil
    }

    /// Hands the capture chrome to the particle layer so it crumbles instead of
    /// blinking out. The dissolve runs alongside the export, which is why it is
    /// fire-and-forget: `DustDissolveOverlay` owns its own lifetime and
    /// `dismissAll` must not be able to cut it short.
    ///
    /// Only the self-drawn chrome takes part. The Done and Cancel controls are
    /// `NSGlassEffectView`s whose backdrop the window server composites, so an
    /// offscreen redraw of them would come back without the glass.
    private func dissolveCaptureGuidance() {
        guard let activeCaptureScreen else {
            dismissCaptureGuidance()
            return
        }

        var requests: [DustDissolveRequest] = []
        if let border = captureBorderPanel?.contentView {
            requests.append(
                DustDissolveRequest(
                    view: border,
                    slices: DustGeometry.borderStrips(in: border.bounds.size)
                )
            )
        }
        if let captureGuidanceView {
            requests.append(DustDissolveRequest(view: captureGuidanceView))
        }

        dustOverlay.dissolve(requests, on: activeCaptureScreen) { [weak self] in
            self?.dismissCaptureGuidance()
        }
    }

    private func dismissCaptureGuidance() {
        dismissCaptureBorder()
        dismissCapturePreview()
    }

    private func dismissCaptureBorder() {
        captureBorderPanel?.orderOut(nil)
        captureBorderPanel = nil
    }

    private func dismissCapturePreview() {
        captureGuidancePanel?.orderOut(nil)
        captureGuidancePanel = nil
        captureGuidanceView = nil
    }

    private func presentProcessingIndicator() {
        dismissProcessingIndicator()

        let label = NSTextField(labelWithString: String(localized: "Creating scrolling screenshot…"))
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        // Spinner, spacing and label sit centred between two 36pt gutters - the
        // close button lives in the leading one, the trailing one balances it.
        let contentWidth = 16 + 8 + ceil(label.intrinsicContentSize.width)
        let size = CGSize(width: max(320, contentWidth + 72), height: 56)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.sharingType = OverlayRecordingMode.panelSharingType
        panel.ignoresMouseEvents = false

        panel.contentView = makeProcessingTip(size: size, label: label)
        panel.setFrame(
            ScrollingCaptureProcessingTipLayout.panelFrame(
                size: size,
                in: activeCaptureScreen?.frame ?? NSScreen.main?.frame ?? .zero
            ),
            display: true
        )
        panel.orderFrontRegardless()
        processingIndicatorPanel = panel

        let presentedAt = Date()
        let revealTask = DispatchWorkItem { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.processingIndicatorPanel === panel,
                  ScrollingCaptureProcessingTipLayout.shouldShowCloseButton(
                    after: Date().timeIntervalSince(presentedAt)
                  ) else {
                return
            }
            self.processingIndicatorCloseButton?.isHidden = false
        }
        processingIndicatorRevealTask = revealTask
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ScrollingCaptureProcessingTipLayout.closeButtonDelay,
            execute: revealTask
        )
    }

    @objc private func dismissProcessingIndicator() {
        processingIndicatorRevealTask?.cancel()
        processingIndicatorRevealTask = nil
        processingIndicatorPanel?.orderOut(nil)
        processingIndicatorPanel = nil
        processingIndicatorCloseButton = nil
    }

    private func makeProcessingTip(size: CGSize, label: NSTextField) -> NSGlassEffectView {
        let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.style = .regular

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        let content = NSStackView(views: [indicator, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Hide progress")) ?? NSImage(),
            target: self,
            action: #selector(dismissProcessingIndicator)
        )
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.isHidden = true
        close.toolTip = String(localized: "Hide progress")

        let container = NSView()
        [content, close].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            close.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16)
        ])
        glass.contentView = container
        processingIndicatorCloseButton = close
        return glass
    }

    private func overlayPanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.sharingType = OverlayRecordingMode.panelSharingType
        // No appear/disappear animation. These panels are swapped for their own
        // particle copies, and a fade or a scale on either side of that swap
        // shows both at once instead of neither.
        panel.animationBehavior = .none
        return panel
    }

    private func makeSelectionConfirmationPanel() -> NSPanel {
        let startTitle = String(localized: "Start")
        let cancelTitle = String(localized: "Cancel")
        let buttonWidth = Self.glassButtonWidth(fitting: [startTitle, cancelTitle])
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: buttonWidth, height: 84),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.sharingType = OverlayRecordingMode.panelSharingType

        let start = makeGlassTextControl(
            title: startTitle,
            action: #selector(startCapture),
            size: CGSize(width: buttonWidth, height: 32)
        )
        let cancel = makeGlassTextControl(
            title: cancelTitle,
            action: #selector(cancelSelection),
            size: CGSize(width: buttonWidth, height: 32)
        )
        let container = NSView()
        [start, cancel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        container.addSubview(start)
        container.addSubview(cancel)
        NSLayoutConstraint.activate([
            start.topAnchor.constraint(equalTo: container.topAnchor),
            start.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            start.widthAnchor.constraint(equalToConstant: buttonWidth),
            start.heightAnchor.constraint(equalToConstant: 32),
            cancel.topAnchor.constraint(equalTo: start.bottomAnchor, constant: 20),
            cancel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            cancel.widthAnchor.constraint(equalToConstant: buttonWidth),
            cancel.heightAnchor.constraint(equalToConstant: 32),
            cancel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        return panel
    }

    private func makeCaptureControlsPanel() -> NSPanel {
        let cancelTitle = String(localized: "Cancel")
        let doneTitle = String(localized: "Done")
        // One width for both, so the pair stays symmetric when only one of the
        // translations runs long.
        let buttonWidth = Self.glassButtonWidth(fitting: [cancelTitle, doneTitle])
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: buttonWidth * 2 + 8, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.sharingType = OverlayRecordingMode.panelSharingType

        let cancel = makeGlassTextControl(
            title: cancelTitle,
            action: #selector(cancelCapture),
            size: CGSize(width: buttonWidth, height: 32)
        )
        let done = makeGlassTextControl(
            title: doneTitle,
            action: #selector(finishCapture),
            size: CGSize(width: buttonWidth, height: 32)
        )
        let container = NSView()
        [cancel, done].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        container.addSubview(cancel)
        container.addSubview(done)
        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cancel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: buttonWidth),
            cancel.heightAnchor.constraint(equalToConstant: 32),
            done.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            done.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            done.widthAnchor.constraint(equalToConstant: buttonWidth),
            done.heightAnchor.constraint(equalToConstant: 32)
        ])
        panel.contentView = container
        return panel
    }

    private static let glassTextControlFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    private static func glassButtonWidth(fitting titles: [String]) -> CGFloat {
        ScrollingCaptureChromeLayout.buttonWidth(
            fittingTitleWidths: titles.map {
                ($0 as NSString).size(withAttributes: [.font: glassTextControlFont]).width
            }
        )
    }

    private func makeGlassTextControl(
        title: String,
        action: Selector,
        size: CGSize = CGSize(width: 112, height: 40)
    ) -> NSGlassEffectView {
        let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.style = .regular

        let button = NSButton(title: title, target: self, action: action)
        button.frame = glass.bounds
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.font = Self.glassTextControlFont
        glass.contentView = button
        return glass
    }

    private func selectionConfirmationOrigin(
        for selection: CGRect,
        on screen: NSScreen,
        size: CGSize
    ) -> CGPoint {
        let selectionOnScreen = selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        return CGPoint(
            x: selectionOnScreen.midX - size.width / 2,
            y: selectionOnScreen.midY - size.height / 2
        )
    }

    private func captureControlsOrigin(for size: CGSize) -> CGPoint {
        guard let activeCaptureRect, let activeCaptureScreen else {
            return CGPoint(x: 24, y: 24)
        }
        return ScrollingCaptureChromeLayout.origin(
            for: size,
            around: activeCaptureRect,
            in: activeCaptureScreen.frame,
            gap: 16,
            preferring: [.below, .above, .right, .left]
        )
    }

    static func screen(for selection: ScrollingCaptureSelection) -> NSScreen? {
        NSScreen.screens.first { screen in
            let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            return screenNumber?.uint32Value == selection.displayID
        }
    }

    /// The selection in AppKit screen coordinates.
    static func screenRect(for selection: ScrollingCaptureSelection) -> CGRect? {
        guard let screen = screen(for: selection) else {
            return nil
        }
        return CGRect(
            x: screen.frame.minX + selection.sourceRect.minX,
            y: screen.frame.maxY - selection.sourceRect.maxY,
            width: selection.sourceRect.width,
            height: selection.sourceRect.height
        )
    }

    private func guidanceOrigin(for selection: CGRect, on screen: NSScreen, size: CGSize) -> CGPoint {
        ScrollingCaptureChromeLayout.origin(
            for: size,
            around: selection,
            in: screen.frame,
            gap: 12,
            preferring: [.right, .left, .below, .above]
        )
    }

}

private final class CaptureBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 3
        path.stroke()
    }
}

private final class CapturePreviewView: NSView {
    private var guidance: ScrollingCaptureGuidance = .scrollDownSlowly
    private var frameCount = 0
    private var capturedHeight = 0
    private var preview: CGImage?

    func updateProgress(
        _ guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    ) {
        self.guidance = guidance
        self.frameCount = frameCount
        self.capturedHeight = capturedHeight
        needsDisplay = true
    }

    func updatePreview(_ image: CGImage) {
        preview = image
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // This surface must remain self-drawn: the completion hand-off snapshots
        // this exact view before its panel disappears, while native glass is
        // composited by the window server and would vanish from that snapshot.
        NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        NSColor.separatorColor.withAlphaComponent(0.58).setStroke()
        let outerBorder = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 17.5,
            yRadius: 17.5
        )
        outerBorder.lineWidth = 1
        outerBorder.stroke()

        let statusColor: NSColor
        let detail: String
        switch guidance {
        case .scrollDownSlowly:
            statusColor = .systemBlue
            detail = String(localized: "Scroll down slowly to add content")
        case .capturedContent:
            statusColor = .systemGreen
            detail = String(localized: "Live preview")
        }

        // The card has a fixed width, so a translation that runs long is cut
        // with an ellipsis rather than drawn past the rounded edge.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: truncating
        ]
        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: statusColor,
            .paragraphStyle: truncating
        ]
        // Each line box is exactly as tall as the text measures, which puts the
        // baseline where `draw(at:)` used to - a taller box would lift it. The
        // box runs to 8pt from the trailing edge rather than mirroring the 12pt
        // leading inset: the English hint is a hair wider than 176pt and was
        // always drawn that far, so a symmetric box would start cutting it off.
        let lineWidth = bounds.width - 12 - 8
        let count = String(localized: "\(frameCount) sections • \(capturedHeight) px")
        detail.draw(
            in: CGRect(
                x: 12,
                y: 14,
                width: lineWidth,
                height: detail.size(withAttributes: detailAttributes).height
            ),
            withAttributes: detailAttributes
        )
        count.draw(
            in: CGRect(
                x: 12,
                y: bounds.height - 22,
                width: lineWidth,
                height: count.size(withAttributes: countAttributes).height
            ),
            withAttributes: countAttributes
        )

        let previewRect = CGRect(x: 12, y: 34, width: bounds.width - 24, height: max(1, bounds.height - 68))
        NSColor.black.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: previewRect, xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let previewBorder = NSBezierPath(
            roundedRect: previewRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5.5,
            yRadius: 5.5
        )
        previewBorder.lineWidth = 1
        previewBorder.stroke()
        guard let preview else {
            return
        }

        let scale = min(
            previewRect.width / CGFloat(preview.width),
            previewRect.height / CGFloat(preview.height)
        )
        let size = CGSize(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
        let destination = CGRect(
            x: previewRect.midX - size.width / 2,
            y: previewRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.current?.cgContext.draw(preview, in: destination)
    }
}

private final class SelectionOverlayView: NSView {
    var onSelection: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    private var selectedRect: CGRect?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()

        if let selectedRect {
            NSColor.clear.setFill()
            selectedRect.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(roundedRect: selectedRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            path.lineWidth = 3
            path.stroke()
            NSColor.systemBlue.setFill()
            for point in selectionHandlePoints(for: selectedRect) {
                NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selectedRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateSelection(for: event)
        guard let selectedRect else {
            return
        }
        onSelection?(selectedRect)
    }

    private func updateSelection(for event: NSEvent) {
        guard let dragStart else {
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        selectedRect = CGRect(
            x: min(dragStart.x, current.x),
            y: min(dragStart.y, current.y),
            width: abs(current.x - dragStart.x),
            height: abs(current.y - dragStart.y)
        )
        needsDisplay = true
    }

    private func selectionHandlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }
}
