//
//  ClothesLineController.swift
//  LongScreenshot
//
//  Adapted from Tendedero by Alejandro Buján, MIT License.
//

import AppKit
import os
import Combine
import SwiftUI

/// What the capture flow needs from the clothesline, so tests can stand in
/// for it without putting windows on screen.
@MainActor
protocol ClothesLineHanging: AnyObject {
    /// Hangs a saved capture. `scope` is the security-scoped save folder the
    /// file is in; `origin` is where on screen it was captured, if known.
    func hang(_ url: URL, scope: URL, from origin: CGRect?)
    func takeEverythingDown()
}

/// Owns the panel along the top of the screen and decides when the line is
/// down, tucked away or gone.
@MainActor
final class ClothesLineController: ClothesLineHanging {
    static let shared = ClothesLineController()

    let line = ClothesLine()
    private var panel: ClothesLinePanel?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private var clickMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private(set) var isRevealed = false
    /// Brought down by a new capture or from the menu: it stays down until
    /// you put it away with a click in the menu bar. Only a line called down
    /// by resting the pointer in the menu bar tucks away by itself.
    private var pinned = false
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var awaySince: Date?
    /// Whether the line should be up at all.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    private init() {}

    /// The panel and its monitors are only set up the first time the line is
    /// used, so turning the feature off costs nothing.
    private func ensurePanel() -> ClothesLinePanel {
        if let panel { return panel }
        let host = NSHostingView(rootView: ClothesLineView(line: line))
        host.sizingOptions = []
        let panel = ClothesLinePanel(content: host)
        self.panel = panel
        panel.placeOnScreen()
        updateCapacity()

        ClothesLineMarkup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.placeOnScreen()
                self?.updateCapacity()
            }
        })
        watchMenuBarClicks()
        return panel
    }

    // MARK: Hanging

    func hang(_ url: URL, scope: URL, from origin: CGRect?) {
        // A long capture can be tens of thousands of pixels tall; decode the
        // thumbnail away from the main thread.
        Task.detached(priority: .userInitiated) {
            let didAccess = scope.startAccessingSecurityScopedResource()
            let image = makeClothesLineThumbnail(url)
            if didAccess { scope.stopAccessingSecurityScopedResource() }
            guard let image else {
                clothesLineLog.error("Could not make a thumbnail for \(url.lastPathComponent, privacy: .public)")
                return
            }
            await MainActor.run {
                self.hang(url, scope: scope, image: image, from: origin)
            }
        }
    }

    private func hang(_ url: URL, scope: URL, image: CGImage, from origin: CGRect?) {
        _ = ensurePanel()
        if let origin {
            let center = CGPoint(x: origin.midX, y: origin.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        let thumb = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let id = line.hang(url, scope: scope, thumb: thumb, flying: origin != nil),
              let origin else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, image: image, from: origin)
        }
    }

    func takeEverythingDown() {
        line.clear()
    }

    /// Brings the line down on purpose, from the menu bar. It stays until
    /// put away. An empty line goes away again once it tucks up.
    func show() {
        let panel = ensurePanel()
        keepOpen = line.liveCount == 0
        wanted = true
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        reveal(pinned: true)
    }

    var hasItems: Bool { line.liveCount > 0 }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            panel?.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(pinned: true)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    private func fly(_ id: UUID, image: CGImage, from: CGRect) {
        guard isPresent, isRevealed, let panel, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        ClothesLineFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: ClothesLineItem) {
        guard isPresent, isRevealed, !item.flying, let screen = panel?.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        ClothesLineFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let panel, let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = ClothesLineLayout.x(index: index, count: line.items.count, width: width)
        let viewTop = ClothesLineLayout.ropeY(x: x, width: width) - ClothesLineLayout.pinAbove
        let cardTop = viewTop + ClothesLineCardView.cardOffsetBelowTop
        let size = ClothesLineCardView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all.
    private func refresh() {
        if wanted {
            present()
            startMouseTracking()
        } else {
            dismiss()
            stopMouseTracking()
        }
    }

    private func present() {
        guard !isPresent, let panel else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            panel?.ignoresMouseEvents = true
            // Opened empty from the menu: nothing to keep it around for.
            if keepOpen && line.liveCount == 0 {
                keepOpen = false
                wanted = false
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        }
    }

    // MARK: Following the pointer

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel?.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts
    /// the line away. Mouse monitors need no Accessibility permission.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }

    private func tick() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)

        let busy = pinned || ClothesLineGrabView.isDragging || line.pressedID != nil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard let panel, !ClothesLineGrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        guard let panel else { return }
        let usable = panel.frame.width - 200
        line.maxItems = max(3, min(12, Int(usable / ClothesLineLayout.spacing)))
    }
}
