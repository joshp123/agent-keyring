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

    @MainActor
    func testCredentialAccessWindowHasUsefulMaximumSize() throws {
        let app = XCUIApplication()
        app.launch()

        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        let manageAccess = mainWindow.buttons["Manage access"]
        XCTAssertTrue(manageAccess.waitForExistence(timeout: 2))
        manageAccess.click()

        let accessWindow = app.windows["access"]
        XCTAssertTrue(accessWindow.waitForExistence(timeout: 5))

        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 2))
        windowMenu.click()
        let fillItem = app.menuBars.menuItems["Fill"]
        XCTAssertTrue(fillItem.waitForExistence(timeout: 2))
        fillItem.click()

        XCTAssertLessThanOrEqual(accessWindow.frame.width, 1_100)
        XCTAssertLessThanOrEqual(accessWindow.frame.height, 760)
    }
}
