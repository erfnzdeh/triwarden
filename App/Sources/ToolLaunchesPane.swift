import SecretsAgent
import SwiftUI

struct ToolLaunchesPane: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
    var previewProfile: SecretsProfile?
    var previewProfiles: [SecretsProfile]?
    var previewGrants: [SecretsActiveGrant]?
    #endif

    @State private var removing: SecretsProfile?
    @State private var resetting = false

    private var savedProfiles: [SecretsProfile] {
        #if DEBUG
        if let previewProfiles { return previewProfiles }
        if let previewProfile { return [previewProfile] }
        #endif
        return model.secrets.profiles
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FormHeader(symbol: "terminal", title: "Tools & Projects",
                           subtitle: "Use saved API keys without copying them into commands or configuration.")
                if let error = model.secrets.lastError {
                    FormCard(title: "Tool settings need attention") {
                        Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.orange)
                        Text("If these settings cannot be recovered, reset the local tool setups and configure them again. Your vault keys are kept.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Reset Tool Setups…") { resetting = true }.buttonStyle(.appSecondarySmall)
                    }
                }
                if !savedProfiles.isEmpty {
                    HStack {
                        Button("Add Tool…") { model.requestedSection = .section(.apiKeys) }.buttonStyle(.appSecondary)
                        Text("Choose a saved key, then Provide to Tool.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(savedProfiles, id: \.name) { configured($0) }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        TrustedToolsCard(profiles: savedProfiles, items: model.items, grants: visibleGrants,
                                         revoke: { model.secrets.revokeGrant($0) }, revokeAll: { model.secrets.reset() })
                    }
                    FormCard(title: "Terminal helper") {
                        Text("Install the terminal helper, keep Triwarden running, and unlock the selected keys' accounts. Each launch refreshes the vault online and asks for approval unless temporary access is still active.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Terminal Helper Setup…") { model.showSettings(.developer) }.buttonStyle(.appSecondarySmall)
                    }
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
                Text("Keys stay in your Bitwarden or Vaultwarden vault. Each tool receives only its selected keys; launch settings are local to this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .thinScroller()
        .confirmationDialog("Remove this tool setup?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Tool", role: .destructive) {
                guard let profile = removing else { return }
                do { try model.secrets.remove(profile.name) } catch { model.flash(error.localizedDescription) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The launch setup is removed from this Mac. Your saved vault keys are kept.")
        }
        .confirmationDialog("Reset all local tool setups?", isPresented: $resetting) {
            Button("Reset Tool Setups", role: .destructive) {
                do { try model.secrets.clearSetups() } catch { model.flash(error.localizedDescription) }
            }
        } message: {
            Text("All saved launch commands and temporary approvals are removed from this Mac. Your vault keys are kept. You will need to set up your tools again.")
        }
    }

    private func configured(_ profile: SecretsProfile) -> some View {
        let item = model.items.first { $0.id == profile.itemID && $0.accountId == profile.accountID && !$0.isDeleted && !$0.isArchived }
        return Group {
            FormCard(title: "Saved tool") {
                Text(verbatim: profile.title).font(.system(size: 18, weight: .semibold))
                Label(status(profile), systemImage: profile.enabled ? "checkmark.shield" : "pause.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(profile.bindings, id: \.variable) { binding in
                    let key = model.items.first { $0.id == binding.itemID && $0.accountId == binding.accountID && !$0.isDeleted && !$0.isArchived }
                    Text(verbatim: (key?.name ?? String(localized: "Unavailable key — unlock its account")) + " → " + binding.variable)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let item, item.isAPIKey {
                    HStack {
                        Button("Edit Tool Setup…") {
                            model.toolLaunchReference = ToolLaunchReference(accountID: profile.accountID, itemID: profile.itemID, toolName: profile.name)
                        }.buttonStyle(.appSecondary)
                        Button("View Key") { model.requestedSection = .section(.apiKeys); model.selectedID = item.id }
                            .buttonStyle(.appSecondary)
                    }
                } else {
                    Button("Advanced Settings…") { model.showSettings(.secrets) }.buttonStyle(.appSecondary)
                }
                HStack {
                    Button(profile.enabled ? "Pause" : "Resume") { setEnabled(!profile.enabled, profile: profile) }.buttonStyle(.appSecondarySmall)
                    Button("Remove Tool…") { removing = profile }.buttonStyle(.appSecondarySmall)
                }
                Divider()
                Text(verbatim: "tw run --profile " + profile.name)
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Button("Copy Launch Command") { model.copyPlain("tw run --profile " + profile.name) }
                    .buttonStyle(.appSecondary).accessibilityIdentifier("copyToolLaunchCommand")
                DisclosureGroup("Saved command details") {
                    Text(verbatim: profile.executable).textSelection(.enabled)
                    ForEach(Array(profile.arguments.enumerated()), id: \.offset) { index, value in
                        Text(verbatim: "\(index + 1): \(value.isEmpty ? "(empty)" : value)")
                    }
                    Text(verbatim: profile.directory).textSelection(.enabled)
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
        if previewProfile != nil || previewProfiles != nil { return "Ready for approval" }
        #endif
        if profile.bindings.contains(where: { model.session(for: $0.accountID) == nil }) { return "Unlock the selected keys' accounts to use this tool" }
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
    let profiles: [SecretsProfile]
    let items: [VaultItem]
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
                    let profile = profiles.first { $0.name == grant.tool }
                    let tool = profile?.title ?? String(localized: "Unavailable tool")
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: tool).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                                if let profile {
                                    ForEach(profile.bindings, id: \.variable) { binding in
                                        let keyName = items.first { $0.id == binding.itemID && $0.accountId == binding.accountID && !$0.isDeleted && !$0.isArchived }?.name
                                            ?? String(localized: "Unavailable key")
                                        Text(verbatim: SecretsController.display(keyName) + " → " + binding.variable)
                                    }
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
