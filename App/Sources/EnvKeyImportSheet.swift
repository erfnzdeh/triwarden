import AppKit
import SecretsAgent
import SwiftUI

struct EnvKeyImportSheet: View {
    var onImported: ((ToolLaunchReference) -> Void)? = nil
    var onSavedTool: ((SecretsProfile) -> Void)? = nil
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
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flow.stage == .saved ? "Keys are in your vault" : "Import from .env")
                        .font(.system(size: 18, weight: .semibold))
                    Text(flow.stage == .saved ? "Next, choose the program that should receive them."
                                              : "Move API keys out of a plain-text file and into your vault.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ImportSteps(current: stepIndex)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if flow.stage == .saved { completion }
                    else {
                        if flow.stage == .check {
                            destination
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Check the saved keys before you continue.").font(.system(size: 13, weight: .medium))
                                Text("This check syncs the destination account. It does not send another import.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(.horizontal, 4)
                        } else {
                            source
                            if let file = displayedFile {
                                destination
                                selection(file)
                            }
                        }
                        Label("Your .env file is only read. Triwarden never changes it or your shell settings.", systemImage: "lock.doc")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let error = flow.error {
                        Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("envImportError")
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.thinScroller()
            Divider().opacity(0.5)
            HStack {
                Button(flow.stage == .saved ? "Done" : "Cancel") { dismiss() }
                    .buttonStyle(.appSecondary).keyboardShortcut(.cancelAction).disabled(flow.busy)
                Spacer()
                if flow.busy { ProgressView().controlSize(.small).accessibilityLabel("Saving or checking keys") }
                if flow.stage == .review {
                    Button(flow.selected.count == 1 ? "Save 1 Key" : "Save \(flow.selected.count) Keys") { Task { await flow.save(using: model) } }
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
            .onChange(of: flow.stage) { _, stage in
                if stage == .saved, let reference = importedReference { onImported?(reference) }
            }
            .sheet(item: $setup) { reference in
                ToolLaunchSetup(reference: reference, onSaved: { savedTool = $0; onSavedTool?($0) }).environment(model)
            }
    }

    private var displayedFile: EnvImportFile? {
        #if DEBUG
        if let previewFile { return previewFile }
        #endif
        return flow.file
    }

    /// Where the keys go: one card holding the account and the project name the items are grouped under.
    private var destination: some View {
        @Bindable var flow = flow
        return VStack(alignment: .leading, spacing: 8) {
            Text("Save to").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.4).padding(.horizontal, 4)
            VStack(spacing: 0) {
                destinationRow("Account") {
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
                if flow.stage != .check {
                    Divider().opacity(0.4).padding(.leading, 14)
                    destinationRow("Project") {
                        TextField("Project name", text: $flow.project).textFieldStyle(.plain).font(.system(size: 12))
                            .accessibilityLabel("Project name")
                    }
                }
            }
            .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
            if let example = displayedFile?.entries.first(where: { flow.selected.contains($0.variable) })?.variable {
                let project = flow.project.trimmingCharacters(in: .whitespacesAndNewlines)
                Text("Each key becomes an API key item, such as “\(project.isEmpty ? String(localized: "Project") : project) · \(example)”.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private func destinationRow(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 14).frame(minHeight: 40)
    }

    private var source: some View {
        Button(action: chooseFile) {
            HStack(spacing: 14) {
                Image(systemName: flow.file == nil && displayedFile == nil ? "doc.badge.plus" : "doc.text")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: flow.source?.lastPathComponent ?? (displayedFile == nil ? String(localized: "Choose your .env file") : ".env"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: flow.source.map { ToolLaunchesPane.abbreviated($0.deletingLastPathComponent().path) }
                         ?? String(localized: "One UTF-8 file, up to 256 KB. Hidden files are shown."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(flow.file == nil && displayedFile == nil ? "Choose…" : "Change…")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(displayedFile == nil ? AnyShapeStyle(.primary.opacity(0.18)) : AnyShapeStyle(Color.panelEdge),
                                  style: StrokeStyle(lineWidth: 1, dash: displayedFile == nil ? [5, 4] : []))
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(flow.busy || model.sessions.isEmpty)
        .accessibilityIdentifier("chooseEnvImportFile")
    }

    private func selection(_ file: EnvImportFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keys to save").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.4)
                Spacer()
                Text("\(flow.selected.count) of up to 16").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(file.entries) { entry in
                    let on = flow.selected.contains(entry.variable)
                    HStack(alignment: .center, spacing: 12) {
                        Toggle("", isOn: Binding(get: { on }, set: { selected in
                            if selected { flow.selected.insert(entry.variable) } else { flow.selected.remove(entry.variable) }
                        })).toggleStyle(.checkbox).labelsHidden()
                            .disabled(entry.problem != nil || flow.busy)
                            .accessibilityLabel(Text(verbatim: entry.variable))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.variable).font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(entry.problem == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if let problem = entry.problem {
                                Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        if entry.problem == nil {
                            Text(verbatim: "••••••••").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                                .accessibilityLabel("Masked value")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(.rect)
                    .onTapGesture {
                        guard entry.problem == nil, !flow.busy else { return }
                        if on { flow.selected.remove(entry.variable) } else { flow.selected.insert(entry.variable) }
                    }
                    if entry.id != file.entries.last?.id { Divider().opacity(0.4).padding(.leading, 44) }
                }
            }
            .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
            if !flow.selected.isEmpty, (try? file.selected(flow.selected)) == nil {
                Label("Choose up to 16 keys, with no more than 32 KB of values in total.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 4)
            } else {
                Text("Pre-selected by name. A name can't prove a value is secret, so check the list.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.bindings.count == 1 ? "1 key saved and checked" : "\(flow.bindings.count) keys saved and checked")
                            .font(.system(size: 14, weight: .semibold))
                        if let account = model.accounts.first(where: { $0.id == flow.accountID }) {
                            Text(verbatim: account.email + " · " + account.serverSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                FlowChips(values: flow.bindings.map(\.variable))
                if let savedTool {
                    Divider().opacity(0.4)
                    Text("Start it from any terminal").font(.system(size: 12, weight: .semibold))
                    CommandWell(command: (try? SavedToolCommands.launch(savedTool)) ?? "", copyLabel: "Copy", prominent: true) {
                        if let command = try? SavedToolCommands.launch(savedTool) {
                            model.copyPlain(command)
                            model.flash(String(localized: "Copied launch for \(savedTool.title)."))
                        }
                    }
                } else if model.secrets.profiles.count >= 64 {
                    Text("Remove an unused tool from Secrets before you add another.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelStrong, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.panelEdge))
            VStack(alignment: .leading, spacing: 8) {
                Label("The keys are still in your .env file", systemImage: "doc.text").font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    Text("1. Test the tool through Triwarden first.")
                    Text("2. Then delete each imported line in your editor — the whole line, not just the value. An empty `KEY=` would override the key Triwarden supplies.")
                    Text("3. Keep any other settings your project still needs.")
                }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            }.padding(.horizontal, 4)
        }
    }

    private var stepIndex: Int {
        switch flow.stage { case .choose, .review: 0; case .check: 1; case .saved: 2 }
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
        setup = importedReference
    }

    private var importedReference: ToolLaunchReference? {
        guard let first = flow.bindings.first else { return nil }
        return ToolLaunchReference(accountID: first.accountID, itemID: first.itemID,
            initialBindings: flow.bindings, suggestedName: flow.project,
            suggestedDirectory: flow.source?.deletingLastPathComponent().path)
    }
}

/// Choose → Save → Use, so the user sees where the import ends.
private struct ImportSteps: View {
    let current: Int
    var body: some View {
        StepTrack(titles: [String(localized: "Choose keys"), String(localized: "Save to vault"), String(localized: "Use with a tool")],
                  current: current)
    }
}

/// Variable names as small monospaced chips that wrap.
struct FlowChips: View {
    let values: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text(verbatim: value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
