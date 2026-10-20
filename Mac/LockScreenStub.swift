import Foundation

/// The Mac has no Lock Screen widget or Live Activity; the store's calls to it do nothing.
@MainActor
enum LockScreen {
    static let liveActivityKey = "pickup.liveActivity"

    static func update(_ snapshot: LockScreenSnapshot) async {}
}
