import SSHAgent
import SwiftUI

/// One SSH history record in Access: who asked, which key, how it ended, and how long ago (no seconds).
struct SSHAccessRecordRow: View {
    let event: SSHAccessEvent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16), in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("via \(event.via) · \(event.keyName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: .capsule)
                Text(verbatim: SSHAccessClock.label(since: event.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help([event.appName, "via " + event.via, event.keyName, event.path ?? "", event.date.formatted()].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var symbol: String {
        switch event.outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .reusedTrust: "checkmark"
        case .allowlisted: "checkmark.seal"
        case .denied: "xmark"
        case .timedOut: "clock"
        case .locked: "lock"
        }
    }

    private var tint: Color {
        switch event.outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .allowlisted, .reusedTrust:
            colorScheme == .dark ? Color(red: 0.35, green: 0.78, blue: 0.55) : Color(red: 0.10, green: 0.40, blue: 0.24)
        case .denied: colorScheme == .dark ? Color(red: 0.95, green: 0.45, blue: 0.42) : Color(red: 0.70, green: 0.18, blue: 0.17)
        case .timedOut: colorScheme == .dark ? Color(red: 0.95, green: 0.72, blue: 0.38) : Color(red: 0.54, green: 0.32, blue: 0.08)
        case .locked: .secondary
        }
    }

    private var label: LocalizedStringKey {
        switch event.outcome {
        case .allowedOnce: "Allowed once"
        case .allowedForTenMinutes: "Allowed for 10 minutes"
        case .allowedUntilLock: "Trusted until lock"
        case .allowlisted: "Always allowed"
        case .denied: "Denied"
        case .timedOut: "Timed out"
        case .locked: "Vault locked"
        case .reusedTrust: "Used an existing grant"
        }
    }
}
