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
        var apiKey = false
        var practiceAPIKey = false
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: Mode
    var prefill: Prefill?
    /// In the detail panel rather than a sheet: Cancel and Save sit at the top, by the title.
    var inPanel = false
    var onSaved: (() -> Void)? = nil

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
    @State private var apiPresetFieldIDs: Set<UUID> = []
    @State private var apiVariableCustomized = false
    @State private var apiKeyPresentation: Bool?
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
    /// Attachment changes stay local to the form until Save, just like the item's text fields.
    @State private var attachmentRows: [AttachmentDraft] = []
    @State private var choosingAttachments = false
    @State private var choosingReplacement = false
    @State private var replacementTarget: UUID?
    @State private var attachmentDropTargeted = false

    /// Row height plus the stack's gap, so a drag swaps as the pointer crosses the next row.
    private var websiteStride: CGFloat { websiteRowHeight + 12 }
    private var websiteAnimation: Animation {
        reduceMotion || !Motion.plays ? .easeOut(duration: 0.15) : .snappy(duration: 0.34, extraBounce: 0.05)
    }

    private struct WebsiteRow: Identifiable, Equatable {
        var id = UUID()
        var text = ""
    }

    private struct ChosenFile: Equatable {
        let url: URL
        let size: Int
        let sizeName: String
    }

    /// An existing attachment, a newly chosen file, or an existing attachment with a replacement chosen.
    private struct AttachmentDraft: Identifiable, Equatable {
        var id = UUID()
        var original: VaultItem.Attachment?
        var chosen: ChosenFile?
        var name: String

        var sizeName: String { chosen?.sizeName ?? original?.sizeName ?? "" }
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
        var attachments: [AttachmentDraft]
    }

    private var draft: Draft {
        Draft(name: name, username: username, password: password, totp: totp, notes: notes, uris: websiteValues, folderId: folderId, accountId: accountId, destinationVault: destinationVault,
              destinationCollection: destinationCollection, chosenCollections: chosenCollections,
              props: props.filter { !$0.value.isEmpty }, customFields: customFields, reprompt: reprompt,
              attachments: attachmentRows)
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
        let keys = customFields.filter { $0.name == APIKeyTemplate.keyField }
        let missingAPIKey = isAPIKey && (hasDuplicateAPIFields || apiVariableProblem != nil || keys.count != 1 || !keys.contains { $0.kind == .hidden && !$0.value.isEmpty && !$0.value.utf8.contains(0) && $0.value.utf8.count <= 32_768 })
        let invalidAttachmentName = attachmentRows.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return missingAPIKey || invalidAttachmentName || name.trimmingCharacters(in: .whitespaces).isEmpty || newFolderIn != nil || (!mode.isEdit && accountId == nil)
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
        if isAPIKey { return mode.isEdit ? "Edit API Key" : "New API Key" }
        return switch mode {
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
        if isAPIKey { return "key.horizontal" }
        return switch kind {
        case .unsupported: "questionmark.square"
        case .login: "key.fill"; case .note: "note.text"; case .card: "creditcard.fill"
        case .identity: "person.crop.rectangle.fill"; case .sshKey: "terminal.fill"
        }
    }

    private var subtitle: LocalizedStringKey {
        if isAPIKey { return "Save a key from your provider, then choose which tool may use it." }
        return switch kind {
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
                        destinationCollection = writableCollections.soleWritableCollection
                    }
                }
                FormField(label: "Name") {
                    TextField("Name", text: $name, prompt: Text("e.g. GitHub"))
                        .textFieldStyle(SoftFieldStyle())
                        .focused($focus, equals: .name)
                        .accessibilityIdentifier("itemName")
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
                                .onChange(of: destinationVault) {
                                    // One folder to choose from: pick it, rather than asking for a click that decides nothing.
                                    destinationCollection = writableCollections.soleWritableCollection
                                    folderId = nil
                                    newFolderIn = nil
                                }
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

            if isAPIKey {
                apiKeySection
                DisclosureGroup("Additional fields") { customFieldsSection }
            } else { customFieldsSection }

            FormCard(title: "Notes") {
                SoftEditor(text: $notes, minHeight: kind == .note && !isAPIKey ? 200 : 80)
                    .accessibilityIdentifier("itemNotes")
            }

            attachmentsSection

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

    // MARK: Attachments

    /// Add, rename, replace and remove attachments in the same Save/Cancel transaction as the rest of the form.
    /// The chosen security-scoped URLs are retained and only read when Save is pressed.
    private var attachmentsSection: some View {
        FormCard(title: "Attachments") {
            if attachmentRows.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "paperclip").font(.system(size: 18)).foregroundStyle(.secondary)
                    Text("Drop files here, or choose files below.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(Color.formInputFill, in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(dash: [5, 4])))
            } else {
                VStack(spacing: 10) {
                    ForEach(attachmentRows) { row in
                        attachmentRow($attachmentRows.identifiedElement(id: row.id, fallback: row))
                    }
                }
            }

            HStack(spacing: 10) {
                Button { choosingAttachments = true } label: {
                    Label("Add Files…", systemImage: "plus")
                }
                .buttonStyle(.appSecondarySmall)
                Spacer()
                Text(mode.isEdit ? "Changes are applied when you save." : "Files upload after the item is saved.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text("Files are encrypted before upload. Each file can be up to 500 MB.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .dropDestination(for: URL.self) { urls, _ in
            stageAttachments(urls)
        } isTargeted: { attachmentDropTargeted = $0 }
        .overlay {
            if attachmentDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.brand.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: attachmentDropTargeted)
        .fileImporter(isPresented: $choosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { _ = stageAttachments(urls) }
        }
        .fileImporter(isPresented: $choosingReplacement, allowedContentTypes: [.item]) { result in
            defer { replacementTarget = nil }
            guard case .success(let url) = result, let replacementTarget,
                  let file = chosenFile(url), let index = attachmentRows.firstIndex(where: { $0.id == replacementTarget }) else { return }
            attachmentRows[index].chosen = file
            attachmentRows[index].name = url.lastPathComponent
        }
    }

    private func attachmentRow(_ row: Binding<AttachmentDraft>) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (row.wrappedValue.name as NSString).pathExtension) ?? .data))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                TextField("File name", text: row.name, prompt: Text("File name"))
                    .textFieldStyle(SoftFieldStyle())
                HStack(spacing: 6) {
                    Text(verbatim: row.wrappedValue.sizeName)
                    if row.wrappedValue.original != nil, row.wrappedValue.chosen != nil {
                        Label("Replacement selected", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if row.wrappedValue.original != nil {
                Button("Replace…") {
                    replacementTarget = row.wrappedValue.id
                    choosingReplacement = true
                }
                .buttonStyle(.appSecondarySmall)
            }
            Button {
                withAnimation(.snappy(duration: 0.22)) { attachmentRows.removeAll { $0.id == row.wrappedValue.id } }
            } label: {
                Image(systemName: "trash").frame(width: 24, height: 24).accessibilityLabel(Text("Remove attachment"))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(Text("Remove attachment"))
        }
        .padding(.vertical, 2)
    }

    @discardableResult
    private func stageAttachments(_ urls: [URL]) -> Bool {
        let files = urls.compactMap(chosenFile)
        guard !files.isEmpty else { return false }
        withAnimation(.snappy(duration: 0.22)) {
            attachmentRows.append(contentsOf: files.map { AttachmentDraft(original: nil, chosen: $0, name: $0.url.lastPathComponent) })
        }
        return true
    }

    private func chosenFile(_ url: URL) -> ChosenFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else {
                model.flash(String(localized: "Choose files, not folders."))
                return nil
            }
            let size = values.fileSize ?? 0
            guard size <= AppModel.attachmentLimit else {
                model.flash(String(localized: "“\(url.lastPathComponent)” is larger than 500 MB."))
                return nil
            }
            return ChosenFile(url: url, size: size,
                              sizeName: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        } catch {
            model.flash(error.localizedDescription)
            return nil
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
                    .onChange(of: destinationVault) {
                        // One folder to choose from: pick it, rather than asking for a click that decides nothing.
                        chosenCollections = writableVaultCollections.soleWritableCollection.map { [$0] } ?? []
                        folderId = nil
                        newFolderIn = nil
                    }
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
                ForEach(websites) { site in
                    let index = websites.firstIndex(where: { $0.id == site.id }) ?? 0
                    let dragging = draggingWebsite == site.id
                    websiteRow(
                        $websites.identifiedElement(id: site.id, fallback: site),
                        index: index,
                        dragging: dragging
                    )
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
            ForEach(customFields) { field in
                let fieldBinding = $customFields.identifiedElement(id: field.id, fallback: field)
                if !isAPIKey || !apiPresetFieldIDs.contains(field.id) {
                HStack(spacing: 8) {
                    // Distinct titles from the item Name field — identical "Name" labels made
                    // AppKit's shared field editor more likely to commit into the wrong binding.
                    TextField("Field name", text: fieldBinding.name, prompt: Text("Name"))
                        .textFieldStyle(SoftFieldStyle()).frame(width: 130)
                        .accessibilityIdentifier("customFieldName-\(field.id.uuidString)")
                    Group {
                        switch field.kind {
                        case .boolean:
                            Toggle("Field value", isOn: Binding(
                                get: { fieldBinding.wrappedValue.value == "true" },
                                set: { fieldBinding.wrappedValue.value = $0 ? "true" : "false" }
                            ))
                                .labelsHidden().toggleStyle(.switch).tint(.brand)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .hidden where !showSecrets:
                            SecureField("Field value", text: fieldBinding.value, prompt: Text("Value")).textFieldStyle(SoftFieldStyle())
                                .accessibilityIdentifier("customFieldValue-\(field.id.uuidString)")
                        default:
                            TextField("Field value", text: fieldBinding.value, prompt: Text("Value")).textFieldStyle(SoftFieldStyle())
                                .accessibilityIdentifier("customFieldValue-\(field.id.uuidString)")
                        }
                    }
                    SoftMenu(options: [(CustomField.Kind.text, String(localized: "Text")), (.hidden, String(localized: "Hidden")),
                                       (.boolean, String(localized: "Yes / No"))],
                             selection: fieldBinding.kind, accessibilityLabel: "Type")
                        .frame(width: 110)
                    Button { withAnimation(.snappy) { customFields.removeAll { $0.id == field.id } } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Remove"))
                    }
                    .accessibilityIdentifier("customFieldRemove-\(field.id.uuidString)")
                    .buttonStyle(.plain).help(Text("Remove"))
                }
                .id(field.id)
                .transition(.opacity.combined(with: .move(edge: .top)))
                }
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

    private var isAPIKey: Bool {
        if prefill?.apiKey == true { return true }
        guard apiKeyPresentation ?? model.showsAPIKeyTools else { return false }
        switch mode {
        case .edit(let item), .clone(let item): return item.isAPIKey
        case .create: return false
        }
    }

    private func apiField(_ name: String, kind: CustomField.Kind) -> Binding<String> {
        Binding(get: { customFields.first { apiPresetFieldIDs.contains($0.id) && $0.name == name && $0.kind == kind }?.value ?? "" }, set: { value in
            if let index = customFields.firstIndex(where: { apiPresetFieldIDs.contains($0.id) && $0.name == name && $0.kind == kind }) {
                customFields[index].value = value
            } else {
                let field = CustomField(name: name, value: value, kind: kind)
                customFields.append(field); apiPresetFieldIDs.insert(field.id)
            }
        })
    }

    private var hasDuplicateAPIFields: Bool {
        [APIKeyTemplate.keyField, APIKeyTemplate.serviceField, APIKeyTemplate.environmentField]
            .contains { name in customFields.filter { $0.name == name }.count > 1 }
    }

    private var apiService: Binding<String> {
        Binding(get: { apiField(APIKeyTemplate.serviceField, kind: .text).wrappedValue }, set: { value in
            apiField(APIKeyTemplate.serviceField, kind: .text).wrappedValue = value
            if !apiVariableCustomized {
                apiField(APIKeyTemplate.environmentField, kind: .text).wrappedValue = APIKeyTemplate.suggestedVariable(service: value)
            }
        })
    }

    private var apiVariable: Binding<String> {
        Binding(get: { apiField(APIKeyTemplate.environmentField, kind: .text).wrappedValue }, set: { value in
            apiVariableCustomized = true
            apiField(APIKeyTemplate.environmentField, kind: .text).wrappedValue = value
        })
    }

    private var apiVariableProblem: String? { APIKeyTemplate.variableProblem(apiVariable.wrappedValue) }

    private func prepareAPIFields() {
        guard isAPIKey else { return }
        if !customFields.contains(where: { $0.name == APIKeyTemplate.serviceField && $0.kind == .text }) {
            customFields.append(CustomField(name: APIKeyTemplate.serviceField, value: "", kind: .text))
        }
        if case .create = mode { apiVariableCustomized = false }
        else { apiVariableCustomized = customFields.contains { $0.name == APIKeyTemplate.environmentField && $0.kind == .text } }
        if !customFields.contains(where: { $0.name == APIKeyTemplate.environmentField && $0.kind == .text }) {
            let service = customFields.first { $0.name == APIKeyTemplate.serviceField && $0.kind == .text }?.value ?? ""
            customFields.append(CustomField(name: APIKeyTemplate.environmentField, value: APIKeyTemplate.suggestedVariable(service: service), kind: .text))
        }
        apiPresetFieldIDs = APIKeyTemplate.primaryFieldIDs(in: customFields)
    }

    private var apiKeySection: some View {
        FormCard(title: "API Key") {
            FormField(label: "Service", note: "The provider that issued this key, for example Anthropic or OpenAI.") {
                TextField("Service", text: apiService)
                    .textFieldStyle(SoftFieldStyle()).accessibilityIdentifier("apiKeyService")
            }
            FormField(label: "API key", note: "Stored encrypted in your vault. You won't need to paste it each time you launch a tool.") {
                Group {
                    if showSecrets { TextField("API key", text: apiField(APIKeyTemplate.keyField, kind: .hidden)) }
                    else { SecureField("API key", text: apiField(APIKeyTemplate.keyField, kind: .hidden)) }
                }
                .textFieldStyle(SoftFieldStyle()).accessibilityIdentifier("apiKeyValue")
            }
            FormField(label: "Default environment variable", note: "The name your tool reads, for example OPENAI_API_KEY. You can choose a different name for each tool during setup.") {
                TextField("API_KEY", text: apiVariable)
                    .textFieldStyle(SoftFieldStyle()).font(.system(size: 13, design: .monospaced))
                    .accessibilityIdentifier("apiKeyVariable")
            }
            if let problem = apiVariableProblem {
                Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.orange)
                    .accessibilityIdentifier("apiKeyVariableError")
            }
            if hasDuplicateAPIFields {
                Text("An additional field uses the reserved name api-key, service or environment-variable. Rename or remove that duplicate under Additional fields before saving.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }

    private func load() {
        if apiKeyPresentation == nil { apiKeyPresentation = model.showsAPIKeyTools }
        defer {
            prepareAPIFields()
            // After the fields have settled (pickers tidy their values on appear).
            DispatchQueue.main.async { original = draft }
        }
        focus = prefill?.focusTOTP == true ? .totp : .name
        if let ids = prefill?.accountIDs {
            accountId = ids.count == 1 ? ids.first : nil
        } else { accountId = model.defaultAccountId }
        if let keys = prefill?.vaultKeys, keys.count == 1 { destinationVault = keys.first }
        // Opened straight into a shared vault with one folder to choose from: pick it, as the picker's onChange would.
        if !mode.isEdit, destinationCollection == nil { destinationCollection = writableCollections.soleWritableCollection }
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
                if prefill.apiKey {
                    customFields = APIKeyTemplate.fields
                    if prefill.practiceAPIKey {
                        for index in customFields.indices {
                            if customFields[index].name == APIKeyTemplate.keyField { customFields[index].value = "triwarden-preview-only" }
                            if customFields[index].name == APIKeyTemplate.environmentField { customFields[index].value = "TRIWARDEN_TEST_KEY" }
                        }
                    }
                }
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
        if case .edit = mode {
            attachmentRows = item.attachments.map { AttachmentDraft(original: $0, chosen: nil, name: $0.fileName) }
        }
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
        let savedItemID: String
        switch mode {
        case .create, .clone:
            if let path = prefill?.folderPath, let accountId,
               chosenSession?.folders.contains(where: { $0.name == path }) != true {
                guard let createdFolder = await model.createFolder(name: path, accountId: accountId) else { return }
                folderId = createdFolder
            }
            guard let newKind = AppModel.NewItemKind(kind) else { return }
            var savedName = name
            if cleanFields.contains(where: { $0.kind == .hidden && !$0.value.isEmpty && $0.value == savedName }) {
                // Prefer an explicit prefill title; otherwise a generic label — never the secret.
                let fallback = prefill?.name.trimmingCharacters(in: .whitespaces) ?? ""
                savedName = fallback.isEmpty ? String(localized: "Item") : fallback
            }
            var edit = CipherEdit(name: savedName, notes: notes, folderId: .some(folderId))
            edit.reprompt = reprompt
            edit.favorite = prefill?.favorite ?? false
            if newKind == .login {
                (edit.username, edit.password, edit.totp) = (username, password, totp)
                edit.uris = websiteValues
            }
            edit.properties = props.filter { !$0.value.isEmpty }
            if !cleanFields.isEmpty { edit.customFields = cleanFields }
            guard let id = await model.createItemID(newKind, edit: edit, accountId: accountId,
                                                    organizationId: creationOrganizationID, collectionIds: creationCollectionIDs) else { return }
            savedItemID = id
        case .edit(let item):
            // Send only what changed.
            var edit = CipherEdit()
            // Safety net: if a focus mix-up pasted a hidden custom-field value into Name, keep the
            // original title so the secret is not stored (and shown) as the item name in plaintext.
            if name != item.name {
                let nameLooksLikeHiddenField = cleanFields.contains {
                    $0.kind == .hidden && !$0.value.isEmpty && $0.value == name
                }
                if !nameLooksLikeHiddenField { edit.name = name }
            }
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
            } else if item.organizationId != nil, Set(item.collectionIds) != chosenCollections {
                guard await model.setCollections(item, collectionIds: Array(chosenCollections)) else { return }
            }
            savedItemID = item.id
        }
        // The item itself now exists or has been updated. If an attachment request fails, close onto its detail
        // view so the successful work is visible and retrying cannot accidentally create a duplicate item.
        _ = await saveAttachments(to: savedItemID)
        onSaved?()
        close(saved: true)
    }

    private var originalAttachments: [VaultItem.Attachment] {
        if case .edit(let item) = mode { return item.attachments }
        return []
    }

    private var hasAttachmentChanges: Bool {
        let kept = Set(attachmentRows.compactMap { $0.original?.id })
        if kept != Set(originalAttachments.map(\.id)) { return true }
        return attachmentRows.contains { row in
            row.original == nil || row.chosen != nil || row.original.map { row.name != $0.fileName } == true
        }
    }

    /// Uploads additions and safe replacements before processing removals, so failure cannot discard an existing
    /// attachment before its successor is on the server.
    private func saveAttachments(to itemID: String) async -> Bool {
        guard hasAttachmentChanges else { return true }
        guard let item = model.items.first(where: { $0.id == itemID }) else {
            model.flash(String(localized: "The item was saved, but its attachments could not be updated."))
            return false
        }

        for row in attachmentRows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let original = row.original {
                if let chosen = row.chosen {
                    guard await model.replaceAttachment(original, of: item, with: chosen.url, named: name) else { return false }
                } else if name != original.fileName {
                    guard await model.renameAttachment(original, of: item, to: name) else { return false }
                }
            } else if let chosen = row.chosen {
                guard await model.addAttachment(chosen.url, named: name, to: item) else { return false }
            }
        }

        let kept = Set(attachmentRows.compactMap { $0.original?.id })
        for attachment in originalAttachments where !kept.contains(attachment.id) {
            guard await model.deleteAttachment(attachment, of: item) else { return false }
        }
        return true
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
