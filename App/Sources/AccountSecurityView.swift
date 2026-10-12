import TriCrypto
import SwiftUI
import VaultwardenAPI

/// One unlocked account's security, as sections of its page in Settings: the fingerprint phrase, two-step
/// login, master password and encryption, devices.
struct AccountSecuritySections: View {
    @Environment(AppModel.self) private var model
    let session: AccountSession
    @State private var providers: [Int: Bool] = [:]
    @State private var devices: [DeviceInfo] = []
    /// The device list shows a few until opened: accounts collect many sign-ins over the years.
    @State private var showsAllDevices = false
    @State private var loading = false
    @State private var devicesLoading = false
    /// Why two-step login couldn't load, and why the devices couldn't (each its own, with the server's words).
    @State private var error: String?
    @State private var devicesError: String?
    /// Bitwarden's cloud answers 403 here: it lets only its own web vault change two-step login (the official
    /// desktop app sends you there too). Vaultwarden has no such rule.
    @State private var twoFactorWebOnly = false
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case authenticator, email, recovery, disable(Int, String), password, kdf, signOutEverywhere
        var id: String {
            switch self {
            case .authenticator: "a"; case .email: "e"; case .recovery: "r"; case .password: "p"; case .kdf: "k"
            case .signOutEverywhere: "s"; case .disable(let t, _): "d\(t)"
            }
        }
    }

    var body: some View {
        Group {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            twoFactorSection(session)
            passwordSection(session)
            fingerprintSection(session)
            devicesSection(session)
        }
        .task(id: session.id) { await load() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .authenticator: AuthenticatorSetupSheet(session: session) { Task { await load() } }
            case .email: EmailTwoFactorSheet(session: session) { Task { await load() } }
            case .recovery: RecoveryCodeSheet(session: session)
            case .disable(let type, let name): DisableTwoFactorSheet(session: session, type: type, name: name) { Task { await load() } }
            case .password: ChangePasswordSheet(session: session, changeKDF: false)
            case .kdf: ChangePasswordSheet(session: session, changeKDF: true)
            case .signOutEverywhere: SignOutEverywhereSheet(session: session) { Task { await load() } }
            }
        }
    }

    /// Two-step login and devices load on their own: one failing doesn't blank the other.
    private func load() async {
        async let p: Void = loadProviders()
        async let d: Void = loadDevices()
        _ = await (p, d)
    }

    private func loadProviders() async {
        loading = true
        defer { loading = false }
        do {
            providers = try await session.twoFactorProviders()
            error = nil
            twoFactorWebOnly = false
        } catch APIError.http(403, _) {
            error = nil
            twoFactorWebOnly = true
        } catch {
            self.error = String(localized: "Couldn't load two-step login: \(problem(error))")
        }
    }

    private func loadDevices() async {
        devicesLoading = true
        defer { devicesLoading = false }
        do {
            devices = try await session.devices()
            devicesError = nil
        } catch {
            devicesError = problem(error)
        }
    }

    /// The server's own words when it gave some, else what went wrong.
    private func problem(_ error: Error) -> String {
        switch error {
        case APIError.http(let status, let message): message ?? String(localized: "Server error (\(status)).")
        case AccountSession.WriteError.offline: String(localized: "This account is offline.")
        default: String(localized: "Couldn't reach the server.")
        }
    }

    // MARK: Sections

    private func fingerprintSection(_ session: AccountSession) -> some View {
        Section {
            let words = session.fingerprint()
            HStack {
                Text(verbatim: words.joined(separator: "-"))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") { model.copyPlain(words.joined(separator: "-")) }
            }
        } header: {
            Text("Fingerprint phrase")
        } footer: {
            Text("Read it out to compare when someone needs to trust your account's key — for example an organization admin, or an emergency contact.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func twoFactorSection(_ session: AccountSession) -> some View {
        Section {
            if twoFactorWebOnly {
                LabeledContent {
                    if let web = session.webVault {
                        Button("Open Web Vault") {
                            NSWorkspace.shared.open(URL(string: web.absoluteString + "/#/settings/security/two-factor") ?? web)
                        }
                    }
                } label: {
                    // Icon, then the title over its explanation, all centred on the button.
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "safari").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Change it in the web vault")
                            Text("Bitwarden lets only its web vault turn two-step login on or off, as with its own desktop app. Codes from your authenticator still work here.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                twoFactorRows(session)
            }
        } header: {
            HStack {
                Text("Two-step login")
                if loading { ProgressView().controlSize(.mini) }
            }
        } footer: {
            Text("A second step after your master password when you sign in on a new device. Keep the recovery code somewhere safe: it turns two-step login off if you lose every method.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func twoFactorRows(_ session: AccountSession) -> some View {
            providerRow(type: 0, name: "Authenticator app", symbol: "clock.badge.checkmark", setup: .authenticator)
            providerRow(type: 1, name: "Email", symbol: "envelope", setup: .email)
            ForEach([(7, "Passkey or security key"), (3, "YubiKey OTP"), (2, "Duo")], id: \.0) { type, name in
                if providers[type] == true {
                    LabeledContent {
                        if let web = session.webVault {
                            Button("Manage in Web Vault") { NSWorkspace.shared.open(web) }
                        }
                    } label: {
                        Label(LocalizedStringKey(name), systemImage: "key.radiowaves.forward")
                    }
                }
            }
            if providers.values.contains(true) {
                LabeledContent {
                    Button("Show…") { sheet = .recovery }
                } label: {
                    Label("Recovery code", systemImage: "lifepreserver")
                }
            }
    }

    private func providerRow(type: Int, name: LocalizedStringKey, symbol: String, setup: Sheet) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if providers[type] == true {
                    Text("On").foregroundStyle(.green)
                    Button("Turn Off…") { sheet = .disable(type, type == 0 ? String(localized: "Authenticator app") : String(localized: "Email")) }
                } else {
                    Button("Set Up…") { sheet = setup }
                }
            }
        } label: {
            Label(name, systemImage: symbol)
        }
    }

    private func passwordSection(_ session: AccountSession) -> some View {
        Section {
            LabeledContent("Master password") { Button("Change…") { sheet = .password } }
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: describe(session.account.kdf)).foregroundStyle(.secondary)
                    Button("Change…") { sheet = .kdf }
                }
            } label: {
                Text("Encryption key settings")
            }
        } header: {
            Text("Master password")
        } footer: {
            Text("Changing either signs out your other devices; this Mac stays signed in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func devicesSection(_ session: AccountSession) -> some View {
        Section {
            if let devicesError {
                LabeledContent {
                    Button("Try Again") { Task { await loadDevices() } }
                } label: {
                    Label { Text(verbatim: devicesError) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } else if devices.isEmpty {
                Text(devicesLoading ? "Loading devices…" : "No devices found.").foregroundStyle(.secondary)
            }
            // This Mac first, then the rest; a few until the list is opened.
            let ordered = devices.filter(\.isCurrent) + devices.filter { !$0.isCurrent }
            let collapsedCount = 3
            ForEach(showsAllDevices ? ordered : Array(ordered.prefix(collapsedCount))) { device in deviceRow(device) }
            if ordered.count > collapsedCount {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsAllDevices.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showsAllDevices ? "Show fewer" : "Show all \(ordered.count) devices")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showsAllDevices ? 180 : 0))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Sign Out Everywhere…", role: .destructive) { sheet = .signOutEverywhere }
            }
        } header: {
            HStack { Text("Devices"); if devicesLoading && !devices.isEmpty { ProgressView().controlSize(.mini) } }
        } footer: {
            Text("Your account is signed in on each of these. Sign out everywhere if one isn't yours; this Mac signs straight back in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Desktop - macOS", when it first signed in (to the second), and how recently it was active; this Mac is
    /// marked as the current session.
    private func deviceRow(_ device: DeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(device))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(device)).font(.system(size: 13, weight: .medium))
                if let first = device.created.flatMap(VaultDecoder.date) {
                    Text("First login \(first.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second()))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help(Text(first.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().second().timeZone())))
                }
            }
            Spacer(minLength: 8)
            if device.isCurrent {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Current session")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9).frame(height: 22)
                .background(Color.primary.opacity(0.07), in: .capsule)
            } else if let last = device.lastActive.flatMap(VaultDecoder.date) {
                Text(Self.recently(last)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .help(Text(last.formatted(date: .complete, time: .standard)))
            }
        }
        .padding(.vertical, 2)
    }

    /// The device's kind in the app's language, its platform as named: "桌面 - macOS".
    private static func title(_ device: DeviceInfo) -> String {
        let parts = device.title.components(separatedBy: " - ")
        let kind: String = switch parts[0] {
        case "Mobile": String(localized: "Mobile")
        case "Extension": String(localized: "Extension")
        case "Desktop": String(localized: "Desktop")
        case "Web app": String(localized: "Web app")
        case "Unknown device": String(localized: "Unknown device")
        default: parts[0]
        }
        return parts.count == 2 ? "\(kind) - \(parts[1])" : kind
    }

    /// "Today", "Yesterday", else "3 days ago".
    private static func recently(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.relative(presentation: .named))
    }

    private func symbol(_ device: DeviceInfo) -> String {
        switch device.kind {
        case "ios", "android": "iphone"
        case "desktop": "desktopcomputer"
        case "extension": "puzzlepiece.extension"
        case "browser": "globe"
        case "cli": "terminal"
        default: "questionmark.circle"
        }
    }

    private func describe(_ kdf: KDFConfig) -> String {
        switch kdf {
        case .pbkdf2(let n): "PBKDF2 · \(n.formatted()) iterations"
        case .argon2id(let t, let m, let p): "Argon2id · \(t) × \(m) MiB × \(p)"
        }
    }
}

