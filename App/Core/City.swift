import Foundation

/// The city that grows out of the work: every top-level task is a building.
/// Nothing here is entered by hand; it is derived from tasks and their İz history, so the
/// city costs no time to keep and looks the same on every device.
struct CityBuilding: Identifiable, Hashable {
    enum Stage: Hashable {
        /// In the inbox: the plot is marked out.
        case planned
        /// Being built (active, or parked for less than three days).
        case rising
        /// Parked for 3–6 days: the crane has stopped.
        case stalled
        /// Parked for a week or more: tape across the door, ivy on the walls.
        case abandoned
        case finished
    }

    let id: String
    let title: String
    let areaId: String?
    let stage: Stage
    /// How much of the building stands, 0…1: the share of steps done, or a fixed amount
    /// for tasks without steps.
    let progress: Double
    let stepsDone: Int
    let stepsTotal: Int
    /// Days since it was parked (stalled and abandoned buildings).
    let idleDays: Int
    /// Finished after waiting a week or more somewhere along the way: these become the
    /// city's landmarks, so the work you kept putting off builds its finest buildings.
    let isLandmark: Bool
    let parkNote: String?
    let createdAt: Date
}

enum CityLevel: Int, CaseIterable {
    case building, site, neighbourhood, city

    var title: String {
        switch self {
        case .building: "Bina"
        case .site: "Site"
        case .neighbourhood: "Mahalle"
        case .city: "Şehir"
        }
    }

    /// Finished buildings needed to reach this level.
    var threshold: Int {
        switch self {
        case .building: 0
        case .site: 5
        case .neighbourhood: 15
        case .city: 40
        }
    }

    static func level(for finished: Int) -> CityLevel {
        allCases.last { finished >= $0.threshold } ?? .building
    }

    var next: CityLevel? { CityLevel(rawValue: rawValue + 1) }
}

struct CitySummary {
    let buildings: [CityBuilding]
    let finished: Int
    let level: CityLevel
    /// Progress towards the next level, 0…1 (1 at the top level).
    let levelProgress: Double
    let stalled: [CityBuilding]
    let landmarks: Int
}

extension AppStore {
    /// Days a parked task may rest before its site counts as stalled, and then abandoned.
    static let stalledAfterDays = 3
    static let abandonedAfterDays = 7

    func city(now: Date = .now) -> CitySummary {
        let calendar = Calendar.current
        var buildings: [CityBuilding] = []
        for task in tasks.values where task.parentId == nil && task.deletedAt == nil && task.status != .archived {
            let steps = progress(of: task.id)
            var idle = 0
            let stage: CityBuilding.Stage
            switch task.status {
            case .done:
                stage = .finished
            case .inbox:
                stage = .planned
            case .active:
                stage = .rising
            case .parked:
                let since = task.parkedAt ?? task.updatedAt
                idle = calendar.dateComponents([.day], from: since, to: now).day ?? 0
                stage = idle >= Self.abandonedAfterDays ? .abandoned
                    : idle >= Self.stalledAfterDays ? .stalled : .rising
            case .archived:
                continue
            }
            let built: Double = {
                if stage == .finished { return 1 }
                if steps.total > 0 { return max(0.15, Double(steps.done) / Double(steps.total)) }
                return stage == .planned ? 0 : 0.45
            }()
            buildings.append(CityBuilding(
                id: task.id,
                title: task.title,
                areaId: task.areaId,
                stage: stage,
                progress: built,
                stepsDone: steps.done,
                stepsTotal: steps.total,
                idleDays: idle,
                isLandmark: stage == .finished && waitedLong(task.id),
                parkNote: task.parkNote,
                createdAt: task.createdAt
            ))
        }
        buildings.sort { $0.createdAt < $1.createdAt }
        let finished = buildings.filter { $0.stage == .finished }.count
        let level = CityLevel.level(for: finished)
        let progress: Double = {
            guard let next = level.next else { return 1 }
            return Double(finished - level.threshold) / Double(next.threshold - level.threshold)
        }()
        let stalled = buildings
            .filter { $0.stage == .stalled || $0.stage == .abandoned }
            .sorted { $0.idleDays > $1.idleDays }
        return CitySummary(
            buildings: buildings,
            finished: finished,
            level: level,
            levelProgress: progress,
            stalled: stalled,
            landmarks: buildings.filter(\.isLandmark).count
        )
    }

    /// Whether the task once sat parked for a week or more before work went on.
    private func waitedLong(_ taskID: String) -> Bool {
        let history = events.values
            .filter { $0.taskId == taskID }
            .sorted { $0.occurredAt < $1.occurredAt }
        var parkedAt: Date?
        for event in history {
            switch event.kind {
            case "parked":
                parkedAt = event.occurredAt
            case "resumed", "started", "done":
                if let start = parkedAt,
                   event.occurredAt.timeIntervalSince(start) >= Double(Self.abandonedAfterDays) * 86_400 {
                    return true
                }
                parkedAt = nil
            default:
                break
            }
        }
        return false
    }
}
