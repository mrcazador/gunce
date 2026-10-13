import SwiftUI

extension Area {
    /// Color means area only. Unknown names fall back to gray.
    var tint: Color {
        switch color {
        case "indigo": .indigo
        case "pink": .pink
        case "orange": .orange
        case "green": .green
        case "blue": .blue
        case "red": .red
        case "purple": .purple
        case "teal": .teal
        case "mint": .mint
        case "cyan": .cyan
        case "yellow": .yellow
        case "brown": .brown
        default: .gray
        }
    }
}

extension Font {
    /// The signature style for park notes. Nothing else uses serif.
    static let parkNote = Font.system(.body, design: .serif).italic()
}

/// Area name with its SF Symbol, always together with the color.
struct AreaLabel: View {
    let area: Area

    var body: some View {
        Label(area.name, systemImage: area.symbol)
            .foregroundStyle(area.tint)
            .accessibilityLabel("Alan: \(area.name)")
    }
}

struct ParkNoteText: View {
    let note: String

    var body: some View {
        Text(note)
            .font(.parkNote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Kaldığın yer: \(note)")
    }
}

/// One line in a task list: status, title, area and where you left off.
struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .imageScale(.medium)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                if task.status == .parked, let note = task.parkNote, !note.isEmpty {
                    ParkNoteText(note: note)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let area = store.area(task.areaId) {
                        AreaLabel(area: area)
                    }
                    if let due = task.dueAt {
                        Label(due.formatted(.relative(presentation: .named)), systemImage: "calendar")
                            .foregroundStyle(due < .now && task.status.isOpen ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusTitle)
    }

    private var statusSymbol: String {
        switch task.status {
        case .active: "play.circle.fill"
        case .parked: "pause.circle"
        case .inbox: "circle"
        case .done: "checkmark.circle.fill"
        case .archived: "archivebox"
        }
    }

    private var statusColor: Color {
        task.status == .active ? .primary : .secondary
    }

    private var statusTitle: String {
        switch task.status {
        case .active: "Aktif"
        case .parked: "Park edildi"
        case .inbox: "Gelen kutusu"
        case .done: "Bitti"
        case .archived: "Arşivde"
        }
    }
}

/// Swipe actions shared by every task list.
struct TaskSwipeActions: ViewModifier {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if task.parentId == nil, task.status == .inbox || task.status == .parked {
                    Button(task.status == .parked ? "Devam et" : "Başla", systemImage: "play") {
                        store.requestStart(task)
                    }
                    .tint(Color.primary)
                } else if task.status == .active {
                    Button("Park et", systemImage: "pause") {
                        store.requestPark(task)
                    }
                    .tint(.gray)
                }
            }
            .swipeActions(edge: .trailing) {
                if task.status.isOpen {
                    Button("Bitti", systemImage: "checkmark") {
                        Task { await store.complete(task) }
                    }
                    .tint(.green)
                } else {
                    Button("Yeniden aç", systemImage: "arrow.counterclockwise") {
                        Task { await store.reopen(task) }
                    }
                }
            }
    }
}

extension View {
    func taskSwipeActions(_ task: TaskItem) -> some View {
        modifier(TaskSwipeActions(task: task))
    }
}
