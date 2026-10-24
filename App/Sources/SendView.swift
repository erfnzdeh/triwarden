import SwiftUI
import UniformTypeIdentifiers
import VaultwardenAPI

/// Sidebar › Send: share text or a file through an end-to-end encrypted link that expires.
struct SendsPane: View {
    @Environment(AppModel.self) private var model

    private var scopedSends: [SendItem] {
        model.sends.filter { send in
            (model.focusedAccountID == nil || send.accountId == model.focusedAccountID) && (!model.expiredSendsOnly || send.isExpired)
        }
    }

    private func sendActions(_ send: SendItem) -> [ActionMenuEntry] {
        var rows: [ActionMenuEntry] = []
        if let link = model.sendLink(send) {
            rows.append(ActionMenuEntry(title: String(localized: "Copy Link"), symbol: "link") { model.copyPlain(link.absoluteString) })
            rows.append(ActionMenuEntry(title: String(localized: "Open Link"), symbol: "safari") { NSWorkspace.shared.open(link) })
        }
        rows.append(ActionMenuEntry(title: String(localized: "Edit…"), symbol: "pencil", separatorBefore: !rows.isEmpty) { model.editSend(send) })
        rows.append(ActionMenuEntry(title: String(localized: "Delete…"), symbol: "trash", destructive: true) { model.confirmDeleteSend(send) })
        return rows
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 10) {
                // Like the item list: a count (new Sends come from the header's + menu).
                HStack {
                    Text("\(scopedSends.count) sends").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 6)
                .frame(height: 32)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(scopedSends) { send in
                            SendRow(send: send, selected: send.id == model.selectedSendID && !model.composingSend && model.editingSend == nil)
                                .onTapGesture { model.closeSendComposer(); model.selectedSendID = send.id }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(send.id == model.selectedSendID ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { model.closeSendComposer(); model.selectedSendID = send.id }
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                .appContextMenu(sendActions(send))
                        }
                    }
                    .padding(6)
                }
                .thinScroller()
                .background(Color.panel, in: .rect(cornerRadius: 18, style: .continuous))
                .overlay {
                    if scopedSends.isEmpty {
                        Text("Your Sends appear here.").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 300)

            Group {
                if model.composingSend || model.editingSend != nil {
                    SendComposer(editing: model.editingSend)
                        .id(model.editingSend?.id ?? model.newSendNonce.uuidString)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                } else if let send = model.sends.first(where: { $0.id == model.selectedSendID }) {
                    SendDetail(send: send).id(send.id)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "paperplane")
                            .font(.system(size: 26, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .background(Color.primary.opacity(0.07), in: .circle)
                        Text("Share something securely").font(.system(size: 17, weight: .semibold))
                        Text("Send text or a file through an end-to-end encrypted link that expires on its own.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                        Button { compose() } label: { Label("New Send", systemImage: "plus") }
                            .buttonStyle(.appPrimary)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.snappy(duration: 0.25), value: model.composingSend)
        }
        .sheet(item: Bindable(model).createdSend) { created in SendCreatedSheet(created: created) }
    }

    private func compose() { withAnimation(.snappy(duration: 0.25)) { model.composeNewSend() } }
}

/// Shown once, right after a Send is made: its link and — for a password-protected Send — the passphrase, which the
/// server only ever stores as a one-way hash. Closing it discards both from memory; nothing is copied automatically,
/// because the link is useless without the passphrase and a single clipboard slot can't hold a choice.
struct SendCreatedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let created: AppModel.CreatedSend
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "paperplane.fill", title: "Send created",
                           subtitle: created.passphrase == nil
                                   ? "Copy the link now — you can also find it again on the Send."
                                   : "Copy what you need now — this is the only time the passphrase can be shown.")

