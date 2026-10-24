import Foundation
import Observation
import SecretsAgent
import VaultwardenAPI

/// Keeps plaintext in memory until the normal vault import confirms the complete batch.
@MainActor @Observable
final class EnvKeyImport {
    enum Stage { case choose, review, check, saved }
    private(set) var stage = Stage.choose
    private(set) var file: EnvImportFile?
    private(set) var source: URL?
    private(set) var busy = false
    private(set) var bindings: [SecretsBinding] = []
    var selected: Set<String> = []
    var project = ""
    var accountID = ""
    var error: String?
    private var plan: APIKeyImport?
    private var operation = UUID()

    var canSave: Bool {
        !busy && stage == .review && !accountID.isEmpty &&
        (try? file?.selected(selected)) != nil && !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func open(_ url: URL) {
        guard !busy, plan == nil else { return }
        clearValues()
        do {
            let file = try EnvImportFile.read(url)
            self.file = file; source = url
            let suggested = file.entries.filter(\.suggested).map(\.variable)
            selected = suggested.count <= 16 ? Set(suggested) : []
            project = url.deletingLastPathComponent().lastPathComponent
            stage = .review; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func save(using model: AppModel) async {
        guard canSave, let file, let session = model.session(for: accountID) else { return }
        let token = operation, destination = accountID
        busy = true; error = nil
        defer { if operation == token { busy = false } }
        do {
            let entries = try file.selected(selected)
            let plan = try APIKeyImport(keys: entries.compactMap { entry in
                entry.value.map { .init(variable: entry.variable, value: $0) }
            }, project: project)
            // Set before the await. An uncertain response must never enable a second send.
            self.plan = plan; stage = .check
            self.file = nil
            let refreshed = try await session.importItems(plan.items(), folders: [])
            guard operation == token else { return }
            guard model.session(for: destination) === session else { locked(); return }
            if refreshed { try complete(session: session) }
            else { error = String(localized: "The server accepted the import. Select Check Saved Keys to confirm the values.") }
        } catch {
            guard operation == token else { return }
            if model.session(for: destination) !== session { locked(); return }
            if plan != nil {
                stage = .check
                self.error = String(localized: "The import is not confirmed. Select Check Saved Keys. Check the destination vault before you import this file again.")
            } else { self.error = error.localizedDescription }
        }
    }

    func check(using model: AppModel) async {
        guard !busy, stage == .check, plan != nil, let session = model.session(for: accountID) else { return }
        let token = operation, destination = accountID
        busy = true; error = nil
        defer { if operation == token { busy = false } }
        do {
            try await session.refresh()
            guard operation == token else { return }
            guard model.session(for: destination) === session else { locked(); return }
            try complete(session: session)
        } catch {
            guard operation == token else { return }
            if model.session(for: destination) !== session { locked(); return }
            self.error = String(localized: "Cannot confirm all saved keys. Keep the source file. Sync and check the destination vault before you import again.")
        }
    }

    func locked() {
        clearValues()
        error = String(localized: "The destination account locked or signed out. Unlock it and check the vault before you import again.")
    }

    func clearValues() {
        operation = UUID(); busy = false; file = nil; plan = nil
        selected = []; bindings = []; source = nil; project = ""; stage = .choose
    }

    #if DEBUG
    func loadPreview(_ file: EnvImportFile) {
        self.file = file; stage = .review
        accountID = "demo"
        project = "Documentation assistant"
        selected = Set(file.entries.filter(\.suggested).map(\.variable))
    }
    #endif

    private func complete(session: AccountSession) throws {
        guard let plan else { return }
        let records = session.items.compactMap { item -> APIKeyImport.Record? in
            guard item.isAPIKey, !item.isDeleted, !item.isArchived, !item.reprompt,
                  let receipt = Self.field(APIKeyImport.receiptField, kind: .text, in: item),
                  let variable = Self.field(APIKeyTemplate.environmentField, kind: .text, in: item),
                  let value = Self.field(APIKeyTemplate.keyField, kind: .hidden, in: item) else { return nil }
            return .init(itemID: item.id, importID: receipt, variable: variable, value: value)
        }
        let ids = try plan.verifiedIDs(in: records)
        bindings = zip(ids, plan.keys).map { id, key in
            .init(accountID: session.id, itemID: id, field: .hidden(APIKeyTemplate.keyField), variable: key.variable)
        }
        // The next step needs references only. Do not retain the file values after confirmation.
        self.plan = nil; file = nil; selected = []; stage = .saved; error = nil
    }

    private static func field(_ name: String, kind: CustomField.Kind, in item: VaultItem) -> String? {
        let fields = item.customFields.filter { $0.name == name }
        guard fields.count == 1, fields[0].kind == kind else { return nil }
        return fields[0].value
    }
}
