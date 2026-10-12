import TriCrypto
import SwiftUI
import VaultwardenAPI

/// One unlocked account's emergency access, as sections of its Settings page: people who can reach this vault if
/// something happens to you (after a wait you choose, unless you reject them), and vaults that trust you.
struct EmergencyAccessSections: View {
    @Environment(AppModel.self) private var model
    let session: AccountSession
    @State private var trusted: [EmergencyContact] = []
    @State private var granted: [EmergencyContact] = []
    @State private var loading = false
    @State private var error: String?
    @State private var sheet: Sheet?
    /// A trusted contact about to be removed, waiting for "Are you sure?".
    @State private var removing: EmergencyContact?

    enum Sheet: Identifiable {
        case add, accept, confirm(EmergencyContact), view(EmergencyContact), takeover(EmergencyContact)
        var id: String {
            switch self {
            case .add: "add"; case .accept: "accept"; case .confirm(let c): "c" + c.id; case .view(let c): "v" + c.id; case .takeover(let c): "t" + c.id
            }
        }
    }

    var body: some View {
        Group {
                Section {
                    ForEach(trusted) { contact in trustedRow(contact, session) }
                    if trusted.isEmpty && !loading { Text("No trusted contacts yet.").foregroundStyle(.secondary) }
                    HStack { Spacer(); Button("Add Contact…") { sheet = .add } }
                } header: {
                    HStack { Text("Emergency access"); if loading { ProgressView().controlSize(.mini) } }
                } footer: {
                    Text("They can ask for access; if you don't reject the request within the wait time, they can view your vault or set a new master password for it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(granted) { contact in grantedRow(contact, session) }
                    if granted.isEmpty && !loading { Text("Nobody has made you their emergency contact.").foregroundStyle(.secondary) }
                    HStack { Spacer(); Button("Accept Invitation…") { sheet = .accept } }
                } header: {
                    Text("Vaults that trust you")
                }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .task(id: session.id) { await load() }
        .confirmationDialog("Remove \(removing?.email ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { c in
            Button("Remove", role: .destructive) { act("delete", c, session) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They can no longer ask for access to your vault. You can invite them again later.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: AddEmergencyContactSheet(session: session) { Task { await load() } }
            case .accept: AcceptEmergencyInviteSheet(session: session) { Task { await load() } }
            case .confirm(let c): ConfirmEmergencyContactSheet(session: session, contact: c) { Task { await load() } }
            case .view(let c): EmergencyVaultSheet(session: session, contact: c)
            case .takeover(let c): EmergencyTakeoverSheet(session: session, contact: c) { Task { await load() } }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let t = session.emergencyContacts(granted: false)
            async let g = session.emergencyContacts(granted: true)
            (trusted, granted) = try await (t, g)
            error = nil
        } catch {
            self.error = String(localized: "Couldn't reach the server, or it doesn't allow emergency access.")
        }
    }

    private func act(_ action: String, _ contact: EmergencyContact, _ session: AccountSession) {
        Task {
            do { try await session.emergencyAccess(action, contact); await load() } catch {
                self.error = (error as? APIError).flatMap { if case .http(_, let m?) = $0 { m } else { nil } }
                    ?? String(localized: "Couldn't reach the server.")
            }
        }
    }

    private func status(_ c: EmergencyContact) -> (LocalizedStringKey, Color) {
        switch c.status {
        case .invited: ("Invited", .secondary)
        case .accepted: ("Needs confirming", .orange)
        case .confirmed: ("Confirmed", .green)
        case .recoveryInitiated: ("Access requested", .orange)
        case .recoveryApproved: ("Access granted", .red)
        }
    }

    private func label(_ c: EmergencyContact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: c.name.map { "\($0) · \(c.email)" } ?? c.email).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(c.takeover ? "Takeover" : "View")
                Text(verbatim: "·")
                Text("Wait \(c.waitDays) days")
                Text(verbatim: "·")
                Text(status(c).0).foregroundStyle(status(c).1)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func trustedRow(_ c: EmergencyContact, _ session: AccountSession) -> some View {
        HStack {
            label(c)
            Spacer()
            switch c.status {
            case .invited: Button("Resend") { act("reinvite", c, session) }
            case .accepted: Button("Confirm…") { sheet = .confirm(c) }
            case .recoveryInitiated:
                Button("Reject") { act("reject", c, session) }
                Button("Approve") { act("approve", c, session) }
            case .recoveryApproved: Button("Revoke") { act("reject", c, session) }
            case .confirmed: EmptyView()
            }
            Button(role: .destructive) { removing = c } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(Text("Remove"))
        }
    }

    @ViewBuilder private func grantedRow(_ c: EmergencyContact, _ session: AccountSession) -> some View {
        HStack {
            label(c)
            Spacer()
            switch c.status {
            case .confirmed: Button("Request Access") { act("initiate", c, session) }
            case .recoveryInitiated: Text("Waiting").foregroundStyle(.secondary)
            case .recoveryApproved:
                if c.takeover { Button("Take Over…") { sheet = .takeover(c) } } else { Button("View Vault") { sheet = .view(c) } }
            default: Text("Waiting for them to confirm").foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddEmergencyContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let done: () -> Void
    @State private var email = ""
    @State private var takeover = false
    @State private var waitDays = 7
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "cross.case", title: "Add trusted contact",
                           subtitle: "Someone with an account on this server who can ask for access in an emergency.")
                FormCard {
                    FormField(label: "Email") {
                        TextField("Email", text: $email, prompt: Text(verbatim: "name@example.com")).textFieldStyle(SoftFieldStyle())
                    }
                    FormField(label: "Access") {
                        AppSegmented(options: [(false, LocalizedStringKey("View")), (true, "Takeover")], selection: $takeover)
                        Text(takeover ? "They can set a new master password and use your account." : "They can see your items, read-only.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    FormField(label: "Wait time") {
                        SoftMenu(options: [1, 2, 3, 7, 14, 30, 90].map { ($0, String(localized: "\($0) days")) }, selection: $waitDays,
                                 accessibilityLabel: "Wait time")
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red) }
            }
            .padding(20)
            FormFooter(action: "Invite", busy: busy, disabled: !email.contains("@"), cancel: { dismiss() }) {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await session.inviteEmergencyContact(email: email.trimmingCharacters(in: .whitespaces), takeover: takeover, waitDays: waitDays)
                        done(); dismiss()
                    } catch {
                        self.error = (error as? APIError).flatMap { if case .http(_, let m?) = $0 { m } else { nil } }
                            ?? String(localized: "Couldn't reach the server.")
                    }
                }
            }
        }
        .frame(width: 460)
        .background(Color.windowBase)
    }
}

/// Before trusting a contact's key: their fingerprint phrase, to compare with what they see.
private struct ConfirmEmergencyContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let contact: EmergencyContact
    let done: () -> Void
    @State private var key: RSAPublicKeyBox?
    @State private var phrase: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "checkmark.shield", title: "Confirm \(contact.email)",
                           subtitle: "Ask them to read their fingerprint phrase (Settings › Accounts). Confirm only if it matches.")
                FormCard {
                    if phrase.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(verbatim: phrase.joined(separator: "-"))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red) }
            }
            .padding(20)
            FormFooter(action: "Confirm", busy: busy, disabled: key == nil, cancel: { dismiss() }) {
                guard let key else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do { try await session.confirmEmergencyContact(contact, key: key.key); done(); dismiss() } catch {
                        self.error = String(localized: "Couldn't confirm. Try again.")
                    }
                }
            }
        }
        .frame(width: 460)
        .background(Color.windowBase)
        .task {
            do {
                let (k, p) = try await session.contactKey(contact)
                key = RSAPublicKeyBox(key: k); phrase = p
            } catch { self.error = String(localized: "Couldn't get their key from the server.") }
        }
    }
}

