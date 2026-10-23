import SecretsAgent
import SwiftUI

struct TerminalHelperSetup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var installation: TerminalHelperInstallation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHeader(symbol: "terminal", title: "Terminal Helper Setup",
                       subtitle: "Install tw to start saved tools from your terminal.").padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let installation {
                        status(installation).font(.system(size: 13))
                        FormCard(title: "Install location") {
                            Text(verbatim: installation.destination.path).textSelection(.enabled)
                                .font(.system(size: 12, design: .monospaced))
                            Text("The command creates a link to the helper in this app. It replaces an existing link at this location.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Move this app to its permanent location before you install the helper.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Helper in this app") {
                            Text(verbatim: installation.source.path).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 12))
                        if let command = installation.installCommand {
                            FormCard(title: "Run this command in Terminal") {
                                Text(verbatim: command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Button("Copy Install Command") { model.copyPlain(command) }.buttonStyle(.appPrimarySmall)
                            }
                        }
                        Text("Your Mac can ask for your login password. Triwarden does not change your shell startup files.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("If your terminal uses another tw, run command -v tw to find it. Check your PATH order.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Use tw tools list to find your saved tools and their launch commands.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else { ProgressView().frame(maxWidth: .infinity) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.thinScroller()
            Divider().opacity(0.5)
            HStack {
                Button("Check Again") { inspect() }.buttonStyle(.appSecondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.appPrimary).keyboardShortcut(.cancelAction)
            }.padding(20)
        }.frame(width: 580, height: 600).background { WindowBackdrop() }
            .task { inspect() }
    }

    private func inspect() {
        installation = TerminalHelperInstallation.inspect(appURL: Bundle.main.bundleURL)
    }

    @ViewBuilder private func status(_ installation: TerminalHelperInstallation) -> some View {
        switch installation.state {
        case .missingLink: Text("This location has no tw helper. Copy the command below to install it.")
        case .wrongLink: Text("This location links to another helper. Copy the command below to replace the link.")
        default: Text(verbatim: installation.instruction)
        }
    }
}
