import AppKit
import AuthenticationServices
import TriCrypto
import Observation
import SwiftUI
import VaultwardenAPI

@MainActor @Observable
final class AutoFillState {
    enum Mode { case password, oneTimeCode, passkey, registration }

    /// A WebAuthn request from the system (sign-in or registration).
    struct PasskeyRequest {
        var rpId: String
        var clientDataHash: Data
        /// Sign-in: credentials the site accepts (empty = any). Registration: ones it already has.
        var credentialIDs: [Data] = []
        var userName = ""
        var userHandle = Data()
        var algorithms: [Int] = []
    }

    var mode: Mode = .password
    var domains: [String] = []
    var preselect: String?
    var items: [VaultItem] = []
    var unlocked = false
    var busy = false
    var error: String?
    var accounts = AccountStore.accounts()
    /// Account the master-password field unlocks (when there are several).
    var selectedAccountID = AccountStore.accounts().first?.id
    var touchIDEnabled = AccountStore.accounts().contains { AccountStore.isTouchIDEnabled($0.id) }
    var email: String {
        get { accounts.first { $0.id == selectedAccountID }?.email ?? storedEmail }
        set { storedEmail = newValue }
    }
    private var storedEmail = ""
    var hasAccount = !AccountStore.accounts().isEmpty

    var passkeyRequest: PasskeyRequest?
    /// Accounts opened in this request, for writing a new passkey back.
    private(set) var opened: [String: (key: SymmetricKeyPair, vault: DecodedVault)] = [:]
    var openedAccounts: [SavedAccount] { accounts.filter { opened[$0.id] != nil } }

    var completePassword: (String, String) -> Void = { _, _ in }
    var completeCode: (String) -> Void = { _ in }
    var completeAssertion: (ASPasskeyAssertionCredential) -> Void = { _ in }
    var completeRegistration: (ASPasskeyRegistrationCredential) -> Void = { _ in }
    var cancel: () -> Void = {}
    var fail: (ASExtensionError.Code) -> Void = { _ in }

    enum SaveError: LocalizedError {
        case signedOut, vaultOutOfDate
        var errorDescription: String? {
            switch self {
            case .signedOut: String(localized: "Open Triwarden and sign in to this account again.")
            case .vaultOutOfDate: String(localized: "Open Triwarden once to refresh your vault.")
            }
        }
    }

    func begin(passkey request: PasskeyRequest, registering: Bool, preselect: String? = nil) {
        mode = registering ? .registration : .passkey
        passkeyRequest = request
        self.preselect = preselect
        domains = [request.rpId.lowercased()]
    }

    func begin(mode: Mode, services: [ASCredentialServiceIdentifier], preselect: String?) {
        self.mode = mode
        self.preselect = preselect
        domains = services.compactMap { service in
            switch service.type {
            case .domain: service.identifier.lowercased()
            default: URL(string: service.identifier)?.host()?.lowercased() ?? service.identifier.lowercased()
            }
        }
    }

    func unlock(password: String) async {
        guard let id = selectedAccountID else { return }
        busy = true
        defer { busy = false }
        let key = await Task.detached(priority: .userInitiated) { AccountStore.unlock(id, password: password) }.value
        guard let key else { error = String(localized: "Wrong master password."); return }
        open(with: [id: key])
    }

    /// One prompt opens every account that has Touch ID turned on.
    func unlockWithTouchID() async {
        let reason = switch mode {
        case .passkey: String(localized: "sign in with a passkey")
        case .registration: String(localized: "save a passkey")
        default: String(localized: "fill a password")
        }
        let keys = await AccountStore.unlockAllWithTouchID(accounts.map(\.id), reason: reason)
        if !keys.isEmpty { open(with: keys) }
    }

