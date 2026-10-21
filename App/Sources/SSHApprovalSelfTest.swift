#if DEBUG
import AppKit
import SSHAgent

/// Exercises the production window with reference-only synthetic prompts before any AppModel is created.
@MainActor
enum SSHApprovalSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-ssh-presentation") else { return }
        let application = NSApplication.shared
        Task { await runChecks() }
        application.run()
        exit(1)
    }

    private static func runChecks() async {
        var failures = 0
        func check(_ passed: Bool, _ message: String) {
            print(passed ? "PASS" : "FAIL", message)
            if !passed { failures += 1 }
        }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            print("FAIL presentation probe requires a running Finder and unlocked desktop")
            exit(1)
        }
        let witness = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        witness.title = "Synthetic vault window — must remain hidden"
        witness.isReleasedWhenClosed = false
        witness.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.yieldActivation(to: finder)
        _ = finder.activate()
        try? await Task.sleep(for: .milliseconds(500))
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier,
              "probe starts with Finder in front")

        let panel = SSHApprovalPanel()
        var decisions: [SSHChoice] = []
        let prompt = SSHPrompt(id: UUID(), trustKey: "synthetic", displayName: "Terminal", via: "ssh",
                               path: "/usr/bin/ssh", keyID: "synthetic", keyName: "Synthetic development key",
                               appPath: "/System/Applications/Utilities/Terminal.app")
        let deadline = ContinuousClock.now.advanced(by: SSHApprovalQueue.timeout)
        panel.show(prompt, deadline: deadline, pendingCount: 1, leadsWithUntilLock: false) { decisions.append($0) }
        try? await Task.sleep(for: .milliseconds(500))
        print("PRESENTATION active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) visible=\(panel.window?.isVisible == true) key=\(panel.window?.isKeyWindow == true) onActiveSpace=\(panel.window?.isOnActiveSpace == true) unoccluded=\(panel.window?.occlusionState.contains(.visible) == true) main=\(panel.window?.isMainWindow == true) hidden=\(NSApp.isHidden) frontmostIsSelf=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier && NSApp.activationPolicy() == .accessory,
              "showing approval keeps Finder in front and Triwarden out of the Dock")
        check(!witness.isVisible && !witness.isKeyWindow, "ordinary vault window remains hidden")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier &&
              panel.window?.isVisible == true && panel.window?.isOnActiveSpace == true &&
              panel.window?.occlusionState.contains(.visible) == true,
              "standalone SSH panel is visible while Finder stays in front")
        check(panel.window?.styleMask.contains(.nonactivatingPanel) == true && panel.window?.canBecomeMain == false &&
              panel.window?.hidesOnDeactivate == false, "approval uses an independent nonactivating panel")
        panel.show(prompt, deadline: deadline, pendingCount: 1, leadsWithUntilLock: false, reveal: true) { decisions.append($0) }
        try? await Task.sleep(for: .milliseconds(250))
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier && !witness.isVisible,
              "revealing approval still leaves the main window hidden")
        panel.window?.performClose(nil)
        check(decisions == [.deny] && panel.window?.isVisible == false, "closing the panel denies exactly its displayed request")
        panel.hide()
        check(decisions == [.deny], "programmatic dismissal does not answer another queued request")
        print("SSH presentation self-test: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
