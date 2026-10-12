import XCTest

/// Small, deterministic checks of the actual app process using synthetic data.
@MainActor
final class CISmokeTests: XCTestCase {
    func testDemoVaultOpensAndLocks() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Vault locked"].firstMatch.waitForExistence(timeout: 10))
    }

    func testDemoItemEditorOpensAndCancels() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        let item = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS %@", "GitHub")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Edit Item"].firstMatch.waitForExistence(timeout: 5))
        app.windows.firstMatch.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(app.staticTexts["Edit Item"].firstMatch.exists)
    }
}
