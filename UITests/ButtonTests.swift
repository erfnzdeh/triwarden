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
        app.launchArguments = ["--demo", "--demo-item", "2", "-appearance", "light"]
        app.launch()
        app.activate()
        let clearSearch = app.buttons["Clear Search"].firstMatch
        if clearSearch.exists { clearSearch.click() }
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

    /// A sidebar row by its title (a row reads as its title, then its count).
    private func sidebarRow(_ title: String) -> XCUIElement {
        window.descendants(matching: .any)["sidebar"].descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ","))
            .firstMatch
    }

    private func sidebar(_ title: String) {
        sidebarRow(title).click()
    }

    /// Cancels the open confirmation dialog / alert (never confirms).
    private func cancelConfirmation(file: StaticString = #filePath, line: UInt = #line) {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "no confirmation appeared", file: file, line: line)
        cancel.click()
    }

    // MARK: Palette copy shortcuts (#88)

    /// The palette's field, looked up fresh: the panel is torn down and rebuilt between copies, so a held
    /// element handle goes stale and Xcode 27 throws instead of reporting a miss.
    private var paletteField: XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Search or run a command")).firstMatch
    }

    /// Opens the palette with `query` typed into its field. The text is pasted rather than typed: a Chinese input
    /// method (this Mac runs Cangjie/Quick) would treat the letters as composition and open a candidate window over
    /// the palette, which no assertion here can get past. The paste lands asynchronously, so wait for the field to
    /// show the query before emptying the pasteboard — otherwise the query itself can be what a copy assertion reads.
    private func openPalette(_ query: String) {
        button("Search or run a command").click()
        XCTAssertTrue(paletteField.waitForExistence(timeout: 5), "palette did not open")
        paletteField.click()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
        paletteField.typeKey("v", modifierFlags: .command)
        let landed = Date.now.addingTimeInterval(5)
        while Date.now < landed, (paletteField.value as? String) != query { usleep(50_000) }
        XCTAssertEqual(paletteField.value as? String, query, "the query did not reach the palette's field")
        NSPasteboard.general.clearContents()
        let emptied = Date.now.addingTimeInterval(2)
        while Date.now < emptied, !(clipboard() ?? "").isEmpty { usleep(20_000) }
    }

    /// Issue #88: with an item highlighted in the palette, ⇧⌘C / ⌥⌘C / ⌃⌘C copy that item's username, password
    /// and one-time code — the same keys as the main window. The vault's selection is GitHub while the palette's
    /// is Cloudflare, so a copy that falls through to the Item menu picks the wrong item and fails here.
    func testPaletteCopyShortcutsCopyTheHighlightedItem() {
        let cases: [(XCUIElement.KeyModifierFlags, String?, String)] = [
            (.shift, "ops@northwind.example", "username"),
            (.option, "cf-9xQ!m2Lp#Vt7", "password"),
            (.control, nil, "one-time code"),
        ]
        for (modifier, expected, what) in cases {
            NSPasteboard.general.clearContents()
            openPalette("cloudflare")
            paletteField.typeKey("c", modifierFlags: [.command, modifier])
            // The palette says what it copied for a moment, then closes.
            let deadline = Date.now.addingTimeInterval(4)
            while Date.now < deadline, (clipboard() ?? "").isEmpty { usleep(50_000) }
            let value = clipboard()
            if let expected {
                XCTAssertEqual(value, expected, "the palette's \(what) shortcut did not copy the highlighted item")
            } else {
                XCTAssertEqual(value?.count, 6, "the palette's \(what) shortcut did not copy a one-time code")
                XCTAssertTrue(value?.allSatisfy(\.isNumber) == true, "the palette's \(what) shortcut copied no digits")
            }
            // Back to the vault, ready for the next key.
            let closed = paletteField.waitForNonExistence(timeout: 5)
            XCTAssertTrue(closed, "the palette stayed open after copying the \(what)")
        }
    }

    /// The shortcuts are discoverable: an item's actions list shows them, like ⌘↵ / ⌥↵ today. GitHub carries every one
    /// of them — username, password, code and notes — while Cloudflare has no notes at all.
    func testPaletteActionsListTheCopyShortcuts() {
        openPalette("github")
        paletteField.typeKey(.tab, modifierFlags: [])
        for keycap in ["⇧⌘C", "⌥⌘C", "⌃⌘C", "⌃⌘N"] {
            XCTAssertTrue(app.staticTexts[keycap].firstMatch.waitForExistence(timeout: 5),
                          "the actions list does not show \(keycap)")
        }
    }

    /// The palette's footer shows the copy keys for the highlighted row, without opening anything: the review on #88
    /// asked for them next to ↵ / More, since the actions list is only reached once you already know they exist.
    func testPaletteFooterShowsTheCopyShortcuts() {
        openPalette("github")
        for keycap in ["⇧⌘C", "⌥⌘C", "⌃⌘C"] {
            XCTAssertTrue(app.staticTexts[keycap].firstMatch.waitForExistence(timeout: 5),
                          "the palette's footer does not show \(keycap)")
        }
        // Each one names what it copies, so the keycap is not left to be guessed.
        for label in ["Username", "Password", "Code"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.exists, "the footer's \(label) hint lost its name")
        }
        // A card has neither a username nor a password, so its footer shows no copy keys. (Escape first: the
        // window's palette button toggles, so clicking it again would close the palette instead of reopening it.)
        paletteField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(paletteField.waitForNonExistence(timeout: 5), "the palette did not close for the second search")
        openPalette("visa")
        XCTAssertTrue(app.staticTexts["Open"].firstMatch.waitForExistence(timeout: 5), "the palette did not show the card")
        XCTAssertFalse(app.staticTexts["⇧⌘C"].firstMatch.exists, "a card's footer offered Copy Username")
        XCTAssertFalse(app.staticTexts["⌥⌘C"].firstMatch.exists, "a card's footer offered Copy Password")
    }

    /// ⌃⌘N copies the notes — a row that used to carry no keycap at all, because the action had no shortcut. It now
    /// exists on the Item menu too, so the key does the same thing in the vault window.
    func testPaletteCopiesNotes() {
        NSPasteboard.general.clearContents()
        openPalette("github")
        paletteField.typeKey("n", modifierFlags: [.command, .control])
        let notesDeadline = Date.now.addingTimeInterval(4)
        while Date.now < notesDeadline, (clipboard() ?? "").isEmpty { usleep(50_000) }
        XCTAssertTrue(clipboard()?.contains("Recovery codes are in") == true,
                      "⌃⌘N did not copy the highlighted item's notes, got \(clipboard() ?? "nothing")")
        XCTAssertTrue(paletteField.waitForNonExistence(timeout: 5), "the palette stayed open after copying the notes")
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

    func testItemActionAccessibilityLabels() {
        select("GitHub")
        for label in ["Reveal", "Archive", "Favorite", "Edit", "Move to Trash"] {
            XCTAssertTrue(window.toolbars.buttons[label].firstMatch.waitForExistence(timeout: 3),
                          "Missing independently named button: \(label)")
        }
    }

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
        let header = window.descendants(matching: .any)["Item Hero Header"].firstMatch
        let username = window.buttons["Copy Username"].firstMatch
        let passwordTile = window.buttons["Copy Password"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(username.waitForExistence(timeout: 3))
        XCTAssertTrue(passwordTile.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(username.frame.minY, header.frame.maxY, "username row should sit below the header card")
        XCTAssertGreaterThan(passwordTile.frame.minY, username.frame.maxY, "password row should sit below the username row")
        let passwordHeight = passwordTile.frame.height
        passwordTile.click()
        XCTAssertEqual(passwordTile.frame.height, passwordHeight, accuracy: 0.5, "password tile height changed while copied")
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(passwordTile.frame.height, passwordHeight, accuracy: 0.5, "password tile height changed during icon animation")
        XCTAssertTrue(window.staticTexts["Password"].exists, "password title disappeared after copying")
        XCTAssertFalse(window.staticTexts["Copied"].exists, "copied text appeared in the password title")
        XCTAssertEqual(clipboard(), "m7Kq#vR2!tLp9wZe$Hu", "password tile did not copy the password")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(clipboard(), "m7Kq#vR2!tLp9wZe$Hu", "reading the password changed the clipboard to the one-time code")
        let codeTile = window.buttons["Copy One-time code"].firstMatch
        XCTAssertTrue(codeTile.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(codeTile.frame.width, 220, "code tile should keep its wider layout")
        let codeHeight = codeTile.frame.height
        codeTile.click()
        XCTAssertEqual(codeTile.frame.height, codeHeight, accuracy: 0.5, "code tile height changed while copied")
        XCTAssertEqual(clipboard()?.count, 6, "code tile did not copy a 6-digit code")
    }

    func testDetailCopyActions() {
        select("GitHub")
        let username = window.buttons["Copy Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(username.frame.width, 200, "The whole username row should be clickable")
        let preview = XCTAttachment(screenshot: window.screenshot())
        preview.name = "Item detail — compact copy actions"
        preview.lifetime = .keepAlways
        add(preview)
        username.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        XCTAssertEqual(clipboard(), "alexchen")
        XCTAssertEqual(username.value as? String, "Copied")
        XCTAssertFalse(window.staticTexts["m7Kq#vR2!tLp9wZe$Hu"].exists, "Copying username revealed the password")

        let website = window.buttons["Copy Website"].firstMatch
        XCTAssertTrue(website.exists, "Website copy should be visible without a context menu")
        website.click()
        XCTAssertEqual(clipboard(), "https://github.com/login?return_to=%2Fsettings%2Fsecurity")
        XCTAssertEqual(website.value as? String, "Copied")
        XCTAssertTrue(window.buttons["Open website"].firstMatch.exists, "Website opening needs its own action")

        window.buttons["Copy Notes"].firstMatch.click()
        XCTAssertEqual(clipboard(), "Recovery codes are in the “GitHub recovery” note.")

    }

    func testDetailContextMenuHasAllItemActions() {
        select("GitHub")
        let passwordTile = window.buttons["Copy Password"].firstMatch
        XCTAssertTrue(passwordTile.waitForExistence(timeout: 3))
        passwordTile.rightClick()

        for action in ["Copy Username", "Copy Password", "Show Password in Large Type",
                       "Copy One-Time Code", "Copy Notes", "Open Website", "Copy Website",
                       "Edit", "Clone", "Remove from Favorites", "Archive", "Move to Trash…"] {
            XCTAssertTrue(app.descendants(matching: .any)[action].firstMatch.waitForExistence(timeout: 2),
                          "Missing detail context action: \(action)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    func testContextMenuUsesTheClickedRowWhileDetailIsOpen() {
        select("GitHub")

        let proton = window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Proton Mail")).firstMatch
        XCTAssertTrue(proton.waitForExistence(timeout: 3))
        proton.rightClick()
        XCTAssertTrue(app.descendants(matching: .any)["Add to Favorites"].firstMatch.waitForExistence(timeout: 2),
                      "item menu came from the open GitHub detail instead of Proton Mail")
        app.typeKey(.escape, modifierFlags: [])

        let logins = sidebarRow("Logins")
        XCTAssertTrue(logins.waitForExistence(timeout: 3))
        logins.rightClick()
        XCTAssertTrue(app.descendants(matching: .any)["New Login"].firstMatch.waitForExistence(timeout: 2),
                      "sidebar menu came from another context-menu surface")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCardFieldsCopyWithoutRevealing() {
        select("Travel Visa")
        window.buttons["Copy Card number"].firstMatch.click()
        XCTAssertEqual(clipboard(), "4111111111116411", "Copy must use raw digits rather than display formatting")
        XCTAssertFalse(window.staticTexts["4111 1111 1111 6411"].exists)

        window.buttons["Copy Cardholder"].firstMatch.click()
        XCTAssertEqual(clipboard(), "Alex Chen")
        XCTAssertEqual(window.buttons["Copy Card number"].firstMatch.value as? String, "")

        window.buttons["Copy Security code"].firstMatch.click()
        XCTAssertEqual(clipboard(), "123")
        XCTAssertFalse(window.staticTexts["123"].exists, "Copying a secret field must leave it masked")
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
