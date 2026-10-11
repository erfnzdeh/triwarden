import AppKit
import SwiftUI
import SSHAgent

/// The decision for one SSH signature, drawn as a card inside the menu bar panel.
struct SSHApprovalCard: View {
    var prompt: SSHPrompt
    var leadsWithUntilLock: Bool
    var choose: (SSHChoice) -> Void
    @State private var grant: SSHGrant

    init(prompt: SSHPrompt, leadsWithUntilLock: Bool, choose: @escaping (SSHChoice) -> Void) {
        self.prompt = prompt
        self.leadsWithUntilLock = leadsWithUntilLock
        self.choose = choose
        _grant = State(initialValue: leadsWithUntilLock ? .untilLock : .once)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prompt.displayName) wants to sign")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("via \(prompt.via) · \(prompt.keyName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if prompt.appPath == nil, let path = prompt.path {
                Text(verbatim: path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if prompt.waitingCount > 1 {
                Text("^[\(prompt.waitingCount) signatures in this request](inflect: true)")
                    .font(.system(size: 12, weight: .medium))
            }
            if leadsWithUntilLock {
                Text("This app has asked to sign before.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("macOS will ask for Touch ID or your Mac login password. That password stays with macOS.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.menuCard, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.menuEdge))
    }

    private var icon: some View {
        Group {
            if let path = prompt.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            Menu {
                Picker("How long", selection: $grant) {
                    Text("Allow Once").tag(SSHGrant.once)
                    Text("Allow for 10 Minutes").tag(SSHGrant.tenMinutes)
                    Text("Trust Until Lock").tag(SSHGrant.untilLock)
                    Text("Always Allow").tag(SSHGrant.always)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(grantTitle)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(Text("How long to allow"))
            HStack(spacing: 8) {
                Button("Allow") { choose(.allow(grant)) }
                    .buttonStyle(.appPrimarySmall)
                    .keyboardShortcut(.defaultAction)
                Button("Deny") { choose(.deny) }
                    .buttonStyle(.appSecondarySmall)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: prompt.id) { _, _ in
            grant = leadsWithUntilLock ? .untilLock : .once
        }
    }

    private var grantTitle: LocalizedStringKey {
        switch grant {
        case .once: "Allow Once"
        case .tenMinutes: "Allow for 10 Minutes"
        case .untilLock: "Trust Until Lock"
        case .always: "Always Allow"
        }
    }
}

/// How long ago an SSH request was, in the largest unit only. Seconds are never shown.
enum SSHAccessClock {
    static func label(since date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return String(localized: "Just now") }
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours) hr") }
        return String(localized: "\(hours / 24) d")
    }
}

/// Opens the menu bar panel. The status item belongs to SwiftUI, so this clicks Triwarden's button.
@MainActor
enum MenuBarOpener {
    static var isOpen = false

    static func open() {
        guard !isOpen, let button = triwardenButton() else { return }
        button.performClick(nil)
    }

    private static func triwardenButton() -> NSStatusBarButton? {
        let bar = NSStatusBar.system
        let sel = NSSelectorFromString("_statusItems")
        guard bar.responds(to: sel), let value = bar.perform(sel)?.takeUnretainedValue() else { return nil }
        let items = (value as? [NSStatusItem]) ?? (value as? NSArray)?.compactMap { $0 as? NSStatusItem } ?? []
        return items.first { item in
            item.button?.image?.accessibilityDescription?.contains("Triwarden") == true
        }?.button
    }
}
