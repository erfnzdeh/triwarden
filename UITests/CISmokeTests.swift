import XCTest
import AppKit

/// Small, deterministic checks of the actual app process using synthetic data.
@MainActor
final class CISmokeTests: XCTestCase {
    /// Keyboard synthesis goes through the user's input method. Paste synthetic text and restore all clipboard formats.
    private func enterText(_ text: String, in field: XCUIElement) {
        let pasteboard = NSPasteboard.general
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        // macOS can launch the process with its SwiftUI window ordered behind the test runner.
        // Bring the actual vault window forward through the app's standard Window menu.
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuBarItems["Window"].menus.menuItems["Triwarden"].firstMatch.click()
        return app
    }

    func testDemoVaultOpensAndLocks() {
        let app = launchDemo()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        app.typeKey("l", modifierFlags: [.command, .shift])
        // Demo accounts are in memory only; locking returns to login rather than a saved-account unlock screen.
        XCTAssertTrue(app.staticTexts["Welcome back"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["GitHub"].firstMatch.exists)
    }

    func testDemoItemEditorOpensAndCancels() {
        let app = launchDemo()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        let item = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS %@", "GitHub")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        app.typeKey("e", modifierFlags: .command)
        let editorName = app.textFields.matching(NSPredicate(format: "value == %@", "GitHub")).firstMatch
        let cancel = app.windows.firstMatch.buttons["Cancel"].firstMatch
        XCTAssertTrue(editorName.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.buttons["Save"].firstMatch.exists)
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(editorName.exists)
    }

    func testSecretsSettingsUsesReferences() {
        continueAfterFailure = false
        let app = launchDemo()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        // Close any Window-menu tracking left by launchDemo before opening the explicit menu action.
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Triwarden"].click()
        app.menuBars.menuBarItems["Triwarden"].menus.menuItems["Settings…"].firstMatch.click()
        let secrets = app.outlines.staticTexts["Secrets"].firstMatch
        XCTAssertTrue(secrets.waitForExistence(timeout: 5))
        secrets.click()
        XCTAssertTrue(app.buttons["Open Tools"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Advanced Launch Settings…"].firstMatch.click()
        XCTAssertTrue(app.textFields["secretsProfileName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveSecretsProfile"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["secretsVaultItem"].firstMatch.exists)
        XCTAssertEqual(app.secureTextFields.count, 0, "The profile editor should select references, not accept a plaintext key")
    }

    func testAPIKeyCreationStartsInTheVault() {
        continueAfterFailure = false
        let app = launchDemo()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["New API Key"].firstMatch.click()
        // The shared header combines title and subtitle for accessibility. Identify the actual form fields.
        XCTAssertTrue(app.textFields["apiKeyService"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["apiKeyValue"].firstMatch.exists)
        let variable = app.textFields["apiKeyVariable"].firstMatch
        XCTAssertTrue(variable.waitForExistence(timeout: 5))
        XCTAssertEqual(variable.value as? String, "API_KEY")
        XCTAssertFalse(app.textFields["secretsProfileName"].exists)
        app.windows.firstMatch.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.textFields["apiKeyService"].firstMatch.waitForNonExistence(timeout: 5))
    }

    func testSavedAPIKeyStartsGuidedToolSetup() {
        continueAfterFailure = false
        let app = launchDemo()
        defer { app.terminate() }
        let key = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Anthropic development")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 15))
        key.click()
        let provide = app.buttons["Provide to Tool…"].firstMatch
        XCTAssertTrue(provide.waitForExistence(timeout: 5))
        provide.click()
        let name = app.textFields["toolLaunchName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["secretsProfileName"].exists)
        let variable = app.textFields["toolLaunchVariable"].firstMatch
        XCTAssertTrue(variable.exists)
        XCTAssertEqual(variable.value as? String, "ANTHROPIC_API_KEY")
        XCTAssertEqual(app.secureTextFields.count, 0, "Tool setup uses the saved key reference")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }

    func testAPIKeyVariableSuggestionsPreserveCustomNames() {
        continueAfterFailure = false
        let app = launchDemo()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 15))
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["New API Key"].firstMatch.click()
        let service = app.textFields["apiKeyService"].firstMatch
        let variable = app.textFields["apiKeyVariable"].firstMatch
        XCTAssertTrue(variable.waitForExistence(timeout: 5))
        enterText("Anthropic", in: service)
        XCTAssertEqual(service.value as? String, "Anthropic")
        XCTAssertEqual(variable.value as? String, "ANTHROPIC_API_KEY")
        enterText("PROJECT_API_TOKEN", in: variable)
        enterText("OpenAI", in: service)
        XCTAssertEqual(variable.value as? String, "PROJECT_API_TOKEN", "A service change must preserve the user's explicit name")
        enterText("NODE_OPTIONS", in: variable)
        let problem = app.descendants(matching: .any)["apiKeyVariableError"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        enterText("PROJECT_API_TOKEN", in: variable)
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5))
        app.windows.firstMatch.buttons["Cancel"].firstMatch.click()
        app.sheets.buttons["Discard Changes"].firstMatch.click()
        XCTAssertTrue(variable.waitForNonExistence(timeout: 5))
    }

}
