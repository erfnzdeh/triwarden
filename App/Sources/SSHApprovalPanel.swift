import AppKit
import SSHAgent
import SwiftUI

/// Presents just the approval. It never activates the app or opens the vault/menu-bar window.
@MainActor
final class SSHApprovalPanel: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private var displayedID: UUID?
    private var choose: ((SSHChoice) -> Void)?

    func show(_ prompt: SSHPrompt, deadline: ContinuousClock.Instant, pendingCount: Int,
              leadsWithUntilLock: Bool, reveal: Bool = false, choose: @escaping (SSHChoice) -> Void) {
        if window == nil {
            let height = min(660, max(460, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
            let panel = SSHSigningPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            panel.title = String(localized: "Approve SSH signing")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.contentMinSize = NSSize(width: 500, height: 460)
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self
            window = panel
        }
        let changed = displayedID != prompt.id
        displayedID = prompt.id
        self.choose = choose
        let view = SSHApprovalView(prompt: prompt, deadline: deadline, pendingCount: pendingCount,
                                   leadsWithUntilLock: leadsWithUntilLock, choose: choose)
            .id(prompt.id)
            .modifier(LiveAppearance())
            .modifier(ReducedMotionPolicy())
        if let host = window?.contentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(view)
        } else {
            window?.contentView = NSHostingView(rootView: AnyView(view))
        }
        if changed || reveal {
            if changed { window?.center() }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        window?.orderOut(nil)
        displayedID = nil
        choose = nil
    }

    func windowWillClose(_ notification: Notification) {
        let decision = choose
        hide()
        decision?(.deny)
    }
}

private final class SSHSigningPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
