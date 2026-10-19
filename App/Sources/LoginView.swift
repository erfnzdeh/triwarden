import AppKit
import SwiftUI

/// Login: the vault door on the left, a calm native form on the right.
/// The stage bleeds to the window edge so the traffic lights sit on it, and hides on narrow windows.
struct LoginView: View {
    var body: some View {
        GeometryReader { geo in
            let showStage = geo.size.width >= 820
            HStack(spacing: 0) {
                if showStage {
                    LoginDoorStage()
                        .frame(width: min(max(geo.size.width * 0.42, 360), 520))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ScrollView {
                    LoginForm()
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .animation(.snappy(duration: 0.3), value: showStage)
        }
        // One calm surface for the page (the window's base, as under the vault's panels): no washes meeting.
        .background(Color.windowBase)
        .ignoresSafeArea()
    }
}

private struct LoginForm: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    /// Bumped by each refusal, to shake the password field.
    @State private var refusals = 0
    @State private var code = ""
    @AppStorage("rememberEmail") private var rememberEmail = true
    @AppStorage("ssoIdentifier") private var ssoIdentifier = ""
    @State private var askingSSO = false
    @FocusState private var focus: Field?

    enum Field { case server, email, password, code }
    private var passwordFocus: Binding<Bool> {
        Binding(get: { focus == .password }, set: { if $0 { focus = .password } else if focus == .password { focus = nil } })
    }

    private enum Step: Equatable { case credentials, authenticator, emailCode, ssoPassword }

    private var step: Step {
        switch model.phase {
        case .twoFactor: .authenticator
        case .deviceVerification: .emailCode
        case .ssoPassword: .ssoPassword
        default: .credentials
        }
    }

    private var title: LocalizedStringKey {
        switch step {
        case .credentials: "Welcome back"
        case .authenticator: "Two-step verification"
        case .emailCode: "Verify this Mac"
        case .ssoPassword: "Unlock your vault"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch step {
        case .credentials: "Sign in to your Bitwarden or Vaultwarden vault."
        case .authenticator: "Enter the 6-digit code from your authenticator app."
        case .emailCode: "Bitwarden emailed a verification code to \(model.email)."
        case .ssoPassword: "Signed in as \(model.email). Your master password decrypts the vault on this Mac."
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if step == .credentials {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Server")
                    ServerPicker(selection: $model.serverKind)
                    if model.serverKind == .selfHosted {
                        TextField("Server URL", text: $model.serverURL, prompt: Text(verbatim: "https://vault.example.com"))
                            .textFieldStyle(SoftFieldStyle(trailingInset: 22))
                            .textContentType(.URL)
                            .focused($focus, equals: .server)
                            .onSubmit { model.checkServer() }
                            .labelsHidden()
                            .overlay(alignment: .trailing) { ServerStatusBadge(status: model.serverStatus).padding(.trailing, 12) }
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    ServerStatusLine(status: model.serverStatus)
                        .padding(.top, 4) // a breath between the field and what it says about the server
                    if model.serverKind == .selfHosted { CustomEnvironmentFields().padding(.top, 4) }
                }

                VStack(alignment: .leading, spacing: 14) {
                    LabeledField("Email") {
                        TextField("Email", text: $model.email, prompt: Text(verbatim: "you@example.com"))
                            .textContentType(.username)
                            .focused($focus, equals: .email)
                    }
                    LabeledField("Master password", accessory: { ForgotPasswordButton(email: model.email) }) {
                        PasswordField(title: "Master password", text: $password, isFocused: passwordFocus)
                            .shake(on: refusals)
                    }
                    Toggle("Remember email", isOn: $rememberEmail)
                        .toggleStyle(TrailingSwitchStyle(size: .mini))
                        .font(.system(size: 12))
                }
                .textFieldStyle(SoftFieldStyle())
            } else if step == .ssoPassword {
                LabeledField("Master password") {
                    PasswordField(title: "Master password", text: $password, isFocused: passwordFocus)
                        .shake(on: refusals)
                }
                .textFieldStyle(SoftFieldStyle())
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // A full code goes straight to the server; a refused one shows in red until it's edited.
                    CodeEntry(code: $code, rejected: model.errorMessage != nil && code.count == 6 && !model.isBusy) { submit() }
                    if step == .emailCode {
                        ResendCodeButton { await model.login(password: password, code: nil) }
                    }
                }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if model.isBusy { ProgressView().controlSize(.small).tint(.white) }
                        Group {
                            switch step {
                            case .credentials: Text("Log in")
                            case .ssoPassword: Text("Unlock")
                            default: Text("Verify")
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)

                if step == .credentials && model.serverKind == .selfHosted {
                    HStack(spacing: 10) {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                        Text("or").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                    }
                    .padding(.vertical, 2)
                    Button { askingSSO = true } label: {
                        Label("Log in with single sign-on", systemImage: "building.2")
                    }
                    .buttonStyle(AppButtonStyle(kind: .secondary, large: true))
                    .disabled(model.isBusy || model.deviceLogin != nil)
                    if let waiting = model.deviceLogin {
                        DeviceLoginCard(waiting: waiting)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        Button { Task { await model.loginWithDevice() } } label: {
                            Label("Log in with another device", systemImage: "iphone.and.arrow.forward")
                        }
                        .buttonStyle(AppButtonStyle(kind: .secondary, large: true))
                        .disabled(model.isBusy)
                    }
                }
                if step != .credentials {
                    Button("Back") { code = ""; password = ""; model.cancelChallenge() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else if model.addingAccount {
                    Button("Cancel") { model.cancelAddAccount() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 4)

            // Unregistered official builds: say up front, quietly, what the launch reminder will ask about later.
            if step == .credentials, !model.addingAccount, model.license.isConfigured, !model.license.isRegistered {
                LicenseNote()
            }
        }
        .frame(width: 380)
        .alert("Single sign-on", isPresented: $askingSSO) {
            TextField("SSO identifier", text: $ssoIdentifier)
            Button("Continue") { Task { await model.loginWithSSO(identifier: ssoIdentifier) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your organization's SSO identifier. On Vaultwarden any value works.")
        }
        .onChange(of: step) { _, new in if new == .ssoPassword { password = ""; focus = .password } }
        .animation(.snappy(duration: 0.25), value: step)
        .animation(.snappy(duration: 0.25), value: model.serverKind)
        .animation(.easeOut(duration: 0.2), value: model.errorMessage)
        .onChange(of: model.errorMessage) { _, message in if message != nil, step == .credentials || step == .ssoPassword { refusals += 1 } }
        .onAppear {
            focus = model.email.isEmpty ? .email : .password
            model.checkServer()
        }
        .onChange(of: model.serverKind) { model.checkServer() }
        // Typing only clears the old answer; the server is asked once the field is left (or Return is pressed).
        .onChange(of: model.serverURL) { model.serverURLEdited() }
        .onChange(of: focus) { old, _ in if old == .server { model.checkServer() } }
        .onChange(of: step) { _, new in if new != .credentials { code = ""; focus = .code } }
    }

    private func submit() {
        guard !model.isBusy else { return }
        Task {
            if step == .ssoPassword {
                await model.completeSSO(password: password)
            } else {
                await model.login(password: password, code: step == .credentials ? nil : code)
            }
            if model.isUnlocked {
                password = ""
                code = ""
                if !rememberEmail { UserDefaults.standard.removeObject(forKey: "email") }
            }
        }
    }
}

/// One neutral line under the form: every feature is free for personal use; work accounts need a license.
private struct LicenseNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "heart").font(.system(size: 10, weight: .semibold))
            Text("Free for personal use, with every feature. Work accounts need a license.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Learn More") { model.license.openPricing() }
                .buttonStyle(.plain)
                .underline()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

/// Full-width brand button: flat tail sky with a white label when ready, a quiet neutral fill when not.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        configuration.label
            .foregroundStyle(isEnabled ? (contrast == .increased ? Color.onBrandFill : Color.white) : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                if isEnabled {
                    Capsule().fill(contrast == .increased ? Color.brandFill : Color.brandButton)
                        .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
                } else {
                    Capsule().fill(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}

private struct FieldLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
}

/// Inside the server URL field: checking, reachable or not.
private struct ServerStatusBadge: View {
    let status: AppModel.ServerStatus

    var body: some View {
        Group {
            switch status {
            case .checking: ProgressView().controlSize(.mini)
            case .reachable: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .unreachable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .unknown: EmptyView()
            }
        }
        .font(.system(size: 13))
        .transition(.scale.combined(with: .opacity))
        .animation(.snappy(duration: 0.2), value: status)
        .accessibilityHidden(true) // the status line below says it in words
    }
}

/// Quiet filled field: subtle fill, hairline border, accent ring on focus.
private struct LabeledField<Accessory: View, Content: View>: View {
    let label: LocalizedStringKey
    let accessory: Accessory
    let content: Content

    init(_ label: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content.labelsHidden()
        }
    }
}

/// "Forgot?" → explains master passwords can't be reset, and offers to send the hint.
private struct ForgotPasswordButton: View {
    @Environment(AppModel.self) private var model
    let email: String
    @State private var isPresented = false

    var body: some View {
        Button("Forgot password?") { isPresented = true }
            .buttonStyle(.plain).foregroundStyle(.secondary).underline()
            .font(.system(size: 12))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                PasswordHintView(email: email)
                    .environment(model)
            }
    }
}

private struct PasswordHintView: View {
    @Environment(AppModel.self) private var model
    @State var email: String
    @State private var state: HintState = .idle

    enum HintState: Equatable { case idle, sending, sent, revealed(String), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Master password hint", systemImage: "questionmark.key.filled")
                .font(.system(size: 14, weight: .semibold))
            Text("Your master password can't be recovered — not even by the server. If you set a hint, we can email it to you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email", text: $email, prompt: Text(verbatim: "you@example.com"))
                .textFieldStyle(SoftFieldStyle(height: 34))
            switch state {
            case .sent:
                Label("If this account has a hint, it's on its way to your inbox.", systemImage: "paperplane.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
            case .revealed(let hint):
                Label { Text(verbatim: hint).textSelection(.enabled) } icon: { Image(systemName: "lightbulb.fill") }
                    .font(.system(size: 13, weight: .medium))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
            default:
                EmptyView()
            }
            Button {
                Task { await send() }
            } label: {
                HStack(spacing: 8) {
                    if state == .sending { ProgressView().controlSize(.small).tint(.white) }
                    Text("Send hint").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(email.isEmpty || state == .sending)
        }
        .padding(18)
        .frame(width: 300)
        .animation(.snappy, value: state)
    }

    private func send() async {
        state = .sending
        switch await model.requestPasswordHint(email: email) {
        case .success(let hint?): state = .revealed(hint)
        case .success(nil): state = .sent
        case .failure(let message): state = .failed(message)
        }
    }
}

private struct ServerStatusLine: View {
    let status: AppModel.ServerStatus

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .unknown:
                Circle().fill(.quaternary).frame(width: 7, height: 7)
                Text("Enter your server address").foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Checking server…").foregroundStyle(.secondary)
            case .reachable(let product, let version):
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(verbatim: [product, version].compactMap { $0 }.joined(separator: " "))
                Text("· reachable").foregroundStyle(.secondary)
            case .unreachable(let message):
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text(verbatim: message).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .animation(.easeOut(duration: 0.15), value: status)
    }
}

/// "Custom environment": per-service URLs for self-hosted servers. Empty fields derive from the server URL.
private struct CustomEnvironmentFields: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A quiet button; the five URLs are edited in a sheet.
            Button { editing = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                    Text("Custom environment…")
                    if model.hasCustomURLs {
                        Text("In use").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.brandFill.opacity(0.2), in: .capsule)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let problem = model.serverURLProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .sheet(isPresented: $editing) { CustomEnvironmentSheet() }
    }
}

/// The per-service URLs for self-hosted servers whose services live on different addresses.
struct CustomEnvironmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// What was there when the sheet opened, for Cancel.
    @State private var original: [String] = []

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient(colors: [Color.brandFill, Color.brandButton], startPoint: .top, endPoint: .bottom),
                                in: .rect(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom environment").font(.system(size: 17, weight: .semibold))
                    Text("Only if your services live on different URLs. Leave a field empty to use the server URL.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                field("Web vault", $model.customWebVault, derived(""))
                field("API", $model.customAPI, derived("/api"))
                field("Identity", $model.customIdentity, derived("/identity"))
                field("Icons", $model.customIcons, derived("/icons"))
                field("Notifications", $model.customNotifications, derived("/notifications"))
            }
            if let problem = model.serverURLProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Clear All") {
                    model.customWebVault = ""; model.customAPI = ""; model.customIdentity = ""
                    model.customIcons = ""; model.customNotifications = ""
                }
                .buttonStyle(.appSecondary)
                .disabled(!model.hasCustomURLs)
                Spacer()
                Button("Cancel") { restore(); dismiss() }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Button("Done") { dismiss() }.buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            original = [model.customWebVault, model.customAPI, model.customIdentity, model.customIcons, model.customNotifications]
        }
    }

    private func restore() {
        guard original.count == 5 else { return }
        model.customWebVault = original[0]; model.customAPI = original[1]; model.customIdentity = original[2]
        model.customIcons = original[3]; model.customNotifications = original[4]
    }

    /// What an empty field will use: the server URL (or web vault) plus the service path.
    private func derived(_ suffix: String) -> String {
        let root = AppModel.parseURL(model.customWebVault.isEmpty ? model.serverURL : model.serverURL.isEmpty ? model.customWebVault : model.serverURL)
        return root.map { $0.absoluteString + suffix } ?? String(localized: "Server URL") + suffix
    }

    private func field(_ label: LocalizedStringKey, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(verbatim: placeholder).foregroundStyle(.tertiary))
                .textFieldStyle(SoftFieldStyle())
                .labelsHidden()
                .textContentType(.URL)
        }
    }
}

/// Waiting for another device: what to check there, and a way out.
private struct DeviceLoginCard: View {
    @Environment(AppModel.self) private var model
    let waiting: AppModel.DeviceLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Approve the sign-in on a device where you're signed in").font(.system(size: 13, weight: .semibold))
            }
            Text("Make sure it shows this phrase:").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(verbatim: waiting.fingerprint.joined(separator: "-"))
                .font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { withAnimation(.snappy) { model.cancelDeviceLogin() } }.buttonStyle(.appSecondarySmall)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
    }
}
