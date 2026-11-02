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

/// The soft game palette: warm cream ground, brick for the one main action, sage for
/// progress. Light and dark variants live in the asset catalog. Area colors stay for areas.
extension Color {
    static let themeBackground = Color("ThemeBackground")
    static let themeBrick = Color("ThemeBrick")
    static let themeBrickShadow = Color("ThemeBrickShadow")
    static let themeOnBrick = Color("ThemeOnBrick")
    static let themeCard = Color("ThemeCard")
    static let themeCardShadow = Color("ThemeCardShadow")
    static let themeSage = Color("ThemeSage")
}

extension View {
    /// The warm cream ground behind lists and forms.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.themeBackground)
    }
}

/// A chunky, game-like button that sits on a solid ledge and presses down into it.
struct ChunkyButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.themeOnBrick : Color.primary)
            .padding(.horizontal, 12)
            .background(prominent ? Color.themeBrick : Color.themeCard, in: RoundedRectangle(cornerRadius: 16))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(prominent ? Color.themeBrickShadow : Color.themeCardShadow)
                    .offset(y: pressed ? 1 : 4)
            )
            .offset(y: pressed ? 3 : 0)
            .padding(.bottom, 4)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: pressed)
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
    /// Lists grouped by area already name it in the section header.
    var showArea = true

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
                    if showArea, let area = store.area(task.areaId) {
                        AreaLabel(area: area)
                    }
                    let steps = store.progress(of: task.id)
                    if steps.total > 0 {
                        Label("\(steps.done)/\(steps.total)", systemImage: "checklist")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(steps.total) adımın \(steps.done) tanesi bitti")
                    }
                    if let due = task.dueAt {
                        Label(dueText(due), systemImage: "calendar")
                            .foregroundStyle(due < .now && task.status.isOpen ? Color.red : Color.secondary)
                    }
                }
                .lineLimit(1)
                .font(.caption)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusTitle)
    }

    /// Today shows the time ("17:00"); other days read relative ("yarın", "2 gün önce").
    private func dueText(_ due: Date) -> String {
        Calendar.current.isDateInToday(due)
            ? due.formatted(date: .omitted, time: .shortened)
            : due.formatted(.relative(presentation: .named))
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
        case .parked: "Duruyor"
        case .inbox: "Gelen kutusu"
        case .done: "Teslim edildi"
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
                    Button(task.status == .parked ? "Şantiyeye dön" : "Başla", systemImage: "play") {
                        store.requestStart(task)
                    }
                    .tint(Color.primary)
                } else if task.status == .active {
                    Button("İnşaatı durdur", systemImage: "pause") {
                        store.requestPark(task)
                    }
                    .tint(.gray)
                }
            }
            .swipeActions(edge: .trailing) {
                if task.status.isOpen {
                    Button("Teslim et", systemImage: "checkmark") {
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

/// A full-width action button. The prominent one carries the screen's main action.
struct ActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(ChunkyButtonStyle(prominent: prominent))
    }

    private var label: some View {
        Label(title, systemImage: symbol)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 48)
    }
}

/// Lays action buttons side by side, or stacked at accessibility text sizes.
struct ActionRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) { content() }
        } else {
            HStack(spacing: 12) { content() }
        }
    }
}