    private func open(with keys: [String: SymmetricKeyPair]) {
        for (id, key) in keys {
            if let vault = AccountStore.loadCache(id).flatMap({ try? VaultDecoder.decode($0, userKey: key, accountId: id) }) {
                opened[id] = (key, vault)
            }
        }
        let vaults = opened.values.map(\.vault)
        equivalents = EquivalentDomains(groups: keys.keys.flatMap { id in
            AccountStore.loadCache(id).map { EquivalentDomains(syncData: $0).groups } ?? []
        })
        guard !vaults.isEmpty else {
            error = String(localized: "Open Triwarden once to download your vault.")
            return
        }
        items = vaults.flatMap(\.items).filter { !$0.isDeleted && !$0.isArchived && $0.kind == .login }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        unlocked = true
        error = nil
        if mode == .registration, let request = passkeyRequest,
           items.contains(where: { item in
               item.passkeys.contains { passkey in
                   guard let rawId = passkey.rawId else { return false }
                   return request.credentialIDs.contains(rawId)
               }
           }) {
            fail(.matchedExcludedCredential) // the site already has one of our passkeys for this account
            return
        }
        // A QuickType pick fills immediately after unlock.
        if let preselect, let item = items.first(where: { $0.id == preselect }) {
            if mode == .passkey, let pk = passkeyCandidates.first(where: { $0.item.id == preselect }) {
                Task { await signIn(pk.item, pk.passkey) }
            } else if mode != .passkey {
                fill(item)
            }
        }
    }

    // MARK: Passkeys

    /// Passkeys for the requesting site that it will accept.
    var passkeyCandidates: [(item: VaultItem, passkey: PasskeyCredential)] {
        guard let request = passkeyRequest else { return [] }
        // Spelled out step by step: as one chained expression the Release build's type-checker gave up on it.
        var found: [(item: VaultItem, passkey: PasskeyCredential)] = []
        for item in items {
            for passkey in item.passkeys where passkey.rpId.caseInsensitiveCompare(request.rpId) == .orderedSame {
                if request.credentialIDs.isEmpty {
                    found.append((item, passkey))
                } else if let rawId = passkey.rawId, request.credentialIDs.contains(rawId) {
                    found.append((item, passkey))
                }
            }
        }
        return found
    }

    func signIn(_ item: VaultItem, _ passkey: PasskeyCredential) async {
        guard let request = passkeyRequest else { return }
        do {
            let a = try Passkey.assert(passkey, clientDataHash: request.clientDataHash)
            if a.counter != passkey.counter {
                // Keep a counting authenticator's counter moving forward for the next sign-in.
                var edit = CipherEdit()
                edit.passkeyCounter = (passkey.credentialId, a.counter)
                try? await write(edit, accountId: item.accountId, itemId: item.id)
            }
            completeAssertion(ASPasskeyAssertionCredential(userHandle: a.userHandle, relyingParty: passkey.rpId,
                                                           signature: a.signature, clientDataHash: request.clientDataHash,
                                                           authenticatorData: a.authenticatorData, credentialID: a.credentialID))
        } catch {
            self.error = String(localized: "This passkey can't be used here.")
        }
    }

    /// Logins in `accountId` a new passkey could be added to.
    func registrationTargets(_ accountId: String?) -> [VaultItem] {
        items.filter { $0.accountId == accountId && matches($0) }
    }

    /// Creates the passkey, saves it to the server (new login, or replacing `itemId`'s passkey), then answers the site.
    func register(accountId: String, itemId: String?) async {
        guard let request = passkeyRequest else { return }
        busy = true
        defer { busy = false }
        do {
            let reg = try Passkey.register(rpId: request.rpId, rpName: request.rpId, userName: request.userName,
                                           userHandle: request.userHandle, clientDataHash: request.clientDataHash,
                                           algorithms: request.algorithms)
            var edit = CipherEdit()
            if itemId == nil {
                edit = CipherEdit(name: request.rpId, username: request.userName, uri: "https://" + request.rpId)
            }
            edit.passkey = reg.credential
            try await write(edit, accountId: accountId, itemId: itemId)
            completeRegistration(ASPasskeyRegistrationCredential(relyingParty: request.rpId, clientDataHash: request.clientDataHash,
                                                                 credentialID: reg.credentialID, attestationObject: reg.attestationObject))
        } catch Passkey.Failure.unsupportedAlgorithm {
            error = String(localized: "This site needs a key type Triwarden can't create.")
        } catch {
            self.error = String(localized: "Couldn't save the passkey: \(error.localizedDescription)")
        }
    }

