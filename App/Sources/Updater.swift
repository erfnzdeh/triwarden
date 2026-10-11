import Combine
import Foundation
import Observation
import Sparkle

/// In-place updates with Sparkle: the appcast attached to the latest GitHub release lists the new version; the
/// update is downloaded, its EdDSA signature checked against `SUPublicEDKey` (and Apple's notarization by
/// Gatekeeper), installed by Sparkle's XPC installer, and the app relaunched.
///
/// Automatic checks stay opt-in, as before: nothing is requested until the user turns them on or checks by hand.
@MainActor @Observable
final class Updater {
    private let controller: SPUStandardUpdaterController?
    private var observers: Set<AnyCancellable> = []

    /// False in builds without a public key (development), and while testing: updates can't be verified there.
    let isConfigured: Bool
    private(set) var canCheck = false
    private(set) var lastChecked: Date?
    /// Set when Sparkle finds a newer signed release. Cleared when a check finds nothing.
    private(set) var availableVersion: String?
    private let notice = UpdateNotice()

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    init(start: Bool) {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        isConfigured = !key.trimmingCharacters(in: .whitespaces).isEmpty
        guard start, isConfigured else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: notice, userDriverDelegate: nil)
        self.controller = controller
        notice.owner = self
        // Carry over the old "check daily" choice once.
        if UserDefaults.standard.bool(forKey: Pref.checkUpdates) {
            controller.updater.automaticallyChecksForUpdates = true
            UserDefaults.standard.removeObject(forKey: Pref.checkUpdates)
        }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observers)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastChecked = $0 }
            .store(in: &observers)
    }

    /// Daily background checks (off until the user turns them on).
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticallyChecks) { controller?.updater.automaticallyChecksForUpdates = newValue }
            if !newValue { automaticallyDownloads = false }
        }
    }

    /// Download and install found updates without asking (the update still shows what's new afterwards).
    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { withMutation(keyPath: \.automaticallyDownloads) { controller?.updater.automaticallyDownloadsUpdates = newValue } }
    }

    /// Shows Sparkle's window: up to date, or what's new with Install / Later.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func noteAvailableVersion(_ version: String?) {
        availableVersion = version
    }
}

/// Remembers a found update for the header bell. Sparkle still shows its own install window.
private final class UpdateNotice: NSObject, SPUUpdaterDelegate {
    weak var owner: Updater?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in owner?.noteAvailableVersion(version) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in owner?.noteAvailableVersion(nil) }
    }
}
