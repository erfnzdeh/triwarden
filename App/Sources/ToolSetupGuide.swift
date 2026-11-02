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
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Guide").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(verbatim: step.guideTitle).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                }
                StepTrack(titles: ToolGuide.Step.allCases.map(\.guideLabel), current: step.rawValue) { index in
                    step = .init(restoring: index)
                }.accessibilityIdentifier("toolGuideSteps")
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .key: keyStep
                    case .tool: toolStep
                    case .helper: helperStep
                    case .launch: launchStep
                    case .daily: dailyStep
                    }
                    if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red) }
                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Steps

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            lead("Your API key stays in your vault. You choose which tool receives it, and you approve each launch.")
            if model.sessions.isEmpty && !model.previewUnlocked {
                card {
                    status(symbol: "lock.fill", tint: .orange, title: "Unlock an account first",
                           note: "Keys are saved to, and read from, an unlocked vault.")
                    Button("Return to Vault") { dismiss(); model.requestedSection = .section(.all) }.buttonStyle(.appPrimarySmall)
                }
            } else {
                if keyReady {
                    card { status(symbol: "checkmark.circle.fill", tint: .green, title: "Key selected", note: "Continue to choose the tool that uses it.") }
                } else if toolReady {
                    card { status(symbol: "checkmark.circle.fill", tint: .green, title: "You already have a saved tool", note: "Continue to review it, or add another key below.") }
                }
                VStack(spacing: 10) {
                    StartChoiceCard(symbol: "doc.text", title: "My project has an .env file",
                                    note: "Pick keys from a masked list. Your file isn't changed.", badge: "Quickest") { sheet = .importFile }
                    StartChoiceCard(symbol: "plus.circle", title: "I have an API key",
                                    note: "Paste it once, with the variable name your tool reads, such as OPENAI_API_KEY.") {
                        practice = false; sheet = .newKey
                    }
                    StartChoiceCard(symbol: "key.horizontal", title: "My key is already in the vault",
                                    note: "Choose an API key from an unlocked account.") { sheet = .keyPicker }
                }
                disclosure("Try it with a practice key") {
                    Text("No provider account or charges. The form fills in a dummy value named TRIWARDEN_TEST_KEY.")
                    Button("Save a Practice Key…") { practice = true; sheet = .newKey }.buttonStyle(.appSecondarySmall)
                }
            }
        }
    }

    private var toolStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            lead("A tool is one program in one project folder, plus the keys it gets. Triwarden hands each key over under the variable name the program reads.")
            card {
                sectionLabel("For example")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    example("sparkles", "Claude Code", "claude", "ANTHROPIC_API_KEY")
                    example("sparkles", "Codex CLI", "codex", "OPENAI_API_KEY")
                    example("sparkles", "Gemini CLI", "gemini", "GEMINI_API_KEY")
                    example("shippingbox", "Your web app", "npm run dev", "STRIPE_SECRET_KEY")
                    example("chevron.left.forwardslash.chevron.right", "A Python script", "uv run main.py", "HF_TOKEN")
                }
                Text("Aider, OpenCode, Cursor CLI, pnpm, Bun and any other program work too.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().opacity(0.4)
                HStack(spacing: 12) {
                    Button(keyReady ? "Set Up Tool…" : "Choose a Key and Set Up Tool…") {
                        if keyReady { sheet = .setup } else { sheet = .keyPicker }
                    }.buttonStyle(.appPrimarySmall).disabled(model.sessions.isEmpty || profiles.count >= 64)
                    Text("Pick a recipe, then check the program and folder.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            toolSelection
            disclosure("Practice with Python") {
                Text("Save this as check_key.py in a test folder. Choose Python script during setup and select the file.")
                CommandWell(command: Self.practiceScript.trimmingCharacters(in: .newlines), copyLabel: "Copy") {
                    model.copyPlain(Self.practiceScript)
                }
                Text("It checks the practice key without printing it.")
            }
            footnote("Triwarden checks the program, not the project's scripts or plugins, so choose a folder you trust. A tool that's already running doesn't get new keys; start it again through Triwarden.")
        }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            lead("tw is the small command that lets your terminal ask Triwarden for keys. Install it once and every saved tool can use it.")
            card {
                switch helper {
                case .installed?:
                    status(symbol: "checkmark.circle.fill", tint: .green, title: "tw is installed", note: "It links to this copy of Triwarden.")
                case nil:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                default:
                    status(symbol: "exclamationmark.circle.fill", tint: .orange, title: "tw isn't set up yet",
                           note: "Setup copies one command and opens Terminal. You enter your Mac password there.")
                }
                HStack(spacing: 10) {
                    if helper != .installed {
                        Button("Install Terminal Helper…") { sheet = .helper }.buttonStyle(.appPrimarySmall)
                        Button("Check Again") { helperCheck += 1 }.buttonStyle(.appSecondarySmall)
                    } else {
                        Button("Helper Details…") { sheet = .helper }.buttonStyle(.appSecondarySmall)
                    }
                }
            }
            if !profiles.isEmpty { toolSelection }
            footnote("Triwarden never edits .zshrc or .bashrc. Move Triwarden to Applications first so tw keeps working.")
        }
    }

    private var launchStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            lead("Run the tool once through Triwarden to see the approval card and check that everything works.")
            toolSelection
            if let target, toolReady, helper == .installed {
                card {
                    sectionLabel("Run this in Terminal")
                    CommandWell(command: (try? SavedToolCommands.launch(target.profile)) ?? "", copyLabel: "Copy", prominent: true) {
                        copyLaunch(target.profile)
                    }
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 10) {
                        numbered(1, "Paste and run it. Keep Triwarden open and the account unlocked.")
                        numbered(2, "On the approval card, check the tool, folder, and keys.")
                        numbered(3, "Choose Once for this first test, then confirm with Touch ID or your password.")
                        numbered(4, "Watch the tool's output to see that it started.")
                    }
                    Divider().opacity(0.4)
                    Toggle("The tool started as expected", isOn: $launchConfirmed)
                        .toggleStyle(.checkbox).font(.system(size: 12, weight: .medium)).accessibilityIdentifier("confirmToolGuideLaunch")
                }
            } else {
                card {
                    status(symbol: "exclamationmark.circle.fill", tint: .orange, title: "Not ready to launch yet",
                           note: helper == .installed ? "Choose a ready tool above." : "Install the terminal helper in the previous step.")
                }
            }
            disclosure("If the launch doesn't work") {
                Text("No approval card: check that tw is installed and Triwarden is open.")
                Text("Account locked or sync failed: unlock or reconnect, then run it again.")
                Text("Missing key: open the tool in Secrets and choose the key again.")
                Text("Provider error: check the key in your provider account. Never paste key values into a report.")
            }
        }
    }

    private var dailyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            lead("You're set up. From now on it takes one command.")
            toolSelection
            if let target {
                card {
                    sectionLabel("Start it with a short name")
                    CommandWell(command: SavedToolCommands.aliasName(target.profile), copyLabel: "Copy Alias", prominent: true) {
                        do { model.copyPlain(try SavedToolCommands.alias(target.profile)) }
                        catch { self.error = error.localizedDescription }
                    }
                    Text("Add the copied line to ~/.zshrc, then open a new terminal.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                tip("square.on.square", "Copy the launch from Secrets", "Or run tw run and pick a saved tool.")
                Divider().opacity(0.4).padding(.leading, 52)
                tip("timer", "Approve for longer", "Choose 10 minutes or Until lock on the card to skip repeat prompts.")
                Divider().opacity(0.4).padding(.leading, 52)
                tip("hand.raised", "Stay in control", "Access shows every approval. End temporary access there at any time.")
            }
            .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
            HStack(spacing: 10) {
                Button("Open Secrets") { dismiss(); model.requestedSection = .toolLaunches }.buttonStyle(.appPrimarySmall)
                Button("Review Access") { dismiss(); model.requestedSection = .access }.buttonStyle(.appSecondarySmall)
                Spacer()
                if target != nil {
                    Button("Save .env References…") { sheet = .export }.buttonStyle(.appSecondarySmall)
                        .help(Text("Writes .env.triwarden with references, not values. Use it with tw, not an ordinary dotenv loader."))
                }
            }
            footnote("The program gets the real keys and can keep or send them. Locking or ending access stops future launches, not keys a program already has.")
        }
    }

    @ViewBuilder private var toolSelection: some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text("Tool").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    SoftMenu(options: [("", String(localized: "Choose a saved tool…"))] + profiles.map { ($0.name, $0.title + " · " + ToolLaunchesPane.abbreviated($0.directory)) },
                             selection: $selectedTool, accessibilityLabel: "Saved tool")
                    if let target {
                        let state = ToolState(target, helperReady: true)
                        HStack(spacing: 6) {
                            StatusDot(state: state)
                            Text(verbatim: state == .ready ? String(localized: "Ready") : target.availability.title)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.fixedSize()
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
                if target != nil, !toolReady {
                    HStack(spacing: 10) {
                        Text("Unlock its account, resume it, or fix its keys in Secrets.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Open Secrets") { dismiss(); model.requestedToolSelection = selectedTool; model.requestedSection = .toolLaunches }
                            .buttonStyle(.appSecondarySmall)
                    }.padding(.horizontal, 4)
                }
            }
        } else if step != .tool {
            card { status(symbol: "exclamationmark.circle.fill", tint: .orange, title: "No saved tool yet", note: "Set one up in step 2 first.") }
        }
    }

    // MARK: Building blocks

    private func lead(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: "info.circle") }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
    }

    private func chip(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6, style: .continuous))
    }

    /// One recipe example: what runs, the command, and the variable it reads its key from.
    private func example(_ symbol: String, _ title: LocalizedStringKey, _ command: String, _ variable: String) -> some View {
        GridRow {
            Label { Text(title).font(.system(size: 12, weight: .medium)) } icon: {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(verbatim: command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "arrow.left").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .accessibilityLabel("reads")
            chip(variable)
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelStrong, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.panelEdge))
    }

    private func status(symbol: String, tint: Color, title: LocalizedStringKey, note: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numbered(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: String(number)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .frame(width: 18, height: 18).overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ symbol: String, _ title: LocalizedStringKey, _ note: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).background(.primary.opacity(0.05), in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func disclosure(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> some View) -> some View {
        let body = content()
        return DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 10) { body }
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
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