                FormCard {
                    FormField(label: "Link") {
                        HStack(spacing: 6) {
                            Text(verbatim: created.link)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CreatedCopyButton(value: created.link, label: String(localized: "Link"), secret: false)
                        }
                    }
                    if let passphrase = created.passphrase {
                        FormField(label: "Passphrase",
                                  note: "Send it to the recipient another way, not in the same message as the link.") {
                            HStack(spacing: 6) {
                                Text(verbatim: revealed ? passphrase : String(repeating: "•", count: min(passphrase.count, 28)))
                                    .font(.system(size: 12, design: revealed ? .monospaced : .default))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { revealed.toggle() } label: {
                                    Image(systemName: revealed ? "eye.slash" : "eye")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .help(revealed ? "Hide passphrase" : "Show passphrase")
                                .accessibilityLabel(revealed ? "Hide passphrase" : "Show passphrase")
                                CreatedCopyButton(value: passphrase, label: String(localized: "Passphrase"))
                            }
                        }
                    }
                }
            }
            .padding(20)
            // One action only: a Cancel beside Done would read as "discard", but the Send already exists on the server.
            HStack {
                Spacer()
                Button("Done", action: { dismiss() })
                    .buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 520)
        .background(Color.windowBase)
        .interactiveDismissDisabled()
        .onDisappear { model.createdSend = nil }
    }
}

/// A copy button that reports back for a moment, for the one-time sheet.
private struct CreatedCopyButton: View {
    let value: String
    /// The resolved name ("Link", "Passphrase"): the copy toast takes a plain string, and a catalog key must not be
    /// looked up twice.
    let label: String
    /// The passphrase is a secret: it goes through `copy`, which hides it from clipboard managers and clears it
    /// after the configured delay, like every other secret in the app. The link is not secret on its own.
    var secret = true
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Button {
            if secret {
                model.copy(value, label: label)
            } else {
                model.copyPlain(value)
            }
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(copied ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(copied ? Text("Copied") : Text("Copy \(label)"))
        .accessibilityLabel(Text(copied ? "Copied" : "Copy \(label)"))
    }
}

private struct SendRow: View {
    let send: SendItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: send.kind == .file ? "doc" : "text.alignleft")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(send.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(status(send)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if send.hasPassword { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).frame(height: 48)
        .background(selected ? Color.panelStrong : .clear, in: .rect(cornerRadius: 11, style: .continuous))
        .contentShape(.rect)
    }
}

func status(_ send: SendItem) -> String {
    if send.disabled { return String(localized: "Disabled") }
    if send.isExpired { return String(localized: "Expired") }
    if send.isUsedUp { return String(localized: "Maximum views reached") }
    if let date = send.deletionDate {
        return String(localized: "Deletes \(date.formatted(.relative(presentation: .named)))")
    }
    return ""
}

private struct SendDetail: View {
    @Environment(AppModel.self) private var model
    let send: SendItem
    @State private var confirmDelete = false
    @State private var revealText = false
    @State private var copied = false

