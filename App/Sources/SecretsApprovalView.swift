import SwiftUI

/// Reference-only presentation shared by the live panel and synthetic visual previews.
struct SecretsApprovalView: View {
    let prompt: SecretsController.Prompt
    var authenticating = false
    var deny: () -> Void
    var allow: () -> Void
    @State private var helperExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHeader(symbol: "terminal", title: "Allow credential access?",
                       subtitle: "Review the credential and saved command.")
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FormCard(title: "Credential") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: prompt.credential)
                                .font(.system(size: 15, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: prompt.account)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        row("Tool", prompt.request.profile.title, monospaced: false)
                        row("Vault field", prompt.request.profile.field.label)
                        row("Environment", prompt.request.profile.variable)
                    }
                    FormCard(title: "Launch command") {
                        row("Executable", prompt.request.launch.executable.path)
                        ForEach(Array(prompt.request.profile.arguments.enumerated()), id: \.offset) { index, argument in
                            row("Argument \(index + 1)", argument.isEmpty ? String(localized: "(empty argument)") : argument)
                        }
                        Divider()
                        row("Working directory", prompt.request.launch.directory)
                    }
                    DisclosureGroup(isExpanded: $helperExpanded) {
                        Text(verbatim: prompt.helper)
                            .font(.system(size: 12, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Label("Requesting helper", systemImage: "app.connected.to.app.below.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("A terminal or an AI agent may have requested this launch.")
                        Text("Only this credential and basic terminal settings are passed. The tool, its child processes, and potentially other processes running as you can read the value. Locking Triwarden cannot recall it.")
                        Text("Approving this command does not verify its scripts, plugins or project code.")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 24).padding(.bottom, 18)
            }
            .thinScroller()

            VStack(alignment: .leading, spacing: 0) {
                Label(authenticationMessage, systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 2)
                FormFooter(action: "Allow This Launch…", cancelTitle: "Deny", defaultAction: false, showsSeparator: false, busy: authenticating,
                           cancel: deny, submit: allow) {
                    DeadlineCountdown(deadline: prompt.deadline, duration: SecretsController.approvalTimeout)
                }
            }
            .background(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(minWidth: 540, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background { WindowBackdrop() }
    }

    private var authenticationMessage: LocalizedStringKey {
        authenticating ? "Waiting for macOS confirmation…" : "macOS will ask for Touch ID or your Mac login password."
    }

    private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SecretsApprovalPanelContent: View {
    @Bindable var controller: SecretsController
    var body: some View {
        Group {
            if let prompt = controller.pending {
                SecretsApprovalView(prompt: prompt, authenticating: controller.authenticating,
                                    deny: controller.deny, allow: controller.allow)
            } else {
                Color.clear
            }
        }
        .modifier(LiveAppearance())
        .modifier(ReducedMotionPolicy())
    }
}
