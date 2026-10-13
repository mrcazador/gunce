import SwiftUI

/// "Bugün": what is due or set to remind today. Calendar events join later via EventKit.
struct TodayView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                section("Gecikmiş", overdue)
                section("Bugün", dueToday)
                section("Hatırlatmalar", remindToday)
            }
            .overlay {
                if overdue.isEmpty && dueToday.isEmpty && remindToday.isEmpty {
                    ContentUnavailableView(
                        "Bugün için bir şey yok",
                        systemImage: "sun.max",
                        description: Text("Tarihi bugün olan görevler burada görünür.")
                    )
                }
            }
            .navigationTitle("Bugün")
            .navigationDestination(for: String.self) { id in
                TaskDetailView(taskID: id)
            }
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            Section(title) {
                ForEach(tasks) { task in
                    NavigationLink(value: task.id) {
                        TaskRow(task: task)
                    }
                    .taskSwipeActions(task)
                }
            }
        }
    }

    private var openTasks: [TaskItem] {
        store.tasks.values.filter { $0.status.isOpen }
    }

    private var startOfToday: Date { Calendar.current.startOfDay(for: .now) }

    private var overdue: [TaskItem] {
        openTasks
            .filter { ($0.dueAt ?? .distantFuture) < startOfToday }
            .sorted { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }
    }

    private var dueToday: [TaskItem] {
        openTasks
            .filter { $0.dueAt.map { Calendar.current.isDateInToday($0) } ?? false }
            .sorted { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }
    }

    private var remindToday: [TaskItem] {
        openTasks
            .filter { task in
                guard let remind = task.remindAt, Calendar.current.isDateInToday(remind) else { return false }
                return !(task.dueAt.map { Calendar.current.isDateInToday($0) } ?? false)
            }
            .sorted { ($0.remindAt ?? .now) < ($1.remindAt ?? .now) }
    }
}
