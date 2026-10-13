import SwiftUI

/// One task: its main action, content, steps, where you left off and the "İz" history.
struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    let taskID: String

    var body: some View {
        if let task = store.tasks[taskID] {
            TaskDetailForm(task: task)
        } else {
            ContentUnavailableView("Görev bulunamadı", systemImage: "questionmark.folder")
        }
    }
}

private struct TaskDetailForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem

    private enum Field: Hashable { case title, details, newStep, note }

    @State private var title: String
    @State private var details: String
    @State private var newStep = ""
    @State private var newNote = ""
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    init(task: TaskItem) {
        self.task = task
        _title = State(initialValue: task.title)
        _details = State(initialValue: task.details ?? "")
    }

    var body: some View {
        Form {
            Section {
                primaryActions
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                TextField("Başlık", text: $title, axis: .vertical)
                    .font(.headline)
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .onSubmit(saveText)
                TextField("Ayrıntılar", text: $details, axis: .vertical)
                    .lineLimit(2...10)
                    .focused($focus, equals: .details)
            }

            if task.status == .parked || task.parkNote?.isEmpty == false {
                Section("Kaldığın yer") {
                    if let note = task.parkNote, !note.isEmpty {
                        ParkNoteText(note: note)
                    }
                    if let reason = task.parkReason, task.status == .parked {
                        Label(reason.title, systemImage: reason.symbol)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if task.parentId == nil {
                stepsSection
            }

            Section {
                Picker("Alan", selection: areaBinding) {
                    Text("Alansız").tag(String?.none)
                    ForEach(store.sortedAreas) { area in
                        Label(area.name, systemImage: area.symbol).tag(Optional(area.id))
                    }
                }
                Toggle("Tarih", isOn: dateToggle(\.dueAt))
                if task.dueAt != nil {
                    DatePicker("Ne zaman", selection: dateBinding(\.dueAt))
                }
                Toggle("Hatırlat", isOn: dateToggle(\.remindAt))
                if task.remindAt != nil {
                    DatePicker("Hatırlatma", selection: dateBinding(\.remindAt))
                }
            } footer: {
                if task.dueAt != nil, store.calendarSyncEnabled {
                    Text("Bu görev PickUp takviminde de görünür.")
                }
            }

            Section("İz") {
                TextField("Not ekle", text: $newNote, axis: .vertical)
                    .focused($focus, equals: .note)
                    .submitLabel(.done)
                    .onSubmit {
                        let note = newNote
                        newNote = ""
                        Task { await store.addNote(note, to: task) }
                    }
                ForEach(store.history(of: task.id)) { event in
                    EventRow(event: event)
                }
            }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Diğer", systemImage: "ellipsis") {
                    if task.status == .inbox || task.status == .parked {
                        Button("Arşivle", systemImage: "archivebox") {
                            Task { await store.archive(task) }
                        }
                    }
                    Button("Sil", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
        }
        .confirmationDialog("Görev silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Sil", role: .destructive) {
                Task {
                    await store.delete(task)
                    dismiss()
                }
            }
        } message: {
            Text(store.subtasks(of: task.id).isEmpty ? "Bu geri alınamaz." : "Adımları da silinir. Bu geri alınamaz.")
        }
        .onChange(of: focus) { old, _ in
            if old == .title || old == .details { saveText() }
        }
        .onDisappear(perform: saveText)
        .task(id: task.id) {
            await store.loadHistory(of: task.id)
        }
    }

    // MARK: - Steps

    private var stepsSection: some View {
        let steps = store.subtasks(of: task.id)
        let progress = store.progress(of: task.id)
        return Section {
            ForEach(steps) { step in
                StepRow(step: step, isFirst: step.id == steps.first?.id, isLast: step.id == steps.last?.id) { offset in
                    guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
                    let target = offset < 0 ? index - 1 : index + 2
                    Task { await store.moveSubtasks(of: task.id, from: IndexSet(integer: index), to: target) }
                }
            }
            .onMove { source, destination in
                Task { await store.moveSubtasks(of: task.id, from: source, to: destination) }
            }
            .onDelete { offsets in
                let doomed = offsets.map { steps[$0] }
                Task { for step in doomed { await store.delete(step) } }
            }
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                TextField("Adım ekle", text: $newStep)
                    .focused($focus, equals: .newStep)
                    .submitLabel(.next)
                    .onSubmit(addStep)
            }
        } header: {
            HStack {
                Text("Adımlar")
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done)/\(progress.total)")
                        .monospacedDigit()
                        .accessibilityLabel("\(progress.total) adımın \(progress.done) tanesi bitti")
                }
            }
        } footer: {
            if progress.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(Color.primary)
                        .accessibilityHidden(true)
                    Text("İlk açık adım Şimdi ekranında sıradaki adım olarak görünür. Sıralamak için basılı tutup sürükle.")
                }
            } else {
                Text("İşi küçük adımlara böl; ilk açık adım Şimdi ekranında görünür.")
            }
        }
    }

    private func addStep() {
        let text = newStep
        newStep = ""
        focus = .newStep
        Task { await store.capture(text, areaId: task.areaId, parentId: task.id) }
    }

    // MARK: - Saving

    /// Text is saved when you leave the field; pickers and toggles save at once.
    private func saveText() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = store.tasks[task.id] else { return }
        guard !trimmedTitle.isEmpty else {
            title = current.title
            return
        }
        guard trimmedTitle != current.title || trimmedDetails != (current.details ?? "") else { return }
        Task {
            await store.edit(current) {
                $0.title = trimmedTitle
                $0.details = trimmedDetails.isEmpty ? nil : trimmedDetails
            }
        }
    }

    private var areaBinding: Binding<String?> {
        Binding(
            get: { task.areaId },
            set: { newValue in Task { await store.edit(task) { $0.areaId = newValue } } }
        )
    }

    private func dateToggle(_ key: WritableKeyPath<TaskItem, Date?>) -> Binding<Bool> {
        Binding(
            get: { task[keyPath: key] != nil },
            set: { on in
                Task {
                    if on, key == \TaskItem.remindAt { await Reminders.requestPermission() }
                    await store.edit(task) { $0[keyPath: key] = on ? Self.nextHour : nil }
                }
            }
        )
    }

    private func dateBinding(_ key: WritableKeyPath<TaskItem, Date?>) -> Binding<Date> {
        Binding(
            get: { task[keyPath: key] ?? Self.nextHour },
            set: { date in Task { await store.edit(task) { $0[keyPath: key] = date } } }
        )
    }

    /// Next full hour, so switching a date on picks something sensible.
    private static var nextHour: Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? .now
    }

    // MARK: - Main action

    /// The one prominent action for the task's state, with "Bitti" beside it while open.
    private var primaryActions: some View {
        ActionRow {
            switch task.status {
            case .inbox, .parked:
                if task.parentId == nil {
                    ActionButton(title: task.status == .parked ? "Devam et" : "Başla", symbol: "play.fill", prominent: true) {
                        store.requestStart(task)
                    }
                }
            case .active:
                ActionButton(title: "Park et", symbol: "pause.fill", prominent: true) {
                    store.requestPark(task)
                }
            case .done, .archived:
                ActionButton(title: "Yeniden aç", symbol: "arrow.counterclockwise", prominent: true) {
                    Task { await store.reopen(task) }
                }
            }
            if task.status.isOpen {
                ActionButton(title: "Bitti", symbol: "checkmark", prominent: task.parentId != nil) {
                    Task { await store.complete(task) }
                }
            }
        }
    }
}