// MARK: - Sheets

/// The shell every security sheet shares: header, a card of fields, an error line, the footer.
private struct SecuritySheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: LocalizedStringKey
    var busy = false
    var disabled = false
    var error: String?
    let submit: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: symbol, title: title, subtitle: subtitle)
                FormCard { content }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }
            .padding(20)
            FormFooter(action: action, busy: busy, disabled: disabled, cancel: { dismiss() }, submit: submit)
        }
        .frame(width: 460)
        .background(Color.windowBase)
    }
}

/// Maps a security failure to words.
@MainActor private func message(_ error: Error) -> String {
    switch error {
    case AccountSession.SecurityError.wrongPassword: String(localized: "That's not your master password.")
    case AccountSession.SecurityError.signInAgain:
        String(localized: "Done. Two-step login is on, so this Mac needs a code: log out and sign in again to keep syncing.")
    case APIError.http(_, let message?): message
    default: String(localized: "Couldn't reach the server.")
    }
}

private struct AuthenticatorSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let done: () -> Void
    @State private var password = ""
    @State private var secret: String?
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SecuritySheet(symbol: "clock.badge.checkmark", title: "Authenticator app",
                      subtitle: secret == nil ? "Confirm it's you to get a setup key." : "Add the key to your authenticator app, then enter its code.",
                      action: secret == nil ? "Continue" : "Turn On", busy: busy,
                      disabled: secret == nil ? password.isEmpty : code.count < 6, error: error, submit: submit) {
            if let secret {
                FormField(label: "Setup key") {
                    HStack {
                        Text(verbatim: secret.chunked(4)).font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(secret, forType: .string) }
                            .buttonStyle(.appSecondarySmall)
                    }
                }
                FormField(label: "Code from the app") {
                    TextField("Code", text: $code, prompt: Text(verbatim: "123456")).textFieldStyle(SoftFieldStyle())
                        .font(.system(size: 15, design: .monospaced)).onSubmit(submit)
                }
            } else {
                FormField(label: "Master password") {
                    PasswordField(title: "Master password", text: $password, prompt: "Master password", onSubmit: submit)
                }
            }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if let secret {
                    try await session.enableAuthenticator(key: secret, code: code.filter(\.isNumber), password: password)
                    done(); dismiss()
                } else {
                    secret = try await session.authenticatorSecret(password: password).key
                    error = nil
                }
            } catch { self.error = message(error) }
        }
    }
}

