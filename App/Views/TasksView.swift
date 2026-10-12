import SwiftUI

/// "Görevler": every task grouped by area.
struct TasksView: View {
    @Environment(AppStore.self) private var store
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            List {
                Picker("Görünüm", selection: $showDone) {
                    Text("Açık").tag(false)
                    Text("Biten").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                ForEach(store.sortedAreas) { area in
                    let tasks = store.topLevelTasks(area: area.id, open: !showDone)
                    if !tasks.isEmpty {
                        Section {
                            rows(tasks)
                        } header: {
                            AreaLabel(area: area)
                        }
                    }
                }

                let unfiled = store.topLevelTasks(area: nil, open: !showDone)
                if !unfiled.isEmpty {
                    Section("Alansız") {
                        rows(unfiled)
                    }
                }
            }
            .overlay {
                if store.tasks.isEmpty {
                    ContentUnavailableView(
                        "Henüz görev yok",
                        systemImage: "checklist",
                        description: Text("Aklına geleni aşağıdaki alana yaz.")
                    )
                }
            }
            .navigationTitle("Görevler")
            .navigationDestination(for: String.self) { id in
                TaskDetailView(taskID: id)
            }
            .refreshable { await store.refresh() }
        }
    }

    private func rows(_ tasks: [TaskItem]) -> some View {
        ForEach(tasks) { task in
            NavigationLink(value: task.id) {
                TaskRow(task: task)
            }
            .taskSwipeActions(task)
        }
    }
}
