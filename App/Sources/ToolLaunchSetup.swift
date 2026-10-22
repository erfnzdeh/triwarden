import AppKit
import SecretsAgent
import SwiftUI

/// Starts from a saved vault item. This form stores references and command metadata only.
struct ToolLaunchSetup: View {
    let reference: ToolLaunchReference
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shortcut = "tool-" + UUID().uuidString.prefix(8).lowercased()
    @State private var title = ""
    @State private var recipe = Recipe.npm
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
    @State private var enabled = true
    #if DEBUG
    var previewReview = false
    var previewProfile: SecretsProfile?
    #endif

    enum Recipe: String, CaseIterable {
        case npm, node, python, custom
        var title: String {
            switch self {
            case .npm: String(localized: "npm development project")
            case .node: String(localized: "Node.js script")
            case .python: String(localized: "Python script")
            case .custom: String(localized: "Other program")
            }
        }
        var binary: String? {
            switch self { case .npm: "npm"; case .node: "node"; case .python: "python3"; case .custom: nil }
        }
    }

    private var item: VaultItem? {
        model.items.first { $0.accountId == reference.accountID && $0.id == reference.itemID && !$0.isDeleted && !$0.isArchived }
    }
    private var launchArguments: [String] {
        switch recipe {
        case .npm: ["run", "dev"] + arguments
        case .node, .python: [script] + arguments
        case .custom: arguments
        }
    }
    private var draft: SecretsProfile {
        SecretsProfile(name: shortcut, accountID: reference.accountID, itemID: reference.itemID,
            field: .hidden(APIKeyTemplate.keyField), variable: variable, executable: executable,
            arguments: launchArguments, directory: directory, enabled: enabled, displayName: title)
    }
    private var hasChanges: Bool { initial.map { $0 != draft } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHeader(symbol: "terminal", title: reviewing ? "Review Tool Access" : "Provide to Tool",
                       subtitle: reviewing ? "Confirm exactly what will run with this key." : "Choose how this tool uses your saved API key.")
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
        .confirmationDialog("Discard tool setup?", isPresented: $discard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var setup: some View {
        Group {
            FormCard(title: "Tool & Project") {
                FormField(label: "Tool name", note: "A name you'll recognize when this tool asks for your key.") {
                    TextField("e.g. Documentation assistant", text: $title).textFieldStyle(SoftFieldStyle())
                        .accessibilityIdentifier("toolLaunchName")
                }
                FormField(label: "What do you want to run?") {
                    SoftMenu(options: Recipe.allCases.map { ($0, $0.title) }, selection: Binding(get: { recipe }, set: {
                        recipe = $0; findExecutable(); arguments = []
                    }),
                             accessibilityLabel: "Tool type")
                }
                if recipe == .node || recipe == .python {
                    path("Script", value: $script, directory: false)
                        .onChange(of: script) { _, value in
                            if directory.isEmpty, value.hasPrefix("/") {
                                directory = URL(fileURLWithPath: value).deletingLastPathComponent().path
                            }
                        }
                }
                path("Project folder", value: $directory, directory: true)
                if recipe == .npm {
                    Text("Runs npm run dev in this folder.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if executable.isEmpty || recipe == .custom { path("Program", value: $executable, directory: false) }
            }
            FormCard(title: "How the tool reads this key") {
                FormField(label: "Environment variable for this tool", note: "Starts with the key's default. Match the name this tool expects; changing it here keeps the vault default unchanged.") {
                    TextField("API_KEY", text: $variable).textFieldStyle(SoftFieldStyle())
                        .accessibilityIdentifier("toolLaunchVariable")
                }
                Text("\(item?.name ?? String(localized: "Selected API key")) → \(variable.isEmpty ? String(localized: "Choose a variable name") : variable) → \(title.isEmpty ? String(localized: "Your tool") : title)")
                    .font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                Text("Use the saved launch command to start this tool. Triwarden supplies the selected key after you approve the launch.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced command options") {
                FormCard {
                    if recipe != .custom { path("Program", value: $executable, directory: false) }
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
                Text(enabled ? "Saving enables local launches for this tool." : "This tool remains paused after saving.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let existing = model.secrets.profile {
                Label("This version supports one saved tool. Saving replaces “\(existing.title)” and its key binding.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Text("The first launch needs your approval and macOS authentication. You can allow one launch, 10 minutes, or until the vault locks. Temporary access applies only to this saved command from the same terminal session or launcher process. The program and its child processes can read or transmit the key. Project scripts and plugins are not verified.")
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

    private func findExecutable() {
        guard let name = recipe.binary else { executable = ""; return }
        executable = LaunchPolicy.searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    private func load() {
        guard initial == nil else { return }
        originalRevision = model.secrets.profile.flatMap { try? $0.revision() }
        var source = model.secrets.profile
        #if DEBUG
        if let previewProfile { source = previewProfile }
        #endif
        if let p = source, p.accountID == reference.accountID, p.itemID == reference.itemID,
           p.field == .hidden(APIKeyTemplate.keyField) {
            shortcut = p.name; title = p.title; variable = p.variable
            enabled = p.enabled
            recipe = .custom; executable = p.executable; directory = p.directory; arguments = p.arguments
        } else {
            title = String(localized: "My development tool")
            variable = item?.apiKeyVariable ?? "API_KEY"
            findExecutable()
        }
        initial = draft
        #if DEBUG
        reviewing = previewReview
        #endif
    }

    private func validate() throws {
        guard let item, item.isAPIKey, !item.reprompt, model.session(for: reference.accountID) != nil else {
            throw SecretsFailure("Unlock the key's account and select an available API key without an additional master-password prompt.")
        }
        guard let field = item.customFields.first(where: { $0.name == APIKeyTemplate.keyField }),
              !field.value.isEmpty, !field.value.utf8.contains(0), field.value.utf8.count <= 32_768 else {
            throw SecretsFailure("This API key is empty or invalid. Update it in your vault before configuring a tool.")
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
            guard model.secrets.profile.flatMap({ try? $0.revision() }) == originalRevision else {
                throw SecretsFailure("Tool settings changed while this setup was open. Close it and start again to review the current setting.")
            }
            try model.secrets.save(draft)
            if let error = model.secrets.lastError { throw SecretsFailure(error) }
            model.requestedSection = .toolLaunches
            model.flash(String(localized: "Tool saved — ready to launch from your terminal"))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func cancel() { if hasChanges { discard = true } else { dismiss() } }
}
