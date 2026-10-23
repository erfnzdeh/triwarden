import SSHAgent
import UniformTypeIdentifiers
import TriCrypto
import SwiftUI
import VaultwardenAPI

/// Tallest website row, so a drag knows when the pointer has crossed into the next one.
private struct WebsiteRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Create or edit any item type. Only changed fields are sent; everything else on the server's copy
/// (passkeys, item key, linked fields, history) is preserved by `CipherEditor`.
struct EditItemSheet: View {
    enum Mode: Equatable {
        case create(AppModel.NewItemKind)
        case edit(VaultItem)
        /// A new item filled in from an existing one (passkeys and attachments stay with the original).
        case clone(VaultItem)

        var isEdit: Bool { if case .edit = self { true } else { false } }
    }

    /// A new item's starting name, website and password.
    struct Prefill: Equatable {
        var name = ""
        var uri = ""
        var password = ""
        var accountIDs: [String]? = nil
        var folderPath: String? = nil
        var favorite = false
        var vaultKeys: [String]? = nil
        var organizationId: String? = nil
        var collectionIds: [String] = []
        var focusTOTP = false
        var importSSH = false
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: Mode
    var prefill: Prefill?
    /// In the detail panel rather than a sheet: Cancel and Save sit at the top, by the title.
    var inPanel = false

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var totp = ""
    @State private var websites: [WebsiteRow] = [WebsiteRow()]
    @State private var notes = ""
    @State private var folderId: String?
    @State private var accountId: String?
    @State private var destinationVault: String?
    /// A new item's shared folder, when it is being made inside one.
    @State private var destinationCollection: String?
    /// The shared folders an existing item is in, or is going into. Only the edit form uses this: a shared item
    /// can be in several, and moving a personal item in needs at least one.
    @State private var chosenCollections: Set<String> = []
    /// Naming a new folder from the Folder field: the path it goes inside, nil when not.
    @State private var newFolderIn: String?
    /// Card / identity / SSH-key properties by API name.
    @State private var props: [String: String] = [:]
    @State private var customFields: [CustomField] = []
    @State private var reprompt = false
    @State private var showSecrets = false
    @State private var showGenerator = false
    @State private var saving = false
    @FocusState private var focus: Field?
    /// The form as it was opened, to tell whether closing it would lose anything.
    @State private var original: Draft?
    @State private var confirmingDiscard = false
    @State private var choosingSSHKey = false
    @State private var sshImportError: String?
    @State private var scanning = false
    @State private var scanProblem: String?
    /// The website row under the pointer, its travel, and where that drag began.
    @State private var draggingWebsite: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragAnchorIndex = 0
    @State private var websiteRowHeight: CGFloat = 64
    @State private var websiteAdds = 0
    @FocusState private var focusedWebsite: UUID?

    /// Row height plus the stack's gap, so a drag swaps as the pointer crosses the next row.
    private var websiteStride: CGFloat { websiteRowHeight + 12 }
    private var websiteAnimation: Animation {
        reduceMotion || !Motion.plays ? .easeOut(duration: 0.15) : .snappy(duration: 0.34, extraBounce: 0.05)
    }

    private struct WebsiteRow: Identifiable, Equatable {
        var id = UUID()
        var text = ""
    }

    /// Websites with the blanks left out, which is what gets saved.
    private var websiteValues: [String] {
        websites.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private struct Draft: Equatable {
        var name, username, password, totp, notes: String
        var uris: [String]
        var folderId: String?
        var accountId: String?
        var destinationVault: String?
        var destinationCollection: String?
        var chosenCollections: Set<String>
        var props: [String: String]
        var customFields: [CustomField]
        var reprompt: Bool
    }

    private var draft: Draft {
        Draft(name: name, username: username, password: password, totp: totp, notes: notes, uris: websiteValues, folderId: folderId, accountId: accountId, destinationVault: destinationVault,
              destinationCollection: destinationCollection, chosenCollections: chosenCollections,
              props: props.filter { !$0.value.isEmpty }, customFields: customFields, reprompt: reprompt)
    }

    private var hasChanges: Bool { original.map { $0 != draft } ?? false }

    private func cancel() {
        // Escape while naming a new folder backs out of that, not the whole form.
        if newFolderIn != nil { withAnimation(.easeOut(duration: 0.15)) { newFolderIn = nil }; return }
        if hasChanges { confirmingDiscard = true } else { close() }
    }

    /// Closes the sheet, or the panel's form (cancelled: back to the item selected before; saved: the new item).
    private func close(saved: Bool = false) {
        if inPanel {
            withAnimation(.snappy(duration: 0.25)) { model.closeNewItemForm(restoringSelection: !saved) }
        } else {
            dismiss()
        }
    }

    /// Not while naming a folder, so Return there makes the folder rather than saving the item.
    private var saveDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || newFolderIn != nil || (!mode.isEdit && accountId == nil)
            || (selectsVault && destinationVault == nil)
            || (!mode.isEdit && creationOrganizationID != nil && creationCollectionIDs.isEmpty)
            || movingNeedsCollection || sharedNeedsCollection
    }

