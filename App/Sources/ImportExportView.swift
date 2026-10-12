import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultwardenAPI

// File › Import… / Export Vault…, in the formats of Bitwarden's official clients.

/// Which account a transfer works on: a picker when more than one is unlocked.
private struct AccountPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var accountId: String
    var allowedIDs: [String]? = nil
    var allowEmpty = false
    private var sessions: [AccountSession] { model.sessions.filter { allowedIDs?.contains($0.id) ?? true } }

    var body: some View {
        if sessions.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                SheetLabel("Account")
                SoftMenu(options: (allowEmpty ? [("", String(localized: "Choose an account…"))] : []) + sessions.map { ($0.id, $0.account.email) }, selection: $accountId,
                         accessibilityLabel: "Account")
            }
        }
    }
}

/// Personal or an organization: where an export reads from or an import goes to.
private struct VaultPicker: View {
    let vaults: [(id: String?, name: String)]
    @Binding var selection: String?
    let label: LocalizedStringKey

    var body: some View {
        if vaults.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                SheetLabel(label)
                SoftMenu(options: vaults.map { ($0.id, $0.name) }, selection: $selection, accessibilityLabel: label)
            }
        }
    }
}

private struct SheetLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
}

/// Title row shared by both sheets: the app's form header.
private struct SheetHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View { FormHeader(symbol: symbol, title: title, subtitle: subtitle).padding(.horizontal, -4) }
}

// MARK: - Export

struct ExportSheet: View {
    var initialAccount: String?
    @Environment(AppModel.self) private var model
    @State private var vaultId: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var formatRaw = VaultExport.Format.encryptedJSON.rawValue
    @State private var accountId = ""
    @State private var filePassword = ""
    @State private var confirmPassword = ""
    @State private var masterPassword = ""
    @State private var error: String?
    @State private var working = false

    private var format: VaultExport.Format { VaultExport.Format(rawValue: formatRaw) ?? .encryptedJSON }
    private var session: AccountSession? { model.session(for: accountId) ?? model.sessions.first }

    private var ready: Bool {
        guard !masterPassword.isEmpty, session != nil, !working else { return false }
        return format != .encryptedJSON || (!filePassword.isEmpty && filePassword == confirmPassword)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(symbol: "square.and.arrow.up", title: "Export Vault",
                        subtitle: "Your personal items and folders, in a file any Bitwarden app can import.")

            AccountPicker(accountId: $accountId)
            VaultPicker(vaults: session?.transferVaults() ?? [], selection: $vaultId, label: "Vault")

            VStack(alignment: .leading, spacing: 8) {
                SheetLabel("Format")
                AppSegmented(options: [(VaultExport.Format.encryptedJSON, LocalizedStringKey("Password-protected")),
                                       (.json, LocalizedStringKey("JSON")), (.csv, LocalizedStringKey("CSV"))],
                             selection: Binding(get: { format }, set: { formatRaw = $0.rawValue; error = nil }))
                // Every format's line laid over the others, so switching never changes the sheet's height (a height
                // change mid-switch broke the segment's sliding thumb).
                ZStack(alignment: .topLeading) {
                    ForEach([VaultExport.Format.encryptedJSON, .json, .csv], id: \.self) { option in
                        Text(Self.description(option)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(option == format ? 1 : 0)
                            .accessibilityHidden(option != format)
                    }
                }
                // The text fades; the segment keeps its own spring (an animation set here would override it).
                .animation(.easeInOut(duration: 0.2), value: format)
            }

            // The file password for an encrypted file; for a plain one, the same space warns that it isn't.
            VStack(alignment: .leading, spacing: 8) {
                SheetLabel("File password")
                PasswordField(title: "File password", text: $filePassword)
                PasswordField(title: "Confirm file password", text: $confirmPassword, prompt: "Confirm file password")
                Text("The passwords don't match.").font(.system(size: 12)).foregroundStyle(.red)
                    .opacity(!confirmPassword.isEmpty && filePassword != confirmPassword ? 1 : 0)
            }
            .opacity(format == .encryptedJSON ? 1 : 0)
            .disabled(format != .encryptedJSON)
            .accessibilityHidden(format != .encryptedJSON)
            .overlay {
                if format != .encryptedJSON {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Not encrypted", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                        Text("Anyone who gets this file can read every password in it. Keep it off shared and synced folders, and delete it when you're done. To keep a backup, choose Password-protected.")
                            .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.22)))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: format)

