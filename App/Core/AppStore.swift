import Foundation
import Observation
import SwiftUI

/// A request to open quick capture, optionally for a given day.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var dueAt: Date? = nil
}

/// The last "Bitti", offered back for a few seconds.
struct CompletionUndo: Identifiable {
    let id = UUID()
    let task: TaskItem
    let stepIDs: [String]
    let wasActive: Bool
}

/// The paused-work limit was hit; once a slot is free, `then` goes ahead.
struct LimitRequest: Identifiable {
    enum Then {
        case park(TaskItem)
        case start(TaskItem)
    }

    let id = UUID()
    let then: Then
}

/// A request to park a task, optionally starting another one right after (a switch).
struct ParkRequest: Identifiable {
    let id = UUID()
    let task: TaskItem
    let next: TaskItem?
}

/// App state: session, cached data from the Worker, and every action the UI can take.
/// The server is the source of truth; this keeps a local snapshot for fast launches.
@MainActor
@Observable
final class AppStore {
    private(set) var isSignedIn: Bool
    private(set) var areas: [Area] = []
    private(set) var tasks: [String: TaskItem] = [:]
    private(set) var events: [String: TaskEvent] = [:]
    private(set) var isSyncing = false
    /// The last automatic sync could not reach the server (no internet, Wi-Fi still waking up).
    private(set) var isOffline = false

