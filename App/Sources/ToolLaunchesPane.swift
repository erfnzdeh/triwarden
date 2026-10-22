import SecretsAgent
import SwiftUI

struct ToolLaunchesPane: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
    var previewProfile: SecretsProfile?
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
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if model.secrets.activeGrantCount > 0 {
                        HStack {
                            Text("Temporary access is active for this tool.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("Revoke Access") { model.secrets.reset() }.buttonStyle(.appSecondarySmall)
                        }
                    }
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

    private func status(_ profile: SecretsProfile) -> LocalizedStringKey {
        if !profile.enabled { return "Paused" }
        if model.secrets.lastError != nil { return "Needs attention" }
        if model.session(for: profile.accountID) == nil { return "Unlock this account to use the tool" }
        return "Ready for approval"
    }

    private func setEnabled(_ enabled: Bool, profile: SecretsProfile) {
        var updated = profile; updated.enabled = enabled
        do { try model.secrets.save(updated) }
        catch { model.flash(error.localizedDescription) }
    }
}
