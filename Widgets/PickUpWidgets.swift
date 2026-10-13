import SwiftUI
import WidgetKit

@main
struct PickUpWidgets: WidgetBundle {
    var body: some Widget {
        ActiveTaskWidget()
        ActiveTaskLiveActivity()
    }
}

/// The widget target never runs Live Activity intents (the app does), so this does nothing.
enum IntentBridge {
    static func complete(taskID: String) async {}
    static func completeStep(taskID: String, stepID: String) async {}
}
