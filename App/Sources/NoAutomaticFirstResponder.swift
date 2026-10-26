import AppKit
import SwiftUI

/// Keeps macOS's AutoFill panel from appearing over the app when it launches.
///
/// When a window is restored, AppKit picks its first key view and makes it first responder. If that view is a text
/// field, AppKit's AutoFill heuristic (`NSAutoFillHeuristicController`) offers a fill panel for it — over the vault,
/// before the user has typed anything, and empty, since the app has nothing to offer a search field. The vault list's
/// search field is the window's first text field, so every launch opened that panel.
///
/// The window is given its content view as the first responder instead, so restoration has no text field to pick.
/// Focus the app asks for itself (the lock screen's password, ⌘F) still works: SwiftUI sets it after the window is up.
struct NoAutomaticFirstResponder: ViewModifier {
    func body(content: Content) -> some View {
        content.background { FirstResponderAnchor() }
    }
}

private struct FirstResponderAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Clear() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Clear: NSView {
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Before the window is ordered: this is the window restoration picks the first key view for.
            guard !done, let window, !window.isVisible else { return }
            done = true
            window.initialFirstResponder = window.contentView
        }
    }
}

extension View {
    /// See `NoAutomaticFirstResponder`.
    func noAutomaticFirstResponder() -> some View { modifier(NoAutomaticFirstResponder()) }
}
