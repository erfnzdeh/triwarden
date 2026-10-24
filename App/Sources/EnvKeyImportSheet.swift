import AppKit
import SecretsAgent
import SwiftUI

struct EnvKeyImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow = EnvKeyImport()
    @State private var setup: ToolLaunchReference?
    @State private var savedTool: SecretsProfile?
    #if DEBUG
    var previewFile: EnvImportFile?
    #endif

    var body: some View {
        @Bindable var flow = flow
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(flow.stage == .saved ? "Keys saved" : "Import .env File")
                    .font(.system(size: 18, weight: .semibold))
                Text(flow.stage == .saved ? "Set up a tool to use these keys." : "Select the keys you want to save in your vault.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if flow.stage == .saved { completion }
                    else {
                        account
                        if flow.stage == .check {
                            Text("Check the saved keys before you continue.").font(.system(size: 13, weight: .medium))
                            Text("This check syncs the destination account. It does not send another import.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            source
                            if let file = displayedFile {
                                FormField(label: "Project name") {
                                    TextField("Project name", text: $flow.project).textFieldStyle(SoftFieldStyle())
                                }
                                selection(file)
                            }
                        }
                        Text("Triwarden keeps the source file unchanged. It does not change your shell settings.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let error = flow.error {
                        Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("envImportError")
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }.thinScroller()
            Divider().opacity(0.5)
            HStack {
                Button(flow.stage == .saved ? "Done" : "Cancel") { dismiss() }
                    .buttonStyle(.appSecondary).keyboardShortcut(.cancelAction).disabled(flow.busy)
                Spacer()
                if flow.busy { ProgressView().controlSize(.small).accessibilityLabel("Saving or checking keys") }
                if flow.stage == .review {
                    Button("Save Selected Keys") { Task { await flow.save(using: model) } }
                        .buttonStyle(.appPrimary).disabled(!flow.canSave)
                        .accessibilityIdentifier("saveEnvKeys")
                } else if flow.stage == .check {
                    Button("Check Saved Keys") { Task { await flow.check(using: model) } }
                        .buttonStyle(.appPrimary).disabled(flow.busy || model.session(for: flow.accountID) == nil)
                } else if flow.stage == .saved {
                    if let savedTool {
                        Button("Copy Launch") {
                            do {
                                model.copyPlain(try SavedToolCommands.launch(savedTool))
                                model.flash(String(localized: "Copied launch for \(savedTool.title)."))
                            } catch { flow.error = error.localizedDescription }
                        }.buttonStyle(.appPrimary)
                    } else {
                        Button("Set Up Tool…", action: setUpTool).buttonStyle(.appPrimary)
                            .disabled(flow.bindings.isEmpty || model.secrets.profiles.count >= 64)
                    }
                }
            }.padding(20)
        }.frame(width: 600, height: 640).background { WindowBackdrop() }
            .interactiveDismissDisabled(flow.busy)
            .onAppear {
                if model.sessions.count == 1 { flow.accountID = model.sessions[0].id }
                #if DEBUG
                if let previewFile { flow.loadPreview(previewFile) }
                #endif
            }
            .onChange(of: model.sessions.map(\.id)) { _, ids in
                if !flow.accountID.isEmpty, !ids.contains(flow.accountID) {
                    flow.locked(); flow.accountID = ""; savedTool = nil; setup = nil
                }
            }
            .sheet(item: $setup) { reference in
                ToolLaunchSetup(reference: reference, onSaved: { savedTool = $0 }).environment(model)
            }
    }

    private var displayedFile: EnvImportFile? {
        #if DEBUG
        if let previewFile { return previewFile }
        #endif
        return flow.file
    }

    private var account: some View {
        @Bindable var flow = flow
        return FormField(label: "Destination account") {
            if model.sessions.isEmpty {
                #if DEBUG
                if previewFile != nil {
                    Text(verbatim: "alex@example.com · vault.example.com").font(.system(size: 12))
                } else {
                    Text("Unlock an account before you import.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                #else
                Text("Unlock an account before you import.").font(.system(size: 12)).foregroundStyle(.secondary)
                #endif
            } else {
                SoftMenu(options: [("", String(localized: "Choose an account…"))] + model.sessions.map {
                    ($0.id, $0.account.email + " · " + $0.account.serverSummary)
                }, selection: $flow.accountID, accessibilityLabel: "Destination account")
                    .disabled(flow.stage == .check || flow.busy)
            }
        }
    }

    private var source: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: flow.source?.lastPathComponent ?? (displayedFile == nil ? String(localized: "No file selected") : ".env"))
                    .font(.system(size: 13, weight: .medium))
                Text("One local UTF-8 file, up to 256 KiB.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(flow.file == nil ? "Choose .env File…" : "Choose Another…", action: chooseFile)
                .buttonStyle(.appSecondarySmall).disabled(flow.busy || model.sessions.isEmpty)
                .accessibilityIdentifier("chooseEnvImportFile")
        }
    }

    private func selection(_ file: EnvImportFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Variables").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(flow.selected.count) of 16 keys selected").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Review the suggested selection. Names do not prove that a value is public or secret.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !flow.selected.isEmpty, (try? file.selected(flow.selected)) == nil {
                Text("Select at most 16 keys with at most 32 KiB of values in total.")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            VStack(spacing: 0) {
                ForEach(file.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(isOn: Binding(get: { flow.selected.contains(entry.variable) }, set: { selected in
                            if selected { flow.selected.insert(entry.variable) } else { flow.selected.remove(entry.variable) }
                        })) {
                            HStack {
                                Text(verbatim: entry.variable).font(.system(size: 12, design: .monospaced))
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                Text("••••••••").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .accessibilityLabel("Masked value")
                            }
                        }.toggleStyle(.checkbox).disabled(entry.problem != nil || flow.busy)
                        if let problem = entry.problem {
                            Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 20)
                        }
                    }.padding(.vertical, 10).padding(.horizontal, 12)
                    if entry.id != file.entries.last?.id { Divider().opacity(0.4) }
                }
            }.background(.primary.opacity(0.025), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(flow.bindings.count) keys saved and confirmed").font(.system(size: 14, weight: .semibold))
            if let account = model.accounts.first(where: { $0.id == flow.accountID }) {
                Text(verbatim: account.email + " · " + account.serverSummary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(flow.bindings, id: \.variable) { binding in
                    Text(verbatim: binding.variable).font(.system(size: 12, design: .monospaced))
                }
            }
            Divider().opacity(0.5)
            if let savedTool {
                Text("Paste the copied launch into your terminal to test this tool.").font(.system(size: 13))
                Text(verbatim: (try? SavedToolCommands.launch(savedTool)) ?? "")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            } else {
                Text("Choose the program that needs these keys. Triwarden asks for approval when you start the saved command.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if model.secrets.profiles.count >= 64 {
                    Text("Remove an unused tool from Tools before you add another tool.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            FormCard(title: "Plaintext remains in the source file") {
                Text("Test the tool before you remove these assignments in your editor.")
                Text("Remove the whole assignment. An empty assignment can replace a supplied key.")
                Text("Keep other settings that your project still needs.")
            }.font(.system(size: 12))
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import .env File")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        flow.open(url)
    }

    private func setUpTool() {
        guard let first = flow.bindings.first else { return }
        setup = ToolLaunchReference(accountID: first.accountID, itemID: first.itemID,
            initialBindings: flow.bindings, suggestedName: flow.project,
            suggestedDirectory: flow.source?.deletingLastPathComponent().path)
    }
}