private struct EmailTwoFactorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let done: () -> Void
    @State private var password = ""
    @State private var email = ""
    @State private var sent = false
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SecuritySheet(symbol: "envelope", title: "Email codes",
                      subtitle: sent ? "Enter the code we emailed." : "Codes are emailed to this address when you sign in.",
                      action: sent ? "Turn On" : "Send Code", busy: busy,
                      disabled: password.isEmpty || email.isEmpty || (sent && code.isEmpty), error: error, submit: submit) {
            FormField(label: "Master password") {
                PasswordField(title: "Master password", text: $password, prompt: "Master password")
            }
            FormField(label: "Email") {
                TextField("Email", text: $email).textFieldStyle(SoftFieldStyle()).disabled(sent)
            }
            if sent {
                FormField(label: "Code") {
                    TextField("Code", text: $code).textFieldStyle(SoftFieldStyle()).font(.system(size: 15, design: .monospaced)).onSubmit(submit)
                }
            }
        }
        .onAppear { email = session.account.email }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if sent {
                    try await session.enableEmailTwoFactor(email: email, code: code.trimmingCharacters(in: .whitespaces), password: password)
                    done(); dismiss()
                } else {
                    try await session.sendTwoFactorEmail(to: email, password: password)
                    withAnimation(.snappy) { sent = true }
                    error = nil
                }
            } catch { self.error = message(error) }
        }
    }
}

private struct RecoveryCodeSheet: View {
    let session: AccountSession
    @State private var password = ""
    @State private var code: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SecuritySheet(symbol: "lifepreserver", title: "Recovery code",
                      subtitle: "Write it down and keep it somewhere safe, away from this Mac.",
                      action: "Show", busy: busy, disabled: password.isEmpty || code != nil, error: error, submit: submit) {
            if let code {
                Text(verbatim: code.chunked(4)).font(.system(size: 16, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            } else {
                FormField(label: "Master password") {
                    PasswordField(title: "Master password", text: $password, prompt: "Master password", onSubmit: submit)
                }
            }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do { code = try await session.recoveryCode(password: password); error = nil } catch { self.error = message(error) }
        }
    }
}

private struct DisableTwoFactorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let type: Int
    let name: String
    let done: () -> Void
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SecuritySheet(symbol: "lock.open", title: "Turn off \(name)?",
                      subtitle: "Signing in will no longer ask for this step.",
                      action: "Turn Off", busy: busy, disabled: password.isEmpty, error: error, submit: submit) {
            FormField(label: "Master password") {
                PasswordField(title: "Master password", text: $password, prompt: "Master password", onSubmit: submit)
            }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do { try await session.disableTwoFactor(type: type, password: password); done(); dismiss() } catch { self.error = message(error) }
        }
    }
}

