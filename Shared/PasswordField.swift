import AppKit
import SwiftUI

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
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 9, style: .continuous))
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

    let title: LocalizedStringKey
    @Binding var text: String
    var look: Look = .soft
    var prompt: Text? = Text(verbatim: "")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revealed: Bool { visible || optionPeek }
    /// This field, or the caller's focus binding (the unlock door drives focus from outside).
    private var fieldActive: Bool { focused || isFocused?.wrappedValue == true }
    private var showsCapsLock: Bool { capsLock && fieldActive && !revealed }
    private var revealAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Keep the secure field in place. Swapping it for a TextField drops focus, and the unlock
            // door then cancels the peek before the password can be seen.
            styled(
                SecureField(title, text: $text, prompt: prompt)
                    .textContentType(.password)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .opacity(revealed ? 0 : 1)
            )
            .overlay(alignment: .leading) {
                if revealed {
                    Text(verbatim: text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                        .padding(.leading, revealTextInset.leading)
                        .padding(.trailing, revealTextInset.trailing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(revealAnimation, value: revealed)

            HStack(spacing: 0) {
                if showsCapsLock {
                    Image(systemName: "capslock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 26)
                        .help(Text("Caps Lock is on"))
                        .accessibilityLabel(Text("Caps Lock is on"))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                Button {
                    toggleReveal()
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: "⌥⌘R")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(revealed ? Text("Hide password") : Text("Reveal (⌥⌘R, or hold ⌥)"))
                .accessibilityLabel(revealed ? Text("Hide password") : Text("Show password"))
            }
            .zIndex(1)
            .padding(.trailing, look == .plain ? 0 : 6)
            .animation(.snappy(duration: 0.2), value: showsCapsLock)
        }
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

    /// Room for ⌥⌘R and the eye, plus the Caps Lock mark when it is showing.
    private var trailingRoom: CGFloat { showsCapsLock ? 86 : 64 }

    /// Where the revealed characters sit, matching the secure field's own insets so they don't slide.
    private var revealTextInset: (leading: CGFloat, trailing: CGFloat) {
        switch look {
        case .soft: (12, 12 + trailingRoom)
        case .rounded: (8, trailingRoom)
        case .plain: (0, trailingRoom + 6)
        }
    }

    @ViewBuilder
    private func styled(_ field: some View) -> some View {
        switch look {
        case .soft: field.textFieldStyle(SoftFieldStyle(trailingInset: trailingRoom))
        case .rounded: field.textFieldStyle(.roundedBorder).padding(.trailing, trailingRoom)
        case .plain: field.textFieldStyle(.plain).padding(.trailing, trailingRoom + 6)
        }
    }
}

extension FocusState<Bool>.Binding {
    /// A plain Bool binding over a FocusState, for `PasswordField(isFocused:)`.
    var wrappedBinding: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
