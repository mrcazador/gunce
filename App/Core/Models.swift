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
        case "created": "Oluşturuldu"
        case "started": "Başlandı"
        case "parked": "Park edildi"
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