    /// Writes an edit through the account's server, then refreshes the shared cache and QuickType list.
    private func write(_ edit: CipherEdit, accountId: String, itemId: String?) async throws {
        guard let (key, vault) = opened[accountId], let account = AccountStore.load(accountId),
              let environment = account.environment else { throw SaveError.vaultOutOfDate }
        guard let token = AccountStore.refreshToken(accountId) else { throw SaveError.signedOut }
        let client = Connection.makeClient(environment)
        await client.restore(refreshToken: token)
        AccountStore.setRefreshToken(try await client.refreshAccessToken(), accountId)
        if let itemId {
            guard let raw = vault.rawCiphers[itemId], let cache = AccountStore.loadCache(accountId),
                  let cipher = try SyncResponse.decode(cache).ciphers.first(where: { $0.id == itemId }),
                  let itemKey = vault.keyring.key(for: cipher) else { throw SaveError.vaultOutOfDate }
            try await client.updateCipher(id: itemId, CipherEditor.updatedCipher(raw: raw, edit: edit, key: itemKey))
        } else {
            _ = try await client.createCipher(CipherEditor.newCipher(kind: .login, edit: edit, key: key))
        }
        let data = try await client.syncData()
        AccountStore.saveCache(data, accountId)
        if let fresh = try? VaultDecoder.decode(data, userKey: key, accountId: accountId) {
            opened[accountId] = (key, fresh)
            AutoFillIdentities.publish(opened.values.flatMap(\.vault.items), equivalents: equivalents)
        }
    }

    /// Sites that share sign-ins (the server's equivalent domains), for matching.
    private var equivalents = EquivalentDomains.none

    func matches(_ item: VaultItem) -> Bool {
        item.hosts.contains { host in domains.contains { equivalents.matches(itemHost: host, site: $0) } }
    }

    func fill(_ item: VaultItem) {
        switch mode {
        case .password:
            guard let password = item.password else { return }
            completePassword(item.username ?? "", password)
        case .oneTimeCode:
            guard let totp = item.totp else { return }
            completeCode(totp.code())
        case .passkey:
            if let pk = passkeyCandidates.first(where: { $0.item.id == item.id }) { Task { await signIn(pk.item, pk.passkey) } }
        case .registration:
            break
        }
    }
}

struct AutoFillView: View {
    @Bindable var state: AutoFillState

    private var heading: (symbol: String, title: LocalizedStringKey) {
        switch state.mode {
        case .registration: ("person.badge.key.fill", "Save a passkey")
        case .passkey: ("person.badge.key.fill", "Sign in with a passkey")
        case .oneTimeCode: ("clock.badge.checkmark", "Fill a one-time code")
        case .password: ("key.fill", "Fill a password")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: heading.symbol, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(heading.title).font(.system(size: 14, weight: .semibold))
                    Text(verbatim: state.passkeyRequest?.rpId ?? state.domains.first ?? "Triwarden")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { state.cancel() }
                    .buttonStyle(CapsuleButtonStyle(primary: false))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Group {
                if !state.hasAccount {
                    ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("Open Triwarden and log in first."))
                } else if state.unlocked && state.mode == .registration {
                    RegisterPane(state: state)
                } else if state.unlocked && state.mode == .passkey {
                    PasskeyList(state: state)
                } else if state.unlocked {
                    PickList(state: state)
                } else {
                    UnlockPane(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 440, height: 520)
        .background { AutoFillGlass() }
        .tint(Color(nsColor: .triwardenBrand))
    }
}

// MARK: - The app's look, for the extension (which can't use the app's own controls)

private enum Palette {
    static let brand = Color(nsColor: .triwardenBrand)
    static let window = adaptive(light: NSColor(red: 0.945, green: 0.947, blue: 0.965, alpha: 1),
                                 dark: NSColor(red: 0.105, green: 0.108, blue: 0.125, alpha: 1))
    static let card = adaptive(light: NSColor.white.withAlphaComponent(0.85), dark: NSColor.white.withAlphaComponent(0.07))
    static let edge = adaptive(light: NSColor.white, dark: NSColor.white.withAlphaComponent(0.08))
    static let selected = adaptive(light: NSColor.triwardenBrand.withAlphaComponent(0.1), dark: NSColor.triwardenBrand.withAlphaComponent(0.2))

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

private struct AppIconMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: Self.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    /// The host app's icon. The extension's own bundle has none, and Launch Services would hand back a generic one.
    private static let icon: NSImage = {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent()
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 256, height: 256)
        return image
    }()
}

private struct AutoFillGlass: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Rectangle()
            .fill(.regularMaterial)
            .background(dark ? Color.black.opacity(0.15) : Color.white.opacity(0.55))
            .overlay(Rectangle().strokeBorder(Color.primary.opacity(dark ? 0.14 : 0.08), lineWidth: 0.5))
            .ignoresSafeArea()
    }
}

