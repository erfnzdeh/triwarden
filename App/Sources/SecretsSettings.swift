import AppKit
import SecretsAgent
import SwiftUI

struct SecretsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var advanced = false
    @State private var helperSetup = false
    var body: some View {
        Form {
            Section {
                Text("Save API keys in your vault. Use Tools to choose how a tool receives a saved key.")
                Button("Open Tools") { model.showToolsAndProjects() }
                Button("Setup Guide…") { model.showToolGuide() }
                Button("Terminal Helper Setup…") { helperSetup = true }
            } header: { Text("Local Tool Access") }
            Section {
                Text("For existing password bindings and manual command configuration.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Advanced Launch Settings…") { advanced = true }
            }
        }
        .formStyle(.grouped).thinScroller()
        .sheet(isPresented: $helperSetup) { TerminalHelperSetup().environment(model) }
        .sheet(isPresented: $advanced) {
            VStack(spacing: 0) {
                HStack {
                    Text("Advanced Launch Settings").font(.headline)
                    Spacer()
                    Button("Done") { advanced = false }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                }.padding(18)
                AdvancedSecretsSettings().environment(model)
            }
            .frame(minWidth: 680, minHeight: 580)
            .background { WindowBackdrop() }
        }
    }
}

/// Recovery and compatibility editor. Guided API-key setup lives in the main feature.
private struct AdvancedSecretsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = "dev"
    @State private var displayName: String?
    @State private var accountID = ""
    @State private var itemID = ""
    @State private var field = "password"
    @State private var variable = "API_KEY"
    @State private var executable = ""
    @State private var arguments: [String] = []
    @State private var directory = ""
    @State private var enabled = false
    @State private var error: String?
    @State private var saved = false
    @State private var selectedTool = ""
    @State private var additionalBindings: [SecretsBinding] = []

    private var draft: SecretsProfile {
        SecretsProfile(name: name, accountID: accountID, itemID: itemID,
                       field: field.hasPrefix("hidden:") ? .hidden(String(field.dropFirst(7))) : .password,
                       variable: variable, executable: executable, arguments: arguments, directory: directory, enabled: enabled, displayName: displayName,
                       additionalBindings: additionalBindings.isEmpty ? nil : additionalBindings)
    }

    private var items: [VaultItem] {
        model.session(for: accountID)?.items.filter { !$0.isDeleted && !$0.isArchived && $0.isSupported }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? []
    }
    private var selectedItem: VaultItem? { items.first { $0.id == itemID } }
    private var hiddenNames: [String] {
        guard let item = selectedItem else { return [] }
        return item.customFields.filter { $0.kind == .hidden && !$0.name.isEmpty }
            .map(\.name).filter { name in item.customFields.filter { $0.name == name }.count == 1 }
    }

    var body: some View {
        Form {
            Section {
                Picker("Saved tool", selection: $selectedTool) {
                    Text("New manual setup").tag("")
                    ForEach(model.secrets.profiles, id: \.name) { p in Text(verbatim: p.title).tag(p.name) }
                }.onChange(of: selectedTool) { _, _ in load() }
                Toggle("Enable local secret launches", isOn: $enabled)
                TextField("Command shortcut", text: $name)
                    .accessibilityIdentifier("secretsProfileName")
                    .disabled(!selectedTool.isEmpty)
                Text("Save a development command and its credential reference. Launches require approval unless temporary access is still active.")
                    .font(.caption).foregroundStyle(.secondary)
                if !additionalBindings.isEmpty {
                    Text("This tool also has \(additionalBindings.count) additional key bindings. They are preserved here; edit them in Tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Local Secrets Agent") }

            Section {
                Picker("Account", selection: Binding(get: { accountID }, set: { accountID = $0; itemID = ""; field = "password"; saved = false })) {
                    Text("Choose an unlocked account").tag("")
                    ForEach(model.accounts) { account in
                        Text(verbatim: account.email + " · " + account.serverSummary).tag(account.id)
                    }
                }
                if model.session(for: accountID) == nil {
                    Text("Unlock this account in the main window to select a credential.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Vault item", selection: $itemID) {
                    Text("Choose an item").tag("")
                    if !itemID.isEmpty, selectedItem == nil { Text("Saved item unavailable — select it again").tag(itemID) }
                    ForEach(items) { item in Text(verbatim: SecretsController.display(item.name)).tag(item.id) }
                }.accessibilityIdentifier("secretsVaultItem").onChange(of: itemID) { _, _ in saved = false }
                Picker("Field", selection: $field) {
                    Text("Password").tag("password")
                    if field.hasPrefix("hidden:"), !hiddenNames.contains(String(field.dropFirst(7))) {
                        Text("Saved field unavailable — select it again").tag(field)
                    }
                    ForEach(hiddenNames, id: \.self) { name in Text(verbatim: SecretsController.display(name)).tag("hidden:" + name) }
                }
                TextField("Environment variable", text: $variable)
                if selectedItem?.reprompt == true {
                    Text("This item requires an additional master-password prompt and cannot be used by this version of tw run.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Credential reference") } footer: {
                Text("Create API keys with the existing vault editor, using a hidden custom field on a Secure Note or a login password. This form stores the reference only.")
            }

            Section {
                HStack {
                    TextField("Executable (absolute path)", text: $executable)
                    Button("Choose…") { choose(directory: false) }
                }
                ForEach(arguments.indices, id: \.self) { index in
                    HStack {
                        TextField("Argument \(index + 1)", text: $arguments[index])
                        Button { arguments.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel(Text("Remove argument \(index + 1)"))
                    }
                }
                Button("Add Argument") { arguments.append("") }.disabled(arguments.count >= 128)
                HStack {
                    TextField("Working directory (absolute path)", text: $directory)
                    Button("Choose…") { choose(directory: true) }
                }
                Text("Use a separate row for each argument; do not add shell quotes. Only basic terminal settings are inherited, with a fixed PATH. Other exported keys and runtime-control variables are omitted.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The tool receives the credential value. It can be read by the tool, its children, and potentially other processes running as you. Scripts and project code are not verified.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Saved launch command") }

            Section {
                HStack {
                    Button("Save Launch Settings") { save() }
                        .accessibilityIdentifier("saveSecretsProfile")
                    Spacer()
                    if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary) }
                }
                if let error = error ?? model.secrets.lastError {
                    Text(verbatim: error).foregroundStyle(.red).font(.caption)
                }
                if let profile = model.secrets.profiles.first(where: { $0.name == selectedTool }) {
                    LabeledContent("Run from a terminal") {
                        Text(verbatim: "tw run --profile " + profile.name).textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Text("Install tw through Tools > Terminal Helper Setup. Keep Triwarden open and the required accounts unlocked. Each launch requires an online refresh. Command overrides are disabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .thinScroller()
        .onAppear { selectedTool = model.secrets.profiles.first?.name ?? ""; load() }
        .onChange(of: draft) { _, _ in saved = false }
    }

    private func load() {
        guard let p = model.secrets.profiles.first(where: { $0.name == selectedTool }) else {
            name = "tool-" + UUID().uuidString.prefix(8).lowercased(); displayName = nil
            accountID = model.sessions.first?.id ?? ""; itemID = ""; field = "password"; variable = "API_KEY"
            executable = ""; arguments = []; directory = ""; enabled = false; additionalBindings = []; return
        }
        name = p.name; accountID = p.accountID; itemID = p.itemID
        displayName = p.displayName
        field = switch p.field { case .password: "password"; case .hidden(let name): "hidden:" + name }
        variable = p.variable; executable = p.executable; arguments = p.arguments
        directory = p.directory; enabled = p.enabled
        additionalBindings = p.additionalBindings ?? []
    }

    private func save() {
        error = nil; saved = false
        let selector: SecretSelector = field.hasPrefix("hidden:") ? .hidden(String(field.dropFirst(7))) : .password
        do {
            if enabled {
                guard let item = selectedItem, !item.reprompt else { throw SecretsFailure("Select an available item without an additional master-password prompt.") }
                // Check shape and existence without resolving the value into this editor.
                switch selector {
                case .password:
                    guard item.password?.isEmpty == false else { throw SecretsFailure("This item has no password. Choose a hidden field instead.") }
                case .hidden(let name):
                    guard hiddenNames.contains(name) else { throw SecretsFailure("Select the hidden field again; its saved name is missing or duplicated.") }
                }
            }
            try model.secrets.save(draft)
            selectedTool = name
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    private func choose(directory isDirectory: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = isDirectory
        picker.canChooseFiles = !isDirectory
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url {
            if isDirectory { directory = url.path } else { executable = url.path }
        }
    }
}
