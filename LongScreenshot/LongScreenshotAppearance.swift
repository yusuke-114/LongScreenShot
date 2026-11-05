import AppKit

@MainActor
enum LongScreenshotAppearance {
    static func apply() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }
}
