import XCTest

final class AgentKeyringUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesInTheMenuBarAndOpensTheStatusWindowOnDemand() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertFalse(app.windows["main"].waitForExistence(timeout: 1))

        let menuBarItem = app.descendants(matching: .statusItem)["agent-keyring-menu"]
        XCTAssertTrue(menuBarItem.waitForExistence(timeout: 5))
        menuBarItem.click()

        let openItem = app.menuItems["Open Agent Keyring"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Quit Agent Keyring"].exists)
        openItem.click()

        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(mainWindow.staticTexts["mirror-status"].exists)
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    func testCredentialAccessRendersRealScaleRulesAndActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-access-control"]
        app.launch()

        let accessWindow = app.windows["access"]
        XCTAssertTrue(accessWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(accessWindow.descendants(matching: .any)["policy-ask"].exists)
        XCTAssertTrue(accessWindow.descendants(matching: .any)["policy-allowAutomatically"].exists)
        XCTAssertTrue(accessWindow.descendants(matching: .any)["policy-block"].exists)
        XCTAssertTrue(accessWindow.buttons["policy-assistant"].exists)
        XCTAssertTrue(accessWindow.descendants(matching: .any)["policy-detail-ask"].exists)
        XCTAssertTrue(accessWindow.scrollViews["credential-list"].exists)
        XCTAssertTrue(accessWindow.staticTexts["Credential"].exists)
        XCTAssertTrue(accessWindow.staticTexts["Account"].exists)
        XCTAssertTrue(accessWindow.staticTexts["Website"].exists)
        XCTAssertTrue(accessWindow.staticTexts["440 credentials"].exists)
        XCTAssertTrue(accessWindow.staticTexts["Credential 1"].exists)
    }

    @MainActor
    func testCredentialAccessChangesRuleAndOpensAssistant() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-access-control"]
        app.launch()
        let accessWindow = app.windows["access"]
        XCTAssertTrue(accessWindow.waitForExistence(timeout: 5))

        accessWindow.staticTexts["Credential 1"].click()
        let changeRule = accessWindow.buttons["change-access-rule"]
        XCTAssertTrue(changeRule.waitForExistence(timeout: 2))
        changeRule.click()
        app.menuItems["Blocked"].click()
        XCTAssertTrue(accessWindow.staticTexts["439 credentials"].waitForExistence(timeout: 2))

        accessWindow.buttons["policy-assistant"].click()
        XCTAssertTrue(
            app.staticTexts["Get rule suggestions from your AI"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Copy prompt"].exists)
        XCTAssertTrue(app.buttons["Review suggestions"].exists)
    }
}
