import AppKit
import SecretsAgent
import SwiftUI

/// Exports reference metadata. This view does not read vault values or change a saved tool.
struct EnvReferenceExport: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: SecretsProfile
    @State private var savedURL: URL?
    @State private var error: String?
    #if DEBUG
    var previewSavedURL: URL?
    var testDestinationURL: URL?
    var onTestCopy: ((URL) -> Void)?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(savedURL == nil ? "Use an .env reference file" : "Reference file saved")
                    .font(.system(size: 18, weight: .semibold))
                Text(verbatim: profile.title).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let savedURL {
                        Text("Paste this command into your terminal to start the saved tool.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        FormCard(title: "Launch command") {
                            Text(verbatim: (try? EnvReferenceFile.launchCommand(for: savedURL)) ?? "")
                                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Triwarden uses the saved command and project folder. It asks for approval when required.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("Save references to this tool's keys. Key values stay in your vault.")
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        FormCard(title: "Variables") {
                            ForEach(profile.bindings, id: \.variable) { binding in
                                Text(verbatim: binding.variable).font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Use the file with tw. Other dotenv loaders cannot resolve these references.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("If you change the selected keys or variable names, save a new reference file.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let error {
                        Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }.thinScroller()
            Divider().opacity(0.5)
            HStack {
                Button(savedURL == nil ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                if let savedURL {
                    Button("Copy Launch") {
                        do {
                            model.copyPlain(try EnvReferenceFile.launchCommand(for: savedURL))
                            model.flash(String(localized: "Copied launch for \(profile.title)."))
                            #if DEBUG
                            onTestCopy?(savedURL)
                            #endif
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("copyEnvFileLaunch")
                } else {
                    Button("Save File…", action: save).buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("saveEnvReferences")
                }
            }.padding(20)
        }.frame(width: 520, height: 480).background { WindowBackdrop() }
            .onAppear {
                #if DEBUG
                savedURL = previewSavedURL
                #endif
            }
    }

    private func save() {
        error = nil
        do {
            guard model.secrets.profiles.first(where: { $0.name == profile.name }) == profile else {
                throw SecretsFailure("The tool settings changed. Close this window and open it again from Tools.")
            }
            let references = try EnvReferenceFile(profile: profile)
            let panel = NSSavePanel()
            panel.title = String(localized: "Save .env References")
            panel.message = String(localized: "This file contains key references, not key values. Use a name that ends with .env.triwarden.")
            panel.nameFieldStringValue = EnvReferenceFile.defaultName
            panel.directoryURL = URL(fileURLWithPath: profile.directory)
            panel.canCreateDirectories = true; panel.showsHiddenFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard url.lastPathComponent.hasSuffix(EnvReferenceFile.defaultName) else {
                throw SecretsFailure("Use a file name that ends with .env.triwarden.")
            }
            #if DEBUG
            if let testDestinationURL, url.standardizedFileURL != testDestinationURL.standardizedFileURL {
                throw SecretsFailure("Keep the proposed file name and folder for this test.")
            }
            #endif
            _ = try EnvReferenceFile.launchCommand(for: url)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            // The picker confirms the destination. Only reference metadata reaches this write.
            try Data(references.text.utf8).write(to: url, options: .atomic)
            savedURL = url
        } catch { self.error = error.localizedDescription }
    }
}
