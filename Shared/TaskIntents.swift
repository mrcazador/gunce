import AppIntents

/// "Bitti" on the Live Activity. Live Activity intents run in the app's process,
/// so `IntentBridge` here is the app's implementation (the widget has a stub).
struct CompleteTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Görevi bitir"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Görev")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        await IntentBridge.complete(taskID: taskID)
        return .result()
    }
}