/// A new master password, or new encryption key settings (`changeKDF`), with the current password to confirm.
private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let session: AccountSession
    let changeKDF: Bool
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var argon = false
    @State private var iterations = 600_000
    @State private var argonIterations = 3
    @State private var memory = 64
    @State private var parallelism = 4
    @State private var busy = false
    @State private var error: String?

    private var ready: Bool {
        !current.isEmpty && (changeKDF || (new.count >= 12 && new == confirm && new != current))
    }

    private var kdf: KDFConfig {
        argon ? .argon2id(iterations: argonIterations, memoryMiB: memory, parallelism: parallelism) : .pbkdf2(iterations: iterations)
    }

    var body: some View {
        SecuritySheet(symbol: changeKDF ? "cpu" : "key", title: changeKDF ? "Encryption key settings" : "Change master password",
                      subtitle: changeKDF ? "How hard your master password is to guess-check. Stronger is slower to unlock."
                                          : "Your other devices sign out; this Mac stays signed in.",
                      action: "Change", busy: busy, disabled: !ready, error: error, submit: submit) {
            FormField(label: "Current master password") {
                PasswordField(title: "Current master password", text: $current, prompt: "Current master password")
            }
            if changeKDF {
                AppSegmented(options: [(false, LocalizedStringKey("PBKDF2")), (true, "Argon2id")], selection: $argon)
                if argon {
                    Stepper("Iterations: \(argonIterations)", value: $argonIterations, in: 2...10)
                    Stepper("Memory: \(memory) MiB", value: $memory, in: 16...1024, step: 16)
                    Stepper("Parallelism: \(parallelism)", value: $parallelism, in: 1...16)
                } else {
                    Stepper("Iterations: \(iterations.formatted())", value: $iterations, in: 600_000...2_000_000, step: 50_000)
                }
            } else {
                FormField(label: "New master password", note: "At least 12 characters. A long passphrase is easiest to remember.") {
                    PasswordField(title: "New master password", text: $new, prompt: "New master password")
                    if !new.isEmpty { StrengthMeter(password: new) }
                }
                FormField(label: "Confirm") {
                    PasswordField(title: "Confirm", text: $confirm, prompt: "New master password again")
                }
                FormField(label: "Hint") {
                    TextField("Hint", text: $hint, prompt: Text("Optional; never the password itself")).textFieldStyle(SoftFieldStyle())
                }
            }
        }
        .onAppear {
            switch session.account.kdf {
            case .pbkdf2(let n): argon = false; iterations = n
            case .argon2id(let t, let m, let p): argon = true; argonIterations = t; memory = m; parallelism = p
            }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if changeKDF {
                    try await session.changeMasterPassword(current: current, new: current, kdf: kdf, hint: nil)
                } else {
                    try await session.changeMasterPassword(current: current, new: new, hint: hint.isEmpty ? nil : hint)
                }
                model.flash(changeKDF ? String(localized: "Encryption key settings changed") : String(localized: "Master password changed"))
                dismiss()
            } catch { self.error = message(error) }
        }
    }
}

private struct SignOutEverywhereSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let session: AccountSession
    let done: () -> Void
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SecuritySheet(symbol: "rectangle.portrait.and.arrow.right", title: "Sign out everywhere?",
                      subtitle: "Every device signs out within the hour; this Mac signs back in.",
                      action: "Sign Out Everywhere", busy: busy, disabled: password.isEmpty, error: error, submit: submit) {
            FormField(label: "Master password") {
                PasswordField(title: "Master password", text: $password, prompt: "Master password", onSubmit: submit)
            }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await session.deauthorizeSessions(password: password)
                model.flash(String(localized: "Signed out everywhere else"))
                done(); dismiss()
            } catch { self.error = message(error) }
        }
    }
}

private extension String {
    /// "ABCDEFGH" → "ABCD EFGH".
    func chunked(_ n: Int) -> String {
        stride(from: 0, to: count, by: n).map { i -> String in
            let start = index(startIndex, offsetBy: i)
            return String(self[start..<(index(start, offsetBy: n, limitedBy: endIndex) ?? endIndex)])
        }.joined(separator: " ")
    }
}
