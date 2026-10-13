import Foundation
import Observation
import SwiftUI

/// A request to open quick capture, optionally for a given day.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var dueAt: Date? = nil
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

    var parkRequest: ParkRequest? = nil
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
            .sorted { ($0.parkedAt ?? $0.updatedAt) > ($1.parkedAt ?? $1.updatedAt) }
    }

    var inboxTasks: [TaskItem] {
        tasks.values
            .filter { $0.status == .inbox && $0.parentId == nil }
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
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        Task { await LockScreen.update(.empty) }
    }

    // MARK: - Sync

    func refresh() async {
        guard let api, isSignedIn, !isSyncing else { return }
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
            saveSnapshot()
            tasksChanged()
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
        let id = UUID().uuidString.lowercased()
        // New steps go to the end of their task's list.
        let sort = parentId.map { (subtasks(of: $0).map(\.sort).max() ?? -1) + 1 } ?? 0
        var body: [String: Any] = ["id": id, "title": trimmed, "sort": sort]
        if let areaId { body["area_id"] = areaId }
        if let parentId { body["parent_id"] = parentId }
        if let dueAt { body["due_at"] = JSONCoding.formatDate(dueAt) }
        captures += 1
        await optimistic {
            localInsert(id: id, title: trimmed, areaId: areaId, parentId: parentId)
            localSet(id) {
                $0.sort = sort
                $0.dueAt = dueAt
            }
        } send: { api in
            let result = try await api.request("POST", "v1/tasks", body: body, as: TaskEnvelope.self)
            self.upsert(result.task)
        }
    }

    /// Starts a task. If another task is active, asks for a "nerede kaldın?" note first.
    func requestStart(_ task: TaskItem) {
        if let current = activeTask, current.id != task.id {
            parkRequest = ParkRequest(task: current, next: task)
        } else {
            Task { await start(task, previousNote: nil, previousReason: nil) }
        }
    }

    func requestPark(_ task: TaskItem) {
        parkRequest = ParkRequest(task: task, next: nil)
    }

    func start(_ task: TaskItem, previousNote: String?, previousReason: ParkReason?) async {
        var body: [String: Any] = ["source": "app"]
        if let previousNote { body["previous_note"] = JSONCoding.value(previousNote) }
        if let previousReason { body["previous_reason"] = previousReason.rawValue }
        starts += 1
        await optimistic {
            localStart(task, previousNote: previousNote, previousReason: previousReason)
        } send: { api in
            let result = try await api.request("POST", "v1/tasks/\(task.id)/start", body: body, as: StartResponse.self)
            self.upsert(result.task)
            if let parked = result.parked { self.upsert(parked) }
        }
    }

    func park(_ task: TaskItem, note: String?, reason: ParkReason, remindAt: Date? = nil) async {
        var body: [String: Any] = ["reason": reason.rawValue, "source": "app"]
        if let note { body["note"] = JSONCoding.value(note) }
        if let remindAt { body["remind_at"] = JSONCoding.formatDate(remindAt) }
        parks += 1
        await optimistic {
            localPark(task.id, note: note, reason: reason)
            if let remindAt { localSet(task.id) { $0.remindAt = remindAt } }
        } send: { api in
            try await self.sendTask("POST", "v1/tasks/\(task.id)/park", body: body, api: api)
        }
    }

    func complete(_ task: TaskItem, source: String = "app") async {
        completions += 1
        await optimistic {
            for id in [task.id] + subtasks(of: task.id).map(\.id) {
                localSet(id) {
                    guard $0.status.isOpen else { return }
                    $0.status = .done
                    $0.completedAt = .now
                }
            }
        } send: { api in
            try await self.sendTask("POST", "v1/tasks/\(task.id)/complete", body: ["source": source], api: api)
        }
    }

    func reopen(_ task: TaskItem) async {
        await optimistic {
            localSet(task.id) {
                $0.status = .inbox
                $0.completedAt = nil
            }
        } send: { api in
            try await self.sendTask("POST", "v1/tasks/\(task.id)/reopen", body: ["source": "app"], api: api)
        }
    }

    func archive(_ task: TaskItem) async {
        await optimistic {
            localSet(task.id) { $0.status = .archived }
        } send: { api in
            try await self.sendTask("POST", "v1/tasks/\(task.id)/archive", body: ["source": "app"], api: api)
        }
    }

    /// Edits content fields: applied locally at once, then sent as a PATCH of what changed.
    func edit(_ task: TaskItem, _ change: (inout TaskItem) -> Void) async {
        guard let current = tasks[task.id] else { return }
        var edited = current
        change(&edited)
        let fields = Self.changedFields(from: current, to: edited)
        guard !fields.isEmpty else { return }
        await optimistic {
            localSet(task.id) { $0 = edited }
        } send: { api in
            try await self.sendTask("PATCH", "v1/tasks/\(task.id)", body: fields, api: api)
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
        if a.calendarEventId != b.calendarEventId { fields["calendar_event_id"] = JSONCoding.value(b.calendarEventId) }
        return fields
    }

    func addNote(_ note: String, to task: TaskItem) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, !trimmed.isEmpty else { return }
        do {
            try await api.send("POST", "v1/tasks/\(task.id)/notes", body: ["note": trimmed, "source": "app"])
            await loadHistory(of: task.id)
        } catch {
            report(error)
        }
    }

    func delete(_ task: TaskItem) async {
        if !isDemo {
            for item in [task] + subtasks(of: task.id) {
                CalendarSync.shared.removeEvent(item.calendarEventId)
            }
        }
        await optimistic {
            for sub in subtasks(of: task.id) { tasks[sub.id] = nil }
            tasks[task.id] = nil
        } send: { api in
            try await api.send("DELETE", "v1/tasks/\(task.id)")
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
        await Reminders.reschedule(reminderItems(all))
        if calendarSyncEnabled, CalendarSync.shared.isAuthorized {
            for (task, change) in CalendarSync.shared.sync(all) {
                await edit(task, change)
            }
        }
    }

    /// Writes the active task to the Live Activity and the widget.
    func updateLockScreen() async {
        guard !isDemo, isSignedIn else { return }
        await LockScreen.update(lockScreenSnapshot())
    }

    func lockScreenSnapshot() -> LockScreenSnapshot {
        // parkedTasks is newest first.
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
    func handleNotification(action: String, taskID: String) async {
        guard let task = tasks[taskID] else { return }
        switch action {
        case Reminders.resumeAction:
            requestStart(task)
        case Reminders.snoozeAction:
            await edit(task) { $0.remindAt = Date.now.addingTimeInterval(3600) }
        case Reminders.doneAction:
            await complete(task)
        default:
            openTaskID = taskID
        }
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

    /// Applies `change` at once with animation, then sends the request. On failure the task
    /// list is restored and the error shown. Demo runs stop after the local change.
    private func optimistic(_ change: () -> Void, send: (APIClient) async throws -> Void) async {
        let before = tasks
        withAnimation(.snappy) { change() }
        tasksChanged()
        guard !isDemo, let api else { return }
        do {
            try await send(api)
            await refresh()
        } catch {
            withAnimation(.snappy) { tasks = before }
            report(error)
        }
    }

    /// Sends a request that returns `{ task }` and applies the server's copy.
    private func sendTask(_ method: String, _ path: String, body: [String: Any], api: APIClient) async throws {
        let result = try await api.request(method, path, body: body, as: TaskEnvelope.self)
        upsert(result.task)
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
            if !trimmed.isEmpty { $0.parkNote = trimmed }
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
        }
    }

    private func report(_ error: Error) {
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
    }

    private func saveSnapshot() {
        let snapshot = Snapshot(
            areas: areas,
            tasks: Array(tasks.values),
            events: Array(events.values),
            cursor: syncCursor
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
        ]
        tasks = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        tasks["s2"]?.sort = 1
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
    }

    #endif
}
