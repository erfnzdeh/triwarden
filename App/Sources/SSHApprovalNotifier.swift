import Foundation
import SSHAgent
import UserNotifications

/// A banner that only brings the approval card forward. It never approves a signature.
enum SSHApprovalNotifier {
    private static let category = "ssh-approval"

    static func arm(_ prompt: SSHPrompt) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(prompt, center: center) }
                }
            case .authorized, .provisional:
                post(prompt, center: center)
            default:
                break
            }
        }
    }

    /// Asks once, when the agent is turned on, so the first signature is not the first time macOS asks.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func post(_ prompt: SSHPrompt, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(prompt.displayName) wants to sign")
        content.body = String(localized: "via \(prompt.via) · \(prompt.keyName)")
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["id": prompt.id.uuidString]
        // Deliver now. A delayed request was removed as soon as the card was answered, so the banner never appeared.
        center.add(UNNotificationRequest(identifier: prompt.id.uuidString, content: content, trigger: nil))
    }

    static func cancel(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
}

extension Notification.Name {
    static let sshApprovalReveal = Notification.Name("sshApprovalReveal")
    static let inboxReveal = Notification.Name("inboxReveal")
}

/// One macOS banner for something waiting in the bell. A tap only opens the bell.
struct InboxBanner: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var sound = false
}

/// Posts each banner once. A banner that goes away is withdrawn, so the same event can notify again later.
enum InboxAnnouncer {
    private static let remembered = "announcedInbox"

    static func deliver(_ banners: [InboxBanner]) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            let current = Set(banners.map(\.id))
            var seen = Set(UserDefaults.standard.stringArray(forKey: remembered) ?? [])
            let gone = seen.subtracting(current).map { "inbox-\($0)" }
            if !gone.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: gone)
                center.removeDeliveredNotifications(withIdentifiers: gone)
            }
            var next = seen.intersection(current)
            if allowed {
                for banner in banners where !next.contains(banner.id) {
                    let content = UNMutableNotificationContent()
                    content.title = banner.title
                    content.body = banner.body
                    content.userInfo = ["inbox": banner.id]
                    if banner.sound { content.sound = .default }
                    center.add(UNNotificationRequest(identifier: "inbox-\(banner.id)", content: content, trigger: nil))
                    next.insert(banner.id)
                }
            }
            UserDefaults.standard.set(Array(next), forKey: remembered)
        }
    }
}

/// Not main-actor isolated, so the system can deliver the tap without crossing a Sendable boundary into `AppDelegate`.
final class SSHNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let opensInbox = response.notification.request.content.userInfo["inbox"] != nil
        await MainActor.run {
            NotificationCenter.default.post(name: opensInbox ? .inboxReveal : .sshApprovalReveal, object: nil)
        }
    }
}