    var body: some View {
        let link = model.sendLink(send)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header: the same card language as an item's — tile, name, status, then the link and its actions.
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: send.kind == .file ? "doc.fill" : "paperplane.fill")
                            .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(LinearGradient(colors: [Color.brandFill, Color.brandButton], startPoint: .top, endPoint: .bottom),
                                        in: .rect(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(send.name).font(.system(size: 22, weight: .bold)).tracking(-0.3).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(status(send))
                                if send.hasPassword {
                                    Label("Password", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 7).frame(height: 18)
                                        .background(Color.primary.opacity(0.07), in: .capsule)
                                }
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let link {
                        HStack(spacing: 8) {
                            Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Text(verbatim: link.absoluteString)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                        // `controlBackgroundColor` is near-black in dark mode, which read as a hole punched in the
                        // card; the app's own input fill keeps the row on the same surface as every other field.
                        .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                        HStack(spacing: 8) {
                            Button {
                                model.copyPlain(link.absoluteString)
                                withAnimation(.snappy) { copied = true }
                                Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation(.snappy) { copied = false } }
                            } label: {
                                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.appPrimary)
                            ShareLink(item: link) { Label("Share…", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.appSecondary)
                            Button { NSWorkspace.shared.open(link) } label: { Label("Open", systemImage: "arrow.up.right") }
                                .buttonStyle(.appSecondary)
                            Spacer(minLength: 0)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panelStrong, in: .rect(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.panelEdge))

                // What's shared.
                if send.kind == .text, let text = send.text {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Text").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if send.hideText {
                                Button { withAnimation(.snappy) { revealText.toggle() } } label: {
                                    Image(systemName: revealText ? "eye.slash" : "eye").font(.system(size: 13, weight: .medium))
                                        .frame(width: 30, height: 26).contentShape(.rect)
                                }
                                .buttonStyle(HeaderIconStyle())
                                .help(revealText ? Text("Hide") : Text("Reveal"))
                            }
                            Button { model.copy(text, label: String(localized: "Text")) } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .medium))
                                    .frame(width: 30, height: 26).contentShape(.rect)
                            }
                            .buttonStyle(HeaderIconStyle())
                            .help(Text("Copy"))
                        }
                        Text(verbatim: send.hideText && !revealText ? String(repeating: "•", count: min(text.count, 24)) : text)
                            .font(.system(size: 13, design: send.hideText && !revealText ? .monospaced : .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10, style: .continuous))
                            .contentTransition(.opacity)
                    }
                    .padding(16)
                    .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
                }

                // Details.
                VStack(spacing: 0) {
                    if send.kind == .file {
                        DetailRow(symbol: "doc", title: "File") {
                            Text(verbatim: [send.fileName, send.sizeName].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                    }
                    DetailRow(symbol: "eye", title: "Views") {
                        Text(send.maxAccessCount.map { "\(send.accessCount) / \($0)" } ?? "\(send.accessCount)").foregroundStyle(.secondary)
                    }
                    if let date = send.expirationDate {
                        DetailRow(symbol: "hourglass", title: "Expires") {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                    if let date = send.deletionDate {
                        DetailRow(symbol: "trash", title: "Deletes on") {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                    DetailRow(symbol: "lock", title: "Password") {
                        Text(send.hasPassword ? "Required" : "None").foregroundStyle(.secondary)
                    }
                    if let notes = send.notes, !notes.isEmpty {
                        DetailRow(symbol: "note.text", title: "Private notes") { Text(verbatim: notes).foregroundStyle(.secondary) }
                    }
                }
                .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))

                HStack(spacing: 8) {
                    Spacer()
                    Button("Edit", systemImage: "pencil") { withAnimation(.snappy(duration: 0.25)) { model.editSend(send) } }
                        .buttonStyle(.appSecondary)
                    Button("Delete Send", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.appSecondary)
                }
                .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .thinScroller()
        .confirmationDialog("Delete “\(send.name)”?", isPresented: $confirmDelete) {
            Button("Delete Send", role: .destructive) { Task { await model.deleteSend(send) } }
        } message: {
            Text("The link stops working immediately.")
        }
    }
}

/// New text or file Send, composed in place (no sheet): cards of soft fields, switches at the row ends.
struct SendComposer: View {
    @Environment(AppModel.self) private var model
    /// Set to change an existing Send (same link) instead of making a new one.
    var editing: SendItem?
    enum Kind: Hashable { case text, file }
    @State private var deletionDate = Date.now.addingTimeInterval(7 * 86_400)
    @State private var removePassword = false
    @State private var kind = Kind.text
    @State private var name = ""
    @State private var text = ""
    @State private var hideText = false
    @State private var file: URL?
    @State private var deleteAfterDays = 7
    @State private var expires = false
    @State private var expiration = Date.now.addingTimeInterval(86_400)
    @State private var limitViews = false
    @State private var maxViews = 1
    @State private var password = ""
    @State private var hideEmail = false
    @State private var notes = ""
    @State private var accountId: String?
    @State private var picking = false
    @State private var saving = false
    @State private var showGenerator = false
    @State private var dropTargeted = false

    private var destinationSessions: [AccountSession] { model.sessions.filter { model.sendContextAccountIDs?.contains($0.id) ?? true } }

    private var ready: Bool {
        accountId != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && (kind == .text ? !text.isEmpty : (file != nil || editing != nil))
    }

    private func dismiss() {
        withAnimation(.snappy(duration: 0.25)) { model.closeSendComposer() }
    }

    private func prefill() {
        guard let send = editing else {
            kind = model.newSendKind
            if let ids = model.sendContextAccountIDs { accountId = ids.count == 1 ? ids.first : nil }
            else { accountId = model.defaultAccountId }
            // "Share by Link…" from an item: its name and fields, hidden until the recipient reveals them. No
            // password: the link is a bearer token for a real secret, but pre-filling one would be a decision the
            // sender has to undo, and the dice beside the field is one click away for whoever wants it (issue #85).
            if let prefill = model.newSendPrefill {
                kind = .text
                name = prefill.name
                text = prefill.text
                hideText = true
                if let id = prefill.accountId, destinationSessions.contains(where: { $0.id == id }) { accountId = id }
            }
            return
        }
        kind = send.kind == .file ? .file : .text
        name = send.name
        text = send.text ?? ""
        hideText = send.hideText
        notes = send.notes ?? ""
        hideEmail = send.hideEmail
        deletionDate = send.deletionDate ?? deletionDate
        if let expiration = send.expirationDate { expires = true; self.expiration = expiration }
        if let max = send.maxAccessCount { limitViews = true; maxViews = max }
        accountId = send.accountId
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormHeader(symbol: "paperplane.fill", title: editing == nil ? "New Send" : "Edit Send",
                               subtitle: editing == nil ? "Share text or a file through an encrypted link that expires."
                                                        : "Changes apply to the same link.")

                    if editing == nil {
                    HStack(spacing: 12) {
                        AppSegmented(options: [(Kind.text, LocalizedStringKey("Text")), (.file, LocalizedStringKey("File"))],
                                     selection: $kind)
                            .frame(maxWidth: 260)
                        Spacer()
                        if editing == nil && destinationSessions.count > 1 {
                            SoftMenu(options: [(nil, String(localized: "Choose an account…"))] + destinationSessions.map { (String?.some($0.id), $0.account.email) }, selection: $accountId,
                                     accessibilityLabel: "Account")
                                .frame(maxWidth: 240)
                        }
                    }
                    }

                    FormCard {
                        FormField(label: "Name") {
                            TextField("Name", text: $name, prompt: Text("e.g. Wi-Fi password")).textFieldStyle(SoftFieldStyle())
                        }
                        if kind == .text {
                            FormField(label: "Text") {
                                SoftEditor(text: $text, minHeight: 120)
                            }
                            Toggle("Hide the text until the recipient reveals it", isOn: $hideText).toggleStyle(.trailingSwitch)
                        } else {
                            FormField(label: "File") {
                                if let editing {
                                    // A Send's file can't change; make a new Send for another file.
                                    Label { Text(verbatim: editing.fileName ?? "") } icon: { Image(systemName: "doc.fill") }
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                } else {
                                    fileZone
                                }
                            }
                        }
                    }

                    FormCard(title: "Availability") {
                        if editing != nil {
                            DatePicker("Deletes on", selection: $deletionDate, in: Date.now...Date.now.addingTimeInterval(31 * 86_400))
                                .font(.system(size: 13))
                        } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Delete after").font(.system(size: 13))
                            // The same sliding segments as Text / File, not a pop-up menu.
                            AppSegmented(options: [1, 2, 3, 7, 14, 30].map { days in
                                (days, days == 1 ? LocalizedStringKey("1 day") : LocalizedStringKey("\(days) days"))
                            }, selection: $deleteAfterDays)
                            .accessibilityLabel(Text("Delete after"))
                        }
                        }
                        Toggle("Expire earlier", isOn: $expires).toggleStyle(.trailingSwitch)
                        if expires {
                            DatePicker("Expires", selection: $expiration,
                                       in: Date.now...Date.now.addingTimeInterval(Double(deleteAfterDays) * 86_400))
                                .font(.system(size: 13))
                        }
                        Toggle("Limit views", isOn: $limitViews).toggleStyle(.trailingSwitch)
                        if limitViews {
                            HStack {
                                Text("Views").font(.system(size: 13))
                                Spacer()
                                NumberStepper(value: $maxViews, range: 1...100)
                            }
                        }
                    }

                    FormCard(title: "Protection") {
                        FormField(label: "Password",
                                  // Only worth saying once there is a passphrase to hand over: Share by Link… starts
                                  // without one, and the sender may leave it that way.
                                  note: model.newSendPrefill != nil && !password.isEmpty
                                        ? "Send this passphrase to the recipient another way. Without it, the link won't open."
                                        : nil) {
                            HStack(spacing: 8) {
                                PasswordField(title: "Password", text: $password,
                                              prompt: editing?.hasPassword == true ? "Leave blank to keep the current one" : "Optional")
                                    .disabled(removePassword)
                                // The same dice as the edit form's password field: a Send made from an item carries
                                // real secrets, and this is the one click that puts a passphrase in front of them.
                                Button { showGenerator = true } label: {
                                    Image(systemName: "dice").font(.system(size: 14, weight: .medium))
                                        .frame(width: 38, height: 38)
                                        .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .help(Text("Generate password"))
                                .accessibilityLabel(Text("Generate password"))
                                .disabled(removePassword)
                                .popover(isPresented: $showGenerator, arrowEdge: .trailing) {
                                    GeneratorView(modes: [.password, .passphrase], compact: true) { generated in
                                        password = generated
                                        showGenerator = false
                                    }
                                }
                            }
                        }
                        if editing?.hasPassword == true {
                            Toggle("Remove the password", isOn: $removePassword).toggleStyle(.trailingSwitch)
                        }
                        Toggle("Hide my email address from recipients", isOn: $hideEmail).toggleStyle(.trailingSwitch)
                        FormField(label: "Private notes") {
                            TextField("Private notes", text: $notes, prompt: Text("Only you see these")).textFieldStyle(SoftFieldStyle())
                        }
                    }
                    // The actions sit with the form, not in a pinned bar: a pinned bar was covered by the window's
                    // floating Sync/Lock pill and cut off the panels' rounded bottoms beneath it.
                    HStack(spacing: 10) {
                        Label("The link holds the key; the server never sees your content.", systemImage: "lock.shield")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Cancel", action: dismiss).buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                        Button(action: { Task { await create() } }) {
                            HStack(spacing: 6) {
                                if saving { ProgressView().controlSize(.small).tint(.white) }
                                Text(editing == nil ? "Create Send" : "Save")
                            }
                        }
                        .buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
                        .disabled(!ready || saving)
                    }
                    .padding(.top, 2)
                }
                .padding(18)
                // Room for the floating Sync/Lock pill over this page's bottom-right corner.
                .padding(.bottom, 40)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .thinScroller()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { choose(url) }
        }
        .onAppear(perform: prefill)
    }

    private func choose(_ url: URL) {
        file = url
        if name.isEmpty { name = url.lastPathComponent }
    }

    /// Choose or drop a file: a dashed zone that shows the file once chosen.
    private var fileZone: some View {
        Button { picking = true } label: {
            HStack(spacing: 12) {
                Image(systemName: file == nil ? "doc.badge.plus" : "doc.fill")
                    .font(.system(size: 22)).foregroundStyle(file == nil ? Color.secondary : Color.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file?.lastPathComponent ?? String(localized: "Choose a file, or drop it here"))
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(file == nil ? "Up to 500 MB" : "Click to choose another").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color.primary.opacity(dropTargeted ? 0.08 : 0.03), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(dropTargeted ? 0.3 : 0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            choose(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        if let editing {
            let content: SendDraft.Content = kind == .text ? .text(text, hidden: hideText) : .file(name: editing.fileName ?? "", contents: Data())
            var draft = SendDraft(name: name, content: content, deletionDate: deletionDate)
            draft.expirationDate = expires ? expiration : nil
            draft.maxAccessCount = limitViews ? maxViews : nil
            draft.password = removePassword || password.isEmpty ? nil : password
            draft.hideEmail = hideEmail
            draft.notes = notes
            if await model.updateSend(editing, draft: draft, removePassword: removePassword) { dismiss() }
            return
        }
        let content: SendDraft.Content
        if kind == .text {
            content = .text(text, hidden: hideText)
        } else {
            guard let file else { return }
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: file), data.count <= AppModel.attachmentLimit else {
                model.flash(String(localized: "Choose a file up to 500 MB."))
                return
            }
            content = .file(name: file.lastPathComponent, contents: data)
        }
        var draft = SendDraft(name: name, content: content, deletionDate: .now.addingTimeInterval(Double(deleteAfterDays) * 86_400))
        draft.expirationDate = expires ? expiration : nil
        draft.maxAccessCount = limitViews ? maxViews : nil
        draft.password = password.isEmpty ? nil : password
        draft.hideEmail = hideEmail
        draft.notes = notes
        if await model.createSend(draft, accountId: accountId) { dismiss() }
    }
}
