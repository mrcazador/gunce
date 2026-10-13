import ActivityKit
import Foundation
import WidgetKit

/// Keeps the Live Activity and the widget in step with the active task.
@MainActor
enum LockScreen {
    static func update(_ snapshot: LockScreenSnapshot) async {
        if snapshot != SharedSnapshot.load() {
            SharedSnapshot.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }

        var kept = false
        for activity in Activity<ActiveTaskAttributes>.activities {
            if !kept, let state = snapshot.state, activity.attributes.taskID == snapshot.taskID {
                kept = true
                if activity.content.state != state {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard !kept, let id = snapshot.taskID, let state = snapshot.state,
              ActivityAuthorizationInfo().areActivitiesEnabled
        else { return }
        // Starting needs the app in the foreground; a background change waits for the next one.
        _ = try? Activity<ActiveTaskAttributes>.request(
            attributes: ActiveTaskAttributes(taskID: id),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }
}

/// Runs Live Activity intents (see `Shared/TaskIntents.swift`) in the app.
enum IntentBridge {
    @MainActor
    static func complete(taskID: String) async {
        if let store = AppStore.current, store.isSignedIn, let task = store.tasks[taskID] {
            await store.complete(task, source: "widget")
            await store.updateLockScreen()
            return
        }
        // The app was launched in the background just for this intent: call the API directly.
        guard let api = APIClient.fromBundle(), let token = Keychain.readToken() else { return }
        api.token = token
        try? await api.send("POST", "v1/tasks/\(taskID)/complete", body: ["source": "widget"])
        var snapshot = SharedSnapshot.load()
        if snapshot.taskID == taskID {
            snapshot.taskID = nil
            snapshot.state = nil
        }
        await LockScreen.update(snapshot)
    }
}
