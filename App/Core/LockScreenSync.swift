import ActivityKit
import Foundation
import WidgetKit

/// Keeps the Live Activity and the widget in step with the active task.
@MainActor
enum LockScreen {
    /// Off by default: a Live Activity always shows in the Dynamic Island too, which can be
    /// distracting. The widgets keep working either way.
    static let liveActivityKey = "pickup.liveActivity"

    static var liveActivityEnabled: Bool {
        UserDefaults.standard.bool(forKey: liveActivityKey)
    }

    static func update(_ snapshot: LockScreenSnapshot) async {
        if snapshot != SharedSnapshot.load() {
            SharedSnapshot.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }

        var kept = false
        for activity in Activity<ActiveTaskAttributes>.activities {
            if liveActivityEnabled, !kept, let state = snapshot.state, activity.attributes.taskID == snapshot.taskID {
                kept = true
                if activity.content.state != state {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard liveActivityEnabled, !kept, let id = snapshot.taskID, let state = snapshot.state,
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
        // On a network error the snapshot stays as it is; the next refresh in the app fixes it.
        guard await sendComplete(taskID) else { return }
        var snapshot = SharedSnapshot.load()
        if snapshot.taskID == taskID {
            snapshot.taskID = nil
            snapshot.state = nil
            snapshot.upcomingSteps = []
            snapshot.parkNote = nil
        }
        await LockScreen.update(snapshot)
    }

    @MainActor
    static func completeStep(taskID: String, stepID: String) async {
        if let store = AppStore.current, store.isSignedIn, let step = store.tasks[stepID] {
            await store.complete(step, source: "widget")
            await store.updateLockScreen()
            return
        }
        guard await sendComplete(stepID) else { return }
        var snapshot = SharedSnapshot.load()
        if snapshot.taskID == taskID {
            snapshot.upcomingSteps.removeAll { $0.id == stepID }
            if var state = snapshot.state {
                state.stepsDone = min(state.stepsDone + 1, state.stepsTotal)
                state.nextStep = snapshot.upcomingSteps.first?.title
                snapshot.state = state
            }
        }
        await LockScreen.update(snapshot)
    }

    /// Completes a task or step with the stored session. Returns whether the server accepted it.
    private static func sendComplete(_ id: String) async -> Bool {
        guard let api = APIClient.fromBundle(), let token = Keychain.readToken() else { return false }
        api.token = token
        do {
            try await api.send("POST", "v1/tasks/\(id)/complete", body: ["source": "widget"])
            return true
        } catch {
            return false
        }
    }
}
