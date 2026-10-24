import Foundation

extension AppModel {
    /// Apply the same visibility rule to sidebar drawing, keyboard navigation, and requested destinations.
    func showsNavigation(_ destination: SidebarSelection) -> Bool {
        switch destination {
        case .section(.apiKeys), .toolLaunches: showsAPIKeyTools
        default: true
        }
    }
}
