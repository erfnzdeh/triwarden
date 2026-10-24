import AppKit
import SecretsAgent
import SwiftUI

/// A replayable path through the real forms. It stores only a page number, never an approval or a key value.
struct ToolSetupGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("localToolGuidePage") private var storedPage = 0
    @State private var step = ToolGuide.Step.key
    @State private var sheet: Sheet?
    @State private var reference: ToolLaunchReference?
    @State private var selectedTool = ""
    @State private var launchConfirmed = false
    @State private var helper: TerminalHelperInstallation.State?
    @State private var helperCheck = 0
    @State private var practice = false
    @State private var setupAfterPicker = false
    @State private var copied = false
    @State private var error: String?
    #if DEBUG
    var previewStep: ToolGuide.Step?
    var previewProfiles: [SecretsProfile]?
    #endif

    private enum Sheet: String, Identifiable {
        case newKey, importFile, keyPicker, setup, helper, export
        var id: Self { self }
    }
    private var profiles: [SecretsProfile] {
        #if DEBUG
        if let previewProfiles { return previewProfiles }
        #endif
        return model.secrets.profiles
    }
    private var index: ToolBrowserIndex {
        var unlocked = Set(model.sessions.map(\.id))
        #if DEBUG
        if model.previewUnlocked { unlocked.formUnion(model.accounts.map(\.id)) }
        #endif
        return .init(profiles: profiles, items: model.items, unlocked: unlocked,
                     configurationError: model.secrets.lastError != nil, configuredAccounts: Set(model.accounts.map(\.id)))
    }
    private var target: ToolBrowserIndex.Entry? { index.entries.first { $0.id == selectedTool } }
    private var toolReady: Bool { target?.availability == .ready }
    private var keyReady: Bool {
        guard let reference else { return false }
        return model.items.contains { $0.accountId == reference.accountID && $0.id == reference.itemID &&
            $0.isAPIKey && !$0.isDeleted && !$0.isArchived && !$0.reprompt && model.session(for: $0.accountId) != nil }
    }
    private var canContinue: Bool {
        step.canContinue(keyReady: keyReady, toolReady: toolReady, helperReady: helper == .installed, launchConfirmed: launchConfirmed)
    }
    private var revision: String? { target.flatMap { try? $0.profile.revision() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Setup Guide").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text("Step \(step.rawValue + 1) of 5").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                AppSegmented(options: ToolGuide.Step.allCases.map { ($0, LocalizedStringKey($0.guideLabel)) }, selection: $step)
                    .accessibilityLabel("Guide steps").accessibilityIdentifier("toolGuideSteps")
            }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(verbatim: step.guideTitle).font(.system(size: 19, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    switch step {
                    case .key: keyStep
                    case .tool: toolStep
                    case .helper: helperStep
                    case .launch: launchStep
                    case .daily: dailyStep
                    }
                    if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red) }
                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22).padding(.bottom, 22).frame(maxWidth: .infinity, alignment: .leading)
            }.thinScroller()
            Divider().opacity(0.5)
            HStack {
                Button("Close") { dismiss() }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                if step != .key {
                    Button("Back") { step = .init(restoring: step.rawValue - 1) }.buttonStyle(.appSecondary)
                }
                Button(step == .daily ? "Finish Guide" : "Continue") {
                    if step == .daily { dismiss() }
                    else { step = .init(restoring: step.rawValue + 1) }
                }.buttonStyle(.appPrimary).disabled(!canContinue).accessibilityIdentifier("toolGuideContinue")
            }.padding(20)
        }.frame(width: 640, height: 640).background { WindowBackdrop() }
            .onAppear {
                step = .init(restoring: storedPage)
                if profiles.count == 1 { selectedTool = profiles[0].name }
                #if DEBUG
                if let previewStep { step = previewStep }
                #endif
            }
            .onChange(of: step) { _, page in
                error = nil
                #if DEBUG
                if model.previewUnlocked { return }
                #endif
                storedPage = page.rawValue
            }
            .onChange(of: revision) { _, _ in copied = false; launchConfirmed = false }
            .onChange(of: model.sessions.map(\.id)) { _, _ in launchConfirmed = false }
            .task(id: helperCheck) {
                #if DEBUG
                if model.previewUnlocked { helper = .installed; return }
                #endif
                let url = Bundle.main.bundleURL
                helper = await Task.detached(priority: .utility) { TerminalHelperInstallation.inspect(appURL: url).state }.value
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in helperCheck += 1 }
            .sheet(item: $sheet, onDismiss: childClosed) { child in childSheet(child).environment(model) }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep a provider key in your Bitwarden vault. Choose which saved tool receives it when you approve a launch.")
            if model.sessions.isEmpty && !model.previewUnlocked {
                Text("Unlock an account before you save or select a key.").foregroundStyle(.secondary)
                Button("Return to Vault") { dismiss(); model.requestedSection = .section(.all) }.buttonStyle(.appPrimarySmall)
            } else {
                guideChoice("I have an API key", note: "Save the key once. Set the variable name that your tool expects, such as OPENAI_API_KEY.", action: "Save a Key…") {
                    practice = false; sheet = .newKey
                }
                guideChoice("My project has an .env file", note: "Select keys from a masked preview. The importer keeps your source file unchanged.", action: "Import .env File…") { sheet = .importFile }
                guideChoice("My key is already in the vault", note: "Choose an available API key from an unlocked account.", action: "Choose Saved Key…") { sheet = .keyPicker }
                DisclosureGroup("Try with a dummy key") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Practice without a provider account or API charges. The form contains a dummy value and TRIWARDEN_TEST_KEY.")
                        Button("Save a Practice Key…") { practice = true; sheet = .newKey }.buttonStyle(.appSecondarySmall)
                    }.padding(.top, 8)
                }.font(.system(size: 12))
            }
            if keyReady { Text("A saved key is selected. Continue to choose the tool.").foregroundStyle(.secondary) }
            if toolReady { Text("You already have a saved tool. Continue to review it.").foregroundStyle(.secondary) }
        }
    }

    private var toolStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A tool setup connects your selected keys to one program and project folder.")
            Text("The variable name tells the program which environment variable to read. For example, OPENAI_API_KEY can hold your OpenAI key.")
            Text("Choose a recipe, confirm the installed program, and check each variable name. Review the command before you save.")
            Button(keyReady ? "Set Up Tool…" : "Choose a Key and Set Up Tool…") {
                if keyReady { sheet = .setup } else { sheet = .keyPicker }
            }.buttonStyle(.appPrimarySmall).disabled(model.sessions.isEmpty || profiles.count >= 64)
            toolSelection
            DisclosureGroup("Practice with Python") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Save this script as check_key.py in a test folder. Choose Python script and select that file during setup.")
                    Text(verbatim: Self.practiceScript).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Practice Script") { model.copyPlain(Self.practiceScript) }.buttonStyle(.appSecondarySmall)
                    Text("The script checks the dummy key without printing it. Run it through the saved Triwarden launch.")
                }.padding(.top, 8)
            }.font(.system(size: 12))
            Text("Program checks do not verify project scripts or plugins. Choose a project you trust.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Start the tool through the saved launch. An already-running tool does not receive new keys automatically.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The terminal helper, tw, connects your terminal to Triwarden. Install it once for this app.")
            Text("Move Triwarden to its permanent location first. Open helper setup, check the install destination, and run the copied command in Terminal.")
            Button("Open Terminal Helper Setup…") { sheet = .helper }.buttonStyle(.appPrimarySmall)
            if helper == .installed {
                Label("The helper links to this signed app.", systemImage: "checkmark").foregroundStyle(.secondary)
            } else if helper != nil {
                Text("The helper needs setup or repair. Complete helper setup, then return here.").foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
            Button("Check Again") { helperCheck += 1 }.buttonStyle(.appSecondarySmall)
            Text("Triwarden does not edit .zshrc or .bashrc. Helper setup shows the location before you run the install command.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            toolSelection
        }
    }

    private var launchStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolSelection
            if let target, toolReady, helper == .installed {
                FormCard(title: "Launch command") {
                    Text(verbatim: (try? SavedToolCommands.launch(target.profile)) ?? "")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button(copied ? "Launch Copied" : "Copy Launch") { copyLaunch(target.profile) }
                        .buttonStyle(.appPrimarySmall)
                }
                instruction(1, "Paste the command into Terminal and run it. Keep Triwarden open and the selected accounts unlocked.")
                instruction(2, "Review the approval card. Check the tool, project folder, and selected keys.")
                instruction(3, "For your first test, select Allow Once. Then complete Touch ID or your Mac password.")
                instruction(4, "Check the tool's output. A saved setup or copied command does not confirm a successful launch.")
                Toggle("I ran the launch and the tool started as expected.", isOn: $launchConfirmed)
                    .toggleStyle(.checkbox).font(.system(size: 12)).accessibilityIdentifier("confirmToolGuideLaunch")
            } else {
                Text("Select a ready tool and complete helper setup before you test the launch.").foregroundStyle(.secondary)
            }
            DisclosureGroup("If the launch fails") {
                Text("If no card appears, check helper setup and keep Triwarden open. Unlock any locked account. Select missing keys again through Edit Setup in Tools. Check the key and provider account if the provider reports an error. Never share key values in a report.")
                    .font(.system(size: 12)).padding(.top, 8)
            }
        }
    }

    private var dailyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Next time, open Tools and copy the saved launch. You can also run tw run to choose a saved tool.")
            Text("Once is the default approval. You can choose 10 minutes or Until lock for repeated launches from the same launcher process.")
            Text("Open Access > Permissions to review or revoke temporary access. Lock and revoke stop future delivery. Programs retain keys already received.")
            Text("The program receives the raw keys and can retain or transmit them. Other processes under your user account may inspect them.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            toolSelection
            if let target {
                DisclosureGroup("More launch options") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Copy Shell Alias") {
                            do { model.copyPlain(try SavedToolCommands.alias(target.profile)) }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(.appSecondarySmall)
                        Text("Paste the alias into your terminal yourself. Triwarden does not change shell settings.")
                        Button("Save .env References…") { sheet = .export }.buttonStyle(.appSecondarySmall)
                        Text("This separate .env.triwarden file contains references. Use it with tw, not an ordinary dotenv loader.")
                        Text("Import keeps your old .env unchanged. After testing, remove imported assignments in your editor. Do not leave empty assignments.")
                    }.font(.system(size: 12)).padding(.top, 8)
                }
            }
            Button("Open Tools") { dismiss(); model.requestedSection = .toolLaunches }.buttonStyle(.appPrimarySmall)
            Button("Review Access") { dismiss(); model.requestedSection = .access }.buttonStyle(.appSecondarySmall)
        }
    }

    @ViewBuilder private var toolSelection: some View {
        if !profiles.isEmpty {
            FormField(label: "Saved tool") {
                SoftMenu(options: [("", String(localized: "Choose a saved tool…"))] + profiles.map { ($0.name, $0.title + " · " + $0.directory) },
                         selection: $selectedTool, accessibilityLabel: "Saved tool")
                if let target {
                    Text(verbatim: target.availability.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    if !toolReady {
                        Text("Unlock its accounts, resume the tool, or repair its key settings in Tools before you continue.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Open Tools to Repair") { dismiss(); model.requestedToolSelection = selectedTool; model.requestedSection = .toolLaunches }
                            .buttonStyle(.appSecondarySmall)
                    }
                }
            }
        } else if step != .tool {
            Text("Save a tool in step 2 before you continue.").foregroundStyle(.secondary)
        }
    }

    private func guideChoice(_ title: LocalizedStringKey, note: LocalizedStringKey, action: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(action, action: perform).buttonStyle(.appSecondarySmall)
        }
    }
    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number).").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text)
        }.font(.system(size: 12))
    }
    @ViewBuilder private func childSheet(_ child: Sheet) -> some View {
        switch child {
        case .newKey:
            EditItemSheet(mode: .create(.secureNote), prefill: newKeyPrefill, onSaved: {
                if let item = model.selectedItem, item.isAPIKey {
                    reference = .init(accountID: item.accountId, itemID: item.id); step = .tool
                }
            })
        case .importFile:
            EnvKeyImportSheet(onImported: { reference = $0; step = .tool }, onSavedTool: saved)
        case .keyPicker:
            ToolKeyPicker { item in
                setupAfterPicker = step == .tool
                reference = .init(accountID: item.accountId, itemID: item.id); step = .tool; sheet = nil
            }
        case .setup:
            if let reference { ToolLaunchSetup(reference: reference, onSaved: saved) }
        case .helper: TerminalHelperSetup()
        case .export:
            if let target { EnvReferenceExport(profile: target.profile) }
        }
    }
    private var newKeyPrefill: EditItemSheet.Prefill {
        var value = EditItemSheet.Prefill(); value.apiKey = true
        if practice { value.name = String(localized: "Triwarden practice key"); value.practiceAPIKey = true }
        return value
    }
    private func saved(_ profile: SecretsProfile) { selectedTool = profile.name; launchConfirmed = false; step = .helper }
    private func childClosed() {
        helperCheck += 1
        if setupAfterPicker { setupAfterPicker = false; if keyReady { sheet = .setup } }
    }
    private func copyLaunch(_ profile: SecretsProfile) {
        do { model.copyPlain(try SavedToolCommands.launch(profile)); copied = true }
        catch { self.error = error.localizedDescription }
    }
    private static let practiceScript = "import os\nassert os.environ.get(\"TRIWARDEN_TEST_KEY\") == \"triwarden-preview-only\"\nprint(\"Key available\")\n"
}

private extension ToolGuide.Step {
    var guideLabel: String {
        switch self {
        case .key: String(localized: "Key")
        case .tool: String(localized: "Tool")
        case .helper: String(localized: "Helper")
        case .launch: String(localized: "Launch")
        case .daily: String(localized: "Next time")
        }
    }
    var guideTitle: String {
        switch self {
        case .key: String(localized: "Save a key in your vault")
        case .tool: String(localized: "Choose the tool that needs this key")
        case .helper: String(localized: "Connect your terminal")
        case .launch: String(localized: "Start your first approved launch")
        case .daily: String(localized: "Use the tool again")
        }
    }
}
