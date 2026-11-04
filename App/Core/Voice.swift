import Foundation

/// Opens the voice note sheet. With a task, what is said is about that task first: its steps,
/// notes, dates and break.
struct VoiceRequest: Identifiable {
    let id = UUID()
    var taskID: String? = nil
    /// Recorded from the task's "Kaldığın yer" note: what is said rewrites that note.
    var noteOnly = false
}

/// The changes Claude read in a voice note (see `POST /v1/voice` in docs/API.md). The Worker
/// has already dropped anything that points outside the user's own open tasks.
struct VoicePlan: Decodable {
    struct Action: Decodable {
        let kind: String
        /// One of the user's open tasks or steps.
        let taskId: String?
        /// The `ref` of a task created earlier in the same plan.
        let taskRef: String?
        let ref: String?
        let title: String?
        let steps: [String]
        let note: String?
        let reason: ParkReason?
        let areaId: String?
        let priority: Int?
        let dueAt: Date?
        let remindAt: Date?
    }

    let summary: String
    let actions: [Action]

    /// Demo runs (screenshots) have no server: the note simply becomes a task.
    static func demo(_ transcript: String) -> VoicePlan {
        VoicePlan(
            summary: "“\(transcript)” gelen kutusuna eklendi.",
            actions: [Action(kind: "create_task", taskId: nil, taskRef: nil, ref: "new1", title: transcript, steps: [],
                             note: nil, reason: nil, areaId: nil, priority: nil, dueAt: nil, remindAt: nil)]
        )
    }
}

/// What a voice note changed, so "Geri al" can take it back. Notes written to İz stay.
struct VoiceUndo: Identifiable {
    let id = UUID()
    let summary: String
    var created: [String] = []
    /// Tasks as they were before the note changed their fields.
    var before: [String: TaskItem] = [:]
    var completed: [String] = []
    /// The task that was in hand and got a break.
    var parked: String?

    var isEmpty: Bool { created.isEmpty && before.isEmpty && completed.isEmpty && parked == nil }
}

extension AppStore {
    /// Applies a voice note's plan through the ordinary actions, so each change is optimistic,
    /// queued offline and checked by the server like any other. Afterwards "Geri al" is offered.
    func apply(_ plan: VoicePlan) async {
        var undo = VoiceUndo(summary: plan.summary)
        var refs: [String: String] = [:]
        if plan.actions.contains(where: { $0.remindAt != nil }) { _ = await Reminders.requestPermission() }

        func target(_ action: VoicePlan.Action) -> TaskItem? {
            guard let id = action.taskId ?? action.taskRef.flatMap({ refs[$0] }) else { return nil }
            return tasks[id]
        }
        func remember(_ task: TaskItem) {
            if undo.before[task.id] == nil, !undo.created.contains(task.id) { undo.before[task.id] = task }
        }

        for action in plan.actions {
            switch action.kind {
            case "create_task":
                guard let title = action.title,
                      let id = await capture(title, areaId: action.areaId, dueAt: action.dueAt)
                else { continue }
                undo.created.append(id)
                if let ref = action.ref { refs[ref] = id }
                if action.priority != nil || action.remindAt != nil, let task = tasks[id] {
                    await edit(task) {
                        if let size = action.priority { $0.priority = size }
                        if let remind = action.remindAt { $0.remindAt = remind }
                    }
                }
                for step in action.steps {
                    if let stepID = await capture(step, areaId: action.areaId, parentId: id) { undo.created.append(stepID) }
                }
            case "add_steps":
                guard let task = target(action) else { continue }
                for step in action.steps {
                    if let stepID = await capture(step, areaId: task.areaId, parentId: task.id) { undo.created.append(stepID) }
                }
            case "note":
                guard let task = target(action), let note = action.note else { continue }
                await addNote(note, to: task)
            case "set_note":
                guard let task = target(action), let note = action.note else { continue }
                remember(task)
                await edit(task) { $0.parkNote = note }
            case "park":
                guard let task = target(action), task.status == .active, let note = action.note else { continue }
                // No room for another break: keep what was said as a note instead.
                if parkedTasks.count >= Self.pausedLimit {
                    await addNote(note, to: task)
                    continue
                }
                await park(task, note: note, reason: action.reason ?? .later, remindAt: action.remindAt)
                undo.parked = task.id
            case "schedule":
                guard let task = target(action), action.dueAt != nil || action.remindAt != nil else { continue }
                remember(task)
                await edit(task) {
                    if let due = action.dueAt { $0.dueAt = due }
                    if let remind = action.remindAt { $0.remindAt = remind }
                }
            case "complete":
                guard let task = target(action), task.status.isOpen else { continue }
                await complete(task)
                undo.completed.append(task.id)
            case "update":
                guard let task = target(action) else { continue }
                remember(task)
                await edit(task) {
                    if let title = action.title { $0.title = title }
                    if let area = action.areaId { $0.areaId = area }
                    if let size = action.priority { $0.priority = size }
                }
            default:
                continue
            }
        }
        // One banner for the whole note, not a separate "bitti" one.
        if !undo.completed.isEmpty { lastCompletion = nil }
        lastVoice = undo
    }

    /// Takes the last voice note back: new tasks go, finished ones reopen, edited fields return
    /// and a task that got a break is back in hand.
    func undoVoice() async {
        guard let undo = lastVoice else { return }
        lastVoice = nil
        for id in undo.created.reversed() {
            if let task = tasks[id], task.deletedAt == nil { await delete(task) }
        }
        for id in undo.completed {
            if let task = tasks[id] { await reopen(task) }
        }
        for (id, before) in undo.before {
            guard let task = tasks[id] else { continue }
            await edit(task) {
                $0.title = before.title
                $0.areaId = before.areaId
                $0.priority = before.priority
                $0.dueAt = before.dueAt
                $0.remindAt = before.remindAt
                $0.parkNote = before.parkNote
            }
        }
        if let id = undo.parked, activeTask == nil, let task = tasks[id] {
            await start(task, previousNote: nil, previousReason: nil)
        }
    }
}
