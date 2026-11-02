import Foundation

enum TaskStatus: String, Codable, CaseIterable {
    case inbox, active, parked, done, archived

    var isOpen: Bool { self == .inbox || self == .active || self == .parked }
}

enum ParkReason: String, Codable, CaseIterable, Identifiable {
    case waiting
    case needInfo = "need_info"
    case later

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waiting: "Yanıt bekliyorum"
        case .needInfo: "Bilgi lazım"
        case .later: "Sonra devam"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "hourglass"
        case .needInfo: "questionmark.circle"
        case .later: "clock.arrow.circlepath"
        }
    }
}

struct Area: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var symbol: String
    var color: String
    var sort: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

struct TaskItem: Codable, Identifiable, Hashable {
    let id: String
    var areaId: String?
    var parentId: String?
    var title: String
    var details: String?
    var status: TaskStatus
    var nextStep: String?
    var parkNote: String?
    var parkReason: ParkReason?
    var parkedAt: Date?
    var startedAt: Date?
    var dueAt: Date?
    var remindAt: Date?
    var calendarEventId: String?
    var sort: Double
    var createdVia: String
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var deletedAt: Date?
    /// Task size, 1…3 (see `TaskSize`). Missing in snapshots saved before sizes existed.
    var priority: Int? = nil
    /// "daily", "weekdays" or "weekly" for a repeating task (see `Recurrence`); nil for a
    /// one-off. Kept as text so an unknown value from a newer server never breaks decoding.
    var recurrence: String? = nil

    var size: TaskSize { TaskSize(rawValue: priority ?? 2) ?? .medium }

    var repeats: Recurrence? { recurrence.flatMap(Recurrence.init(rawValue:)) }

    /// A repeating task already done in the current round: today, or this week for weekly ones.
    func isDoneThisRound(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let repeats, let done = completedAt else { return false }
        switch repeats {
        case .daily, .weekdays: return calendar.isDate(done, inSameDayAs: now)
        case .weekly: return calendar.isDate(done, equalTo: now, toGranularity: .weekOfYear)
        }
    }

    /// A repeating task still to do in the current round (weekday tasks rest at the weekend).
    func isDueThisRound(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let repeats, status != .archived, deletedAt == nil else { return false }
        if repeats == .weekdays, calendar.isDateInWeekend(now) { return false }
        return !isDoneThisRound(now: now, calendar: calendar)
    }
}

/// How a repeating task comes back. Repeating tasks are not buildings: each time one is done
/// it adds a little street furniture to its area's district.
enum Recurrence: String, CaseIterable, Identifiable {
    case daily, weekdays, weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Her gün"
        case .weekdays: "Hafta içi"
        case .weekly: "Her hafta"
        }
    }
}

/// How big a task is: Ufak, Orta or Büyük. Decides how grand its building is in Şehir.
enum TaskSize: Int, CaseIterable, Identifiable {
    case small = 1, medium = 2, large = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: "Ufak"
        case .medium: "Orta"
        case .large: "Büyük"
        }
    }
}

struct TaskEvent: Codable, Identifiable, Hashable {
    let id: String
    let taskId: String
    let kind: String
    let note: String?
    let reason: ParkReason?
    let durationSeconds: Int?
    let source: String
    let occurredAt: Date

    var title: String {
        switch kind {
        case "created": "Eklendi"
        case "started": "Başlandı"
        case "parked": "Ara verildi"
        case "resumed": "Devam edildi"
        case "done": "Bitti"
        case "reopened": "Yeniden açıldı"
        case "note": "Not"
        default: kind
        }
    }

    var symbol: String {
        switch kind {
        case "created": "plus.circle"
        case "started": "play.circle"
        case "parked": "pause.circle"
        case "resumed": "arrow.uturn.forward.circle"
        case "done": "checkmark.circle"
        case "reopened": "arrow.counterclockwise.circle"
        case "note": "text.bubble"
        default: "circle"
        }
    }
}

/// A change made in the app that has not reached the server yet. Kept on disk with the
/// snapshot, so changes made offline are sent once the connection is back.
struct PendingRequest: Codable, Identifiable {
    let id: UUID
    let method: String
    let path: String
    /// JSON body, if any.
    let body: Data?
    let createdAt: Date

    init(_ method: String, _ path: String, body: [String: Any]?) {
        id = UUID()
        self.method = method
        self.path = path
        self.body = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        createdAt = .now
    }

    var bodyObject: [String: Any]? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

// MARK: - API envelopes

struct AuthResponse: Decodable {
    let token: String
    let userId: String
    let newUser: Bool
}

struct AreasEnvelope: Decodable { let areas: [Area] }
struct TaskEnvelope: Decodable { let task: TaskItem }
struct StartResponse: Decodable {
    let task: TaskItem
    let parked: TaskItem?
}
struct EventsEnvelope: Decodable { let events: [TaskEvent] }

struct SyncResponse: Decodable {
    let serverTime: String
    let hasMore: Bool
    let areas: [Area]
    let tasks: [TaskItem]
    let events: [TaskEvent]
}

struct APIErrorBody: Decodable {
    let error: String
    let message: String?
}

/// A pairing code for the Claude connector (POST /v1/mcp/link-code).
struct ClaudeLinkCode: Decodable, Equatable {
    let code: String
    let expiresAt: Date
    let mcpUrl: String
}

struct ClaudeConnection: Decodable, Hashable {
    let label: String?
    let createdAt: Date
    let lastUsedAt: Date
}
