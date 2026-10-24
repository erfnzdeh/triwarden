import AppKit
import SecretsAgent
import SwiftUI

/// Starts from a saved vault item. This form stores references and command metadata only.
struct ToolLaunchSetup: View {
    let reference: ToolLaunchReference
    var onSaved: ((SecretsProfile) -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shortcut = "tool-" + UUID().uuidString.prefix(8).lowercased()
    @State private var title = ""
    @State private var recipe: ToolLaunchRecipe?
    @State private var executable = ""
    @State private var directory = ""
    @State private var script = ""
    @State private var variable = "API_KEY"
    @State private var arguments: [String] = []
    @State private var reviewing = false
    @State private var error: String?
    @State private var initial: SecretsProfile?
    @State private var originalRevision: String?
    @State private var discard = false
    @State private var helperSetup = false
    @State private var helperCheck = 0
    @State private var enabled = true
    @State private var additionalBindings: [SecretsBinding] = []
    @State private var nextKey = ""
    #if DEBUG
    var previewReview = false
    var previewProfile: SecretsProfile?
    var previewRecipe: ToolLaunchRecipe?
    #endif

    private var item: VaultItem? {
        model.items.first { $0.accountId == reference.accountID && $0.id == reference.itemID && !$0.isDeleted && !$0.isArchived }
    }
    private var launchArguments: [String] { recipe?.arguments(script: script, extra: arguments) ?? [] }
    private var draft: SecretsProfile {
        SecretsProfile(name: shortcut, accountID: reference.accountID, itemID: reference.itemID,
            field: .hidden(APIKeyTemplate.keyField), variable: variable, executable: executable,
            arguments: launchArguments, directory: directory, enabled: enabled, displayName: title,
            additionalBindings: additionalBindings.isEmpty ? nil : additionalBindings)
    }
    private var hasChanges: Bool { initial.map { $0 != draft } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHeader(symbol: "terminal", title: reviewing ? "Review Tool Access" : "Provide to Tool",
                       subtitle: reviewing ? "Confirm the command and every key it will receive." : "Choose how this tool uses your saved API keys.")
                .padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormCard(title: "API Key") {
                        Text(verbatim: item?.name ?? String(localized: "This key is unavailable"))
                            .font(.system(size: 15, weight: .semibold))
                        Text("The key stays in your vault. This setup saves a reference to it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if item?.reprompt == true {
                            Text("This key requires an additional master-password prompt, which tool launches don't yet support. Choose another key; its protection will not be bypassed.")
                                .font(.system(size: 12)).foregroundStyle(.orange)
                        }
                    }
                    if reviewing { review } else { setup }
                    helperStatus.id(helperCheck)
                    if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red) }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
            .thinScroller()
            FormFooter(action: reviewing ? "Save Tool" : "Review", cancelTitle: reviewing ? "Back" : "Cancel", defaultAction: false,
                       disabled: item == nil || item?.reprompt == true,
                       cancel: { if reviewing { reviewing = false } else { cancel() } },
                       submit: { if reviewing { save() } else { reviewDraft() } }) {
                if reviewing { Text("2 of 2 · Review").font(.system(size: 11)).foregroundStyle(.secondary) }
                else { Text("1 of 2 · Setup").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 560, idealHeight: 680)
        .background { WindowBackdrop() }
        .onAppear(perform: load)
        .interactiveDismissDisabled(hasChanges)
        .sheet(isPresented: $helperSetup, onDismiss: { helperCheck += 1 }) { TerminalHelperSetup().environment(model) }
        .confirmationDialog("Discard tool setup?", isPresented: $discard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    @ViewBuilder private var helperStatus: some View {
        #if DEBUG
        if model.previewUnlocked { TerminalHelperStatusRow(openSetup: { helperSetup = true }, previewState: .installed) }
        else { TerminalHelperStatusRow(openSetup: { helperSetup = true }) }
        #else
        TerminalHelperStatusRow(openSetup: { helperSetup = true })
        #endif
    }

    private var setup: some View {
        Group {
            FormCard(title: "Tool & Project") {
                FormField(label: "What do you want to run?") {
                    SoftMenu(options: [(Optional<ToolLaunchRecipe>.none, String(localized: "Choose a tool…"))] +
                             ToolLaunchRecipe.allCases.map { (Optional($0), $0.localizedTitle) },
                             selection: Binding(get: { recipe }, set: selectRecipe), accessibilityLabel: "Tool type")
                }
                if recipe != nil {
                    FormField(label: "Tool name", note: "Use a name you can recognize when this tool requests access.") {
                        TextField("e.g. Documentation assistant", text: $title).textFieldStyle(SoftFieldStyle())
                            .accessibilityIdentifier("toolLaunchName")
                    }
                }
                if recipe == .node || recipe == .python {
                    path("Script", value: $script, directory: false)
                        .onChange(of: script) { _, value in
                            if directory.isEmpty, value.hasPrefix("/") {
                                directory = URL(fileURLWithPath: value).deletingLastPathComponent().path
                            }
                        }
                }
                if recipe != nil { path("Project folder", value: $directory, directory: true) }
                if recipe == .npm {
                    Text("Runs npm run dev in this folder.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if recipe != nil {
                    path("Program", value: $executable, directory: false)
                    if executable.isEmpty {
                        Text("Choose the installed program. Triwarden does not run programs during setup.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Find Installed Program") { findExecutable() }.buttonStyle(.appSecondarySmall)
                    } else {
                        Text("Confirm this program path before you save the tool.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if recipe == .claudeCode {
                    Text("Use an Anthropic API key. Claude Code can charge this API account instead of your subscription.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if recipe != nil {
                FormCard(title: "How the tool reads this key") {
                    FormField(label: "Environment variable for this tool", note: "Use the name this tool expects. This setting does not change the key in your vault.") {
                        TextField("API_KEY", text: $variable).textFieldStyle(SoftFieldStyle())
                            .accessibilityIdentifier("toolLaunchVariable")
                    }
                    if let problem = APIKeyTemplate.variableProblem(variable) {
                        Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    if let suggestion = recipe?.variable, variable != suggestion {
                        HStack {
                            Text("This tool expects \(suggestion).").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use Suggested Name") { variable = suggestion }.buttonStyle(.appSecondarySmall)
                        }
                    }
                    Text("\(item?.name ?? String(localized: "Selected API key")) → \(variable.isEmpty ? String(localized: "Choose a variable name") : variable) → \(title.isEmpty ? String(localized: "Your tool") : title)")
                        .font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                    Text("Use the saved launch command to start this tool. Triwarden supplies the selected key after you approve the launch.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                FormCard(title: "Additional keys for this tool") {
                    Text("Add only the keys this tool needs. Each key must use a different environment variable.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(additionalBindings.indices, id: \.self) { index in
                        let binding = additionalBindings[index]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(verbatim: keyName(binding)).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Button("Remove") { additionalBindings.remove(at: index) }.buttonStyle(.appSecondarySmall)
                                    .accessibilityLabel("Remove key \(keyName(binding)) from this tool")
                            }
                            TextField("Environment variable", text: $additionalBindings[index].variable)
                                .textFieldStyle(SoftFieldStyle())
                                .accessibilityLabel("Environment variable for \(keyName(binding))")
                        }
                    }
                    if additionalBindings.count < 15 {
                        Picker("Saved API key", selection: $nextKey) {
                            Text("Choose another key…").tag("")
                            ForEach(availableKeys) { key in
                                Text(verbatim: key.name + " · " + accountLabel(key.accountId)).tag(key.accountId + "|" + key.id)
                            }
                        }.pickerStyle(.menu)
                        Button("Add Key") { addKey() }.buttonStyle(.appSecondarySmall).disabled(nextKey.isEmpty)
                        if availableKeys.isEmpty {
                            Text("Save another API key in your vault or unlock its account to add it here.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Advanced command options") {
                    FormCard {
                        ForEach(arguments.indices, id: \.self) { index in
                            HStack {
                                TextField("Argument \(index + 1)", text: $arguments[index]).textFieldStyle(SoftFieldStyle())
                                Button { arguments.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel(Text("Remove argument \(index + 1)"))
                            }
                        }
                        Button("Add Argument") { arguments.append("") }.buttonStyle(.appSecondarySmall)
                            .disabled(arguments.count >= 120)
                        Text("Enter each argument separately, without shell quotes. Shell command text is never evaluated.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var review: some View {
        Group {
            FormCard(title: "Saved launch") {
                Text(verbatim: title).font(.system(size: 15, weight: .semibold))
                reviewRow("Key provided to this tool", item?.name ?? String(localized: "Unavailable key"))
                reviewRow("Program", executable)
                ForEach(Array(launchArguments.enumerated()), id: \.offset) { index, value in
                    reviewRow("Argument \(index + 1)", value.isEmpty ? String(localized: "(empty argument)") : value)
                }
                reviewRow("Project folder", directory)
                reviewRow("Environment variable", variable)
                ForEach(additionalBindings.indices, id: \.self) { index in
                    let binding = additionalBindings[index]
                    Divider()
                    reviewRow("Additional key", keyName(binding) + " · " + accountLabel(binding.accountID))
                    reviewRow("Environment variable", binding.variable)
                }
                if recipe == .claudeCode {
                    Text("This launch supplies an Anthropic API key. Claude Code can charge that API account instead of your subscription.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(enabled ? "Saving enables local launches for this tool." : "This tool remains paused after saving.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("The first launch needs your approval and macOS authentication. You can allow one launch, 10 minutes, or until the vault locks. Temporary access applies only to this saved command from the same terminal session or launcher process. The program and its child processes can read or transmit the selected keys. Project scripts and plugins are not verified.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func reviewRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        FormField(label: label) {
            Text(verbatim: value).font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func path(_ label: LocalizedStringKey, value: Binding<String>, directory: Bool) -> some View {
        FormField(label: label) {
            HStack {
                TextField(label, text: value).textFieldStyle(SoftFieldStyle())
                Button("Choose…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = directory; picker.canChooseFiles = !directory
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK, let url = picker.url { value.wrappedValue = url.path }
                }.buttonStyle(.appSecondarySmall)
            }
        }
    }

    private func selectRecipe(_ selected: ToolLaunchRecipe?) {
        let previous = recipe
        if let selected {
            let suggested = selected.suggestedName(current: title, previous: previous)
            title = suggested == selected.title || title == previous?.localizedTitle ? selected.localizedTitle : suggested
            variable = selected.suggestedVariable(current: variable, previous: previous, keyDefault: item?.apiKeyVariable ?? "API_KEY")
        }
        recipe = selected; arguments = []; script = ""
        findExecutable()
    }

    private func findExecutable() {
        executable = recipe?.findExecutable(home: FileManager.default.homeDirectory(forUser: NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser) ?? ""
    }

    private func load() {
        guard initial == nil else { return }
        var source = reference.toolName.flatMap { name in model.secrets.profiles.first { $0.name == name } }
        #if DEBUG
        if let previewProfile { source = previewProfile }
        #endif
        originalRevision = source.flatMap { try? $0.revision() }
        if let p = source {
            shortcut = p.name; title = p.title; variable = p.variable
            enabled = p.enabled
            additionalBindings = p.additionalBindings ?? []
            recipe = .custom; executable = p.executable; directory = p.directory; arguments = p.arguments
        } else {
            variable = item?.apiKeyVariable ?? "API_KEY"
            if let first = reference.initialBindings.first,
               first.accountID == reference.accountID, first.itemID == reference.itemID {
                variable = first.variable
                additionalBindings = Array(reference.initialBindings.dropFirst())
            }
            title = reference.suggestedName ?? ""
            directory = reference.suggestedDirectory ?? ""
            findExecutable()
        }
        initial = draft
        #if DEBUG
        if let previewRecipe { selectRecipe(previewRecipe) }
        reviewing = previewReview
        #endif
    }

    private func validate() throws {
        guard recipe != nil else { throw SecretsFailure("Choose the tool you want to run.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SecretsFailure("Enter a name for this tool.") }
        guard executable.hasPrefix("/") else { throw SecretsFailure("Use Choose… to select the installed program.") }
        guard directory.hasPrefix("/") else { throw SecretsFailure("Use Choose… to select the project folder.") }
        if let problem = APIKeyTemplate.variableProblem(variable) { throw SecretsFailure(problem) }
        guard let item, item.isAPIKey, !item.reprompt, model.session(for: reference.accountID) != nil else {
            throw SecretsFailure("Unlock the key's account and select an available API key without an additional master-password prompt.")
        }
        guard let field = item.customFields.first(where: { $0.name == APIKeyTemplate.keyField }),
              !field.value.isEmpty, !field.value.utf8.contains(0), field.value.utf8.count <= 32_768 else {
            throw SecretsFailure("This API key is empty or invalid. Update it in your vault before configuring a tool.")
        }
        for binding in additionalBindings {
            guard let selected = model.items.first(where: { $0.accountId == binding.accountID && $0.id == binding.itemID && !$0.isDeleted && !$0.isArchived }),
                  selected.isAPIKey, !selected.reprompt, model.session(for: binding.accountID) != nil,
                  let field = selected.customFields.first(where: { $0.name == APIKeyTemplate.keyField && $0.kind == .hidden }),
                  !field.value.isEmpty, !field.value.utf8.contains(0), field.value.utf8.count <= 32_768 else {
                throw SecretsFailure("An additional key is unavailable or its account is locked. Unlock the account, or remove and select that key again.")
            }
        }
        if (recipe == .node || recipe == .python) && script.isEmpty {
            throw SecretsFailure("Choose the script you want this tool to run.")
        }
        try draft.validate()
        _ = try LaunchIdentity.capture(draft)
    }

    private func reviewDraft() {
        do { try validate(); error = nil; reviewing = true }
        catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            try validate()
            guard model.secrets.profiles.first(where: { $0.name == shortcut }).flatMap({ try? $0.revision() }) == originalRevision else {
                throw SecretsFailure("Tool settings changed while this setup was open. Close it and start again to review the current setting.")
            }
            try model.secrets.save(draft)
            if let error = model.secrets.lastError { throw SecretsFailure(error) }
            model.requestedToolSelection = draft.name
            model.requestedSection = .toolLaunches
            model.flash(String(localized: "Tool saved. Copy its launch from Tools."))
            onSaved?(draft)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func cancel() { if hasChanges { discard = true } else { dismiss() } }

    private func accountLabel(_ id: String) -> String {
        model.accounts.first { $0.id == id }.map { $0.email + " · " + $0.serverSummary } ?? String(localized: "Unavailable account")
    }

    private func keyName(_ binding: SecretsBinding) -> String {
        model.items.first { $0.accountId == binding.accountID && $0.id == binding.itemID && !$0.isDeleted && !$0.isArchived }?.name
            ?? String(localized: "Unavailable key — select it again")
    }

    private var availableKeys: [VaultItem] {
        let used = draft.bindings.map { $0.accountID + "|" + $0.itemID }
        return model.items.filter { $0.isAPIKey && !$0.isDeleted && !$0.isArchived && !$0.reprompt &&
            model.session(for: $0.accountId) != nil && !used.contains($0.accountId + "|" + $0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func addKey() {
        guard let key = availableKeys.first(where: { $0.accountId + "|" + $0.id == nextKey }) else { return }
        additionalBindings.append(.init(accountID: key.accountId, itemID: key.id, field: .hidden(APIKeyTemplate.keyField),
                                        variable: key.apiKeyVariable))
        nextKey = ""
    }
}
