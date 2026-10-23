import AppKit
import SecretsAgent
import SwiftUI

/// Setup guidance only. Every launch still authenticates the actual running helper.
struct TerminalHelperStatusRow: View {
    let openSetup: () -> Void
    @State private var state: TerminalHelperInstallation.State?
    @State private var refresh = 0
    #if DEBUG
    var previewState: TerminalHelperInstallation.State?
    #endif

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: summary).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Terminal Helper Setup…", action: openSetup).buttonStyle(.appSecondarySmall)
                .accessibilityIdentifier("toolsHelperSetup")
        }
        .task(id: refresh) {
            #if DEBUG
            if let previewState { state = previewState; return }
            #endif
            let app = Bundle.main.bundleURL
            let result = await Task.detached(priority: .utility) { TerminalHelperInstallation.inspect(appURL: app) }.value
            guard !Task.isCancelled else { return }
            state = result.state
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private var summary: String {
        switch state {
        case .installed: String(localized: "Terminal helper ready.")
        case .missingLink: String(localized: "Set up tw before your first launch.")
        case .wrongLink: String(localized: "Update tw to use this app.")
        case .missingSource, .invalidSignature: String(localized: "Repair this app before you install tw.")
        case .occupied: String(localized: "The install location needs attention.")
        case nil: String(localized: "Check terminal helper setup.")
        }
    }
}