/// One step: check it off, rename it in place, swipe to delete, drag (or use the menu) to move.
private struct StepRow: View {
    @Environment(AppStore.self) private var store
    let step: TaskItem
    let isFirst: Bool
    let isLast: Bool
    /// -1 moves the step up, +1 down. The menu alternative to dragging.
    let move: (Int) -> Void

    @State private var title: String
    @FocusState private var editing: Bool

    init(step: TaskItem, isFirst: Bool, isLast: Bool, move: @escaping (Int) -> Void) {
        self.step = step
        self.isFirst = isFirst
        self.isLast = isLast
        self.move = move
        _title = State(initialValue: step.title)
    }

    private var isDone: Bool { step.status == .done }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if isDone {
                        await store.reopen(step)
                    } else {
                        await store.complete(step)
                    }
                }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? Color.primary : Color.secondary)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isDone ? "Adımı yeniden aç" : "Adımı bitti olarak işaretle")

            TextField("Adım", text: $title, axis: .vertical)
                .focused($editing)
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .submitLabel(.done)
                .onSubmit(save)
                .onChange(of: editing) { _, now in
                    if !now { save() }
                }
        }
        .contextMenu {
            if !isFirst {
                Button("Yukarı taşı", systemImage: "arrow.up") { move(-1) }
            }
            if !isLast {
                Button("Aşağı taşı", systemImage: "arrow.down") { move(1) }
            }
            Button("Sil", systemImage: "trash", role: .destructive) {
                Task { await store.delete(step) }
            }
        }
        .onChange(of: step.title) { _, newTitle in
            if !editing { title = newTitle }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = step.title
            return
        }
        guard trimmed != step.title else { return }
        Task { await store.edit(step) { $0.title = trimmed } }
    }
}

private struct EventRow: View {
    let event: TaskEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: event.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title)
                    Spacer()
                    Text(event.occurredAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = event.note, !note.isEmpty {
                    if event.kind == "parked" {
                        ParkNoteText(note: note)
                    } else {
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                }
                if let reason = event.reason {
                    Label(reason.title, systemImage: reason.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let seconds = event.durationSeconds, seconds >= 60 {
                    Text("\(Duration.seconds(seconds), format: .units(allowed: [.hours, .minutes], width: .abbreviated)) çalışıldı")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
