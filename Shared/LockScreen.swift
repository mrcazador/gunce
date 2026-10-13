import ActivityKit
import Foundation
import Security
import SwiftUI

/// The active task as the Lock Screen shows it: in the Live Activity and in the widget.
struct ActiveTaskAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var areaName: String?
        var areaSymbol: String?
        var areaColor: String?
        var startedAt: Date
        var nextStep: String?
        var stepsDone: Int
        var stepsTotal: Int
    }

    var taskID: String
}

/// What the widget reads. Written by the app after every task change.
struct LockScreenSnapshot: Codable, Equatable {
    var taskID: String?
    var state: ActiveTaskAttributes.ContentState?
    var parkedCount: Int

    static let empty = LockScreenSnapshot(taskID: nil, state: nil, parkedCount: 0)
}

/// Shares the snapshot with the widget through a Keychain access group, so no App Group
/// (and no extra portal setup) is needed. It holds task titles only, never the session token.
enum SharedSnapshot {
    private static let service = "pickup.widget"
    private static let account = "snapshot"

    /// `PickUpKeychainGroup` in Info.plist: the team prefix plus `<bundle id>.shared`.
    private static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PickUpKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(")
        else { return nil }
        return group
    }

    private static var baseQuery: [String: Any]? {
        guard let accessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func load() -> LockScreenSnapshot {
        guard var query = baseQuery else { return .empty }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let snapshot = try? JSONDecoder().decode(LockScreenSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    static func save(_ snapshot: LockScreenSnapshot) {
        guard let query = baseQuery, let data = try? JSONEncoder().encode(snapshot) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Area colors for the widget, matching `Area.tint` in the app.
enum AreaPalette {
    static func color(_ name: String?) -> Color {
        switch name {
        case "indigo": .indigo
        case "pink": .pink
        case "orange": .orange
        case "green": .green
        case "blue": .blue
        case "red": .red
        case "purple": .purple
        case "teal": .teal
        case "mint": .mint
        case "cyan": .cyan
        case "yellow": .yellow
        case "brown": .brown
        default: .gray
        }
    }
}

/// Deep links the Lock Screen opens: `pickup://now` and `pickup://park`.
enum PickUpLink {
    static let now = URL(string: "pickup://now")!
    static let park = URL(string: "pickup://park")!
}