            VStack(alignment: .leading, spacing: 8) {
                SheetLabel("Master password")
                PasswordField(title: "Master password", text: $masterPassword, prompt: "Confirm it's you", onSubmit: export)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red)
            }

            HStack {
                Text("Attachments and items in Trash are not exported.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Button("Export…", action: export).buttonStyle(.appPrimary).keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { if accountId.isEmpty { accountId = initialAccount ?? model.sessions.first?.id ?? "" } }
        .onChange(of: accountId) { vaultId = nil }
    }

    private static func description(_ format: VaultExport.Format) -> LocalizedStringKey {
        switch format {
        case .encryptedJSON: "Encrypted with a password you choose. Recommended: Bitwarden and Triwarden can import it on any device."
        case .json: "Everything, readable by any app: logins, notes, cards, identities, SSH keys, passkeys and folders."
        case .csv: "Logins and secure notes only, for spreadsheets and other password managers."
        }
    }

    private func export() {
        guard ready, let session else { return }
        guard model.verifyMasterPassword(masterPassword, accountId: session.id) else {
            error = String(localized: "That master password isn't right.")
            return
        }
        working = true
        defer { working = false }
        let result: (data: Data, skipped: Int, count: Int)
        do {
            result = try session.export(format, filePassword: filePassword, organizationId: vaultId)
        } catch {
            self.error = String(localized: "Couldn't read the vault. Sync, then try again.")
            return
        }
        let panel = NSSavePanel()
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            .replacingOccurrences(of: "T", with: "")
        panel.nameFieldStringValue = "triwarden_export_\(stamp).\(format == .csv ? "csv" : "json")"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Straight to the chosen file, readable by this user only; never via a temporary copy.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: result.data, attributes: [.posixPermissions: 0o600]) else {
            error = String(localized: "Couldn't save the file there.")
            return
        }
        let count = result.count
        model.flash(result.skipped > 0
                    ? String(localized: "Exported \(count) items · \(result.skipped) not supported by CSV")
                    : String(localized: "Exported \(count) items"))
        dismiss()
    }
}

// MARK: - Import

struct ImportSheet: View {
    var initialFile: URL?
    @Environment(AppModel.self) private var model
    @State private var vaultId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var file: URL?
    @State private var fileData: Data?
    @State private var filePassword = ""
    @State private var needsPassword = false
    @State private var preview: ImportPreview?
    @State private var skipDuplicates = true
    @State private var error: String?
    @State private var phase = Phase.choose
    @State private var dropTargeted = false

    enum Phase { case choose, preview, importing, done(Int), interrupted }
    @State private var syncingImport = false
    @State private var deliveryReport: String?

