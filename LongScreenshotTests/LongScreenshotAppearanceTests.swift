import AppKit
import Testing
@testable import LongScreenshot

@MainActor
struct LongScreenshotAppearanceTests {
    @Test func applyingTheAppAppearanceForcesDarkAqua() {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        LongScreenshotAppearance.apply()

        #expect(application.appearance?.name == .darkAqua)
    }
}
