import SecretsAgent
import SwiftUI

struct ToolLaunchesPane: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
    var previewProfile: SecretsProfile?
    var previewGrants: [SecretsActiveGrant]?
    #endif

    private var savedProfile: SecretsProfile? {
        #if DEBUG
        if let previewProfile { return previewProfile }
        #endif
        return model.secrets.profile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FormHeader(symbol: "terminal", title: "Tools & Projects",
                           subtitle: "Use saved API keys without copying them into commands or configuration.")
                if let profile = savedProfile {
                    configured(profile)
                } else {
                    FormCard {
                        Text("Give a tool access to a saved key").font(.system(size: 17, weight: .semibold))
                        Text("Save an API key in your vault, open it, then choose Provide to Tool. You'll review the command before saving.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("Choose an API Key") { model.requestedSection = .section(.apiKeys) }
                            .buttonStyle(.appPrimary).accessibilityIdentifier("chooseToolAPIKey")
                        Button("Add API Key") { model.beginAPIKey() }.buttonStyle(.appSecondary)
                    }
                }
                Text("This version supports one saved tool with one key. Keys stay in your Bitwarden or Vaultwarden vault; tool settings are local to this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .thinScroller()
    }

    private func configured(_ profile: SecretsProfile) -> some View {
        let item = model.items.first { $0.id == profile.itemID && $0.accountId == profile.accountID && !$0.isDeleted && !$0.isArchived }
        return Group {
            FormCard(title: "Saved tool") {
                Text(verbatim: profile.title).font(.system(size: 18, weight: .semibold))
                Label(status(profile), systemImage: profile.enabled ? "checkmark.shield" : "pause.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(verbatim: item?.name ?? String(localized: "Unlock the key's account to view or change its binding."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let error = model.secrets.lastError {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if let item, item.isAPIKey {
                    HStack {
                        Button("Edit Tool Setup…") { model.provideKeyToTool(item) }.buttonStyle(.appSecondary)
                        Button("View Key") { model.requestedSection = .section(.apiKeys); model.selectedID = item.id }
                            .buttonStyle(.appSecondary)
                        Button(profile.enabled ? "Pause" : "Resume") { setEnabled(!profile.enabled, profile: profile) }
                            .buttonStyle(.appSecondary)
                    }
                } else {
                    Button("Advanced Settings…") { model.showSettings(.secrets) }.buttonStyle(.appSecondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                TrustedToolsCard(tool: profile.title, keyName: item?.name, grants: visibleGrants,
                                 revoke: { model.secrets.revokeGrant($0) }, revokeAll: { model.secrets.reset() })
            }
            FormCard(title: "Use it from your terminal") {
                Text("Run this whenever you want to start the tool. Triwarden asks for approval unless temporary access from this terminal or launcher is still active.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(verbatim: "tw run --profile " + profile.name)
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Button("Copy Launch Command") { model.copyPlain("tw run --profile " + profile.name) }
                    .buttonStyle(.appSecondary).accessibilityIdentifier("copyToolLaunchCommand")
                Text("First time? Install the terminal helper, keep Triwarden running, and unlock the key's account. Each launch refreshes the vault online.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Terminal Helper Setup…") { model.showSettings(.developer) }.buttonStyle(.appSecondarySmall)
            }
            DisclosureGroup("Saved command details") {
                FormCard {
                    Text(verbatim: profile.executable).textSelection(.enabled)
                    ForEach(Array(profile.arguments.enumerated()), id: \.offset) { index, value in
                        Text(verbatim: "\(index + 1): \(value.isEmpty ? "(empty)" : value)")
                    }
                    Text(verbatim: profile.directory).textSelection(.enabled)
                    Text(verbatim: profile.variable)
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private var visibleGrants: [SecretsActiveGrant] {
        #if DEBUG
        if let previewGrants { return previewGrants.filter { $0.deadline.map { .now < $0 } ?? true } }
        #endif
        return model.secrets.activeGrants
    }

    private func status(_ profile: SecretsProfile) -> LocalizedStringKey {
        if !profile.enabled { return "Paused" }
        if model.secrets.lastError != nil { return "Needs attention" }
        #if DEBUG
        if previewProfile != nil { return "Ready for approval" }
        #endif
        if model.session(for: profile.accountID) == nil { return "Unlock this account to use the tool" }
        return "Ready for approval"
    }

    private func setEnabled(_ enabled: Bool, profile: SecretsProfile) {
        var updated = profile; updated.enabled = enabled
        do { try model.secrets.save(updated) }
        catch { model.flash(error.localizedDescription) }
    }
}

/// Displays only active, memory-only approvals. Saving a tool never adds it to this list.
private struct TrustedToolsCard: View {
    let tool: String
    let keyName: String?
    let grants: [SecretsActiveGrant]
    let revoke: (UUID) -> Void
    let revokeAll: () -> Void

    var body: some View {
        FormCard {
            HStack {
                Text("Trusted tools").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !grants.isEmpty {
                    Button("Revoke All", action: revokeAll).buttonStyle(.appSecondarySmall)
                        .accessibilityIdentifier("revokeAllToolAccess")
                }
            }
            if grants.isEmpty {
                Text("No tools have temporary access.").font(.system(size: 13, weight: .medium))
                Text("Choose 10 minutes or Until lock when approving a launch to see it here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Each terminal or launcher has its own temporary approval.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(grants) { grant in
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: tool).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                                if let keyName {
                                    Label(SecretsController.display(keyName), systemImage: "key.horizontal")
                                } else {
                                    Text("The saved credential is currently unavailable.")
                                }
                                Text("Started from: \(SecretsController.display(grant.caller.label))")
                                    .help(SecretsController.display(grant.caller.path))
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Revoke") { revoke(grant.id) }.buttonStyle(.appSecondarySmall)
                                .accessibilityLabel("Revoke access for \(tool), \(SecretsController.display(grant.caller.label))")
                                .accessibilityIdentifier("revokeToolAccess-\(grant.id)")
                        }
                        Label {
                            if let deadline = grant.deadline {
                                let parts = ContinuousClock.now.duration(to: deadline).components
                                let remaining = max(0, parts.seconds + (parts.attoseconds > 0 ? 1 : 0))
                                Text("\(remaining / 60)m \(remaining % 60)s remaining").monospacedDigit()
                            } else {
                                Text("Until Triwarden locks")
                            }
                        } icon: {
                            Image(systemName: grant.deadline == nil ? "lock" : "clock")
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                Text("Revoking access makes the next launch ask again. Programs that already received a key can keep using it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("trustedTools")
    }
}
