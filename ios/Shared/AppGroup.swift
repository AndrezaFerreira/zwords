import Foundation

/// Shared container used by the app and the broadcast extension.
enum AppGroup {
    static let identifier: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        // AltStore / SideStore rewrite app-group IDs on install and expose the new ones here.
        if let groups = info["ALTAppGroups"] as? [String], let first = groups.first {
            return first
        }
        return (info["AppGroupID"] as? String) ?? "group.com.zwords.live"
    }()

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
