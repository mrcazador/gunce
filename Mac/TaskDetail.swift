import SwiftUI

/// A task on the Mac: title and details, where you left off, steps, area and dates, İz.
struct MacTaskDetail: View {
    @Environment(AppStore.self) private var store
    let taskID: String

    @State private var title = ""
    @State private var details = ""
    @State private var newStep = ""
    @State private var note = ""
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    private enum Field { case title, details, step, note }

    private var task: TaskItem? { store.tasks[taskID] }

    var body: some View {
        if let task {
            Form {
                Section {
                    TextField("Başlık", text: $title)
                        .font(.title2.weight(.semibold))
                        .focused($focus, equals: .title)
                        .onSubmit(saveText)
                    TextField("Ayrıntılar", text: $details, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focus, equals: .details)
                    actions(task)
                }

                if let parkNote = task.parkNote, !parkNote.isEmpty {
                    Section("Kaldığın yer") {
                        MacParkNote(note: parkNote)
                        if let reason = task.parkReason {
                            Label(reason.title, systemImage: reason.symbol)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                stepsSection(task)

                Section {
                    Picker("Alan", selection: areaBinding(task)) {
                        Text("Yok").tag(String?.none)
                        ForEach(store.sortedAreas) { area in
                            Label(area.name, systemImage: area.symbol).tag(Optional(area.id))
                        }
                    }
                    dateRow("Tarih", task: task, key: \.dueAt)
                    dateRow("Hatırlat", task: task, key: \.remindAt)
                } footer: {
                    if store.calendarSyncEnabled, task.dueAt != nil {
                        Text("Bu görev PickUp takviminde de görünür.")
                    }
                }

                Section("İz") {
                    HStack {
                        TextField("Not ekle", text: $note)
                            .focused($focus, equals: .note)
                            .onSubmit(addNote)
                        Button("Ekle", action: addNote)
                            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(store.history(of: taskID)) { event in
                        MacEventRow(event: event)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(task.title)
            .toolbar {
                ToolbarItem {
                    Menu("Diğer", systemImage: "ellipsis.circle") {
                        if task.status != .active, task.status != .archived {
                            Button("Arşivle", systemImage: "archivebox") {
                                Task { await store.archive(task) }
                            }
                        }
                        Button("Sil", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .confirmationDialog("Görev silinsin mi?", isPresented: $confirmDelete) {
                Button("Sil", role: .destructive) { Task { await store.delete(task) } }
            } message: {
                Text("Adımları ve İz geçmişi de silinir.")
            }
            .onAppear(perform: load)
            .onChange(of: taskID) { load() }
            .onChange(of: focus) { old, _ in
                if old == .title || old == .details { saveText() }
            }
            .onDisappear(perform: saveText)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func actions(_ task: TaskItem) -> some View {
        HStack {
            switch task.status {
            case .inbox, .parked:
                Button(task.status == .parked ? "Devam et" : "Başla", systemImage: "play.fill") {
                    store.requestStart(task)
                }
                .buttonStyle(.borderedProminent)
                Button("Bitti", systemImage: "checkmark") { Task { await store.complete(task) } }
            case .active:
                Button("Park et", systemImage: "pause.fill") { store.requestPark(task) }
                    .buttonStyle(.borderedProminent)
                Button("Bitti", systemImage: "checkmark") { Task { await store.complete(task) } }
            case .done, .archived:
                Button("Yeniden aç", systemImage: "arrow.counterclockwise") {
                    Task { await store.reopen(task) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    private func stepsSection(_ task: TaskItem) -> some View {
        let steps = store.subtasks(of: task.id)
        let progress = store.progress(of: task.id)
        return Section {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    Button {
                        Task {
                            if step.status.isOpen {
                                await store.complete(step)
                            } else {
                                await store.reopen(step)
                            }
                        }
                    } label: {
                        Image(systemName: step.status.isOpen ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(step.status.isOpen ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.status.isOpen ? "\(step.title), bitti olarak işaretle" : "\(step.title), yeniden aç")
                    Text(step.title)
                        .strikethrough(!step.status.isOpen, color: .secondary)
                        .foregroundStyle(step.status.isOpen ? .primary : .secondary)
                    Spacer()
                    Button("Sil", systemImage: "trash") { Task { await store.delete(step) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .onMove { from, to in
                Task { await store.moveSubtasks(of: task.id, from: from, to: to) }
            }
            HStack {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                TextField("Adım ekle", text: $newStep)
                    .focused($focus, equals: .step)
                    .onSubmit(addStep)
            }
        } header: {
            HStack {
                Text("Adımlar")
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done)/\(progress.total)")
                        .monospacedDigit()
                }
            }
        } footer: {
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(Color.primary)
            } else {
                Text("İşi küçük adımlara böl; ilk açık adım Şimdi'de görünür.")
            }
        }
    }

    private func dateRow(_ label: String, task: TaskItem, key: WritableKeyPath<TaskItem, Date?>) -> some View {
        HStack {
            Toggle(label, isOn: Binding(
                get: { task[keyPath: key] != nil },
                set: { on in
                    Task {
                        if on, key == \TaskItem.remindAt { await Reminders.requestPermission() }
                        await store.edit(task) { $0[keyPath: key] = on ? Self.nextHour : nil }
                    }
                }
            ))
            if let date = task[keyPath: key] {
                DatePicker(label, selection: Binding(
                    get: { date },
                    set: { new in Task { await store.edit(task) { $0[keyPath: key] = new } } }
                ))
                .labelsHidden()
            }
        }
    }

    private func areaBinding(_ task: TaskItem) -> Binding<String?> {
        Binding(
            get: { task.areaId },
            set: { id in Task { await store.edit(task) { $0.areaId = id } } }
        )
    }

    // MARK: - Actions

    private func load() {
        guard let task else { return }
        title = task.title
        details = task.details ?? ""
        Task { await store.loadHistory(of: taskID) }
    }

    private func saveText() {
        guard let task else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              trimmedTitle != task.title || trimmedDetails != (task.details ?? "")
        else { return }
        Task {
            await store.edit(task) {
                $0.title = trimmedTitle
                $0.details = trimmedDetails.isEmpty ? nil : trimmedDetails
            }
        }
    }

    private func addStep() {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let task else { return }
        newStep = ""
        Task { await store.capture(text, areaId: task.areaId, parentId: task.id) }
    }

    private func addNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let task else { return }
        note = ""
        Task { await store.addNote(text, to: task) }
    }

    private static var nextHour: Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? .now
    }
}

private struct MacEventRow: View {
    let event: TaskEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title)
                    Spacer()
                    Text(event.occurredAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = event.note, !note.isEmpty {
                    if event.kind == "parked" {
                        MacParkNote(note: note, small: true)
                    } else {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                if let reason = event.reason {
                    Label(reason.title, systemImage: reason.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
