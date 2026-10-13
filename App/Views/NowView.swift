import SwiftUI

/// "Şimdi": the active task and the places you left off.
struct NowView: View {
    @Environment(AppStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        @Bindable var store = store
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
            // Opened from a notification tap.
            .navigationDestination(item: $store.openTaskID) { id in
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
                    Text(StartTime.sentence(started))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(StartTime.spoken(started))
                }
            }

            NavigationLink(value: task.id) {
                Text(task.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }

            let progress = store.progress(of: task.id)
            let note = task.parkNote ?? ""
            // Resumed from park: where you left off comes first.
            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kaldığın yer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ParkNoteText(note: note)
                }
            }
            if let step = store.nextStep(of: task.id) {
                NextStepRow(step: step, done: progress.done, total: progress.total)
            } else if let next = task.nextStep, !next.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sıradaki adım")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(next)
                }
            } else if progress.total > 0 {
                Label("Tüm adımlar bitti", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if note.isEmpty {
                FirstStepField(task: task)
            }

            ActionRow {
                ActionButton(title: "Park et", symbol: "pause.fill", prominent: true) {
                    store.requestPark(task)
                }
                ActionButton(title: "Bitti", symbol: "checkmark") {
                    Task { await store.complete(task) }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// An empty card asks for the first step; it is added as the task's first subtask.
private struct FirstStepField: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("İlk adımı yaz", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
                .accessibilityLabel("İlk adım")
                .accessibilityHint("Yazdığın metin görevin ilk adımı olur")
        }
        .frame(minHeight: 44)
    }

    private func add() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        text = ""
        Task { await store.capture(title, areaId: task.areaId, parentId: task.id) }
    }
}

private struct ParkedRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: TaskItem

    private var resumeButton: some View {
        Button("Devam et") {
            store.requestStart(task)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .accessibilityHint("Bu görevi aktif yapar")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize.isAccessibilitySize {
                Text(task.title)
                    .font(.headline)
                resumeButton
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(task.title)
                        .font(.headline)
                    Spacer(minLength: 0)
                    resumeButton
                }
            }
            if let note = task.parkNote, !note.isEmpty {
                ParkNoteText(note: note)
            }
            // Full details when they fit on one line, the essentials when they don't.
            ViewThatFits(in: .horizontal) {
                meta(showReason: true)
                meta(showReason: false)
                VStack(alignment: .leading, spacing: 2) { metaItems(showReason: true) }
                    .labelStyle(.titleAndIcon)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        // The whole row opens the task; a hidden link keeps the visible button tappable
        // and avoids a disclosure chevron in the middle of the row.
        .background {
            NavigationLink(value: task.id) { EmptyView() }
                .opacity(0)
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

    private func meta(showReason: Bool) -> some View {
        HStack(spacing: 10) { metaItems(showReason: showReason) }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func metaItems(showReason: Bool) -> some View {
            if let area = store.area(task.areaId) {
                AreaLabel(area: area)
            }
            if showReason, let reason = task.parkReason {
                Label(reason.title, systemImage: reason.symbol)
            }
            if let parked = task.parkedAt {
                Text(parked, format: .relative(presentation: .named))
            }
    }
}

/// The first open step of the active task, checked off in place so the next one moves up.
private struct NextStepRow: View {
    @Environment(AppStore.self) private var store
    let step: TaskItem
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sıradaki adım")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(total) adımın \(done) tanesi bitti")
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(Color.primary)
                .accessibilityHidden(true)
            Button {
                Task { await store.complete(step) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(step.title), bitti olarak işaretle")
            .id(step.id)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        }
    }
}
