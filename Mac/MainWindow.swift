import SwiftUI

enum MacSection: Hashable {
    case now, inbox, parked, today, done
    case area(String)
}

struct MacRootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.isSignedIn {
            MacMainView()
        } else {
            MacSignInView()
        }
    }
}

/// Sidebar (lists and areas), the tasks of the selected list, and the selected task.
struct MacMainView: View {
    @Environment(AppStore.self) private var store
    @State private var section: MacSection? = .now
    @State private var selection: String?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    sidebarRow("Şimdi", "bookmark", .now, count: store.activeTask == nil ? 0 : 1)
                    sidebarRow("Gelen kutusu", "tray", .inbox, count: store.inboxTasks.count)
                    sidebarRow("Kaldığın yerler", "pause.circle", .parked, count: store.parkedTasks.count)
                    sidebarRow("Bugün", "calendar", .today, count: todayTasks.count)
                    sidebarRow("Bitenler", "checkmark.circle", .done, count: 0)
                }
                Section("Alanlar") {
                    ForEach(store.sortedAreas) { area in
                        Label(area.name, systemImage: area.symbol)
                            .foregroundStyle(area.macTint)
                            .tag(MacSection.area(area.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let selection, store.tasks[selection] != nil {
                MacTaskDetail(taskID: selection)
            } else {
                ContentUnavailableView("Bir görev seç", systemImage: "bookmark",
                                       description: Text("Ayrıntılar, adımlar ve İz burada görünür."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Yenile", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r")
            }
        }
        .sheet(item: $store.parkRequest) { request in
            MacParkForm(
                taskTitle: request.task.title,
                confirmTitle: request.next == nil ? "Park et" : "Park et ve geç"
            ) {
                store.parkRequest = nil
            } onConfirm: { note, reason, remindAt in
                store.parkRequest = nil
                Task { await store.macPark(request, note: note, reason: reason, remindAt: remindAt) }
            }
            .padding(20)
            .frame(width: 420)
        }
        .alert(
            "Olmadı",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: section) { selection = nil }
    }

    private func sidebarRow(_ title: String, _ symbol: String, _ value: MacSection, count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(value)
    }

    // MARK: - Content column

    @ViewBuilder
    private var content: some View {
        switch section ?? .now {
        case .now:
            MacNowColumn(selection: $selection)
        case .inbox:
            taskList("Gelen kutusu", store.inboxTasks, empty: "Gelen kutun boş.")
        case .parked:
            taskList("Kaldığın yerler", store.parkedTasks, empty: "Park edilmiş görev yok.")
        case .today:
            taskList("Bugün", todayTasks, empty: "Bugün için tarihli görev yok.")
        case .done:
            taskList("Bitenler", doneTasks, empty: "Henüz biten görev yok.")
        case .area(let id):
            taskList(store.area(id)?.name ?? "Alan", store.topLevelTasks(area: id, open: true), empty: "Bu alanda açık görev yok.")
        }
    }

    private func taskList(_ title: String, _ tasks: [TaskItem], empty: String) -> some View {
        List(selection: $selection) {
            ForEach(tasks) { task in
                MacTaskRow(task: task)
                    .tag(task.id)
                    .contextMenu { MacTaskMenu(task: task) }
            }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView(empty, systemImage: "tray")
            }
        }
        .safeAreaInset(edge: .bottom) {
            MacCaptureField()
                .padding(10)
                .background(.bar)
        }
        .navigationTitle(title)
    }

    private var todayTasks: [TaskItem] {
        let calendar = Calendar.current
        return store.tasks.values
            .filter { $0.status.isOpen && $0.parentId == nil }
            .filter { task in
                [task.dueAt, task.remindAt].compactMap { $0 }.contains { calendar.isDateInToday($0) || $0 < .now }
            }
            .sorted { ($0.dueAt ?? $0.remindAt ?? .now) < ($1.dueAt ?? $1.remindAt ?? .now) }
    }

    private var doneTasks: [TaskItem] {
        store.tasks.values
            .filter { $0.status == .done && $0.parentId == nil }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
            .prefix(100)
            .map { $0 }
    }
}

/// The "Şimdi" column: the active task in large, then where you left off.
private struct MacNowColumn: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section("Şimdi") {
                if let task = store.activeTask {
                    MacActiveCard(task: task)
                        .tag(task.id)
                } else {
                    Text("Aktif görev yok. Kaldığın yerlerden birine devam et ya da yeni bir görev ekle.")
                        .foregroundStyle(.secondary)
                }
            }
            if !store.parkedTasks.isEmpty {
                Section("Kaldığın yerler") {
                    ForEach(store.parkedTasks) { task in
                        HStack(alignment: .firstTextBaseline) {
                            MacTaskRow(task: task)
                            Spacer(minLength: 8)
                            Button("Devam et") { store.requestStart(task) }
                                .controlSize(.small)
                        }
                        .tag(task.id)
                        .contextMenu { MacTaskMenu(task: task) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            MacCaptureField()
                .padding(10)
                .background(.bar)
        }
        .navigationTitle("Şimdi")
    }
}

/// The active task: start time, park note, next step and the two actions.
private struct MacActiveCard: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let area = store.area(task.areaId) {
                    MacAreaLabel(area: area)
                }
                Spacer()
                if let started = task.startedAt {
                    Text(StartTime.sentence(started))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(StartTime.spoken(started))
                }
            }
            .font(.subheadline)
            Text(task.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let note = task.parkNote, !note.isEmpty {
                MacParkNote(note: note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let step = store.nextStep(of: task.id) {
                let progress = store.progress(of: task.id)
                Button {
                    Task { await store.complete(step) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle")
                        Text("Sıradaki: \(step.title)")
                        Spacer()
                        Text("\(progress.done)/\(progress.total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Adımı bitir")
            }
            HStack {
                Button("Park et", systemImage: "pause.fill") { store.requestPark(task) }
                    .buttonStyle(.borderedProminent)
                Button("Bitti", systemImage: "checkmark") {
                    Task { await store.complete(task) }
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}

/// Right-click actions for a task row.
struct MacTaskMenu: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        switch task.status {
        case .inbox, .parked:
            Button(task.status == .parked ? "Devam et" : "Başla") { store.requestStart(task) }
            Button("Bitti") { Task { await store.complete(task) } }
        case .active:
            Button("Park et") { store.requestPark(task) }
            Button("Bitti") { Task { await store.complete(task) } }
        case .done, .archived:
            Button("Yeniden aç") { Task { await store.reopen(task) } }
        }
        if task.status != .active, task.status != .archived {
            Divider()
            Button("Arşivle") { Task { await store.archive(task) } }
        }
    }
}
