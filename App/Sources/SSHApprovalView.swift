import AppKit
import SSHAgent
import SwiftUI

/// The standalone SSH decision uses the same form language as local Secrets approval.
struct SSHApprovalView: View {
    let prompt: SSHPrompt
    let deadline: ContinuousClock.Instant
    let pendingCount: Int
    let leadsWithUntilLock: Bool
    let choose: (SSHChoice) -> Void
    @State private var grant: SSHGrant

    init(prompt: SSHPrompt, deadline: ContinuousClock.Instant, pendingCount: Int = 1,
         leadsWithUntilLock: Bool, choose: @escaping (SSHChoice) -> Void) {
        self.prompt = prompt
        self.deadline = deadline
        self.pendingCount = pendingCount
        self.leadsWithUntilLock = leadsWithUntilLock
        self.choose = choose
        _grant = State(initialValue: leadsWithUntilLock ? .untilLock : .once)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHeader(symbol: "key", title: "Allow SSH signing?", subtitle: "Review the app and SSH key.")
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FormCard(title: "Signing request") {
                        HStack(spacing: 10) {
                            requesterIcon
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: prompt.displayName).font(.system(size: 15, weight: .semibold))
                                Text("via \(prompt.via)").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        row("SSH key", prompt.keyName, monospaced: false)
                        if let path = prompt.appPath { row("Application", path) }
                        if let path = prompt.path { row("Executable", path) }
                        if prompt.waitingCount > 1 {
                            Text("^[\(prompt.waitingCount) signatures in this request](inflect: true)")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    FormCard(title: "Authorization") {
                        SoftMenu(options: [(.once, String(localized: "Allow Once")),
                                           (.tenMinutes, String(localized: "Allow for 10 Minutes")),
                                           (.untilLock, String(localized: "Trust Until Lock")),
                                           (.always, String(localized: "Always Allow"))],
                                 selection: $grant, accessibilityLabel: "How long to allow")
                        Text(grantDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if leadsWithUntilLock {
                            Text("This app has asked to sign before.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Text("The agent returns a signature. It does not send the private key to the requesting app.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    if pendingCount > 1 {
                        Text("^[\(pendingCount - 1) more request](inflect: true) waiting")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 18)
            }
            .thinScroller()
            VStack(alignment: .leading, spacing: 0) {
                Label("macOS will ask for Touch ID or your Mac login password.", systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 2)
                FormFooter(action: "Allow Signing…", cancelTitle: "Deny", defaultAction: false, showsSeparator: false,
                           cancel: { choose(.deny) }, submit: { choose(.allow(grant)) }) {
                    DeadlineCountdown(deadline: deadline, duration: SSHApprovalQueue.timeout)
                }
            }
            .background(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .background { WindowBackdrop() }
    }

    private var grantDescription: LocalizedStringKey {
        switch grant {
        case .once: "Also covers signatures from this app and key for the next 15 seconds."
        case .tenMinutes: "This app and key may sign for 10 minutes, or until the vault locks."
        case .untilLock: "This app and key may sign until the vault locks."
        case .always: "This app may use available SSH keys whenever the vault is unlocked, without asking again. This permission survives lock and quit."
        }
    }

    @ViewBuilder private var requesterIcon: some View {
        if let path = prompt.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).accessibilityHidden(true)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: value).font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
