import Foundation
import Testing
@testable import LongScreenshot

@Suite(.serialized)
struct ScrollingCaptureCoordinatorTests {
    @Test @MainActor func saveFolderDisplayNameIsNotSelectedBeforeUserGrantsFolderAccess() {
        let suiteName = "ScrollingCaptureCoordinatorTests-\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ScrollingCaptureSaveFolderPreferences(
            userDefaults: defaults,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) }
        )
        let coordinator = ScrollingCaptureCoordinator(saveFolderPreferences: preferences)

        #expect(coordinator.saveFolderDisplayName == String(localized: "Not selected"))
    }
}
