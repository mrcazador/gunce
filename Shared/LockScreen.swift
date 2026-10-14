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
/// New fields have defaults and decode leniently, so an older saved snapshot still loads.
struct LockScreenSnapshot: Codable, Equatable {
    var taskID: String?
    var state: ActiveTaskAttributes.ContentState?
    var parkedCount: Int
    /// The active task's next open steps, at most three.
    var upcomingSteps: [Step] = []
    /// The active task's last park note.
    var parkNote: String? = nil
    /// The most recently parked tasks, at most three.
    var parked: [Parked] = []

    struct Step: Codable, Hashable, Identifiable {
        var id: String
        var title: String
    }

    struct Parked: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var areaSymbol: String?
        var areaColor: String?
        var parkNote: String?
        /// `waiting`, `need_info` or `later`.
        var parkReason: String?
    }

    static let empty = LockScreenSnapshot(taskID: nil, state: nil, parkedCount: 0)

    enum CodingKeys: String, CodingKey {
        case taskID, state, parkedCount, upcomingSteps, parkNote, parked
    }
}

extension LockScreenSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        state = try c.decodeIfPresent(ActiveTaskAttributes.ContentState.self, forKey: .state)
        parkedCount = try c.decodeIfPresent(Int.self, forKey: .parkedCount) ?? 0
        upcomingSteps = try c.decodeIfPresent([Step].self, forKey: .upcomingSteps) ?? []
        parkNote = try c.decodeIfPresent(String.self, forKey: .parkNote)
        parked = try c.decodeIfPresent([Parked].self, forKey: .parked) ?? []
    }
}

/// Park reasons as the widget shows them: always an SF Symbol with a label.
enum ParkReasonStyle {
    static func symbol(_ raw: String?) -> String {
        switch raw {
        case "waiting": "hourglass"
        case "need_info": "questionmark.circle"
        default: "clock.arrow.circlepath"
        }
    }

    static func title(_ raw: String?) -> String {
        switch raw {
        case "waiting": "Yanıt bekliyorum"
        case "need_info": "Bilgi lazım"
        default: "Sonra devam"
        }
    }
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

/// Deep links the widgets open: `pickup://now`, `pickup://park`, `pickup://capture`
/// and `pickup://resume/<task id>`.
enum PickUpLink {
    static let now = URL(string: "pickup://now")!
    static let park = URL(string: "pickup://park")!
    static let capture = URL(string: "pickup://capture")!

    static func resume(_ taskID: String) -> URL {
        URL(string: "pickup://resume/\(taskID)") ?? now
    }
}
