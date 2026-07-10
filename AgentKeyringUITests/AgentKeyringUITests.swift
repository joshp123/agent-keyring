import XCTest

final class AgentKeyringUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesOneReadableStatusWindow() throws {
        let app = XCUIApplication()
        app.launch()

        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(mainWindow.staticTexts["mirror-status"].exists)
        XCTAssertEqual(app.windows.count, 1)
    }
}
