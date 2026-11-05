import AppKit
import SwiftUI

@MainActor
enum LongScreenshotWindowGlass {
    static func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }
}

struct LongScreenshotWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        return backdrop
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct LongScreenshotWindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }
            LongScreenshotWindowGlass.configure(window)
        }
    }
}