    private var selectsVault: Bool { prefill?.vaultKeys != nil && prefill?.organizationId == nil }
    private var creationOrganizationID: String? {
        prefill?.organizationId ?? (destinationVault == AppModel.VaultFilter.personalKey ? nil : destinationVault)
    }
    private var creationCollectionIDs: [String] {
        if let fixed = prefill?.collectionIds, !fixed.isEmpty { return fixed }
        return destinationCollection.map { [$0] } ?? []
    }
    private var chosenSession: AccountSession? { accountId.flatMap { model.session(for: $0) } }
    private var writableCollections: [Grouping] {
        chosenSession?.organizations.first { $0.id == creationOrganizationID }?.children.filter(\.canWrite) ?? []
    }

    /// The account whose shared vaults the form offers: the item's own when editing.
    private var vaultSession: AccountSession? { folderAccountId.flatMap { model.session(for: $0) } }
    private var vaultOrganizations: [Grouping] {
        if let session = vaultSession { return session.organizations }
        // Previews and `--demo` have no sessions: the model's own list is the vault's.
        return model.organizations.filter { $0.accountId == nil || $0.accountId == folderAccountId }
    }

    /// The shared vault this edit moves the item into (nil: it stays where it is). Moving is one way, so only a
    /// personal item can move, and only into a vault of its own account.
    private var movingTo: String? {
        guard case .edit(let item) = mode, item.organizationId == nil,
              let vault = destinationVault, vault != AppModel.VaultFilter.personalKey else { return nil }
        return vault
    }

    /// An item on its way into a shared vault needs at least one shared folder.
    private var movingNeedsCollection: Bool { movingTo != nil && chosenCollections.isEmpty }

    /// A shared item that was in shared folders has to stay in at least one (the server would leave it unreachable).
    /// One that never had any can still be edited.
    private var sharedNeedsCollection: Bool {
        guard case .edit(let item) = mode else { return false }
        return item.organizationId != nil && !item.collectionIds.isEmpty && chosenCollections.isEmpty
    }

    enum Field { case name, totp }

    private var kind: VaultItem.Kind {
        switch mode {
        case .create(let k): k.itemKind
        case .edit(let item), .clone(let item): item.kind
        }
    }

    /// Folders belong to one account; only offer the item's (or the chosen) account's folders.
    private var folderAccountId: String? {
        switch mode { case .edit(let item), .clone(let item): item.accountId; case .create: accountId }
    }

    private var destinationSessions: [AccountSession] {
        guard let ids = prefill?.accountIDs else { return model.sessions }
        return model.sessions.filter { ids.contains($0.id) }
    }

    private var accountFolders: [Grouping] {
        folderAccountId.flatMap { model.session(for: $0)?.folders } ?? model.folders
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .create(.login): "New Login"
        case .create(.secureNote): "New Secure Note"
        case .create(.card): "New Card"
        case .create(.identity): "New Identity"
        case .create(.sshKey): "New SSH Key"
        case .edit: "Edit Item"
        case .clone: "Clone Item"
        }
    }

    private var symbol: String {
        switch kind {
        case .unsupported: "questionmark.square"
        case .login: "key.fill"; case .note: "note.text"; case .card: "creditcard.fill"
        case .identity: "person.crop.rectangle.fill"; case .sshKey: "terminal.fill"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch kind {
        case .unsupported: "Unsupported item"
        case .login: "A sign-in for a website or app."
        case .note: "Private text, encrypted like everything else."
        case .card: "A payment card, ready for AutoFill."
        case .identity: "Your details, for filling in forms."
        case .sshKey: "A key the Triwarden SSH agent can sign with."
        }
    }

    /// Hidden item values or custom fields hide until asked for.
    private var hasHiddenValues: Bool {
        kind == .card || kind == .identity || kind == .sshKey
            || customFields.contains { $0.kind == .hidden }
    }

    var body: some View {
        Group {
            if inPanel { panelBody } else { sheetBody }
        }
        .onAppear(perform: load)
        .onChange(of: hasChanges) { _, dirty in if inPanel { model.newItemFormDirty = dirty } }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) { close() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("What you've typed here isn't saved yet.")
        }
    }

