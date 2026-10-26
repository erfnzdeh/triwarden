import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// Signed in, vault locked: a vault door fills the window, the master password goes in at its hub (Touch ID just
/// under it), and the account pill sits below. Works offline.
struct UnlockView: View {
    /// Where the door sits in a window of this size (shared with the gate's plates, so they match it exactly).
    static func doorLayout(_ size: CGSize) -> (radius: CGFloat, center: CGPoint) {
        let top: CGFloat = 40
        // Bottom strip: "Not you? Log out" above the account pill.
        let bottom: CGFloat = 100
        let outer = max(130, min((size.width - 32) / 2, (size.height - top - bottom) / 2))
        return (outer / DoorGeometry.frameOuter, CGPoint(x: size.width / 2, y: top + (size.height - top - bottom) / 2))
    }

    @Environment(AppModel.self) private var model
    @Environment(\.vaultDoorFrozen) private var frozen
    @State private var password = ""
    /// With a PIN set, the hub asks for it; this switches to the master password instead.
    @State private var usePassword = false
    @State private var turns = 0
    @State private var errorAt: Date?
    /// While the door assembles itself after a lock, the hub's controls wait.
    @State private var assembling = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let (radius, center) = Self.doorLayout(size)
            let opening = model.unlockOpening || frozen?.opened != nil
            let hubHidden = opening || assembling || (frozen?.closed ?? 1) < 0.5

            ZStack {
                // A layer over the (empty, locked) vault: frosted, then the door's own room on top.
                Rectangle().fill(.ultraThinMaterial)

                VaultDoorStage(radius: radius, center: center, typed: frozen?.typed ?? password.count, turns: turns,
                               busy: frozen?.busy ?? model.isBusy, errorAt: errorAt, openedAt: model.unlockOpenedAt, closedAt: model.lockClosedAt)

                DoorCore(password: $password, focused: $focused, pinMode: pinMode, hasPIN: hasPIN, accountDoor: model.accountDoor != nil,
                         switchMode: { usePassword.toggle(); password = ""; model.errorMessage = nil; focused = true },
                         submit: submit)
                    .shake(on: errorAt)
                    .frame(width: radius * DoorGeometry.core * 2 * 0.84)
                    .position(center)
                    .opacity(hubHidden ? 0 : 1)
                    .scaleEffect(hubHidden ? 0.9 : 1)
                    .blur(radius: hubHidden ? 6 : 0)
                    .animation(.easeOut(duration: 0.25), value: assembling)

                VStack(spacing: 10) {
                    // Above the account pill (was under the hub).
                    if model.accountDoor == nil {
                        HStack(spacing: 4) {
                            Text("Not you?").foregroundStyle(.secondary)
                            Button("Log out") { model.confirmLogOut(model.unlockTarget?.id) }
                                .buttonStyle(.plain).foregroundStyle(.primary).underline()
                        }
                        .font(.system(size: 11))
                    }
                    // Account pill.
                    AccountLine()
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)
                .opacity(opening ? 0 : 1)
            }
            // The calm unlock fades the controls quickly, then the gate's plates (which don't carry them) cover the door.
            .animation(.easeIn(duration: model.unlockOpenedAt == nil ? AppModel.gateFade : 0.28), value: opening)
        }
        .ignoresSafeArea()
        // An account's door (other accounts open behind it): Esc goes back to all of them.
        .background {
            if model.accountDoor != nil {
                Button("") { model.accountFocus = nil }.keyboardShortcut(.cancelAction).hidden()
            }
        }
        // Switched to another locked account from the pill: start clean.
        .onChange(of: model.accountDoor) { _, door in
            guard door != nil else { return }
            password = ""; usePassword = false; focused = true
        }
        .onAppear {
            focused = true
            // Locked from the vault: the door closes over it.
            // (The gate closes first; the door's own timing comes from model.lockClosedAt, shared by every copy.)
            // Without the full door animation (no lockClosedAt), the gate's plates part onto a still door and the
            // controls fade in.
            if model.lockClosing {
                assembling = true
                let wait = model.lockClosedAt.map { max(0, $0.timeIntervalSinceNow) + 0.56 } ?? 0.06
                Task {
                    try? await Task.sleep(for: .seconds(wait))
                    assembling = false
                }
            }
        }
        .onChange(of: model.errorMessage) { _, message in
            // A wrong password: the light warms to red and the tumblers rewind to an empty field.
            guard message != nil else { return }
            errorAt = .now
            password = ""
            // Next turn: clearing the field in the same frame steals focus again.
            Task { @MainActor in focused = true }
        }
        .onChange(of: model.isBusy) { _, busy in
            // Key derivation disables the field and drops first responder. Return it once that ends in failure.
            guard !busy, model.errorMessage != nil else { return }
            Task { @MainActor in focused = true }
        }
        .onChange(of: password.count) { old, new in
            // The pins repeat every 12 notches, so a paste (or a clear) only needs the shortest turn to the same place;
            // one character at a time clicks a single notch.
            var delta = (new - old) % 12
            if delta > 6 { delta -= 12 } else if delta < -6 { delta += 12 }
            let paste = abs(new - old) > 1
            withAnimation(paste ? .easeInOut(duration: 0.7) : .spring(duration: 0.5, bounce: 0.1)) { turns += delta }
        }
        .onChange(of: password) { _, typed in if !typed.isEmpty, model.errorMessage != nil { model.errorMessage = nil } }
        .onChange(of: password.count) { _, count in model.doorDial.typed = count }
        .onChange(of: turns) { _, turns in model.doorDial.turns = turns }
    }

    private var hasPIN: Bool { model.unlockTarget.map { model.isPINEnabled($0.id) } ?? false }
    private var pinMode: Bool { hasPIN && !usePassword }

    private func submit() {
        guard !password.isEmpty, !model.isBusy, !model.unlockOpening else { return }
        let typed = password
        Task { if pinMode { await model.unlockWithPIN(typed) } else { await model.unlock(password: typed) } }
    }
}

