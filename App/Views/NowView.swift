import SwiftUI

/// "Şimdi": the active task and the places you left off.
struct NowView: View {
    @Environment(AppStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let task = store.activeTask {
                        ActiveTaskCard(task: task)
                    } else {
                        ContentUnavailableView(
                            "Şu an aktif görev yok",
                            systemImage: "cup.and.saucer",
                            description: Text("Kaldığın yerlerden birine devam et ya da aklına geleni aşağıya yaz.")
                        )
                    }
                }

                if !store.parkedTasks.isEmpty {
                    Section("Kaldığın yerler") {
                        ForEach(store.parkedTasks) { task in
                            ParkedRow(task: task)
                        }
                    }
                }

                if !store.inboxTasks.isEmpty {
                    Section("Gelen kutusu") {
                        ForEach(store.inboxTasks.prefix(5)) { task in
                            NavigationLink(value: task.id) {
                                TaskRow(task: task)
                            }
                            .taskSwipeActions(task)
                        }
                    }
                }
            }
            .navigationTitle("Şimdi")
            .navigationDestination(for: String.self) { id in
                TaskDetailView(taskID: id)
            }
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ayarlar", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

private struct ActiveTaskCard: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let area = store.area(task.areaId) {
                    AreaLabel(area: area)
                        .font(.subheadline)
                }
                Spacer()
                if let started = task.startedAt {
                    Text(started, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Süre")
                }
            }

            NavigationLink(value: task.id) {
                Text(task.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }

            if let next = task.nextStep, !next.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sıradaki adım")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(next)
                }
            } else if let note = task.parkNote, !note.isEmpty {
                ParkNoteText(note: note)
            }

            HStack(spacing: 12) {
                Button {
                    store.requestPark(task)
                } label: {
                    Label("Park et", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await store.complete(task) }
                } label: {
                    Label("Bitti", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ParkedRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: task.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.headline)
                    if let note = task.parkNote, !note.isEmpty {
                        ParkNoteText(note: note)
                    }
                    HStack(spacing: 8) {
                        if let area = store.area(task.areaId) {
                            AreaLabel(area: area)
                        }
                        if let reason = task.parkReason {
                            Label(reason.title, systemImage: reason.symbol)
                        }
                        if let parked = task.parkedAt {
                            Text(parked, format: .relative(presentation: .named))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Button("Devam et") {
                store.requestStart(task)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityHint("Bu görevi aktif yapar")
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Devam et", systemImage: "play") {
                store.requestStart(task)
            }
            .tint(Color.primary)
        }
        .contextMenu {
            Button("Devam et", systemImage: "play") { store.requestStart(task) }
            Button("Bitti", systemImage: "checkmark") {
                Task { await store.complete(task) }
            }
        }
    }
}
