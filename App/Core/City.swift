import Foundation

/// The city that grows out of the work: every top-level task is a building.
/// Nothing here is entered by hand; it is derived from tasks and their İz history, so the
/// city costs no time to keep and looks the same on every device.
struct CityBuilding: Identifiable, Hashable {
    enum Stage: Hashable {
        /// In the inbox: the plot is marked out.
        case planned
        /// Being built: a step was checked off in the last three days.
        case rising
        /// No step checked off for 3–6 days: the crane has stopped.
        case stalled
        /// No step checked off for a week or more: tape across the door, ivy on the walls.
        case abandoned
        case finished
    }

    /// Where the building stands, from the foundation to moving in.
    enum Art: String {
        case foundation = "temel"
        case groundFloor = "kat1"
        case upperFloor = "kat2"
        case shell = "kaba"
        case finished = "final"
        /// Lived in: the finished building, lit up warmly.
        case occupied = "iskan"
        case stalled = "durmus"
    }

    /// Days after finishing until the building is lived in.
    static let movesInAfterDays = 2

    var art: Art {
        switch stage {
        case .planned:
            return .foundation
        case .stalled, .abandoned:
            return .stalled
        case .finished:
            return finishedDays >= Self.movesInAfterDays ? .occupied : .finished
        case .rising:
            guard stepsTotal > 0 else { return .groundFloor }
            if stepsDone == 0 { return .foundation }
            if stepsDone == stepsTotal { return .shell }
            return Double(stepsDone) / Double(stepsTotal) < 0.5 ? .groundFloor : .upperFloor
        }
    }

    /// Asset name: `city-temel` for every plot, `city-<kind>-<stage>` while building, and
    /// `city-<kind>-final<size>` once finished, so a big task ends as a grander building.
    var imageName: String {
        switch art {
        case .foundation: "city-temel"
        case .finished, .occupied: "city-\(kind.rawValue)-final\(size.rawValue)"
        default: "city-\(kind.rawValue)-\(art.rawValue)"
        }
    }

    let id: String
    let title: String
    let areaId: String?
    /// The kind of building, from the task's area.
    let kind: CityKind
    let size: TaskSize
    let stage: Stage
    /// How much of the building stands, 0…1: the share of steps done, or a fixed amount
    /// for tasks without steps.
    let progress: Double
    let stepsDone: Int
    let stepsTotal: Int
    /// Days since a step was last checked off (or since construction began).
    let idleDays: Int
    /// Days since it was finished: after a few days the building is moved into (iskan).
    let finishedDays: Int
    /// Finished after waiting a week or more somewhere along the way: these become the
    /// city's landmarks, so the work you kept putting off builds its finest buildings.
    let isLandmark: Bool
    let parkNote: String?
    let createdAt: Date
}

/// Each area builds its own kind of building in its own district: homes for Hayat, glass
/// offices for İş, sports halls for Spor and banks for Yatırım. Areas added later build homes.
enum CityKind: String, CaseIterable {
    case work = "is"
    case investment = "yatirim"
    case life = "hayat"
    case sport = "spor"

    init(area: Area?) {
        guard let area else { self = .life; return }
        switch area.symbol {
        case "briefcase", "briefcase.fill": self = .work
        case "chart.line.uptrend.xyaxis": self = .investment
        case "figure.run": self = .sport
        case "heart", "heart.fill": self = .life
        default:
            switch area.name.lowercased(with: Locale(identifier: "tr")) {
            case "iş": self = .work
            case "yatırım": self = .investment
            case "spor": self = .sport
            default: self = .life
            }
        }
    }

    /// Districts are laid out back to front in this order: the tall offices stand behind.
    var order: Int {
        switch self {
        case .work: 0
        case .investment: 1
        case .life: 2
        case .sport: 3
        }
    }
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

    /// The city's story at this level: what the place looks like now.
    var story: String {
        switch self {
        case .building: "Toprak yollar, tek bir vinç. İlk binaların yükseliyor."
        case .site: "Yollar asfaltlandı, sokak lambaları yanıyor."
        case .neighbourhood: "Sokaklar ağaçlandı; her semt kendi yüzünü buldu."
        case .city: "Ufukta silüet, akşam ışıkları yanıyor. Burası artık bir şehir."
        }
    }

    /// What reaching this level adds to the city.
    var unlock: String {
        switch self {
        case .building: "Toprak yollar ve vinçler"
        case .site: "Asfalt yollar ve sokak lambaları"
        case .neighbourhood: "Ağaçlı sokaklar"
        case .city: "Ufuk silüeti ve akşam ışıkları"
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
    /// Days without a checked-off step before a site counts as stalled, and then abandoned.
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
            case .active, .parked:
                // A site is judged by its work, not by whether it is in hand: days since a step
                // was last checked off (or since construction began, before the first one).
                idle = calendar.dateComponents([.day], from: lastProgress(of: task), to: now).day ?? 0
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
                kind: CityKind(area: area(task.areaId)),
                size: task.size,
                stage: stage,
                progress: built,
                stepsDone: steps.done,
                stepsTotal: steps.total,
                idleDays: idle,
                finishedDays: task.completedAt.map { calendar.dateComponents([.day], from: $0, to: now).day ?? 0 } ?? 0,
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

    /// The last sign of work on a building. With steps: the newest checked-off step, or when
    /// construction began (first started) before the first one. Without steps there is
    /// nothing to check off, so going back to the site (the latest start) counts.
    func lastProgress(of task: TaskItem) -> Date {
        let steps = subtasks(of: task.id).filter { $0.deletedAt == nil }
        let begun = task.createdAt
        if steps.isEmpty {
            return max(task.startedAt ?? begun, begun)
        }
        if let stepDone = steps.compactMap({ $0.status == .done ? $0.completedAt : nil }).max() {
            return stepDone
        }
        let firstStart = events.values
            .filter { $0.taskId == task.id && $0.kind == "started" }
            .map(\.occurredAt)
            .min()
        return firstStart ?? task.startedAt ?? begun
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
