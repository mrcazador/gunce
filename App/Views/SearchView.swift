import SwiftUI

struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.search(query)) { task in
                NavigationLink(value: task.id) {
                    TaskRow(task: task)
                }
                .taskSwipeActions(task)
            }
            .overlay {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty && store.search(query).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Ara")
            .navigationDestination(for: String.self) { id in
                TaskDetailView(taskID: id)
            }
            .searchable(text: $query, prompt: "Görev, not, kaldığın yer")
        }
    }
}
