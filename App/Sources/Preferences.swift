import Foundation
import Security
import SwiftUI

/// UserDefaults keys for settings. Secrets (header values) live in the Keychain instead.
enum Pref {
    static let appearance = "appearance"           // "system" | "light" | "dark"
    static let autoLockMinutes = "autoLockMinutes" // 0 = never
    static let lockOnSleep = "lockOnSleep"
    /// Opt-in: the vault door drifts on the lock screen and plays its open/close sequences (by default only the gate's
    /// plates slide). A new key, so everyone starts with it off, including people who had the old default
    /// `lockAnimations` (retired: it was on by default, so its stored value says nothing about what anyone chose).
    static let fullDoorAnimation = "fullDoorAnimation"
    static let clipboardSeconds = "clipboardSeconds" // 0 = never clear
    static let showIcons = "showIcons"
    static let sshAgent = "sshAgent"                 // serve SSH key items over the agent socket
    static let sshApprovalSeconds = "sshApprovalSeconds" // 0 = ask for every signature
    static let cli = "cli"                               // answer the `cw` command
    static let cliApprovalSeconds = "cliApprovalSeconds"
    static let browser = "browser"                       // answer the Safari/Chrome extension
    static let checkUpdates = "checkUpdates"             // opt-in: look at GitHub's latest release daily
    static let codeAfterPassword = "codeAfterPassword"   // after a password is pasted, the clipboard holds its code
    static let hideFromCapture = "hideFromCapture"       // windows stay out of screen sharing, recordings and screenshots
    static let timeoutAction = "timeoutAction"           // after inactivity: "lock" or "logOut" (accounts may override)
    static let showMenuBar = "showMenuBar"               // the menu bar icon and its panel
    static let closeToMenuBar = "closeToMenuBar"         // closing the window leaves the Dock; Triwarden waits in the menu bar
    /// Opt-in: ask the front browser for its tab address (Automation). A new key, so it stays off until chosen.
    static let matchFrontTab = "matchFrontTab"
    /// The menu bar and palette reminder was dismissed. Turning the feature off sets this too, so it does not return.
    static let matchFrontTabDismissed = "matchFrontTabDismissed"

    static func register() {
        UserDefaults.standard.register(defaults: [
            appearance: "system", autoLockMinutes: 15, lockOnSleep: true, fullDoorAnimation: false, clipboardSeconds: 30,
            codeAfterPassword: true, hideFromCapture: false, timeoutAction: "lock", // opt-in: some screen tools and recordings need the window
            showMenuBar: true, closeToMenuBar: false, matchFrontTab: false, matchFrontTabDismissed: false,
        ])
        UserDefaults.standard.removeObject(forKey: "lockAnimations") // retired (see fullDoorAnimation)
    }

    static var colorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: appearance) {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
