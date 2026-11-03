import SwiftUI

/// "Büyüklük" tucked inside a task's menu: never asked up front (the app does not make people
/// decide), but there to set or change whenever wanted. It picks how grand the building is.
struct TaskSizeMenu: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        if task.parentId == nil {
            Picker("Büyüklük", systemImage: "square.stack.3d.up", selection: Binding(
                get: { task.size },
                set: { size in
                    guard let fresh = store.tasks[task.id] else { return }
                    Task { await store.edit(fresh) { $0.priority = size.rawValue } }
                }
            )) {
                ForEach(TaskSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