/// What sits in the door's hub: the master password and what's happening.
private struct DoorCore: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Binding var password: String
    var focused: FocusState<Bool>.Binding
    /// Asking for the PIN rather than the master password.
    var pinMode = false
    var hasPIN = false
    /// One account's door over the open vault: the way out is back to all accounts, not logging out.
    var accountDoor = false
    var switchMode: () -> Void = {}
    let submit: () -> Void

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 12) {
            Image(systemName: model.unlockOpening ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            UnlockCapsuleField(pinMode: pinMode, password: $password, focused: focused.wrappedBinding, submit: submit)

            // Touch ID just under the field: an icon that names itself on hover, or while it prompts.
            if model.touchIDEnabled { InlineTouchID() }

            Group {
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(dark ? Color(red: 1, green: 0.55, blue: 0.55) : Color(red: 0.8, green: 0.2, blue: 0.2))
                } else if model.isBusy {
                    Text("Turning the tumblers…").foregroundStyle(.secondary)
                } else {
                    UnlockReturnHint(hasInput: !password.isEmpty)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: model.errorMessage)
            .animation(.easeOut(duration: 0.2), value: model.isBusy)

            if hasPIN || accountDoor {
                HStack(spacing: 4) {
                    if hasPIN {
                        Button(pinMode ? "Use master password" : "Use PIN", action: switchMode)
                            .buttonStyle(.plain).foregroundStyle(.primary).underline()
                        if accountDoor { Text(verbatim: "·").foregroundStyle(.tertiary) }
                    }
                    if accountDoor {
                        Button("Show all accounts") { model.accountFocus = nil }
                            .buttonStyle(.plain).foregroundStyle(.primary).underline()
                            .help(Text("Back to the open accounts (Esc)"))
                    }
                }
                .font(.system(size: 11))
                .padding(.top, -4)
            }
        }
    }
}

/// "Press return to unlock", once the field has something to submit. Empty, the line stays so the door doesn't jump.
struct UnlockReturnHint: View {
    var hasInput: Bool

    var body: some View {
        Text("Press ↵ to unlock")
            .foregroundStyle(.tertiary)
            .opacity(hasInput ? 1 : 0)
            .accessibilityLabel(Text("Press Return to unlock"))
            .accessibilityHidden(!hasInput)
            .animation(.easeOut(duration: 0.2), value: hasInput)
    }
}