private struct IconTile: View {
    let symbol: String
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color.brandFill, Color.brandButton], startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

private struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// The app's capsule buttons: flat brand blue, or a quiet grey.
private struct CapsuleButtonStyle: ButtonStyle {
    var primary = true
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 12, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, large ? 20 : 12)
            .frame(height: large ? 38 : 28)
            .background(primary ? Color.brandButton : Color.primary.opacity(0.08), in: .capsule)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(.capsule)
    }
}

/// A white tile with the item's first letter in the brand's sky, like the app's monograms.
private struct LetterTile: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Text(verbatim: name.prefix(1).uppercased())
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.7))
            .frame(width: size, height: size)
            .background(.white, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
    }
}

/// A row to pick: soft until hovered or chosen, then a brand tint and border.
private struct ChoiceRow<Leading: View>: View {
    let title: String
    let subtitle: String
    let selected: Bool
    var trailing: LocalizedStringKey?
    @ViewBuilder var leading: Leading
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Color.primary : .secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 50)
        .background(selected ? Palette.selected : hovering ? Color.primary.opacity(0.05) : .clear,
                    in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Palette.brand.opacity(0.6) : .clear))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Panes

private struct UnlockPane: View {
    @Bindable var state: AutoFillState
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            AppIconMark(size: 64)
            Card(padding: 22) {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.primary)
                    Group {
                        switch state.mode {
                        case .passkey: Text("Unlock to sign in")
                        case .registration: Text("Unlock to save passkey")
                        default: Text("Unlock to fill")
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    if state.accounts.count > 1 {
                        Menu {
                            ForEach(state.accounts) { account in
                                Button { state.selectedAccountID = account.id } label: {
                                    Text(verbatim: "\(account.email) · \(account.serverSummary)")
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: state.email).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 12)).foregroundStyle(.primary)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Color.primary.opacity(0.06), in: .capsule)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    } else {
                        Text(verbatim: state.email).font(.system(size: 12)).foregroundStyle(.primary)
                    }
                    PasswordField(title: "Master password", text: $password, prompt: Text("Master password"),
                                  isFocused: $focused.wrappedBinding) {
                        Task { await state.unlock(password: password) }
                    }
                    if let error = state.error {
                        Text(verbatim: error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        if state.touchIDEnabled {
                            Button { Task { await state.unlockWithTouchID() } } label: {
                                Label("Touch ID", systemImage: "touchid")
                            }
                            .buttonStyle(CapsuleButtonStyle(primary: false, large: true))
                        }
                        Button {
                            Task { await state.unlock(password: password) }
                        } label: {
                            HStack(spacing: 6) {
                                if state.busy { ProgressView().controlSize(.small).tint(.white) }
                                Text("Unlock")
                            }
                            .frame(minWidth: 90)
                        }
                        .buttonStyle(CapsuleButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || state.busy)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .onAppear {
            focused = true
            if state.touchIDEnabled { Task { await state.unlockWithTouchID() } }
        }
    }
}

private struct PickList: View {
    @Bindable var state: AutoFillState
    @State private var query = ""
    @State private var index = 0

    private var candidates: [VaultItem] {
        let usable = state.items.filter { state.mode == .password ? $0.password != nil : $0.totp != nil }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return usable.filter(state.matches) }
        return usable.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.username?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.host?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search vault", text: $query, prompt: Text("Search vault"))
                .textFieldStyle(SoftFieldStyle())
                .onKeyPress(.downArrow) { index = min(index + 1, max(candidates.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onSubmit { if candidates.indices.contains(index) { state.fill(candidates[index]) } }
                .onChange(of: query) { index = 0 }
            Card(padding: 6) {
                if candidates.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No logins for this site" : "No results",
                                           systemImage: "magnifyingglass",
                                           description: query.isEmpty ? Text("Search to fill from any item.") : nil)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { i, item in
                                ChoiceRow(title: item.name, subtitle: item.username ?? item.host ?? "", selected: i == index,
                                          trailing: state.mode == .oneTimeCode ? "Fill code" : "Fill") {
                                    LetterTile(name: item.name)
                                }
                                .onTapGesture { state.fill(item) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { state.fill(item) }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }
}

/// Passkeys the site will accept; Return signs in with the highlighted one.
private struct PasskeyList: View {
    @Bindable var state: AutoFillState
    @State private var index = 0

    var body: some View {
        let candidates = state.passkeyCandidates
        VStack(spacing: 10) {
            Card(padding: 6) {
                if candidates.isEmpty {
                    ContentUnavailableView("No passkeys for this site", systemImage: "person.badge.key",
                                           description: Text("Passkeys you save with Triwarden appear here."))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(candidates.enumerated()), id: \.element.passkey.credentialId) { i, c in
                                ChoiceRow(title: c.passkey.userName ?? c.item.username ?? c.item.name,
                                          subtitle: "\(c.item.name) · \(c.passkey.rpId)", selected: i == index, trailing: "Sign In") {
                                    IconTile(symbol: "person.badge.key.fill", size: 32)
                                }
                                .onTapGesture { Task { await state.signIn(c.item, c.passkey) } }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { Task { await state.signIn(c.item, c.passkey) } }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { index = min(index + 1, candidates.count - 1); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.return) {
                        if candidates.indices.contains(index) { Task { await state.signIn(candidates[index].item, candidates[index].passkey) } }
                        return .handled
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if let error = state.error {
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }
}

/// Where to save a new passkey: a new login, or an existing login for the site.
struct RegisterPane: View {
    @Bindable var state: AutoFillState
    @State private var accountId: String?
    @State private var target: String? // nil = new login

    var body: some View {
        let request = state.passkeyRequest
        let targets = state.registrationTargets(accountId)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // What's being saved: the site and the account name it gave.
                    Card {
                        HStack(spacing: 12) {
                            LetterTile(name: request?.rpId ?? "?", size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: request?.userName.isEmpty == false ? request!.userName : String(localized: "New passkey"))
                                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(verbatim: request?.rpId ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Label("End-to-end encrypted", systemImage: "lock.shield")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                                .help(Text("Saved encrypted in your vault, and synced to your other devices."))
                        }
                    }

                    if state.openedAccounts.count > 1 {
                        Text("Account").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 4)
                        Card(padding: 6) {
                            VStack(spacing: 2) {
                                ForEach(state.openedAccounts) { account in
                                    ChoiceRow(title: account.email, subtitle: account.serverSummary, selected: accountId == account.id) {
                                        LetterTile(name: account.email, size: 30)
                                    }
                                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { accountId = account.id } }
                                }
                            }
                        }
                    }

                    Text("Save to").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    Card(padding: 6) {
                        VStack(spacing: 2) {
                            ChoiceRow(title: String(localized: "New login"), subtitle: request?.rpId ?? "", selected: target == nil) {
                                IconTile(symbol: "plus", size: 32)
                            }
                            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { target = nil } }
                            ForEach(targets) { item in
                                ChoiceRow(title: item.name, subtitle: item.username ?? "", selected: target == item.id,
                                          trailing: item.hasPasskey ? "Has a passkey" : nil) {
                                    LetterTile(name: item.name, size: 32)
                                }
                                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { target = item.id } }
                            }
                        }
                    }
                    if let target, targets.first(where: { $0.id == target })?.hasPasskey == true {
                        Label("This replaces the passkey already saved on that login.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 4)
                            .transition(.opacity)
                    }
                    if let error = state.error {
                        Text(verbatim: error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            HStack(spacing: 10) {
                Label("Saved to your vault, on every device.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    guard let accountId else { return }
                    Task { await state.register(accountId: accountId, itemId: target) }
                } label: {
                    HStack(spacing: 6) {
                        if state.busy { ProgressView().controlSize(.small).tint(.white) }
                        Text("Save Passkey")
                    }
                }
                .buttonStyle(CapsuleButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(accountId == nil || state.busy)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(alignment: .top) { Divider().opacity(0.5) }
        }
        .onAppear { accountId = accountId ?? state.openedAccounts.first?.id }
        .onChange(of: accountId) { target = nil }
    }
}
