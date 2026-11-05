import Foundation
import Testing
@testable import LongScreenshot

@MainActor
private final class FakeHotKeyRegistrar: GlobalHotKeyRegistering {
    private(set) var active: [(shortcut: ScrollingCaptureShortcut, onPress: () -> Void, id: Int)] = []
    private var nextID = 0

    var isHoldingEscape: Bool {
        active.contains { $0.shortcut == ScrollingCaptureOverlayController.escapeShortcut }
    }

    func pressEscape() {
        active.first { $0.shortcut == ScrollingCaptureOverlayController.escapeShortcut }?.onPress()
    }

    func register(
        _ shortcut: ScrollingCaptureShortcut,
        onPress: @escaping () -> Void
    ) throws -> any GlobalHotKeyRegistration {
        nextID += 1
        let id = nextID
        active.append((shortcut, onPress, id))
        return FakeRegistration { [weak self] in
            self?.active.removeAll { $0.id == id }
        }
    }
}

@MainActor
private final class FakeRegistration: GlobalHotKeyRegistration {
    private let onInvalidate: () -> Void

    init(onInvalidate: @escaping () -> Void) {
        self.onInvalidate = onInvalidate
    }

    func invalidate() {
        onInvalidate()
    }
}

@Suite(.serialized)
struct ScrollingCaptureEscapeTests {
    @Test @MainActor func escapeCancelsSelectionAndReleasesTheKey() {
        let registrar = FakeHotKeyRegistrar()
        let controller = ScrollingCaptureOverlayController(hotKeyRegistrar: registrar)
        var results: [ScrollingCaptureSelection?] = []

        controller.presentSelection { results.append($0) }
        #expect(registrar.isHoldingEscape)

        registrar.pressEscape()

        #expect(results.count == 1)
        #expect(results.first == .some(nil))
        #expect(!registrar.isHoldingEscape)
    }

    /// While capturing, the user is working in the captured app: its Esc must
    /// reach it, and a stray press must not throw the capture away.
    @Test @MainActor func capturingLeavesEscapeToTheCapturedApp() {
        let registrar = FakeHotKeyRegistrar()
        let controller = ScrollingCaptureOverlayController(hotKeyRegistrar: registrar)

        controller.presentCaptureControls(onDone: {}, onCancel: {})

        #expect(!registrar.isHoldingEscape)
    }

    @Test @MainActor func dismissingReleasesEscape() {
        let registrar = FakeHotKeyRegistrar()
        let controller = ScrollingCaptureOverlayController(hotKeyRegistrar: registrar)

        controller.presentSelection { _ in }
        controller.dismissAll()
        #expect(!registrar.isHoldingEscape)
        #expect(registrar.active.isEmpty)
    }
}
