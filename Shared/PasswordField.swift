import AppKit
import SwiftUI

extension Color {
    /// A quiet field fill: native in light mode, softly lifted in dark mode.
    static let formInputFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.controlBackgroundColor
    })
}

/// Rounded field used on the login, unlock and AutoFill screens.
struct SoftFieldStyle: TextFieldStyle {
    var height: CGFloat = 38
    /// Room on the right for an accessory inside the field (the reveal button).
    var trailingInset: CGFloat = 0
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.leading, 12)
            .padding(.trailing, 12 + trailingInset)
            .frame(height: height)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    // Focus: a firmer neutral outline — no colour, no glow.
                    .strokeBorder(focused ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// A password field with a show/hide button. Toggling keeps the cursor in the field.
struct PasswordField: View {
    enum Look { case soft, rounded, plain }

    /// Catalog key ("Master password"). Resolved before it reaches the field, so the help tag
    /// doesn't look it up again and show "localized string not found".
    let title: String
    @Binding var text: String
    var look: Look = .soft
    /// Catalog key for the placeholder. Empty shows no placeholder.
    var prompt: String? = nil
    /// Optional link to the caller's focus state.
    var isFocused: Binding<Bool>?
    var onSubmit: () -> Void = {}

    @State private var visible = false
    /// ⌥ peek, after a short hold, and only while this field is focused.
    @State private var optionPeek = false
    @State private var optionDown = false
    @State private var peekWait: Task<Void, Never>?
    @FocusState private var focused: Bool
    /// Caps Lock is on: worth a word while typing a password you can't see.
    @State private var capsLock = NSEvent.modifierFlags.contains(.capsLock)
    @State private var capsMonitor: Any?

    private var revealed: Bool { visible || optionPeek }
    /// This field, or the caller's focus binding (the unlock door drives focus from outside).
    private var fieldActive: Bool { focused || isFocused?.wrappedValue == true }
    private var showsCapsLock: Bool { capsLock && fieldActive && !revealed }

    var body: some View {
        ZStack(alignment: .trailing) {
            // One field draws both the letters and the caret. An overlay of the password on top of a
            // still-secure field leaves the caret on the bullet widths, which are wider than the letters,
            // so it sits in a gap. Swapping fields drops focus; the next turn puts it back.
            styled(Group {
                // Plain strings: the help tag must not look these keys up a second time.
                if revealed {
                    TextField(spokenTitle, text: $text, prompt: Text(verbatim: spokenPrompt))
                } else {
                    SecureField(spokenTitle, text: $text, prompt: Text(verbatim: spokenPrompt))
                }
            }
            .textContentType(.password)
            .labelsHidden()
            .focused($focused)
            .onSubmit(onSubmit))

            HStack(spacing: 0) {
                if showsCapsLock {
                    Image(systemName: "capslock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 26)
                        .help(Self.localize("Caps Lock is on"))
                        .accessibilityLabel(Self.localize("Caps Lock is on"))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                Button {
                    toggleReveal()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(revealHelp)
                .accessibilityLabel(revealLabel)
            }
            .zIndex(1)
            .padding(.trailing, look == .plain ? 0 : 6)
            .animation(.snappy(duration: 0.2), value: showsCapsLock)
        }
        .background { SelectionWash(active: fieldActive) }
        .onAppear {
            capsLock = NSEvent.modifierFlags.contains(.capsLock)
            optionDown = Self.optionAlone(NSEvent.modifierFlags)
            capsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                if event.type == .flagsChanged {
                    capsLock = event.modifierFlags.contains(.capsLock)
                    optionDown = Self.optionAlone(event.modifierFlags)
                    return event
                }
                guard fieldActive, Self.revealChord(event) else { return event }
                toggleReveal()
                return nil
            }
        }
        .onDisappear {
            capsMonitor.map(NSEvent.removeMonitor)
            capsMonitor = nil
            peekWait?.cancel()
            visible = false
            optionPeek = false
        }
        .onChange(of: revealed) { _, _ in
            Task { @MainActor in focused = true }
        }
        .onChange(of: optionDown) { _, held in setOptionPeek(held) }
        .onChange(of: focused) { _, now in
            if isFocused?.wrappedValue != now { isFocused?.wrappedValue = now }
            if now, optionDown {
                setOptionPeek(true)
            } else if !now, !optionDown {
                peekWait?.cancel()
                optionPeek = false
            }
        }
        .onChange(of: isFocused?.wrappedValue) { _, wanted in
            if let wanted, wanted != focused { focused = wanted }
            if wanted == true, optionDown { setOptionPeek(true) }
        }
        .onAppear { if isFocused?.wrappedValue == true { focused = true } }
    }

    /// The field's name, already translated. A second lookup from the help tag fails.
    private var spokenTitle: String { Self.localize(title) }
    /// Placeholder. No prompt means an empty one, so a labelled field doesn't repeat its name inside.
    private var spokenPrompt: String { prompt.map(Self.localize) ?? "" }

    private var revealHelp: String {
        if revealed {
            String(localized: "Hide password")
        } else {
            String(localized: "Reveal (⌥⌘R, or hold ⌥)")
        }
    }

    private var revealLabel: String {
        if revealed {
            String(localized: "Hide password")
        } else {
            String(localized: "Show password")
        }
    }

    /// Looks the catalog key up once, here, where the app's language is known.
    private static func localize(_ key: String) -> String {
        String(localized: String.LocalizationValue(stringLiteral: key))
    }

    /// Show or hide. ⌥⌘R toggles; holding ⌥ peeks and lets go of it hides again.
    private func toggleReveal() {
        if revealed {
            visible = false
            optionPeek = false
            peekWait?.cancel()
        } else {
            visible = true
        }
        focused = true
    }

    /// ⌥⌘R, and not a key repeat. Shift and Control stay out so this isn't a character the field should keep.
    private static func revealChord(_ event: NSEvent) -> Bool {
        guard !event.isARepeat, event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.option) && flags.contains(.command) && !flags.contains(.shift) && !flags.contains(.control)
    }

    /// ⌥ by itself. Caps Lock and the extra flags macOS attaches to the key do not count; Shift, Control and Command do.
    private static func optionAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .control, .option, .command]) == .option
    }

    /// A quick tap of ⌥ does nothing. Letting go waits, then the field masks again.
    private func setOptionPeek(_ held: Bool) {
        peekWait?.cancel()
        if !held {
            peekWait = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                optionPeek = false
            }
            return
        }
        guard fieldActive else { return }
        peekWait = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, fieldActive, optionDown else { return }
            optionPeek = true
        }
    }

    /// Room for the eye, plus the Caps Lock mark when it is showing.
    private var trailingRoom: CGFloat { showsCapsLock ? 54 : 32 }

    @ViewBuilder
    private func styled(_ field: some View) -> some View {
        switch look {
        case .soft: field.textFieldStyle(SoftFieldStyle(trailingInset: trailingRoom))
        case .rounded: field.textFieldStyle(.roundedBorder).padding(.trailing, trailingRoom)
        case .plain: field.textFieldStyle(.plain).padding(.trailing, trailingRoom + 6)
        }
    }
}

/// The field editor's selection is an opaque light slab, which reads as a white box on the dark capsule.
/// A translucent wash keeps the letters in the label colour.
private struct SelectionWash: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.active = active
        context.coordinator.apply(view)
        // The field editor attaches after this update when focus has just moved.
        Task { @MainActor in context.coordinator.apply(view) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var active = false
        private var editor: NSTextView?
        private var previous: [NSAttributedString.Key: Any]?

        func apply(_ view: NSView?) {
            guard active, let editor = view?.window?.firstResponder as? NSTextView, editor.isFieldEditor else {
                restore()
                return
            }
            if self.editor !== editor {
                restore()
                previous = editor.selectedTextAttributes
                self.editor = editor
            }
            let dark = editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            editor.selectedTextAttributes = [
                .backgroundColor: (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.28 : 0.16),
                .foregroundColor: NSColor.labelColor,
            ]
            editor.insertionPointColor = .labelColor
        }

        func restore() {
            editor?.selectedTextAttributes = previous ?? [:]
            editor = nil
            previous = nil
        }
    }
}

extension FocusState<Bool>.Binding {
    /// A plain Bool binding over a FocusState, for `PasswordField(isFocused:)`.
    var wrappedBinding: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
