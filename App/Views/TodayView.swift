import Combine
import EventKit
import SwiftUI
import UIKit

/// "Bugün": a day planner. A week strip picks the day; below it the day's tasks, reminders
/// and Apple Calendar events in time order. Tasks with a date also live in the PickUp
/// calendar when calendar sync is on.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var events: [EKEvent] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WeekStrip(selection: $day, hasItems: hasItems)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                if !store.isDemo, !store.calendarSyncEnabled {
                    Section {
                        ConnectCalendarRow()
                    }
                }

                if isToday, !overdue.isEmpty {
                    Section("Gecikmiş") {
                        ForEach(overdue) { task in
                            taskLink(task)
                        }
                    }
                }

                Section {
                    if agenda.isEmpty {
                        Text(isToday ? "Bugün için planlanmış bir şey yok." : "Bu gün için planlanmış bir şey yok.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(agenda) { item in
                        switch item.kind {
                        case .task(let task):
                            taskLink(task)
                        case .event(let event):
                            CalendarEventRow(event: event) {
                                let seconds = Int(event.startDate.timeIntervalSinceReferenceDate)
                                if let url = URL(string: "calshow:\(seconds)") { openURL(url) }
                            }
                        }
                    }
                } header: {
                    Text(dayTitle)
                }
            }
            .navigationTitle(isToday ? "Bugün" : dayTitle)
            .navigationDestination(for: String.self) { id in
                TaskDetailView(taskID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isToday {
                        Button("Bugün") {
                            withAnimation { day = Calendar.current.startOfDay(for: .now) }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bu güne ekle", systemImage: "plus") {
                        store.captureRequest = CaptureRequest(dueAt: suggestedTime)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .task(id: day) { loadEvents() }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in loadEvents() }
            .onChange(of: store.calendarSyncEnabled) { loadEvents() }
        }
    }

    private func taskLink(_ task: TaskItem) -> some View {
        NavigationLink(value: task.id) {
            TaskRow(task: task)
        }
        .taskSwipeActions(task)
    }

    private func loadEvents() {
        events = store.isDemo ? [] : CalendarSync.shared.events(on: day)
    }

    // MARK: - Data

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }

    private var dayTitle: String {
        if calendar.isDateInToday(day) { return "Bugün" }
        if calendar.isDateInTomorrow(day) { return "Yarın" }
        if calendar.isDateInYesterday(day) { return "Dün" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Today: the next full hour. Other days: 09:00.
    private var suggestedTime: Date {
        if isToday {
            let hour = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
            return calendar.date(byAdding: .hour, value: 1, to: hour) ?? .now
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    private var openTasks: [TaskItem] {
        store.tasks.values.filter { $0.status.isOpen }
    }

    private var overdue: [TaskItem] {
        let start = calendar.startOfDay(for: .now)
        return openTasks
            .filter { ($0.dueAt ?? .distantFuture) < start }
            .sorted { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }
    }

    private func hasItems(_ date: Date) -> Bool {
        openTasks.contains { task in
            [task.dueAt, task.remindAt].compactMap { $0 }.contains { calendar.isDate($0, inSameDayAs: date) }
        }
    }

    private struct AgendaItem: Identifiable {
        enum Kind {
            case task(TaskItem)
            case event(EKEvent)
        }
        let id: String
        let time: Date
        let kind: Kind
    }

    /// Tasks due or reminding on the day, and calendar events, by time (all-day events first).
    private var agenda: [AgendaItem] {
        var items: [AgendaItem] = []
        for task in openTasks {
            let dates = [task.dueAt, task.remindAt].compactMap { $0 }.filter { calendar.isDate($0, inSameDayAs: day) }
            if let first = dates.min() {
                items.append(AgendaItem(id: task.id, time: first, kind: .task(task)))
            }
        }
        for event in events {
            let time = event.isAllDay ? calendar.startOfDay(for: day) : event.startDate ?? day
            items.append(AgendaItem(id: "event-\(event.eventIdentifier ?? UUID().uuidString)", time: time, kind: .event(event)))
        }
        return items.sorted { $0.time < $1.time }
    }
}

/// Seven days around the selection; swipe or use the arrows to change week.
private struct WeekStrip: View {
    @Binding var selection: Date
    let hasItems: (Date) -> Bool

    private var calendar: Calendar { .current }

    private var days: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selection)?.start ?? selection
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button("Önceki hafta", systemImage: "chevron.left") { shift(-7) }
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 44)
            ForEach(days, id: \.self) { date in
                DayCell(date: date, selected: calendar.isDate(date, inSameDayAs: selection), marked: hasItems(date)) {
                    withAnimation(.snappy) { selection = calendar.startOfDay(for: date) }
                }
            }
            Button("Sonraki hafta", systemImage: "chevron.right") { shift(7) }
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 44)
        }
        .buttonStyle(.borderless)
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.width < -40 { shift(7) }
                if value.translation.width > 40 { shift(-7) }
            }
        )
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func shift(_ days: Int) {
        withAnimation(.snappy) {
            selection = calendar.date(byAdding: .day, value: days, to: selection) ?? selection
        }
    }
}

private struct DayCell: View {
    let date: Date
    let selected: Bool
    let marked: Bool
    let action: () -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(date.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                Text(date.formatted(.dateTime.day()))
                    .font(.body.weight(isToday || selected ? .bold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                Circle()
                    .fill(marked ? (selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary)) : AnyShapeStyle(.clear))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isToday, !selected {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.4))
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An Apple Calendar event: its calendar's color, title and time. Tapping opens Calendar.
private struct CalendarEventRow: View {
    let event: EKEvent
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(cgColor: event.calendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1)))
                    .frame(width: 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title ?? "Etkinlik")
                        .foregroundStyle(.primary)
                    Text(timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "calendar")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Takvim'de açar")
    }

    private var timeText: String {
        let name = event.calendar?.title ?? ""
        if event.isAllDay { return "Tüm gün · \(name)" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end) · \(name)"
    }
}

/// Invites the person to connect Apple Calendar.
private struct ConnectCalendarRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Apple Takvim'i bağla", systemImage: "calendar.badge.plus")
                .font(.headline)
            Text("Etkinliklerin burada görünür, tarihli görevlerin telefonundaki PickUp takvimine yazılır.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if CalendarSync.shared.isDenied {
                Button("Ayarlar'da izin ver") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            } else {
                Button("Bağla") {
                    Task { await store.enableCalendarSync() }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }
}
