import AppKit
import Foundation
import Testing
@testable import LongScreenshot

struct OverlayRecordingModeTests {
    @Test func overlaysAreHiddenFromScreenRecordersUntilRecordingIsAskedFor() {
        // True even in this debug build. Nothing is capturable by default.
        #expect(OverlayRecordingMode.panelSharingType == .none)
    }

    #if DEBUG
    @Test @MainActor func recordingModeIsOffAtLaunchSoItCannotBeLeftOnFromLastTime() {
        // The setting deliberately does not persist - the previous attempt at
        // this feature used a scheme environment variable, which stayed set and
        // took a long debugging session to notice.
        #expect(!OverlayRecordingMode.isEnabled)
        #expect(OverlayRecordingMode.panelSharingType == .none)
    }
    #endif

    @Test func everyOverlayPanelAsksTheHelperRatherThanHardcodingItsSharingType() throws {
        let sources = try [
            "ScrollingCapture/ScrollingCaptureOverlayController.swift",
            "DustEffect/DustDissolveOverlay.swift"
        ].map { try Self.source(at: $0) }.joined(separator: "\n")

        #expect(!sources.contains("sharingType = .none"))
        #expect(!sources.contains("sharingType = .readOnly"))
        #expect(Self.occurrences(
            of: "sharingType = OverlayRecordingMode.panelSharingType",
            in: sources
        ) == 5)
    }

    /// The badge is the one panel that must never follow the mode: it warns that
    /// recording is on, so it cannot appear in the recording.
    @Test func theWarningBadgeStaysOutOfEveryCapture() throws {
        let source = try Self.source(at: "ScrollingCapture/OverlayRecordingMode.swift")

        #expect(source.contains("panel.sharingType = .none"))
        #expect(!source.contains("panel.sharingType = OverlayRecordingMode"))
    }

    /// The one that matters. `.readOnly` escaping the `#if DEBUG` block would
    /// ship an app whose chrome can be filmed - and, worse, gets baked into the
    /// long screenshots the app produces.
    @Test func theEscapeHatchCannotSurviveIntoARelease() throws {
        let source = try Self.source(at: "ScrollingCapture/OverlayRecordingMode.swift")
        let (gated, ungated) = Self.splitOnDebugGate(source)

        #expect(gated.contains(".readOnly"))
        #expect(!ungated.contains(".readOnly"))
        #expect(!ungated.contains("isEnabled"))
        #expect(!ungated.contains("setEnabled"))
        #expect(!ungated.contains("badge"))
    }

    @Test func theStatusBarToggleIsDebugOnly() throws {
        let source = try Self.source(at: "../LongScreenshot/StatusBarManager.swift")
        let (gated, ungated) = Self.splitOnDebugGate(source)

        #expect(gated.contains("toggleRecordingMode"))
        #expect(!ungated.contains("toggleRecordingMode"))
        #expect(!ungated.contains("OverlayRecordingMode"))
    }

    @Test func theWindowAnnouncesADebugBuild() {
        #if DEBUG
        #expect(ScrollingCaptureView.title == String(localized: "Long Screenshot (Debug Mode)"))
        #else
        #expect(ScrollingCaptureView.title == String(localized: "Long Screenshot"))
        #endif
    }

    // MARK: - Helpers

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Splits source into the lines inside `#if DEBUG` blocks and the lines
    /// outside them, so a test can assert where a symbol is allowed to appear.
    ///
    /// Comments are dropped first. The question is where the compiler sees a
    /// symbol, and prose that happens to name one should not fail the test.
    private static func splitOnDebugGate(_ source: String) -> (gated: String, ungated: String) {
        var gated: [String] = []
        var ungated: [String] = []
        var depth = 0

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: "//").first ?? rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if DEBUG" {
                depth += 1
                continue
            }
            if trimmed == "#endif", depth > 0 {
                depth -= 1
                continue
            }
            (depth > 0 ? { gated.append(line) } : { ungated.append(line) })()
        }
        #expect(depth == 0, "unbalanced #if DEBUG in the source")
        return (gated.joined(separator: "\n"), ungated.joined(separator: "\n"))
    }

    private static func source(at relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository
                .appendingPathComponent("LongScreenshot")
                .appendingPathComponent(relativePath)
                .standardizedFileURL,
            encoding: .utf8
        )
    }
}
