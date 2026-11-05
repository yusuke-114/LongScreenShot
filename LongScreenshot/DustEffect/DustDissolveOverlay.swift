//
//  DustDissolveOverlay.swift
//  LongScreenshot
//

import AppKit
import CoreGraphics
import QuartzCore

/// A view to dissolve, and optionally the parts of it worth spending particles
/// on.
struct DustDissolveRequest {
    let view: NSView
    /// Sub-rects of `view`, in y-down points relative to its bounds. Empty
    /// dissolves the whole view.
    var slices: [CGRect] = []

    init(view: NSView, slices: [CGRect] = []) {
        self.view = view
        self.slices = slices
    }
}

/// Turns on-screen AppKit views into a cloud of dust.
///
/// The overlay owns everything it needs - its own screen-sized panel, its own
/// Metal layer, its own display link - and tears all of it down when the last
/// particle burns out. That independence is the point: a dissolve outlives the
/// panels it replaced and runs alongside an export whose duration nobody knows,
/// so it cannot be tied to the capture overlay's lifecycle.
@MainActor
final class DustDissolveOverlay {
    private let settings: DustSettings
    private var panel: NSPanel?
    private var metalView: DustMetalView?
    private var timeout: DispatchWorkItem?

    init(settings: DustSettings = DustSettings()) {
        self.settings = settings
    }

    /// Stages a dissolve for `requests`.
    ///
    /// Order matters and is the whole trick: the particles are put on screen
    /// showing frame zero - where every particle still sits in its original
    /// cell at full alpha, so the layer is pixel-identical to the views behind
    /// it - and only then is `hideSources` called to take the real views away.
    /// The swap happens inside one runloop turn and never shows a seam.
    ///
    /// `hideSources` is always called exactly once, including when the dissolve
    /// cannot run at all. The return value only reports whether particles were
    /// actually staged.
    @discardableResult
    func dissolve(
        _ requests: [DustDissolveRequest],
        on screen: NSScreen,
        hideSources: () -> Void
    ) -> Bool {
        cancel()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hideSources()
            return false
        }
        let pieces = requests.flatMap { self.pieces(for: $0, on: screen) }
        guard !pieces.isEmpty,
              let renderer = DustRenderer(pixelFormat: .bgra8Unorm),
              renderer.addGroup(pieces, settings: settings) else {
            hideSources()
            return false
        }

        let panel = makePanel(covering: screen)
        let metalView = DustMetalView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            renderer: renderer,
            scale: screen.backingScaleFactor
        )
        metalView.onFinish = { [weak self] in self?.cancel() }
        panel.contentView = metalView
        panel.orderFrontRegardless()
        self.panel = panel
        self.metalView = metalView

        metalView.renderFirstFrame()
        hideSources()
        metalView.start()

        // The display link stops itself once the particles burn out, but it can
        // only do that if it keeps firing. This panel sits at screen-saver level
        // over the whole display, so a link that stalls - the screen is
        // disconnected, the app is suspended mid-dissolve - must not be able to
        // strand it there.
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(settings.duration) + 1,
            execute: timeout
        )
        return true
    }

    /// Ends any dissolve in flight and removes the layer.
    func cancel() {
        timeout?.cancel()
        timeout = nil
        metalView?.stop()
        metalView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Snapshots

    private func pieces(for request: DustDissolveRequest, on screen: NSScreen) -> [DustPiece] {
        let view = request.view
        guard let window = view.window, let shot = snapshot(view) else {
            return []
        }
        let boundsInScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let layerFrame = DustGeometry.layerFrame(for: boundsInScreen, in: screen.frame)
        let slices = request.slices.isEmpty
            ? [CGRect(origin: .zero, size: view.bounds.size)]
            : request.slices

        return slices.compactMap { slice in
            guard let image = crop(shot.image, scale: shot.scale, to: slice) else {
                return nil
            }
            return DustPiece(
                image: image,
                frame: CGRect(
                    x: layerFrame.minX + slice.minX,
                    y: layerFrame.minY + slice.minY,
                    width: slice.width,
                    height: slice.height
                )
            )
        }
    }

    /// Redraws a view offscreen. Only safe for views that draw themselves - a
    /// material or a glass backdrop is composited by the window server and does
    /// not survive the trip, which is why the glass capture controls are left
    /// out of the dissolve.
    private func snapshot(_ view: NSView) -> (image: CGImage, scale: CGFloat)? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else {
            return nil
        }
        return (image, CGFloat(rep.pixelsWide) / bounds.width)
    }

    /// `rect` is y-down points relative to the snapshot; `CGImage` cropping is
    /// y-down pixels, so the two only differ by the backing scale.
    private func crop(_ image: CGImage, scale: CGFloat, to rect: CGRect) -> CGImage? {
        let pixels = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard pixels.width >= 1, pixels.height >= 1 else {
            return nil
        }
        let full = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        return pixels == full ? image : image.cropping(to: pixels)
    }

    private func makePanel(covering screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        // Matches every other capture overlay: our chrome stays out of other
        // people's recordings, and out of our own captures.
        panel.sharingType = OverlayRecordingMode.panelSharingType
        panel.ignoresMouseEvents = true
        // The layer has to arrive at full size on its first frame. An appear
        // animation would scale the particles up from 98%, which is exactly the
        // seam the pixel-identical first frame exists to avoid.
        panel.animationBehavior = .none
        return panel
    }
}

private final class DustMetalView: NSView {
    var onFinish: (() -> Void)?

    private let renderer: DustRenderer
    private let scale: CGFloat
    /// Named `activeLink` rather than `displayLink` so it does not shadow
    /// `NSView.displayLink(target:selector:)`.
    private var activeLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    init(frame frameRect: NSRect, renderer: DustRenderer, scale: CGFloat) {
        self.renderer = renderer
        self.scale = scale
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        configureLayer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func configureLayer() {
        guard let metalLayer else { return }
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = nil
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
    }

    /// Draws the untouched state: every particle still in its own cell at full
    /// alpha, so the layer matches the views it is about to replace.
    func renderFirstFrame() {
        guard let metalLayer else { return }
        renderer.render(in: metalLayer, viewSize: bounds.size, deltaTime: 0)
    }

    func start() {
        guard activeLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        activeLink = link
        lastTimestamp = nil
    }

    func stop() {
        activeLink?.invalidate()
        activeLink = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let metalLayer else {
            stop()
            return
        }

        let timestamp = link.timestamp
        let elapsed = timestamp - (lastTimestamp ?? (timestamp - 1.0 / 60.0))
        lastTimestamp = timestamp
        // A hitch or a paused window should not teleport the particles.
        let deltaTime = min(max(Float(elapsed), 1.0 / 240.0), 1.0 / 20.0)

        renderer.advance(deltaTime: deltaTime)
        renderer.render(in: metalLayer, viewSize: bounds.size, deltaTime: deltaTime)

        if !renderer.isActive {
            stop()
            onFinish?()
        }
    }
}