/// The master password (or PIN) in a capsule with its unlock arrow: the door's hub and a locked account's pane.
struct UnlockCapsuleField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var pinMode = false
    @Binding var password: String
    var focused: Binding<Bool>
    let submit: () -> Void

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 4) {
            PasswordField(title: pinMode ? "PIN" : "Master password", text: $password, look: .plain,
                          prompt: pinMode ? "PIN" : "Master password",
                          isFocused: focused, onSubmit: submit)
                .font(.system(size: 13))
            Button(action: submit) {
                ZStack {
                    if model.isBusy {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                }
                .foregroundStyle(password.isEmpty ? Color.secondary : Color.white)
                .frame(width: 26, height: 26)
                .background(password.isEmpty ? Color.primary.opacity(0.08) : Color.brandButton, in: .circle)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty || model.isBusy)
            .help(Text("Unlock"))
            .accessibilityLabel(Text("Unlock"))
            .animation(.easeOut(duration: 0.15), value: password.isEmpty)
        }
        .padding(.leading, 14).padding(.trailing, 5)
        .frame(height: 36)
        .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.9), in: .capsule)
        .overlay(Capsule().strokeBorder(focused.wrappedValue ? Color.primary.opacity(dark ? 0.35 : 0.3) : Color.primary.opacity(0.1),
                                        lineWidth: focused.wrappedValue ? 1.5 : 1))
        .animation(.easeOut(duration: 0.15), value: focused.wrappedValue)
    }
}

/// Whose vault this is, as a quiet pill that opens a menu: the other accounts on this Mac, and adding one.
private struct AccountLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Menu {
            if model.accounts.count > 1 {
                ForEach(model.accounts, id: \.id) { account in
                    Button {
                        if model.accountDoor != nil {
                            // Over the open vault: switch the focus (an open account just lifts the door).
                            model.accountFocus = account.id
                        } else {
                            model.unlockTargetID = account.id
                        }
                        model.errorMessage = nil
                    } label: {
                        if account.id == model.unlockTarget?.id {
                            Label { Text(verbatim: account.email) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: account.email)
                        }
                    }
                }
                Divider()
            }
            Button("Add Account…", systemImage: "person.badge.plus") {
                model.beginAddAccount(sameServerAs: model.unlockTarget)
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(Text(model.accounts.count > 1 ? "Switch account" : "Add another account"))
    }

    private var label: some View {
        let account = model.unlockTarget
        let dark = scheme == .dark
        return HStack(spacing: 8) {
            if let account { AccountAvatar(account: account, size: 24) }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: account?.email ?? "").font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: account?.serverSummary ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 5)
        .background(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.7), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(dark ? 0.1 : 0.08)))
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Embedded Touch ID prompt (the system's own sensor glyph) that unseals every enrolled account in place.
private struct InlineTouchID: View {
    @Environment(AppModel.self) private var model
    @State private var context = LAContext()
    @State private var attempt = 0
    @State private var prompting = false
    @State private var hovering = false
    @State private var labelWidth: CGFloat = 0

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let open = hovering || prompting
        HStack(spacing: 0) {
            ZStack {
                // The system glyph only draws during a prompt; show ours otherwise.
                Image(systemName: "touchid").font(.system(size: 17)).foregroundStyle(.secondary)
                    .opacity(prompting ? 0 : 1)
                TouchIDGlyph(context: context).opacity(prompting ? 1 : 0)
            }
            .frame(width: 24, height: 24)
            .padding(.leading, 8)

            Text("Touch ID to unlock").font(.system(size: 12, weight: .semibold))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                .padding(.leading, 8).padding(.trailing, 10)
                .opacity(open ? 1 : 0)
                .frame(width: open ? labelWidth + 18 : 0, alignment: .leading)
                .clipped()
        }
        .padding(.trailing, 8)
        .frame(height: 36, alignment: .leading)
        // Closed, it's just the glyph; hovering wraps it in the pill that names it.
        .background(open ? AnyShapeStyle(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.7)) : AnyShapeStyle(.clear),
                    in: .capsule)
        .overlay(Capsule().strokeBorder(open ? Color.primary.opacity(dark ? 0.1 : 0.08) : .clear))
        .clipShape(.capsule)
        .contentShape(.capsule)
        .onHover { h in withAnimation(.snappy(duration: 0.28, extraBounce: 0)) { hovering = h } }
        .onTapGesture { if !prompting { attempt += 1 } }
        .help(open ? Text("Try Touch ID again") : Text("Touch ID to unlock"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Touch ID to unlock"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !prompting { attempt += 1 } }
        .task(id: attempt) {
            // A fresh context per attempt; the embedded view shows its prompt inline.
            let fresh = LAContext()
            context = fresh
            try? await Task.sleep(for: .milliseconds(150)) // let the view attach to the new context
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) { prompting = true }
            await model.unlockWithTouchID(context: fresh)
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) { prompting = false }
        }
    }
}

private struct TouchIDGlyph: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // LAAuthenticationView is bound to one LAContext; swap the child when it changes.
        if (container.subviews.first as? LAAuthenticationView)?.context !== self.context { install(in: container) }
    }

    private func install(in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let glyph = LAAuthenticationView(context: self.context, controlSize: .small)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }
}