    private var sheetBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormHeader(symbol: symbol, title: title, subtitle: subtitle)
                    fields
                }
                .padding(20)
            }
            .thinScroller()

            FormFooter(action: "Save", busy: saving, disabled: saveDisabled, cancel: cancel, submit: { Task { await save() } }) {
                if hasHiddenValues {
                    Toggle("Show hidden values", isOn: $showSecrets).toggleStyle(.switch).tint(.brand).controlSize(.mini).font(.system(size: 12))
                }
            }
        }
        .frame(width: 580, height: kind == .note ? 560 : 700)
        .background(Color.windowBase)
        .navigationTitle(title)
        .interactiveDismissDisabled(hasChanges)
    }

    /// The detail panel's form: the title with Cancel and Save beside it (the window's footer has the bottom corner),
    /// then the fields, scrolling under it. Centred at a readable width, like the Send composer.
    private var panelBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FormHeader(symbol: symbol, title: title, subtitle: subtitle)
                Spacer(minLength: 12)
                if hasHiddenValues {
                    Button { showSecrets.toggle() } label: {
                        Image(systemName: showSecrets ? "eye.slash" : "eye")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(showSecrets ? Text("Hide hidden values") : Text("Show hidden values"))
                    .accessibilityLabel(showSecrets ? Text("Hide hidden values") : Text("Show hidden values"))
                }
                Button("Cancel", action: cancel).buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small).tint(.white) }
                        Text("Save")
                    }
                }
                .buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
                .disabled(saveDisabled || saving)
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) { fields }
                    .padding(.horizontal, 18).padding(.bottom, 18)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
            }
            .thinScroller()
        }
    }

    @ViewBuilder private var fields: some View {
            FormCard {
                if case .create = mode, destinationSessions.count > 1 {
                    FormField(label: "Account") {
                        SoftMenu(options: [(String?.none, String(localized: "Choose an account…"))] + destinationSessions.map { (String?.some($0.id), "\($0.account.email) · \($0.account.serverSummary)") },
                                 selection: $accountId, accessibilityLabel: "Account")
                    }
                    .onChange(of: accountId) {
                        folderId = prefill?.folderPath.flatMap { path in model.session(for: accountId ?? "")?.folders.first { $0.name == path }?.id }
                        newFolderIn = nil
                        destinationCollection = nil
                    }
                }
                FormField(label: "Name") {
                    TextField("Name", text: $name, prompt: Text("e.g. GitHub"))
                        .textFieldStyle(SoftFieldStyle())
                        .focused($focus, equals: .name)
                }
                if case .edit = mode {
                    editDestinationFields
                } else {
                    if selectsVault {
                        FormField(label: "Vault") {
                            SoftMenu(options: [(String?.none, String(localized: "Choose a vault…"))]
                                + ((prefill?.vaultKeys?.contains(AppModel.VaultFilter.personalKey) == true) ? [(String?.some(AppModel.VaultFilter.personalKey), String(localized: "My vault"))] : [])
                                + (chosenSession?.organizations.filter { prefill?.vaultKeys?.contains($0.id) == true }.map { (String?.some($0.id), $0.name) } ?? []),
                                selection: $destinationVault, accessibilityLabel: "Vault")
                                .onChange(of: destinationVault) { destinationCollection = nil; folderId = nil; newFolderIn = nil }
                        }
                    }
                    if creationOrganizationID != nil && prefill?.collectionIds.isEmpty != false {
                        FormField(label: "Shared Folders") {
                            SoftMenu(options: [(String?.none, String(localized: "Choose a collection…"))] + writableCollections.map { (String?.some($0.id), $0.name) },
                                selection: $destinationCollection, accessibilityLabel: "Shared Folders")
                        }
                    }
                    if let organizationId = prefill?.organizationId,
                       let org = destinationSessions.first?.organizations.first(where: { $0.id == organizationId }) {
                        LabeledContent("Shared vault", value: org.name)
                        ForEach(org.children.filter { prefill?.collectionIds.contains($0.id) == true }) { collection in
                            LabeledContent("Shared Folders", value: collection.name)
                        }
                    }
                }
                if let path = prefill?.folderPath {
                    LabeledContent("Folder", value: path)
                } else if sharedVaultID == nil { FormField(label: "Folder") {
                    FolderCascader(folders: prefill?.organizationId == nil ? accountFolders : [], selection: $folderId, create: { path in
                        await model.createFolder(name: path, accountId: folderAccountId)
                    }, newFolderIn: $newFolderIn)
                } }
            }

            switch kind {
            case .login:
                loginSection
                autofillSection
            case .card: cardSection
            case .identity: identitySection
            case .sshKey: sshSection
            case .note, .unsupported: EmptyView()
            }

            customFieldsSection

            FormCard(title: "Notes") {
                SoftEditor(text: $notes, minHeight: kind == .note ? 200 : 80)
            }

            FormCard {
                Toggle(isOn: $reprompt) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask for master password").font(.system(size: 13))
                        Text("Before showing or copying this item's secrets.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.trailingSwitch)
            }
    }

    // MARK: Where the item lives

    /// The edit form's Vault and Shared Folders fields, the same as the right-click menu's move and collections
    /// sheets, but saved with the rest of the edit. A personal item can move into a shared vault; a shared item
    /// stays where it is (moving is one way) and only changes its shared folders.
    @ViewBuilder private var editDestinationFields: some View {
        if let organizationId = sharedOrganizationID {
            let vaultName = vaultOrganizations.first { $0.id == organizationId }?.name ?? organizationId
            LabeledContent("Vault") {
                HStack(spacing: 6) {
                    Image(systemName: "building.2").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(verbatim: vaultName)
                }
            }
            FormField(label: "Shared Folders", note: "Who in \(vaultName) can see this item.") {
                VStack(alignment: .leading, spacing: 6) {
                    CollectionChecklist(collections: writableVaultCollections, chosen: $chosenCollections)
                    // Folders this account may read but not change stay as they are.
                    ForEach(lockedVaultCollections) { collection in
                        Label(collection.name, systemImage: "lock")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        } else if !vaultOrganizations.isEmpty {
            FormField(label: "Vault") {
                SoftMenu(options: [(String?.some(AppModel.VaultFilter.personalKey), String(localized: "My vault"))]
                    + vaultOrganizations.map { (String?.some($0.id), $0.name) },
                    selection: $destinationVault, accessibilityLabel: "Vault")
                    .onChange(of: destinationVault) { chosenCollections = []; folderId = nil; newFolderIn = nil }
            }
            if movingTo != nil {
                FormField(label: "Shared Folders", note: "Moving is one way: the shared vault owns the item afterwards.") {
                    VStack(alignment: .leading, spacing: 6) {
                        CollectionChecklist(collections: writableVaultCollections, chosen: $chosenCollections)
                        if chosenCollections.isEmpty, !writableVaultCollections.isEmpty {
                            Text("Choose at least one shared folder.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// The vault the item is already in: a shared item's stays read-only.
    private var sharedOrganizationID: String? {
        guard case .edit(let item) = mode else { return nil }
        return item.organizationId
    }

    /// The shared vault whose folders are listed: the one it is in, or the one it is moving into.
    private var sharedVaultID: String? {
        switch mode {
        case .edit: sharedOrganizationID ?? movingTo
        case .create, .clone: creationOrganizationID
        }
    }

    /// The shared vault's folders this account can put items in.
    private var writableVaultCollections: [Grouping] {
        vaultOrganizations.first { $0.id == sharedVaultID }?.children.filter(\.canWrite) ?? []
    }

    /// The folders the item is already in that this account may not change.
    private var lockedVaultCollections: [Grouping] {
        vaultOrganizations.first { $0.id == sharedVaultID }?.children
            .filter { !$0.canWrite && chosenCollections.contains($0.id) } ?? []
    }

    // MARK: Sections

    @ViewBuilder private var loginSection: some View {
        FormCard(title: "Sign-in") {
            FormField(label: "Username") {
                TextField("Username", text: $username, prompt: Text(verbatim: "you@example.com"))
                    .textFieldStyle(SoftFieldStyle())
                    .textContentType(.username)
            }
            FormField(label: "Password") {
                HStack(spacing: 8) {
                    PasswordField(title: "Password", text: $password, prompt: "Password")
                        .font(.system(size: 13, design: .monospaced))
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
                    .popover(isPresented: $showGenerator, arrowEdge: .trailing) {
                        GeneratorView(modes: [.password, .passphrase], compact: true) { generated in
                            password = generated
                            showGenerator = false
                        }
                    }
                }
                if !password.isEmpty { StrengthMeter(password: password).padding(.top, 2) }
            }
            FormField(label: "One-time code secret", note: "From the site's two-factor setup: scan its QR code, or paste the otpauth:// link or the key under it.") {
                HStack(spacing: 8) {
                    TextField("One-time code secret", text: $totp, prompt: Text("otpauth://… or base32 key"))
                        .focused($focus, equals: .totp)
                        .textFieldStyle(SoftFieldStyle())
                        .font(.system(size: 13, design: .monospaced))
                    Button { Task { await scanQRCode() } } label: {
                        Group {
                            if scanning { ProgressView().controlSize(.small) } else { Image(systemName: "qrcode.viewfinder") }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(scanning)
                    .help(Text("Scan the QR code from a window on screen, or from a copied image"))
                    .accessibilityLabel(Text("Scan QR code"))
                }
                if let scanProblem {
                    Label(scanProblem, systemImage: "qrcode")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !totp.isEmpty, TOTP(totp) == nil {
                    Label("That doesn't look like a valid one-time code secret.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Where this login is offered. Separate from the sign-in itself.
    @ViewBuilder private var autofillSection: some View {
        FormCard(title: "AutoFill") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($websites) { $site in
                    let index = websites.firstIndex(where: { $0.id == site.id }) ?? 0
                    let dragging = draggingWebsite == site.id
                    websiteRow($site, index: index, dragging: dragging)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: WebsiteRowHeightKey.self, value: proxy.size.height)
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.panelStrong)
                                .shadow(color: .black.opacity(dragging ? 0.16 : 0), radius: dragging ? 16 : 0, y: dragging ? 8 : 0)
                                .padding(.horizontal, -8)
                                .padding(.vertical, -4)
                                .opacity(dragging ? 1 : 0)
                        }
                        .scaleEffect(dragging && Motion.plays && !reduceMotion ? 1.02 : 1)
                        .offset(y: websiteOffset(id: site.id, index: index))
                        .zIndex(dragging ? 1 : 0)
                        // The lifted row tracks the pointer. The others slide into the gap it leaves.
                        .animation(dragging ? nil : websiteAnimation, value: websites.map(\.id))
                        .animation(websiteAnimation, value: dragging)
                        .transition(websiteRowTransition)
                }
                Button(action: addWebsite) {
                    Label("Add website", systemImage: "plus")
                        .symbolEffect(.bounce, value: websiteAdds)
                }
                .buttonStyle(.appSecondarySmall)
            }
            .onPreferenceChange(WebsiteRowHeightKey.self) { height in
                if height > 1 { websiteRowHeight = height }
            }
        }
    }

    private var websiteRowTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        )
    }

    @ViewBuilder private func websiteRow(_ site: Binding<WebsiteRow>, index: Int, dragging: Bool) -> some View {
        let label: LocalizedStringKey = index == 0 ? "Website" : "Website \(index + 1)"
        FormField(label: label) {
            HStack(spacing: 8) {
                websiteField(site)
                if websites.count > 1 {
                    websiteControls(id: site.wrappedValue.id, dragging: dragging)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(websiteAnimation, value: websites.count)
        }
    }

    private func websiteField(_ site: Binding<WebsiteRow>) -> some View {
        TextField("Website", text: site.text, prompt: Text(verbatim: "https://example.com"))
            .textFieldStyle(SoftFieldStyle())
            .textContentType(.URL)
            .focused($focusedWebsite, equals: site.wrappedValue.id)
    }

    private func websiteControls(id: UUID, dragging: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                removeWebsite(id)
            } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 38)
                    .accessibilityLabel(Text("Remove"))
            }
            .buttonStyle(.plain)
            .help(Text("Remove"))
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dragging ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 28, height: 38)
                .contentShape(.rect)
                .gesture(websiteDrag(id))
                .onHover { hovering in
                    if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }
                .help(Text("Drag to reorder"))
                .accessibilityLabel(Text("Drag to reorder"))
                .accessibilityAction(named: Text("Move up")) { moveWebsite(id, by: -1) }
                .accessibilityAction(named: Text("Move down")) { moveWebsite(id, by: 1) }
        }
    }

    /// Keeps the grabbed row under the pointer after its slot in the stack has moved.
    private func websiteOffset(id: UUID, index: Int) -> CGFloat {
        guard draggingWebsite == id else { return 0 }
        return dragTranslation - CGFloat(index - dragAnchorIndex) * websiteStride
    }

    private func websiteDrag(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let index = websites.firstIndex { $0.id == id } ?? 0
                if draggingWebsite != id {
                    dragAnchorIndex = index
                    withAnimation(websiteAnimation) { draggingWebsite = id }
                }
                dragTranslation = value.translation.height
                let proposed = min(max(dragAnchorIndex + Int((value.translation.height / websiteStride).rounded()), 0), websites.count - 1)
                guard index != proposed else { return }
                withAnimation(websiteAnimation) {
                    websites.move(fromOffsets: IndexSet(integer: index), toOffset: proposed > index ? proposed + 1 : proposed)
                }
            }
            .onEnded { _ in
                withAnimation(websiteAnimation) {
                    draggingWebsite = nil
                    dragTranslation = 0
                }
            }
    }

    private func addWebsite() {
        let row = WebsiteRow()
        withAnimation(websiteAnimation) {
            websites.append(row)
            websiteAdds += 1
        }
        // The field is inserted by the animation above; focus it once it is on screen.
        Task { @MainActor in focusedWebsite = row.id }
    }

    private func removeWebsite(_ id: UUID) {
        withAnimation(websiteAnimation) {
            websites.removeAll { $0.id == id }
            if draggingWebsite == id {
                draggingWebsite = nil
                dragTranslation = 0
            }
        }
    }

    private func moveWebsite(_ id: UUID, by step: Int) {
        guard let from = websites.firstIndex(where: { $0.id == id }) else { return }
        let dest = from + step
        guard websites.indices.contains(dest) else { return }
        withAnimation(websiteAnimation) {
            websites.move(fromOffsets: IndexSet(integer: from), toOffset: dest > from ? dest + 1 : dest)
        }
    }

    @ViewBuilder private var cardSection: some View {
        FormCard(title: "Card") {
            prop("Cardholder", "cardholderName")
            FormField(label: "Brand") {
                SoftMenu(options: [("", "—")] + ["Visa", "Mastercard", "Amex", "Discover", "JCB", "UnionPay", "Diners Club", "Maestro", "Other"].map { ($0, $0) },
                         selection: binding("brand"), accessibilityLabel: "Brand")
            }
            prop("Card number", "number", secret: true, monospaced: true)
            HStack(alignment: .top, spacing: 12) {
                FormField(label: "Expires") {
                    HStack(spacing: 8) {
                        SoftMenu(options: (1...12).map { (String($0), String(format: "%02d", $0)) }, selection: binding("expMonth"),
                                 placeholder: "Month", accessibilityLabel: "Expiry month")
                        TextField("Year", text: binding("expYear"), prompt: Text(verbatim: "2030"))
                            .textFieldStyle(SoftFieldStyle())
                            .frame(width: 90)
                    }
                }
                prop("Security code", "code", secret: true, monospaced: true)
                    .frame(width: 150)
            }
        }
    }

    @ViewBuilder private var identitySection: some View {
        FormCard(title: "Name") {
            pair(("Title", "title"), ("First name", "firstName"))
            pair(("Middle name", "middleName"), ("Last name", "lastName"))
        }
        FormCard(title: "Contact") {
            pair(("Email", "email"), ("Phone", "phone"))
            pair(("Company", "company"), ("Username", "username"))
        }
        FormCard(title: "Address") {
            prop("Address 1", "address1"); prop("Address 2", "address2")
            pair(("City", "city"), ("State / Province", "state"))
            pair(("Postal code", "postalCode"), ("Country", "country"))
        }
        FormCard(title: "Documents") {
            prop("National ID / SSN", "ssn", secret: true)
            pair(("Passport number", "passportNumber"), ("Licence number", "licenseNumber"), secret: true)
        }
    }

    @ViewBuilder private var sshSection: some View {
        FormCard(title: "Key") {
            FormField(label: "Private key") {
                if showSecrets || (props["privateKey"] ?? "").isEmpty {
                    SoftEditor(text: binding("privateKey"), minHeight: 150, monospaced: true,
                               prompt: "-----BEGIN OPENSSH PRIVATE KEY-----\nPaste a key, or generate one below.")
                } else {
                    Text(verbatim: "•••••••• OpenSSH private key ••••••••")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                }
                Button("Import SSH Key…", systemImage: "square.and.arrow.down") { choosingSSHKey = true }
                    .buttonStyle(.appSecondary)
                    .fileImporter(isPresented: $choosingSSHKey, allowedContentTypes: [.item]) { result in
                        guard case .success(let url) = result else { return }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= 1_048_576 else { throw SSHPrivateKey.Failure.malformed }
                            let data = try Data(contentsOf: url)
                            guard data.count <= 1_048_576, let pem = String(data: data, encoding: .utf8) else {
                                throw SSHPrivateKey.Failure.malformed
                            }
                            let key = try SSHPrivateKey(pem: pem)
                            props["privateKey"] = pem
                            props["publicKey"] = "\(key.type) \(key.publicBlob.base64EncodedString()) \(key.comment)"
                            props["keyFingerprint"] = key.fingerprint
                            sshImportError = nil
                        } catch { sshImportError = String(localized: "Choose a UTF-8, unencrypted private key smaller than 1 MB.") }
                    }
                if let sshImportError { Text(sshImportError).font(.caption).foregroundStyle(.red) }
                Button("Generate Ed25519 Key", systemImage: "wand.and.stars") {
                    let pair = SSHKeyPair.generateEd25519(comment: name.isEmpty ? "" : name)
                    props["privateKey"] = pair.privateKey
                    props["publicKey"] = pair.publicKey
                    props["keyFingerprint"] = pair.fingerprint
                }
                .buttonStyle(.appSecondary)
                .padding(.top, 2)
            }
            prop("Public key", "publicKey", monospaced: true)
            prop("Fingerprint", "keyFingerprint", monospaced: true)
        }
    }

    @ViewBuilder private var customFieldsSection: some View {
        FormCard(title: "Custom fields") {
            ForEach($customFields) { $field in
                HStack(spacing: 8) {
                    TextField("Name", text: $field.name, prompt: Text("Name"))
                        .textFieldStyle(SoftFieldStyle()).frame(width: 130)
                    Group {
                        switch field.kind {
                        case .boolean:
                            Toggle("Value", isOn: Binding(get: { field.value == "true" }, set: { field.value = $0 ? "true" : "false" }))
                                .labelsHidden().toggleStyle(.switch).tint(.brand)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .hidden where !showSecrets:
                            SecureField("Value", text: $field.value, prompt: Text("Value")).textFieldStyle(SoftFieldStyle())
                        default:
                            TextField("Value", text: $field.value, prompt: Text("Value")).textFieldStyle(SoftFieldStyle())
                        }
                    }
                    SoftMenu(options: [(CustomField.Kind.text, String(localized: "Text")), (.hidden, String(localized: "Hidden")),
                                       (.boolean, String(localized: "Yes / No"))],
                             selection: $field.kind, accessibilityLabel: "Type")
                        .frame(width: 110)
                    Button { withAnimation(.snappy) { customFields.removeAll { $0.id == field.id } } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Remove"))
                    }
                    .buttonStyle(.plain).help(Text("Remove"))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Button {
                withAnimation(.snappy) { customFields.append(CustomField(name: "", value: "", kind: .text)) }
            } label: {
                Label("Add Field", systemImage: "plus")
            }
            .buttonStyle(.appSecondary)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { props[key] ?? "" }, set: { props[key] = $0 })
    }

    @ViewBuilder
    private func prop(_ label: LocalizedStringKey, _ key: String, secret: Bool = false, monospaced: Bool = false) -> some View {
        FormField(label: label) {
            Group {
                if secret && !showSecrets {
                    SecureField(label, text: binding(key), prompt: Text(verbatim: ""))
                } else {
                    TextField(label, text: binding(key), prompt: Text(verbatim: ""))
                }
            }
            .textFieldStyle(SoftFieldStyle())
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
        }
    }

    /// Two short fields side by side.
    private func pair(_ a: (LocalizedStringKey, String), _ b: (LocalizedStringKey, String), secret: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            prop(a.0, a.1, secret: secret)
            prop(b.0, b.1, secret: secret)
        }
    }

    /// Fills the code secret from a QR code, and the name and username too when they're still empty.
    private func scanQRCode() async {
        scanning = true
        scanProblem = nil
        defer { scanning = false }
        do {
            guard let link = try await QRScanner.scan() else { return }
            totp = link
            let details = QRScanner.details(of: link)
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let issuer = details.issuer { name = issuer }
            if username.isEmpty, let account = details.account { username = account }
        } catch {
            scanProblem = error.localizedDescription
        }
    }

    // MARK: Load / save

    private func load() {
        defer {
            // After the fields have settled (pickers tidy their values on appear).
            DispatchQueue.main.async { original = draft }
        }
        focus = prefill?.focusTOTP == true ? .totp : .name
        if let ids = prefill?.accountIDs {
            accountId = ids.count == 1 ? ids.first : nil
        } else { accountId = model.defaultAccountId }
        if let keys = prefill?.vaultKeys, keys.count == 1 { destinationVault = keys.first }
        if let path = prefill?.folderPath, let accountId {
            folderId = model.session(for: accountId)?.folders.first { $0.name == path }?.id
        }
        let source: VaultItem
        switch mode {
        case .create:
            if let prefill {
                name = prefill.name
                password = prefill.password
                if !prefill.uri.isEmpty { websites = [WebsiteRow(text: prefill.uri)] }
                if prefill.importSSH { DispatchQueue.main.async { choosingSSHKey = true } }
            }
            return
        case .edit(let item): source = item
        case .clone(let item): source = item
        }
        let item = source
        name = item.name
        username = item.kind == .login ? item.username ?? "" : ""
        password = item.password ?? ""
        totp = item.totpSecret ?? ""
        websites = item.websites.isEmpty ? [WebsiteRow()] : item.websites.map { WebsiteRow(text: $0) }
        notes = item.notes ?? ""
        folderId = item.folderId
        props = item.properties
        customFields = item.customFields.filter { $0.kind != .linked }
        reprompt = item.reprompt
        if case .clone = mode {
            name = String(localized: "\(item.name) - Clone")
            accountId = item.accountId
            if item.organizationId != nil { folderId = nil } // the copy is personal
        }
        if case .edit = mode {
            // A shared item starts out in the shared folders it is already in; its vault stays read-only.
            if item.organizationId != nil { chosenCollections = Set(item.collectionIds) }
            // A personal item offers the vaults it could move into, starting on the one it is in.
            else if destinationVault == nil { destinationVault = AppModel.VaultFilter.personalKey }
        }
    }

    private func save() async {
        guard kind != .unsupported, !saveDisabled else { return }
        switch mode {
        case .edit(let item), .clone(let item): guard model.allowMutation([item.id]) else { return }
        case .create: break
        }
        saving = true
        defer { saving = false }
        let cleanFields = customFields.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let ok: Bool
        switch mode {
        case .create, .clone:
            if let path = prefill?.folderPath, let accountId,
               chosenSession?.folders.contains(where: { $0.name == path }) != true {
                guard let createdFolder = await model.createFolder(name: path, accountId: accountId) else { return }
                folderId = createdFolder
            }
            guard let newKind = AppModel.NewItemKind(kind) else { return }
            var edit = CipherEdit(name: name, notes: notes, folderId: .some(folderId))
            edit.reprompt = reprompt
            edit.favorite = prefill?.favorite ?? false
            if newKind == .login {
                (edit.username, edit.password, edit.totp) = (username, password, totp)
                edit.uris = websiteValues
            }
            edit.properties = props.filter { !$0.value.isEmpty }
            if !cleanFields.isEmpty { edit.customFields = cleanFields }
            ok = await model.createItem(newKind, edit: edit, accountId: accountId, organizationId: creationOrganizationID, collectionIds: creationCollectionIDs)
        case .edit(let item):
            // Send only what changed.
            var edit = CipherEdit()
            if name != item.name { edit.name = name }
            if notes != (item.notes ?? "") { edit.notes = notes }
            if folderId != item.folderId { edit.folderId = .some(folderId) }
            if reprompt != item.reprompt { edit.reprompt = reprompt }
            if item.kind == .login {
                if username != (item.username ?? "") { edit.username = username }
                if password != (item.password ?? "") { edit.password = password }
                if totp != (item.totpSecret ?? "") { edit.totp = totp }
                if websiteValues != item.websites { edit.uris = websiteValues }
            }
            edit.properties = props.filter { item.properties[$0.key, default: ""] != $0.value }
            if cleanFields != item.customFields.filter({ $0.kind != .linked }) { edit.customFields = cleanFields }
            // Folders are personal; the item is leaving its own behind when it moves into a shared vault.
            if movingTo != nil, item.folderId != nil { edit.folderId = .some(nil) }
            let changed = edit != CipherEdit()
            // Fields first, then the move: sharing re-encrypts the server's copy of the item, so it has to run
            // after the edit or the new values would be overwritten with the old ones.
            if changed, !(await model.updateItem(item.id, edit: edit)) { return }
            if let organizationId = movingTo {
                let collectionIds = Array(chosenCollections)
                guard await model.share([item.id], organizationId: organizationId, collectionIds: collectionIds) else { return }
                ok = true
            } else if item.organizationId != nil, Set(item.collectionIds) != chosenCollections {
                guard await model.setCollections(item, collectionIds: Array(chosenCollections)) else { return }
                ok = true
            } else {
                ok = true
            }
        }
        if ok { close(saved: true) }
    }
}

/// Password generator: length, character classes, look-alike avoidance, entropy meter.
/// Four-segment strength meter.
struct StrengthMeter: View {
    let bits: Double

    init(bits: Double) { self.bits = bits }
    init(password: String) {
        var pool = 0
        if password.contains(where: \.isLowercase) { pool += 26 }
        if password.contains(where: \.isUppercase) { pool += 26 }
        if password.contains(where: \.isNumber) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 15 }
        bits = Double(password.count) * log2(Double(max(pool, 2)))
    }

    /// 1…4 with a label and colour; shared with the item card.
    var level: (Int, LocalizedStringKey, Color) {
        switch bits {
        case ..<40: (1, "Weak", .red)
        case ..<64: (2, "Fair", .orange)
        case ..<90: (3, "Strong", .green)
        default: (4, "Very strong", .green)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    // Segments fill (or empty) one after another, each with a little spring.
                    Capsule().fill(i < level.0 ? level.2 : Color.secondary.opacity(0.2)).frame(height: 4)
                        .animation(.spring(duration: 0.35, bounce: 0.3).delay(Double(i) * 0.05), value: level.0)
                }
            }
            .frame(width: 120)
            Text(level.1).font(.caption).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.snappy, value: level.0)
            Spacer()
        }
    }
}
