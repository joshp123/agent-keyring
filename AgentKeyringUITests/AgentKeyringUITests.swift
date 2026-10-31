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

        XCTAssertTrue(app.buttons["menu-rules"].waitForExistence(timeout: 2))
        app.buttons["menu-more"].click()
        let openItem = app.menuItems["Open Agent Keyring"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Quit Agent Keyring"].exists)
        openItem.click()

        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(mainWindow.staticTexts["mirror-status"].exists)
        XCTAssertTrue(mainWindow.descendants(matching: .any)["agent-instructions"].exists)
        XCTAssertTrue(mainWindow.buttons["copy-agent-instructions"].exists)
    }

    /// 522 logins: 440 Ask, 52 Automatic, 30 Blocked, rules already confirmed.
    @MainActor
    func testRulesWindowRendersRealScaleRules() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-access-control"]
        app.launch()

        let rulesWindow = app.windows["access"]
        XCTAssertTrue(rulesWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(rulesWindow.staticTexts["All logins"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["522"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["440"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["52"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["30"].exists)
        XCTAssertFalse(rulesWindow.staticTexts["Confirm your rules"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["Login"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["Rule"].exists)
        XCTAssertTrue(rulesWindow.staticTexts["service-1.example"].exists)
        XCTAssertTrue(rulesWindow.buttons["rules-assistant"].exists)
    }

    @MainActor
    func testRulesWindowChangesARuleAndOpensTheAssistant() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-access-control"]
        app.launch()
        let rulesWindow = app.windows["access"]
        XCTAssertTrue(rulesWindow.waitForExistence(timeout: 5))

        rulesWindow.staticTexts["service-1.example"].click()
        let setRule = rulesWindow.descendants(matching: .any)["set-rule"]
        XCTAssertTrue(setRule.waitForExistence(timeout: 2))
        setRule.click()
        app.menuItems["Blocked"].click()
        XCTAssertTrue(rulesWindow.staticTexts["439"].waitForExistence(timeout: 2))
        XCTAssertTrue(rulesWindow.staticTexts["31"].exists)

        rulesWindow.buttons["rules-assistant"].click()
        XCTAssertTrue(app.staticTexts["Set Rules with AI"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Copy Prompt"].exists)
        XCTAssertTrue(app.buttons["Review Changes"].exists)
    }
}
