import SSHAgent
import SwiftUI

/// One SSH history record in Access: who asked, which key, how it ended, and how long ago (no seconds).
struct SSHAccessRecordRow: View {
    let event: SSHAccessEvent
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
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
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                    Text(label)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .foregroundStyle(event.outcome == .denied ? Color.red : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                Text(verbatim: SSHAccessClock.label(since: event.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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

    private var label: LocalizedStringKey {
        switch event.outcome {
        case .allowedOnce: "Allowed once"
        case .allowedForTenMinutes: "Allowed for 10 minutes"
        case .allowedUntilLock: "Allowed until lock"
        case .allowlisted: "Always allowed"
        case .denied: "Denied"
        case .timedOut: "Timed out"
        case .locked: "Vault locked"
        case .reusedTrust: "Used existing approval"
        }
    }
}