    private var session: AccountSession? { model.session(for: accountId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(symbol: "square.and.arrow.down", title: "Import",
                        subtitle: "From Bitwarden, 1Password, LastPass, KeePass, Proton Pass, Dashlane, Apple Passwords or your browser.")
            switch phase {
            case .choose: chooser
            case .preview: previewBody
            case .importing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Encrypting and importing…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .interrupted:
                Text("Import stopped. Sync and inspect your vault before importing again.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            case .done(let count):
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                    Text("Imported \(count) items").font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            if let deliveryReport {
                Text(deliveryReport).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            if accountId.isEmpty {
                let ids = model.importAccountIDs ?? [model.defaultAccountId].compactMap { $0 }
                accountId = ids.count == 1 ? ids[0] : ""
            }
            if let initialFile { load(initialFile) }
        }
    }

    // MARK: Choose

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            AccountPicker(accountId: $accountId, allowedIDs: model.importAccountIDs, allowEmpty: true)
            if needsPassword, let file {
                VStack(alignment: .leading, spacing: 8) {
                    SheetLabel("“\(file.lastPathComponent)” is password-protected")
                    PasswordField(title: "File password", text: $filePassword, onSubmit: read)
                }
            } else {
                Button(action: choose) {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.arrow.up").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("Choose a file, or drop it here").font(.system(size: 13, weight: .medium))
                        Text("JSON, CSV, KeePass XML or 1Password .1pux").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .background(Color.primary.opacity(dropTargeted ? 0.08 : 0.04), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(dropTargeted ? 0.25 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    load(url)
                    return true
                } isTargeted: { dropTargeted = $0 }
            }
        }
    }

    // MARK: Preview

    private var included: [ImportedItem] {
        guard let preview else { return [] }
        return skipDuplicates ? preview.items.filter { !isDuplicate($0) } : preview.items
    }

    private var duplicateCount: Int { preview?.items.filter(isDuplicate).count ?? 0 }

    /// Same name, username and site as an item already in the target account.
    private func isDuplicate(_ item: ImportedItem) -> Bool {
        let name = item.name.lowercased()
        return model.items.contains { existing in
            existing.accountId == accountId && existing.organizationId == vaultId && !existing.isDeleted && existing.name.lowercased() == name
                && (existing.username ?? "") == (item.username ?? "") && existing.host == item.host
        }
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preview {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(verbatim: file?.lastPathComponent ?? "").font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(formatName(preview.format)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                AccountPicker(accountId: $accountId, allowedIDs: model.importAccountIDs, allowEmpty: true)
                VaultPicker(vaults: session?.transferVaults() ?? [], selection: $vaultId, label: "Import into")

                let counts = Dictionary(grouping: included, by: \.type).mapValues(\.count)
                HStack(spacing: 8) {
                    ForEach([1, 2, 3, 4, 5], id: \.self) { type in
                        if let n = counts[type] { countChip(n, type) }
                    }
                    if !preview.folders.isEmpty {
                        let used = Set(included.compactMap(\.folder)).count
                        Label(vaultId == nil ? "\(used) folders" : "\(used) shared folders", systemImage: vaultId == nil ? "folder" : "rectangle.stack").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 26).background(Color.primary.opacity(0.06), in: .capsule)
                    }
                }

                if duplicateCount > 0 {
                    Toggle(isOn: $skipDuplicates) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Skip \(duplicateCount) likely duplicates").font(.system(size: 13))
                            Text("Same name, username and website as an item you already have.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.trailingSwitch)
                }

                if !preview.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(preview.problems.count) entries can't be imported", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                        ForEach(Array(preview.problems.prefix(5).enumerated()), id: \.offset) { _, problem in
                            Text(describe(problem)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func countChip(_ n: Int, _ type: Int) -> some View {
        let (symbol, title): (String, LocalizedStringKey) = switch type {
        case 1: ("key", "\(n) logins")
        case 2: ("note.text", "\(n) notes")
        case 3: ("creditcard", "\(n) cards")
        case 4: ("person.crop.rectangle", "\(n) identities")
        default: ("terminal", "\(n) SSH keys")
        }
        return Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(height: 26).background(Color.primary.opacity(0.06), in: .capsule)
    }

    private func formatName(_ format: ImportPreview.Format) -> LocalizedStringKey {
        switch format {
        case .bitwardenJSON: "Bitwarden JSON"
        case .bitwardenPasswordProtected: "Bitwarden JSON, password-protected"
        case .bitwardenAccountEncrypted: "Bitwarden JSON, encrypted with your account"
        case .bitwardenCSV: "Bitwarden CSV"
        case .chromeCSV: "Chrome, Edge, Brave or Arc CSV"
        case .safariCSV: "Safari or Apple Passwords CSV"
        case .firefoxCSV: "Firefox CSV"
        case .onePassword1pux: "1Password (.1pux)"
        case .onePasswordCSV: "1Password CSV"
        case .lastPassCSV: "LastPass CSV"
        case .keePassXCCSV: "KeePassXC CSV"
        case .keePassXML: "KeePass 2 XML"
        case .protonPassCSV: "Proton Pass CSV"
        case .dashlaneCSV: "Dashlane CSV"
        }
    }

    private func describe(_ problem: ImportProblem) -> String {
        switch problem {
        case .unknownType(let item): String(localized: "Item \(item): unknown item type")
        case .unsupportedRow(let row, let type): String(localized: "Row \(row): “\(type)” items can't be imported from CSV")
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack {
            Text("Encrypted on this Mac before anything is sent.").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            switch phase {
            case .choose:
                Button("Cancel") { dismiss() }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                if needsPassword {
                    Button("Continue", action: read).buttonStyle(.appPrimary).keyboardShortcut(.defaultAction).disabled(filePassword.isEmpty)
                }
            case .preview:
                Button("Back") { reset() }.buttonStyle(.appSecondary)
                Button("Import \(included.count) Items", action: runImport)
                    .buttonStyle(.appPrimary).keyboardShortcut(.defaultAction).disabled(included.isEmpty || session == nil)
            case .importing:
                EmptyView()
            case .done, .interrupted:
                if error != nil || deliveryReport != nil {
                    Button("Sync Now") {
                        syncingImport = true
                        Task {
                            defer { syncingImport = false }
                            do {
                                guard let session else { throw AccountSession.WriteError.offline }
                                try await session.refresh(); error = nil
                            }
                            catch { self.error = String(localized: "Couldn't sync. The vault on this Mac is unchanged.") }
                        }
                    }.buttonStyle(.appSecondary).disabled(syncingImport)
                }
                Button("Done") { dismiss() }.buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText, .xml] + [UTType(filenameExtension: "1pux")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = String(localized: "Couldn't open that file.")
            return
        }
        file = url
        fileData = data
        filePassword = ""
        needsPassword = false
        read()
    }

    private func read() {
        guard let fileData, let session else { return }
        do {
            preview = try session.previewImport(fileData, password: needsPassword ? filePassword : nil)
            error = nil
            withAnimation(.snappy) { phase = .preview }
        } catch .passwordRequired {
            withAnimation(.snappy) { needsPassword = true }
        } catch .wrongPassword {
            error = String(localized: "That file password isn't right.")
        } catch .otherAccount {
            error = String(localized: "This file is encrypted with another account's key. Import it into that account, or export it again as password-protected.")
        } catch .empty {
            error = String(localized: "There's nothing to import in this file.")
        } catch {
            self.error = String(localized: "This file isn't in a format Triwarden can import.")
        }
    }

    private func reset() {
        withAnimation(.snappy) { phase = .choose; preview = nil; needsPassword = false; file = nil; fileData = nil }
    }

    private func runImport() {
        guard let preview, let session else { return }
        let items = included
        deliveryReport = nil
        error = nil
        withAnimation(.snappy) { phase = .importing }
        Task {
            do {
                let synced = try await session.importItems(items, folders: preview.folders, organizationId: vaultId)
                if !synced { error = String(localized: "Import saved. Sync failed; do not import the file again.") }
                withAnimation(.snappy) { phase = .done(items.count) }
            } catch let delivery as ImportDeliveryError {
                self.deliveryReport = String(localized: "Confirmed: \(delivery.confirmed). Unconfirmed: \(delivery.uncertain). Not sent: \(delivery.notSent).")
                withAnimation(.snappy) { phase = .interrupted }
            } catch {
                self.error = String(localized: "The import didn't go through: \(error.localizedDescription)")
                withAnimation(.snappy) { phase = .preview }
            }
        }
    }
}
