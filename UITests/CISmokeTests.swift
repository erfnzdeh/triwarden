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
        // Demo accounts are in memory only; locking returns to login rather than a saved-account unlock screen.
        XCTAssertTrue(app.staticTexts["Welcome back"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["GitHub"].firstMatch.exists)
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
