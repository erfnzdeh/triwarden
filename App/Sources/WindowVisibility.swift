import AppKit
import SwiftUI

extension EnvironmentValues {
    /// False while the window can't be seen: ordered out (the palette and the menu bar panel stay built while
    /// closed), minimized, covered by other windows, or the app hidden. Live clocks rest then. True wherever nothing
    /// tracks it, so a view shown elsewhere keeps running.
    @Entry var windowVisible = true
}

extension View {
    /// Follows whether this window can be seen and tells the views inside it (`windowVisible`).
    func tracksWindowVisibility() -> some View { modifier(WindowVisibilityTracking()) }
}

private struct WindowVisibilityTracking: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowVisible, visible)
            .background {
                WindowVisibilityProbe(visible: $visible)
                    .allowsHitTesting(false)
            }
    }
}

/// Tracks the actual hosting window, including minimization and occlusion, without polling.
struct WindowVisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool
    /// Also counts the window as unseen while another app is in front (the vault door's idle drift rests then).
    var needsActiveApp = false

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        update(view)
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        update(view)
    }

    private func update(_ view: VisibilityView) {
        let visible = $visible
        view.needsActiveApp = needsActiveApp
        view.changed = { if visible.wrappedValue != $0 { visible.wrappedValue = $0 } }
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        view.changed = nil
    }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        var needsActiveApp = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    notifications.addObserver(self, selector: #selector(refresh), name: name, object: window)
                }
                for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                             NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    notifications.addObserver(self, selector: #selector(refresh), name: name, object: nil)
                }
            }
            refresh()
        }

        @objc private func refresh() {
            // Window attachment can happen during a SwiftUI update. Publish on the next main-loop turn,
            // reading current state so queued notifications cannot restore an outdated visibility value.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changed?((NSApp.isActive || !self.needsActiveApp) && !NSApp.isHidden && self.window.map {
                    $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                } == true)
            }
        }
    }
}
