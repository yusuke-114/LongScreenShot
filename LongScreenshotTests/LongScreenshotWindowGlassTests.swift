import AppKit
import Testing
@testable import LongScreenshot

@MainActor
struct LongScreenshotWindowGlassTests {
    @Test func configuringTheMainWindowMakesItsGlassFoundationTranslucent() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        LongScreenshotWindowGlass.configure(window)

        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.titlebarAppearsTransparent)
    }
}
