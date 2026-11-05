//
//  OverlayRecordingMode.swift
//  LongScreenshot
//

import AppKit

/// Decides whether the capture chrome is visible to screen recorders.
///
/// Every overlay panel is normally `.none`, which tells the window server to
/// hand those pixels to no capture client at all - not Screenshot, not
/// QuickTime, not ScreenCaptureKit. That is load-bearing rather than
/// incidental: it is why the selection border, the preview card and the dust
/// never end up baked into the long screenshot the app itself produces.
///
/// The same setting makes the whole feature impossible to film. Debug builds
/// can lift it so App Store material can be recorded; release builds cannot,
/// because `DEBUG` is only defined in the Debug configuration and every branch
/// below is compiled away everywhere else.
///
/// The mode is deliberately awkward to leave on by accident. It resets to off
/// on every launch, it is toggled from a visible menu item rather than a
/// scheme setting, and while it is on a badge sits on screen - a badge that is
/// itself excluded from capture, so it warns you without appearing in the very
/// recording it is warning about.
enum OverlayRecordingMode {
    /// What an overlay panel should set its `sharingType` to.
    static var panelSharingType: NSWindow.SharingType {
        #if DEBUG
        if isEnabled {
            return .readOnly
        }
        #endif
        return .none
    }

    #if DEBUG
    private(set) static var isEnabled = false
    private static var badge: NSPanel?

    /// Only affects panels created after the change. Toggle before starting a
    /// capture, not during one.
    @MainActor
    static func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        enabled ? showBadge() : hideBadge()
    }

    @MainActor
    private static func showBadge() {
        hideBadge()
        guard let screen = NSScreen.main else { return }

        let size = CGSize(width: 460, height: 30)
        let panel = NSPanel(
            contentRect: CGRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height - 6,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // Hardcoded, not routed through `panelSharingType`. The warning must not
        // show up in the recording it is warning about.
        panel.sharingType = .none

        let label = NSTextField(
            labelWithString: "● RECORDING MODE — overlays are capturable; saved screenshots may include chrome"
        )
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        background.layer?.cornerRadius = size.height / 2
        label.frame = background.bounds.insetBy(dx: 12, dy: 6)
        label.autoresizingMask = [.width, .height]
        background.addSubview(label)

        panel.contentView = background
        panel.orderFrontRegardless()
        badge = panel
    }

    @MainActor
    private static func hideBadge() {
        badge?.orderOut(nil)
        badge = nil
    }
    #endif
}