    var parkRequest: ParkRequest? = nil
    /// Shown instead of a break when the paused-work limit is reached.
    var limitRequest: LimitRequest? = nil
    /// The daily two-minute tidy-up of paused work ("Toparla").
    var reviewRequested = false
    var errorMessage: String? = nil
    /// The quick-capture sheet, optionally with a date already set (from the calendar).
    var captureRequest: CaptureRequest? = nil
    /// A task to open, e.g. from a notification tap.
    var openTaskID: String? = nil
    /// Whether tasks with a date are written to the PickUp calendar in Apple Calendar.
    var calendarSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "pickup.calendarSync") {
        didSet {
            UserDefaults.standard.set(calendarSyncEnabled, forKey: "pickup.calendarSync")
            tasksChanged()
        }
    }
    /// The active task as a Live Activity on the Lock Screen (and so in the Dynamic Island).
    var liveActivityEnabled: Bool = UserDefaults.standard.bool(forKey: LockScreen.liveActivityKey) {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: LockScreen.liveActivityKey)
            Task { await updateLockScreen() }
        }
    }

    let isConfigured: Bool
    /// Debug builds launched with `-demo` run on invented data with no server (UI tests, screenshots).
    let isDemo: Bool

    private let api: APIClient?
    /// The live store, for Live Activity intents that run while the app is open.
    static weak var current: AppStore?
    @ObservationIgnored private var syncCursor: String? = nil

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") || args.contains("-demo-signed-out") {
            api = nil
            isConfigured = true
            isDemo = true
            isSignedIn = args.contains("-demo")
            if isSignedIn { loadDemoData() }
            return
        }
        #endif
        isDemo = false
        let api = APIClient.fromBundle()
        self.api = api
        isConfigured = api != nil
        let token = Keychain.readToken()
        api?.token = token
        isSignedIn = token != nil
        if token != nil { loadSnapshot() }
        CalendarSync.shared.onExternalChange = { [weak self] in self?.tasksChanged() }
        Self.current = self
    }

    // MARK: - Queries

    var activeTask: TaskItem? {
        tasks.values.first { $0.status == .active && $0.parentId == nil }
    }

    var parkedTasks: [TaskItem] {
        tasks.values
            .filter { $0.status == .parked && $0.parentId == nil }
            // The site waiting longest for its next step comes first, so postponed work does
            // not sink below what was parked a minute ago.
            .sorted { lastProgress(of: $0) < lastProgress(of: $1) }
    }

    var inboxTasks: [TaskItem] {
        tasks.values
            // Repeating tasks live in Bugün's "Günlük işler", not in the inbox.
            .filter { $0.status == .inbox && $0.parentId == nil && $0.repeats == nil }
            .sorted(by: Self.listOrder)
    }

    var sortedAreas: [Area] {
        areas.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    }

    func area(_ id: String?) -> Area? {
        guard let id else { return nil }
        return areas.first { $0.id == id }
    }

    func topLevelTasks(area areaId: String?, open: Bool) -> [TaskItem] {
        tasks.values
            .filter { $0.parentId == nil && $0.areaId == areaId && $0.status.isOpen == open && $0.status != .archived }
            .sorted(by: open ? Self.listOrder : Self.recentFirst)
    }

    func subtasks(of id: String) -> [TaskItem] {
        tasks.values
            .filter { $0.parentId == id }
            .sorted { ($0.sort, $0.createdAt) < ($1.sort, $1.createdAt) }
    }

    /// Steps done and total, for the progress bar.
    func progress(of id: String) -> (done: Int, total: Int) {
        let steps = subtasks(of: id).filter { $0.status != .archived }
        return (steps.filter { $0.status == .done }.count, steps.count)
    }

    /// The first open step: what to do next when coming back to a task.
    func nextStep(of id: String) -> TaskItem? {
        subtasks(of: id).first { $0.status.isOpen }
    }

    func history(of id: String) -> [TaskEvent] {
        events.values
            .filter { $0.taskId == id }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    func search(_ query: String) -> [TaskItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return tasks.values
            .filter { task in
                [task.title, task.details, task.parkNote, task.nextStep]
                    .compactMap { $0 }
                    .contains { $0.localizedStandardContains(q) }
            }
            .sorted(by: Self.recentFirst)
    }

    nonisolated private static func listOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        func rank(_ s: TaskStatus) -> Int {
            switch s {
            case .active: 0
            case .parked: 1
            case .inbox: 2
            default: 3
            }
        }
        if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
        if a.sort != b.sort { return a.sort < b.sort }
        return a.updatedAt > b.updatedAt
    }

    nonisolated private static func recentFirst(_ a: TaskItem, _ b: TaskItem) -> Bool {
        a.updatedAt > b.updatedAt
    }

    // MARK: - Session

    func signIn(identityToken: String, nonce: String) async {
        guard let api else { return report(APIError(status: 0, code: "not_configured", message: nil)) }
        do {
            let auth = try await api.request(
                "POST", "v1/auth/apple",
                body: ["identity_token": identityToken, "nonce": nonce],
                as: AuthResponse.self
            )
            Keychain.saveToken(auth.token)
            api.token = auth.token
            isSignedIn = true
            await refresh()
        } catch {
            report(error)
        }
    }

    func signOut() async {
        try? await api?.send("POST", "v1/auth/logout")
        clearSession()
    }

    func deleteAccount() async {
        do {
            try await api?.send("DELETE", "v1/me")
            clearSession()
        } catch {
            report(error)
        }
    }

    private func clearSession() {
        Keychain.deleteToken()
        api?.token = nil
        isSignedIn = false
        areas = []
        tasks = [:]
        events = [:]
        syncCursor = nil
        outbox = []
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        Task { await LockScreen.update(.empty) }
    }

    // MARK: - Sync

    func refresh() async {
        guard let api, isSignedIn, !isSyncing else { return }
        // Changes made offline go out before the server's copy comes in.
        if !outbox.isEmpty {
            await flushOutbox()
            guard outbox.isEmpty else { return }
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var more = true
            while more {
                var query: [URLQueryItem] = []
                if let syncCursor { query.append(URLQueryItem(name: "since", value: syncCursor)) }
                let page = try await api.request("GET", "v1/sync", query: query, as: SyncResponse.self)
                merge(page)
                syncCursor = page.serverTime
                more = page.hasMore
            }
            isOffline = false
            saveSnapshot()
            tasksChanged()
        } catch let error as APIError where error.code == "offline" {
            // Sync runs on its own (every minute, on wake, after edits). A moment without a
            // connection is not worth an alert; the cached tasks stay and the next sync catches up.
            isOffline = true
        } catch {
            report(error)
        }
    }

    private func merge(_ page: SyncResponse) {
        for area in page.areas {
            areas.removeAll { $0.id == area.id }
            if area.deletedAt == nil { areas.append(area) }
        }
        for task in page.tasks { upsert(task) }
        for event in page.events { events[event.id] = event }
    }

    private func upsert(_ task: TaskItem) {
        if task.deletedAt == nil {
            tasks[task.id] = task
        } else {
            tasks[task.id] = nil
        }
    }

    func loadHistory(of id: String) async {
        guard let api else { return }
        if let page = try? await api.request("GET", "v1/tasks/\(id)/events", as: EventsEnvelope.self) {
            for event in page.events { events[event.id] = event }
        }
    }

    // MARK: - Actions
    //
    // State changes are optimistic: the screen updates at once (animated), the request goes out
    // after, and a failure rolls the change back and shows the error. The server stays the
    // source of truth through the sync that follows every change.

    func capture(_ title: String, areaId: String? = nil, parentId: String? = nil, dueAt: Date? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // No area picked: guess it from earlier tasks, so most captures need no choice.
        let area = areaId ?? (parentId == nil ? guessArea(for: trimmed) : nil)
        let id = UUID().uuidString.lowercased()
        // New steps go to the end of their task's list.
        let sort = parentId.map { (subtasks(of: $0).map(\.sort).max() ?? -1) + 1 } ?? 0
        var body: [String: Any] = ["id": id, "title": trimmed, "sort": sort]
        if let area { body["area_id"] = area }
        if let parentId { body["parent_id"] = parentId }
        if let dueAt { body["due_at"] = JSONCoding.formatDate(dueAt) }
        captures += 1
        await optimistic(PendingRequest("POST", "v1/tasks", body: body)) {
            localInsert(id: id, title: trimmed, areaId: area, parentId: parentId)
            localSet(id) {
                $0.sort = sort
                $0.dueAt = dueAt
            }
        }
    }

    /// Starts a task. If another task is active, asks for a "nerede kaldın?" note first.
    /// The area of earlier tasks that share the most words (four letters or more) with a new
    /// title, if any; nil when nothing matches, so a wrong guess is rare and easy to change.
    func guessArea(for title: String) -> String? {
        let locale = Locale(identifier: "tr")
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased(with: locale)
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count >= 4 })
        }
        let wanted = words(title)
        guard !wanted.isEmpty else { return nil }
        var votes: [String: Int] = [:]
        for task in tasks.values where task.parentId == nil && task.deletedAt == nil {
            guard let areaId = task.areaId, area(areaId) != nil else { continue }
            let shared = wanted.intersection(words(task.title)).count
            if shared > 0 { votes[areaId, default: 0] += shared }
        }
        return votes.max { $0.value < $1.value }?.key
    }

    /// At most this many tasks can be paused at once. A new break needs one of them finished
    /// or let go first: half-done work cannot pile up.
    static let pausedLimit = 5

    private var atPausedLimit: Bool { parkedTasks.count >= Self.pausedLimit }

    func requestStart(_ task: TaskItem) {
        if let current = activeTask, current.id != task.id {
            // Resuming a paused task frees its slot, so only a new one can hit the limit.
            if atPausedLimit, task.status != .parked {
                limitRequest = LimitRequest(then: .start(task))
                return
            }
            parkRequest = ParkRequest(task: current, next: task)
        } else {
            Task { await start(task, previousNote: nil, previousReason: nil) }
        }
    }

    func requestPark(_ task: TaskItem) {
        if atPausedLimit {
            limitRequest = LimitRequest(then: .park(task))
            return
        }
        parkRequest = ParkRequest(task: task, next: nil)
    }

    /// Picks up what was waiting for a free slot.
    func continueAfterLimit(_ request: LimitRequest) {
        limitRequest = nil
        switch request.then {
        case .park(let task):
            if let fresh = tasks[task.id], fresh.status == .active { requestPark(fresh) }
        case .start(let task):
            if let fresh = tasks[task.id], fresh.status.isOpen { requestStart(fresh) }
        }
    }

    /// Lets a paused task go: it leaves the list (archived, still in Görevler's history).
    func letGo(_ task: TaskItem) async {
        await archive(task)
    }

    func start(_ task: TaskItem, previousNote: String?, previousReason: ParkReason?) async {
        var body: [String: Any] = ["source": "app"]
        // Sent as typed: an empty note clears the old one instead of keeping it.
        if let previousNote { body["previous_note"] = previousNote.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let previousReason { body["previous_reason"] = previousReason.rawValue }
        starts += 1
        await optimistic(PendingRequest("POST", "v1/tasks/\(task.id)/start", body: body)) {
            localStart(task, previousNote: previousNote, previousReason: previousReason)
        }
    }

    func park(_ task: TaskItem, note: String?, reason: ParkReason, remindAt: Date? = nil) async {
        var body: [String: Any] = ["reason": reason.rawValue, "source": "app"]
        if let note { body["note"] = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let remindAt { body["remind_at"] = JSONCoding.formatDate(remindAt) }
        parks += 1
        await optimistic(PendingRequest("POST", "v1/tasks/\(task.id)/park", body: body)) {
            localPark(task.id, note: note, reason: reason)
            if let remindAt { localSet(task.id) { $0.remindAt = remindAt } }
        }
    }

    func complete(_ task: TaskItem, source: String = "app") async {
        completions += 1
        // A finished task can be taken back for a few seconds ("Geri al"). A repeating task
        // only closes today's round, so there is nothing to take back.
        if task.parentId == nil, task.status.isOpen, task.repeats == nil {
            lastCompletion = CompletionUndo(
                task: task,
                stepIDs: subtasks(of: task.id).filter { $0.status.isOpen }.map(\.id),
                wasActive: task.status == .active
            )
        }
        await optimistic(PendingRequest("POST", "v1/tasks/\(task.id)/complete", body: ["source": source])) {
            if task.repeats != nil {
                // This round is done; the task comes back in the next one.
                localSet(task.id) {
                    if $0.status == .active || $0.status == .parked { $0.status = .inbox }
                    $0.completedAt = .now
                    $0.remindAt = nil
                }
            } else {
                for id in [task.id] + subtasks(of: task.id).map(\.id) {
                    localSet(id) {
                        guard $0.status.isOpen else { return }
                        $0.status = .done
                        $0.completedAt = .now
                    }
                }
            }
        }
    }

    /// The last finished task, offered back for a few seconds.
    var lastCompletion: CompletionUndo?

    /// Takes the last "Bitti" back: the task and the steps it closed open again, and a
    /// task that was in hand goes back in hand.
    func undoCompletion() async {
        guard let undo = lastCompletion else { return }
        lastCompletion = nil
        if let task = tasks[undo.task.id] { await reopen(task) }
        for id in undo.stepIDs {
            if let step = tasks[id] { await reopen(step) }
        }
        if undo.wasActive, activeTask == nil, let task = tasks[undo.task.id] {
            await start(task, previousNote: nil, previousReason: nil)
        }
    }

    func reopen(_ task: TaskItem) async {
        await optimistic(PendingRequest("POST", "v1/tasks/\(task.id)/reopen", body: ["source": "app"])) {
            localSet(task.id) {
                $0.status = .inbox
                $0.completedAt = nil
            }
        }
    }

    func archive(_ task: TaskItem) async {
        await optimistic(PendingRequest("POST", "v1/tasks/\(task.id)/archive", body: ["source": "app"])) {
            localSet(task.id) { $0.status = .archived }
        }
    }

    /// Edits content fields: applied locally at once, then sent as a PATCH of what changed.
    func edit(_ task: TaskItem, _ change: (inout TaskItem) -> Void) async {
        guard let current = tasks[task.id] else { return }
        var edited = current
        change(&edited)
        let fields = Self.changedFields(from: current, to: edited)
        guard !fields.isEmpty else { return }
        await optimistic(PendingRequest("PATCH", "v1/tasks/\(task.id)", body: fields)) {
            localSet(task.id) { $0 = edited }
        }
    }

    /// Moves steps within a task. Rewrites the sort order of the ones whose position changed.
    func moveSubtasks(of parentId: String, from source: IndexSet, to destination: Int) async {
        var ordered = subtasks(of: parentId)
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, step) in ordered.enumerated() where step.sort != Double(index) {
            await edit(step) { $0.sort = Double(index) }
        }
    }

    nonisolated static func changedFields(from a: TaskItem, to b: TaskItem) -> [String: Any] {
        var fields: [String: Any] = [:]
        if a.title != b.title { fields["title"] = b.title }
        if a.details != b.details { fields["details"] = JSONCoding.value(b.details) }
        if a.nextStep != b.nextStep { fields["next_step"] = JSONCoding.value(b.nextStep) }
        if a.areaId != b.areaId { fields["area_id"] = (b.areaId as Any?) ?? NSNull() }
        if a.dueAt != b.dueAt { fields["due_at"] = JSONCoding.value(b.dueAt) }
        if a.remindAt != b.remindAt { fields["remind_at"] = JSONCoding.value(b.remindAt) }
        if a.sort != b.sort { fields["sort"] = b.sort }
        if a.priority != b.priority { fields["priority"] = b.priority ?? TaskSize.medium.rawValue }
        if a.recurrence != b.recurrence { fields["recurrence"] = (b.recurrence as Any?) ?? NSNull() }
        if a.calendarEventId != b.calendarEventId { fields["calendar_event_id"] = JSONCoding.value(b.calendarEventId) }
        return fields
    }

    func addNote(_ note: String, to task: TaskItem) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDemo, api != nil, !trimmed.isEmpty else { return }
        // Queued like every other change, so a note written offline is not lost.
        outbox.append(PendingRequest("POST", "v1/tasks/\(task.id)/notes", body: ["note": trimmed, "source": "app"]))
        saveSnapshot()
        await flushOutbox()
        await loadHistory(of: task.id)
    }

    func delete(_ task: TaskItem) async {
        if !isDemo {
            for item in [task] + subtasks(of: task.id) {
                CalendarSync.shared.removeEvent(item.calendarEventId)
            }
        }
        await optimistic(PendingRequest("DELETE", "v1/tasks/\(task.id)", body: nil)) {
            for sub in subtasks(of: task.id) { tasks[sub.id] = nil }
            tasks[task.id] = nil
        }
    }

    // MARK: - Reminders and calendar

    @ObservationIgnored private var sideEffects: Task<Void, Never>?

    /// Debounced: reschedules notifications and syncs the PickUp calendar after task changes.
    func tasksChanged() {
        guard !isDemo, isSignedIn else { return }
        sideEffects?.cancel()
        sideEffects = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.runSideEffects()
        }
    }

    private func runSideEffects() async {
        let all = Array(tasks.values)
        await updateLockScreen()
        let reminders = reminderItems(all)
        // Ask once, the first time there is something to remind about (a due date set in the
        // capture sheet never asked before, so those reminders were silently dropped).
        if !reminders.isEmpty, await Reminders.status() == .notDetermined {
            await Reminders.requestPermission()
        }
        await Reminders.reschedule(reminders)
        if calendarSyncEnabled, CalendarSync.shared.isAuthorized {
            let edits = CalendarSync.shared.sync(all)
            guard !edits.isEmpty else { return }
            // Each edit calls tasksChanged(), which cancels this side-effects task. Saving the
            // event ids from inside it cancelled its own requests ("Sunucuya ulaşılamadı") and
            // lost the ids, so they are saved in a task of their own.
            Task {
                for (task, change) in edits {
                    await self.edit(task, change)
                }
            }
        }
    }

    /// Writes the active task to the Live Activity and the widget.
    func updateLockScreen() async {
        guard !isDemo, isSignedIn else { return }
        await LockScreen.update(lockScreenSnapshot())
    }

    func lockScreenSnapshot() -> LockScreenSnapshot {
        // parkedTasks is the longest waiting first.
        let parkedList = parkedTasks
            .prefix(3)
            .map { item -> LockScreenSnapshot.Parked in
                let itemArea = self.area(item.areaId)
                return .init(
                    id: item.id,
                    title: item.title,
                    areaSymbol: itemArea?.symbol,
                    areaColor: itemArea?.color,
                    parkNote: item.parkNote,
                    parkReason: item.parkReason?.rawValue
                )
            }
        guard let task = activeTask else {
            return LockScreenSnapshot(taskID: nil, state: nil, parkedCount: parkedTasks.count, parked: parkedList)
        }
        let taskArea = self.area(task.areaId)
        let steps = progress(of: task.id)
        let state = ActiveTaskAttributes.ContentState(
            title: task.title,
            areaName: taskArea?.name,
            areaSymbol: taskArea?.symbol,
            areaColor: taskArea?.color,
            startedAt: task.startedAt ?? task.updatedAt,
            nextStep: nextStep(of: task.id)?.title ?? task.nextStep,
            stepsDone: steps.done,
            stepsTotal: steps.total
        )
        let upcoming = subtasks(of: task.id)
            .filter { $0.status.isOpen }
            .prefix(3)
            .map { LockScreenSnapshot.Step(id: $0.id, title: $0.title) }
        let note = task.parkNote.flatMap { $0.isEmpty ? nil : $0 }
        return LockScreenSnapshot(
            taskID: task.id,
            state: state,
            parkedCount: parkedTasks.count,
            upcomingSteps: Array(upcoming),
            parkNote: note,
            parked: parkedList
        )
    }

    private func reminderItems(_ all: [TaskItem]) -> [Reminders.Item] {
        var items: [Reminders.Item] = []
        for task in all where task.status.isOpen {
            let body: String? = {
                if task.status == .parked, let note = task.parkNote, !note.isEmpty {
                    return "Kaldığın yer: \(note)"
                }
                if let next = nextStep(of: task.id) { return "Sıradaki adım: \(next.title)" }
                return task.nextStep
            }()
            if let remind = task.remindAt {
                items.append(.init(taskID: task.id, title: task.title, body: body, date: remind, isDue: false))
            }
            if let due = task.dueAt, due != task.remindAt {
                items.append(.init(taskID: task.id, title: task.title, body: body, date: due, isDue: true))
            }
        }
        // One calm nudge a day, at 09:30: the two-minute tidy-up of paused work. Rebuilt after
        // every change, so it always counts today's paused tasks; tapping it opens "Toparla".
        let paused = parkedTasks
        if let oldest = paused.first {
            let calendar = Calendar.current
            var when = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: .now) ?? .now
            if when <= .now { when = calendar.date(byAdding: .day, value: 1, to: when) ?? when }
            let body = paused.count == 1
                ? "“\(oldest.title)” seni bekliyor. 2 dakikada toparla."
                : "\(paused.count) yarım iş seni bekliyor; en eskisi “\(oldest.title)”. 2 dakikada toparla."
            items.append(.init(taskID: Self.reviewNotificationID, title: "Günün toparlanması", body: body,
                               date: when, isDue: false, isNudge: true))
        }
        return items
    }

    /// Turns calendar sync on after asking for access. Returns whether it is on.
    @discardableResult
    func enableCalendarSync() async -> Bool {
        let granted = await CalendarSync.shared.requestAccess()
        calendarSyncEnabled = granted
        return granted
    }

    /// Handles a notification action (or a plain tap) for a task.
    /// The task id carried by the daily tidy-up notification.
    static let reviewNotificationID = "review"

    func handleNotification(action: String, taskID: String) async {
        if taskID == Self.reviewNotificationID {
            reviewRequested = true
            return
        }
        guard let task = tasks[taskID] else { return }
        switch action {
        case Reminders.resumeAction:
            // Already in hand: just open it instead of "starting" it again.
            if task.status == .active {
                openTaskID = taskID
            } else {
                requestStart(task)
            }
        case Reminders.snoozeAction:
            await edit(task) { $0.remindAt = Date.now.addingTimeInterval(3600) }
        case Reminders.doneAction:
            await complete(task)
        default:
            openTaskID = taskID
        }
    }

    // MARK: - Diagnostics

    /// The connection test in Settings.
    func checkConnection() async -> [ConnectionCheck] {
        guard let api else { return [ConnectionCheck(name: "Sunucu", ok: false, detail: "adres ayarlı değil")] }
        return await api.checkConnection()
    }

    // MARK: - Claude connector

    /// The MCP server address to paste into Claude.
    var claudeServerURL: String {
        if isDemo { return "https://pickup.example.com/mcp" }
        return api?.baseURL.appendingPathComponent("mcp").absoluteString ?? ""
    }

    func createClaudeLinkCode() async -> ClaudeLinkCode? {
        if isDemo {
            return ClaudeLinkCode(code: "K7QP-M3XA", expiresAt: .now.addingTimeInterval(600), mcpUrl: claudeServerURL)
        }
        guard let api else { return nil }
        do {
            return try await api.request("POST", "v1/mcp/link-code", body: [:], as: ClaudeLinkCode.self)
        } catch {
            report(error)
            return nil
        }
    }

    func claudeConnections() async -> [ClaudeConnection] {
        guard !isDemo, let api else { return [] }
        struct Envelope: Decodable { let connections: [ClaudeConnection] }
        return (try? await api.request("GET", "v1/mcp/connections", as: Envelope.self).connections) ?? []
    }

    func disconnectClaude() async {
        guard !isDemo, let api else { return }
        do {
            try await api.send("DELETE", "v1/mcp/connections")
        } catch {
            report(error)
        }
    }

    // MARK: - Profile

    func loadMemberSince() async -> Date? {
        guard let api else { return nil }
        struct Me: Decodable {
            struct User: Decodable { let createdAt: Date }
            let user: User
        }
        return try? await api.request("GET", "v1/me", as: Me.self).user.createdAt
    }

    /// Counters the views watch to play haptics for the matching action.
    private(set) var captures = 0
    private(set) var starts = 0
    private(set) var parks = 0
    private(set) var completions = 0

    /// Applies `change` at once with animation, then queues the request and sends the queue.
    /// Without a connection the change stays on screen and in the queue (saved on disk) until
    /// the next sync sends it: nothing you typed is lost. Only a change the server refuses is
    /// rolled back, with its error shown. Demo runs stop after the local change.
    private func optimistic(_ request: PendingRequest, _ change: () -> Void) async {
        let before = tasks
        withAnimation(.snappy) { change() }
        tasksChanged()
        guard !isDemo, api != nil else { return }
        outbox.append(request)
        saveSnapshot()
        let refused = await flushOutbox()
        if refused.contains(request.id) {
            withAnimation(.snappy) { tasks = before }
        }
        await refresh()
    }

    /// Changes waiting to reach the server, oldest first.
    private(set) var outbox: [PendingRequest] = []
    @ObservationIgnored private var isFlushing = false

    /// Sends queued changes in order and stops at the first connection problem, keeping the
    /// rest for later. Returns the requests the server refused (dropped, error shown).
    @discardableResult
    private func flushOutbox() async -> Set<UUID> {
        guard let api, !isDemo, !isFlushing else { return [] }
        isFlushing = true
        defer { isFlushing = false }
        var refused: Set<UUID> = []
        while let next = outbox.first {
            do {
                try await api.send(next.method, next.path, body: next.bodyObject)
            } catch let error as APIError where error.code == "offline" {
                isOffline = true
                saveSnapshot()
                return refused
            } catch let error as APIError where error.status == 409 && next.method == "POST" && next.path == "v1/tasks" {
                // Created on an earlier try whose answer never arrived: already done.
                _ = error
            } catch is CancellationError {
                return refused
            } catch {
                refused.insert(next.id)
                report(error)
                // Local state may now differ from the server's; fetch everything again.
                syncCursor = nil
            }
            outbox.removeFirst()
        }
        isOffline = false
        saveSnapshot()
        return refused
    }

    // MARK: - Local changes (mirror the Worker's rules)

    private func localSet(_ id: String, _ change: (inout TaskItem) -> Void) {
        guard var task = tasks[id] else { return }
        change(&task)
        task.updatedAt = .now
        tasks[id] = task
    }

    private func localInsert(id: String, title: String, areaId: String?, parentId: String?) {
        tasks[id] = TaskItem(
            id: id, areaId: areaId, parentId: parentId, title: title, details: nil, status: .inbox,
            nextStep: nil, parkNote: nil, parkReason: nil, parkedAt: nil, startedAt: nil, dueAt: nil,
            remindAt: nil, calendarEventId: nil, sort: 0, createdVia: "app", createdAt: .now,
            updatedAt: .now, completedAt: nil, deletedAt: nil
        )
    }

    private func localPark(_ id: String, note: String?, reason: ParkReason) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        localSet(id) {
            $0.status = .parked
            // The sheet starts with the old note, so what comes back is the note to keep.
            if note != nil { $0.parkNote = trimmed.isEmpty ? nil : trimmed }
            $0.parkReason = reason
            $0.parkedAt = .now
        }
    }

    /// One active task: starting a task parks the current one first.
    private func localStart(_ task: TaskItem, previousNote: String?, previousReason: ParkReason?) {
        if let current = activeTask, current.id != task.id {
            localPark(current.id, note: previousNote, reason: previousReason ?? .later)
        }
        localSet(task.id) {
            $0.status = .active
            $0.startedAt = .now
            // Back at the site: the reminder to come back has done its job.
            $0.remindAt = nil
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        if let apiError = error as? APIError, apiError.status == 401 {
            clearSession()
        }
        errorMessage = error.localizedDescription
    }

    // MARK: - Local snapshot

    private struct Snapshot: Codable {
        var areas: [Area]
        var tasks: [TaskItem]
        var events: [TaskEvent]
        var cursor: String?
        var outbox: [PendingRequest]?
    }

    private static var snapshotURL: URL {
        URL.applicationSupportDirectory.appending(path: "snapshot.json")
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONCoding.decoder.decode(Snapshot.self, from: data)
        else { return }
        areas = snapshot.areas
        tasks = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        events = Dictionary(snapshot.events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        syncCursor = snapshot.cursor
        outbox = snapshot.outbox ?? []
    }

    private func saveSnapshot() {
        let snapshot = Snapshot(
            areas: areas,
            tasks: Array(tasks.values),
            events: Array(events.values),
            cursor: syncCursor,
            outbox: outbox
        )
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        let url = Self.snapshotURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Demo data (debug builds only)

    #if DEBUG
    private func loadDemoData() {
        let now = Date.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let made = ago(60 * 24 * 3)
        let specs: [(String, String, String, String)] = [
            ("İş", "briefcase", "indigo", "a-is"),
            ("Hayat", "heart", "pink", "a-hayat"),
            ("Spor", "figure.run", "orange", "a-spor"),
            ("Yatırım", "chart.line.uptrend.xyaxis", "green", "a-yatirim"),
        ]
        areas = specs.enumerated().map { pair in
            let a = pair.element
            return Area(id: a.3, name: a.0, symbol: a.1, color: a.2, sort: pair.offset,
                        createdAt: made, updatedAt: made, deletedAt: nil)
        }
        func task(
            _ id: String, _ title: String, area: String?, status: TaskStatus, parent: String? = nil,
            next: String? = nil, note: String? = nil, reason: ParkReason? = nil,
            parked: Date? = nil, started: Date? = nil, due: Date? = nil
        ) -> TaskItem {
            TaskItem(
                id: id, areaId: area, parentId: parent, title: title, details: nil, status: status,
                nextStep: next, parkNote: note, parkReason: reason, parkedAt: parked, startedAt: started,
                dueAt: due, remindAt: nil, calendarEventId: nil, sort: 0, createdVia: "app",
                createdAt: made, updatedAt: parked ?? started ?? made,
                completedAt: status == .done ? ago(90) : nil, deletedAt: nil
            )
        }
        let today = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: now)
        let list = [
            task("t1", "Çeyrek sunumunu hazırla", area: "a-is", status: .active,
                 next: "Gelir grafiğini güncelle", note: "Grafikler hazır, metinler kaldı.", reason: .later,
                 started: ago(42), due: today),
            task("t2", "Kira sözleşmesini yenile", area: "a-hayat", status: .parked,
                 note: "Ev sahibinden yeni fiyatı bekliyorum, cuma tekrar ara.", reason: .waiting, parked: ago(30)),
            task("t3", "Fon dağılımını gözden geçir", area: "a-yatirim", status: .parked,
                 note: "Tablonun ikinci sekmesinde kaldım; tahvil oranı eksik.", reason: .needInfo, parked: ago(60 * 5)),
            task("t4", "Koşu planını haftaya göre ayarla", area: "a-spor", status: .inbox),
            task("t5", "Müşteri teklifine dön", area: "a-is", status: .inbox, due: ago(60 * 20)),
            task("t6", "Diş randevusu al", area: nil, status: .inbox),
            task("t7", "Banka ekstresini kontrol et", area: "a-yatirim", status: .done),
            task("s1", "Taslak slaytlar", area: "a-is", status: .done, parent: "t1"),
            task("s2", "Rakamları finansla doğrula", area: "a-is", status: .inbox, parent: "t1"),
            // The city: a site stalled for a week, finished work, one of them a landmark.
            task("t8", "Bisiklet bakımını yaptır", area: "a-spor", status: .parked,
                 note: "Fren balatası siparişte.", reason: .waiting, parked: ago(60 * 24 * 9)),
            task("t9", "Kütüphane üyeliğini yenile", area: "a-hayat", status: .parked,
                 note: "Formun ikinci sayfasında kaldım.", reason: .later, parked: ago(60 * 24 * 4)),
            task("t10", "Vergi beyannamesini gönder", area: "a-yatirim", status: .done),
            task("t11", "Takım toplantısı notlarını paylaş", area: "a-is", status: .done),
            task("t12", "Balkon saksılarını değiştir", area: "a-hayat", status: .done),
        ]
        tasks = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        tasks["s2"]?.sort = 1
        // Finished a while ago: moved in (iskan) in the city.
        for id in ["t11", "t12"] { tasks[id]?.completedAt = ago(60 * 24 * 5) }
        // Repeating tasks: not buildings, but street furniture in their districts.
        for (id, title, area, repeats) in [("r1", "Sabah yürüyüşü", "a-spor", "daily"),
                                          ("r2", "Gelen kutusunu sıfırla", "a-is", "weekdays"),
                                          ("r3", "Haftalık bütçeye bak", "a-yatirim", "weekly")] {
            var chore = task(id, title, area: area, status: .inbox)
            chore.recurrence = repeats
            tasks[id] = chore
        }
        tasks["r1"]?.completedAt = ago(60 * 3)
        for n in 0..<9 {
            let id = "c\(n)"
            let owner = n < 6 ? "r1" : n < 8 ? "r2" : "r3"
            events[id] = TaskEvent(id: id, taskId: owner, kind: "done", note: nil, reason: nil,
                                   durationSeconds: nil, source: "app", occurredAt: ago(Double(60 * 24 * (n + 1))))
        }
        // Sizes: the city mixes small, medium and grand buildings.
        for (id, size) in [("t1", 3), ("t3", 3), ("t10", 3), ("t4", 1), ("t7", 1), ("t9", 1), ("t11", 1)] {
            tasks[id]?.priority = size
        }
        let history: [(String, String, String?, ParkReason?, Int?, Date)] = [
            ("e1", "created", nil, nil, nil, made),
            ("e2", "started", nil, nil, nil, ago(60 * 26)),
            ("e3", "parked", "Grafikler hazır, metinler kaldı.", .later, 3_900, ago(60 * 25)),
            ("e4", "resumed", nil, nil, nil, ago(42)),
        ]
        for e in history {
            events[e.0] = TaskEvent(id: e.0, taskId: "t1", kind: e.1, note: e.2, reason: e.3,
                                    durationSeconds: e.4, source: "app", occurredAt: e.5)
        }
        // Parked for twelve days, then finished: a landmark in the city.
        for (id, kind, when) in [("e5", "parked", ago(60 * 24 * 14)), ("e6", "resumed", ago(60 * 24 * 2)), ("e7", "done", ago(60 * 24))] {
            events[id] = TaskEvent(id: id, taskId: "t10", kind: kind, note: nil, reason: nil,
                                   durationSeconds: nil, source: "app", occurredAt: when)
        }
    }

    #endif
}
