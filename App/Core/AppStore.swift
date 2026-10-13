import Foundation
import Observation
import SwiftUI

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

    let isConfigured: Bool
    /// Debug builds launched with `-demo` run on invented data with no server (UI tests, screenshots).
    let isDemo: Bool

    private let api: APIClient?
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

    func capture(_ title: String, areaId: String? = nil, parentId: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        var body: [String: Any] = ["id": id, "title": trimmed]
        if let areaId { body["area_id"] = areaId }
        if let parentId { body["parent_id"] = parentId }
        captures += 1
        await optimistic {
            localInsert(id: id, title: trimmed, areaId: areaId, parentId: parentId)
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

    func park(_ task: TaskItem, note: String?, reason: ParkReason) async {
        var body: [String: Any] = ["reason": reason.rawValue, "source": "app"]
        if let note { body["note"] = JSONCoding.value(note) }
        parks += 1
        await optimistic {
            localPark(task.id, note: note, reason: reason)
        } send: { api in
            try await self.sendTask("POST", "v1/tasks/\(task.id)/park", body: body, api: api)
        }
    }

    func complete(_ task: TaskItem) async {
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
            try await self.sendTask("POST", "v1/tasks/\(task.id)/complete", body: ["source": "app"], api: api)
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

    func update(_ task: TaskItem, fields: [String: Any]) async {
        guard !fields.isEmpty, !isDemo else { return }
        await optimistic {} send: { api in
            try await self.sendTask("PATCH", "v1/tasks/\(task.id)", body: fields, api: api)
        }
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
        await optimistic {
            for sub in subtasks(of: task.id) { tasks[sub.id] = nil }
            tasks[task.id] = nil
        } send: { api in
            try await api.send("DELETE", "v1/tasks/\(task.id)")
        }
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
                 next: "Gelir grafiğini güncelle", started: ago(42), due: today),
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
