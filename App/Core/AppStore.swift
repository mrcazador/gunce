import Foundation
import Observation

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

    func capture(_ title: String, areaId: String? = nil, parentId: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var body: [String: Any] = ["id": UUID().uuidString.lowercased(), "title": trimmed]
        if let areaId { body["area_id"] = areaId }
        if let parentId { body["parent_id"] = parentId }
        #if DEBUG
        if isDemo { return demoCapture(trimmed, areaId: areaId, parentId: parentId) }
        #endif
        await mutate("POST", "v1/tasks", body: body)
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
        #if DEBUG
        if isDemo { return demoStart(task, previousNote: previousNote, previousReason: previousReason) }
        #endif
        guard let api else { return }
        var body: [String: Any] = ["source": "app"]
        if let previousNote { body["previous_note"] = JSONCoding.value(previousNote) }
        if let previousReason { body["previous_reason"] = previousReason.rawValue }
        do {
            let result = try await api.request("POST", "v1/tasks/\(task.id)/start", body: body, as: StartResponse.self)
            upsert(result.task)
            if let parked = result.parked { upsert(parked) }
            await refresh()
        } catch {
            report(error)
        }
    }

    func park(_ task: TaskItem, note: String?, reason: ParkReason) async {
        var body: [String: Any] = ["reason": reason.rawValue, "source": "app"]
        if let note { body["note"] = JSONCoding.value(note) }
        #if DEBUG
        if isDemo { return demoPark(task, note: note, reason: reason) }
        #endif
        await mutate("POST", "v1/tasks/\(task.id)/park", body: body)
    }

    func complete(_ task: TaskItem) async {
        #if DEBUG
        if isDemo { return demoSet(task.id) { $0.status = .done; $0.completedAt = .now } }
        #endif
        await mutate("POST", "v1/tasks/\(task.id)/complete", body: ["source": "app"])
    }

    func reopen(_ task: TaskItem) async {
        await mutate("POST", "v1/tasks/\(task.id)/reopen", body: ["source": "app"])
    }

    func archive(_ task: TaskItem) async {
        await mutate("POST", "v1/tasks/\(task.id)/archive", body: ["source": "app"])
    }

    func update(_ task: TaskItem, fields: [String: Any]) async {
        guard !fields.isEmpty else { return }
        await mutate("PATCH", "v1/tasks/\(task.id)", body: fields)
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
        guard let api else { return }
        do {
            try await api.send("DELETE", "v1/tasks/\(task.id)")
            tasks[task.id] = nil
            for sub in subtasks(of: task.id) { tasks[sub.id] = nil }
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Sends a request that returns `{ task }`, applies it, then syncs history.
    private func mutate(_ method: String, _ path: String, body: [String: Any]) async {
        guard let api else { return }
        do {
            let result = try await api.request(method, path, body: body, as: TaskEnvelope.self)
            upsert(result.task)
            await refresh()
        } catch {
            report(error)
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

    private func demoSet(_ id: String, _ change: (inout TaskItem) -> Void) {
        guard var task = tasks[id] else { return }
        change(&task)
        task.updatedAt = .now
        tasks[id] = task
    }

    private func demoCapture(_ title: String, areaId: String?, parentId: String?) {
        let id = UUID().uuidString.lowercased()
        tasks[id] = TaskItem(
            id: id, areaId: areaId, parentId: parentId, title: title, details: nil, status: .inbox,
            nextStep: nil, parkNote: nil, parkReason: nil, parkedAt: nil, startedAt: nil, dueAt: nil,
            remindAt: nil, calendarEventId: nil, sort: 0, createdVia: "app", createdAt: .now,
            updatedAt: .now, completedAt: nil, deletedAt: nil
        )
    }

    private func demoPark(_ task: TaskItem, note: String?, reason: ParkReason) {
        demoSet(task.id) {
            $0.status = .parked
            $0.parkNote = note?.isEmpty == false ? note : $0.parkNote
            $0.parkReason = reason
            $0.parkedAt = .now
        }
    }

    private func demoStart(_ task: TaskItem, previousNote: String?, previousReason: ParkReason?) {
        if let current = activeTask, current.id != task.id {
            demoPark(current, note: previousNote, reason: previousReason ?? .later)
        }
        demoSet(task.id) {
            $0.status = .active
            $0.startedAt = .now
        }
    }
    #endif
}
