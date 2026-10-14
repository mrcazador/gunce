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

/// "Adımı bitir" and the step rows on the widgets. Runs in the app like `CompleteTaskIntent`.
struct CompleteStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Adımı bitir"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Görev")
    var taskID: String

    @Parameter(title: "Adım")
    var stepID: String

    init() {}

    init(taskID: String, stepID: String) {
        self.taskID = taskID
        self.stepID = stepID
    }

    func perform() async throws -> some IntentResult {
        await IntentBridge.completeStep(taskID: taskID, stepID: stepID)
        return .result()
    }
}