private struct RSAPublicKeyBox { let key: RSAPublicKey }

/// The other account's items, read-only, after it approved (or didn't reject in time) your request.
private struct EmergencyVaultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let session: AccountSession
    let contact: EmergencyContact
    @State private var items: [VaultItem] = []
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                FormHeader(symbol: "eye", title: "\(contact.email)", subtitle: "Their vault, read-only. Nothing is saved on this Mac.")
                TextField("Search", text: $query).textFieldStyle(SoftFieldStyle())
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                            HStack(spacing: 10) {
                                Monogram(name: item.name, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.system(size: 13, weight: .semibold))
                                    if let u = item.username { Text(verbatim: u).font(.system(size: 11)).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if let u = item.username { Button("Username") { model.copy(u, label: String(localized: "Username")) }.buttonStyle(.appSecondarySmall) }
                                if let p = item.password { Button("Password") { model.copy(p, label: String(localized: "Password")) }.buttonStyle(.appSecondarySmall) }
                                if let n = item.notes { Button("Notes") { model.copy(n, label: String(localized: "Notes")) }.buttonStyle(.appSecondarySmall) }
                            }
                            .padding(8)
                            .background(Color.panelStrong, in: .rect(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(height: 340)
                if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red) }
            }
            .padding(20)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.appPrimary).keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 560)
        .background(Color.windowBase)
        .task {
            do { items = try await session.emergencyView(contact).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            catch { self.error = String(localized: "Couldn't open their vault.") }
        }
    }
}

private struct EmergencyTakeoverSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let contact: EmergencyContact
    let done: () -> Void
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "key", title: "Take over \(contact.email)",
                           subtitle: "Set a new master password for their account, then sign in to it with that password.")
                FormCard {
                    FormField(label: "New master password", note: "At least 12 characters.") {
                        PasswordField(title: "New master password", text: $password, prompt: "New master password")
                        if !password.isEmpty { StrengthMeter(password: password) }
                    }
                    FormField(label: "Confirm") {
                        PasswordField(title: "Confirm", text: $confirm, prompt: "New master password again")
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red) }
            }
            .padding(20)
            FormFooter(action: "Set Password", busy: busy, disabled: password.count < 12 || password != confirm, cancel: { dismiss() }) {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await session.emergencyTakeover(contact, newPassword: password); done(); dismiss() } catch {
                        self.error = String(localized: "Couldn't set the password.")
                    }
                }
            }
        }
        .frame(width: 460)
        .background(Color.windowBase)
    }
}

/// Paste the link from the invitation email to become someone's emergency contact.
private struct AcceptEmergencyInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: AccountSession
    let done: () -> Void
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "envelope.open", title: "Accept invitation",
                           subtitle: "Paste the link from the “Emergency access” email.")
                FormCard {
                    SoftEditor(text: $link, minHeight: 70, monospaced: true)
                }
                if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red) }
            }
            .padding(20)
            FormFooter(action: "Accept", busy: busy, disabled: !link.contains("token="), cancel: { dismiss() }) {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await session.acceptEmergencyInvite(link: link.trimmingCharacters(in: .whitespacesAndNewlines)); done(); dismiss() }
                    catch { self.error = String(localized: "That link didn't work. It may have expired, or be for another account.") }
                }
            }
        }
        .frame(width: 460)
        .background(Color.windowBase)
    }
}
