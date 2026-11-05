import Foundation
import Testing

struct ScrollingCaptureViewStructureTests {
    @Test func mainWindowContainsOnlyIntroShortcutAndSaveFolderSections() throws {
        let source = try scrollingCaptureViewSource()

        #expect(source.contains("heroSection"))
        #expect(source.contains("shortcutSection"))
        #expect(source.contains("saveFolderSection"))
        #expect(!source.contains("statusSection"))
        #expect(!source.contains("statusCard"))
    }

    private func scrollingCaptureViewSource() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repository
            .appendingPathComponent("LongScreenshot")
            .appendingPathComponent("ScrollingCapture")
            .appendingPathComponent("ScrollingCaptureView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
