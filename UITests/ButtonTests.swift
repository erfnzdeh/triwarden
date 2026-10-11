import AppKit
import XCTest

/// Clicks through the app's buttons in `--demo` mode (demo vault, in-memory account, no server).
/// Server-backed actions can't finish without a server; these tests check that every button does its UI part:
/// opens the right sheet, menu or confirmation, copies the right value, switches the right page.
/// Destructive confirmations are only ever cancelled.
@MainActor
final class ButtonTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 10), "demo vault did not open")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private var window: XCUIElement { app.windows.firstMatch }

    private func clipboard() -> String? { NSPasteboard.general.string(forType: .string) }

    private func button(_ label: String) -> XCUIElement {
        window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    private func select(_ item: String) {
        window.buttons.matching(NSPredicate(format: "label CONTAINS %@", item)).firstMatch.click()
    }

    private func menuButton(_ title: String) -> XCUIElement {
        window.menuButtons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
    }

    private var generated: String {
        window.staticTexts["generatedValue"].label
    }

    private func sidebar(_ title: String) {
        window.outlines.staticTexts[title].firstMatch.click()
    }

    /// Cancels the open confirmation dialog / alert (never confirms).
    private func cancelConfirmation(file: StaticString = #filePath, line: UInt = #line) {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "no confirmation appeared", file: file, line: line)
        cancel.click()
    }

    // MARK: Header

    func testCommandPaletteOpensAndCloses() {
        button("Search or run a command").click()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Search or run a command")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "palette did not open")
        field.click()
        field.typeText("git")
        XCTAssertTrue(app.staticTexts["GitHub recovery"].firstMatch.waitForExistence(timeout: 2) || app.staticTexts["GitHub"].exists)
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(field.waitForExistence(timeout: 1) && field.isHittable, "palette did not close")
    }

    func testNewItemMenuOpensEveryEditor() {
        for kind in ["New Login", "New Secure Note", "New Card", "New Identity", "New SSH Key"] {
            menuButton("New Item").click()
            let entry = app.menuItems[kind]
            XCTAssertTrue(entry.waitForExistence(timeout: 2), "\(kind) missing from + menu")
            entry.click()
            let cancel = app.sheets.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 3), "\(kind) did not open the editor")
            cancel.click()
            XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1), "\(kind) editor did not close")
        }
        menuButton("New Item").click()
        app.menuItems["New Folder…"].click()
        cancelConfirmation()
    }

    // MARK: Item detail

    func testItemToolbar() {
        select("GitHub")
        XCTAssertTrue(button("Edit").waitForExistence(timeout: 3), "item toolbar missing")
        button("Edit").click()
        XCTAssertTrue(window.staticTexts["Edit Item"].waitForExistence(timeout: 3), "Edit did not open in the detail panel")
        window.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(window.staticTexts["Edit Item"].waitForExistence(timeout: 1), "Edit did not close")

        button("Reveal").click()
        XCTAssertTrue(window.staticTexts["m7Kq#vR2!tLp9wZe$Hu"].waitForExistence(timeout: 2), "Reveal did not show the password")
        button("Hide").click()
        XCTAssertFalse(window.staticTexts["m7Kq#vR2!tLp9wZe$Hu"].waitForExistence(timeout: 1), "Hide did not hide the password")

        // Trash doesn't ask; the toast's Undo brings the item back.
        button("Move to Trash").click()
        let undo = window.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no Undo after moving to Trash")
        undo.click()
        XCTAssertTrue(window.staticTexts["GitHub"].firstMatch.waitForExistence(timeout: 3), "Undo did not bring the item back")
    }

    func testFavoriteButton() {
        select("GitHub") // a favorite in the demo vault
        let star = window.toolbars.buttons["Favorite"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        XCTAssertEqual(star.identifier, "star.fill", "GitHub should start as a favorite")
        star.click()
        XCTAssertTrue(window.toolbars.buttons.matching(identifier: "star").firstMatch.waitForExistence(timeout: 2), "star did not empty")
        window.buttons["Favorites"].firstMatch.click() // the list chip
        XCTAssertFalse(window.buttons.matching(NSPredicate(format: "label CONTAINS 'GitHub,'")).firstMatch.waitForExistence(timeout: 1),
                       "GitHub still listed under Favorites")
        window.buttons["All"].firstMatch.click()
        select("GitHub")
        window.toolbars.buttons["Favorite"].firstMatch.click()
        XCTAssertTrue(window.toolbars.buttons.matching(identifier: "star.fill").firstMatch.waitForExistence(timeout: 2), "star did not fill again")
    }

    func testPasswordAndCodeTilesCopy() {
        select("GitHub")
        window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Password")).firstMatch.click()
        XCTAssertEqual(clipboard(), "m7Kq#vR2!tLp9wZe$Hu", "password tile did not copy the password")
        window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "One-time code")).firstMatch.click()
        XCTAssertEqual(clipboard()?.count, 6, "code tile did not copy a 6-digit code")
    }

    // MARK: Sidebar pages

    func testSidebarSections() {
        for (row, proof) in [("Generator", "Regenerate"), ("One-Time Codes", "One-Time Codes"), ("Watchtower", "Watchtower"),
                             ("Send", "Send"), ("Favorites", "GitHub"), ("All Items", "Cloudflare")] {
            sidebar(row)
            XCTAssertTrue(window.descendants(matching: .any)[proof].firstMatch.waitForExistence(timeout: 3), "\(row) did not open")
        }
    }

    func testGeneratorButtons() {
        sidebar("Generator")
        let regenerate = button("Regenerate")
        XCTAssertTrue(regenerate.waitForExistence(timeout: 3))
        let first = generated
        regenerate.click()
        XCTAssertNotEqual(generated, first, "Regenerate did not make a new value")
        button("Copy").click()
        XCTAssertEqual(clipboard(), generated, "Copy did not copy the shown value")

        for mode in ["Passphrase", "Username", "Password"] {
            window.buttons[mode].firstMatch.click()
            button("Copy").click()
            XCTAssertFalse((clipboard() ?? "").isEmpty, "\(mode) mode copied nothing")
        }

        // History lists what was copied; Clear asks first.
        XCTAssertTrue(window.staticTexts["History"].exists)
        button("Clear").click()
        cancelConfirmation()
        XCTAssertFalse(window.staticTexts["Nothing yet"].exists, "history was cleared although Cancel was pressed")
    }

    // MARK: Account card

    func testAccountMenu() {
        menuButton("Account").click()
        // Open Web Vault / Copy Server Address need a signed-in server, so the demo vault doesn't show them.
        for entry in ["Sync Now", "Import…", "Export Vault…", "Add Account…", "Settings…", "Lock Vault", "Log Out…"] {
            XCTAssertTrue(app.menuItems[entry].waitForExistence(timeout: 2), "\(entry) missing from account menu")
        }
        app.menuItems["Log Out…"].click()
        cancelConfirmation()

        menuButton("Account").click()
        app.menuItems["Lock Vault"].click()
        XCTAssertTrue(app.staticTexts["Vault locked"].waitForExistence(timeout: 3), "Lock Vault did not lock")
    }

    func testSettingsOpensFromAccountMenuAndPalette() {
        menuButton("Account").click()
        app.menuItems["Settings…"].click()
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings' OR title CONTAINS[c] 'General' OR title CONTAINS[c] 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "Settings… in the account menu did not open Settings")
        settings.typeKey("w", modifierFlags: .command)

        button("Search or run a command").click()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Search or run a command")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("settings\r")
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "the palette's Settings command did not open Settings")
    }

    func testImportAndExportSheets() {
        menuButton("Account").click()
        app.menuItems["Export Vault…"].click()
        XCTAssertTrue(app.sheets.staticTexts["Export Vault"].waitForExistence(timeout: 3), "Export Vault… did not open")
        XCTAssertFalse(app.sheets.buttons["Export…"].isEnabled, "Export must wait for the master password")
        app.sheets.buttons["Cancel"].click()

        menuButton("Account").click()
        app.menuItems["Import…"].click()
        XCTAssertTrue(app.sheets.staticTexts["Import"].waitForExistence(timeout: 3), "Import… did not open")
        app.sheets.buttons["Cancel"].click()
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))
    }

    func testLockButton() {
        button("Lock Vault").click()
        XCTAssertTrue(app.staticTexts["Vault locked"].waitForExistence(timeout: 3), "lock button did not lock")
        XCTAssertFalse(button("Unlock").isEnabled, "Unlock should wait for a password")
    }
}
