import XCTest

final class LongScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        // The assertions look elements up by their English labels.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testMainScreenPresentsCaptureSetup() throws {
        let app = XCUIApplication()
        // The assertions look elements up by their English labels.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.groups["Capture setup"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Record Shortcut"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Choose Save Folder…"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testMainScreenDisplaysBundledAppIcon() throws {
        let app = XCUIApplication()
        // The assertions look elements up by their English labels.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.images["LongScreenshotAppIcon"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testMainScreenUsesLongScreenshotBranding() throws {
        let app = XCUIApplication()
        // The assertions look elements up by their English labels.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Long Screenshot"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testMainScreenPrioritizesActionsOnTheTrailingEdge() throws {
        let app = XCUIApplication()
        // The assertions look elements up by their English labels.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let window = app.windows.firstMatch
        let recordShortcut = app.buttons["Record Shortcut"]
        let chooseSaveFolder = app.buttons["Choose Save Folder…"]

        XCTAssertTrue(recordShortcut.waitForExistence(timeout: 2))
        XCTAssertTrue(chooseSaveFolder.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(recordShortcut.frame.minX, window.frame.midX)
        XCTAssertGreaterThan(chooseSaveFolder.frame.minX, window.frame.midX)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
