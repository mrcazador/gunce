import SwiftUI

/// One task: content, where you left off, subtasks, actions and the "İz" history.
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

    @State private var draft: Draft
    @State private var newSubtask = ""
    @State private var newNote = ""
    @State private var confirmDelete = false

    init(task: TaskItem) {
        self.task = task
        _draft = State(initialValue: Draft(task))
    }

    var body: some View {
        Form {
            Section {
                TextField("Başlık", text: $draft.title, axis: .vertical)
                    .font(.headline)
                TextField("Sıradaki adım", text: $draft.nextStep, axis: .vertical)
                TextField("Ayrıntılar", text: $draft.details, axis: .vertical)
                    .lineLimit(3...10)
            }

            Section {
                Picker("Alan", selection: $draft.areaId) {
                    Text("Alansız").tag(String?.none)
                    ForEach(store.sortedAreas) { area in
                        Label(area.name, systemImage: area.symbol).tag(Optional(area.id))
                    }
                }
                Toggle("Tarih", isOn: $draft.hasDue)
                if draft.hasDue {
                    DatePicker("Ne zaman", selection: $draft.dueAt)
                }
                Toggle("Hatırlat", isOn: $draft.hasRemind)
                if draft.hasRemind {
                    DatePicker("Hatırlatma", selection: $draft.remindAt)
                }
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
                Section("Alt görevler") {
                    ForEach(store.subtasks(of: task.id)) { sub in
                        SubtaskRow(task: sub)
                    }
                    TextField("Alt görev ekle", text: $newSubtask)
                        .submitLabel(.done)
                        .onSubmit {
                            let title = newSubtask
                            newSubtask = ""
                            Task { await store.capture(title, areaId: task.areaId, parentId: task.id) }
                        }
                }
            }

            Section {
                actions
            }

            Section("İz") {
                TextField("Not ekle", text: $newNote, axis: .vertical)
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
            if draft != Draft(task) {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet", action: save)
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            Text("Alt görevleri de silinir.")
        }
        .task(id: task.id) {
            draft = Draft(task)
            await store.loadHistory(of: task.id)
        }
        .onChange(of: task.updatedAt) {
            draft = Draft(task)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch task.status {
        case .inbox, .parked:
            if task.parentId == nil {
                Button(task.status == .parked ? "Devam et" : "Başla", systemImage: "play") {
                    store.requestStart(task)
                }
            }
            Button("Bitti", systemImage: "checkmark") {
                Task { await store.complete(task) }
            }
            Button("Arşivle", systemImage: "archivebox") {
                Task { await store.archive(task) }
            }
        case .active:
            Button("Park et", systemImage: "pause") {
                store.requestPark(task)
            }
            Button("Bitti", systemImage: "checkmark") {
                Task { await store.complete(task) }
            }
        case .done, .archived:
            Button("Yeniden aç", systemImage: "arrow.counterclockwise") {
                Task { await store.reopen(task) }
            }
        }
        Button("Sil", systemImage: "trash", role: .destructive) {
            confirmDelete = true
        }
    }

    private func save() {
        let original = Draft(task)
        let draft = draft
        var fields: [String: Any] = [:]
        if draft.title != original.title { fields["title"] = draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if draft.nextStep != original.nextStep { fields["next_step"] = JSONCoding.value(draft.nextStep) }
        if draft.details != original.details { fields["details"] = JSONCoding.value(draft.details) }
        if draft.areaId != original.areaId { fields["area_id"] = (draft.areaId as Any?) ?? NSNull() }
        if draft.hasDue != original.hasDue || (draft.hasDue && draft.dueAt != original.dueAt) {
            fields["due_at"] = JSONCoding.value(draft.hasDue ? draft.dueAt : Optional<Date>.none)
        }
        if draft.hasRemind != original.hasRemind || (draft.hasRemind && draft.remindAt != original.remindAt) {
            fields["remind_at"] = JSONCoding.value(draft.hasRemind ? draft.remindAt : Optional<Date>.none)
        }
        Task { await store.update(task, fields: fields) }
    }
}

/// Editable copy of a task's content fields.
private struct Draft: Equatable {
    var title = ""
    var nextStep = ""
    var details = ""
    var areaId: String? = nil
    var hasDue = false
    var dueAt = Date.now
    var hasRemind = false
    var remindAt = Date.now

    init() {}

    /// Dates only count while their toggle is on.
    static func == (a: Draft, b: Draft) -> Bool {
        a.title == b.title && a.nextStep == b.nextStep && a.details == b.details && a.areaId == b.areaId
            && a.hasDue == b.hasDue && (!a.hasDue || a.dueAt == b.dueAt)
            && a.hasRemind == b.hasRemind && (!a.hasRemind || a.remindAt == b.remindAt)
    }

    init(_ task: TaskItem) {
        title = task.title
        nextStep = task.nextStep ?? ""
        details = task.details ?? ""
        areaId = task.areaId
        hasDue = task.dueAt != nil
        dueAt = task.dueAt ?? Self.defaultDate
        hasRemind = task.remindAt != nil
        remindAt = task.remindAt ?? Self.defaultDate
    }

    /// Next full hour, so toggling a date on picks something sensible and stable.
    private static var defaultDate: Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? .now
    }
}

private struct SubtaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        Button {
            Task {
                if task.status == .done {
                    await store.reopen(task)
                } else {
                    await store.complete(task)
                }
            }
        } label: {
            Label {
                Text(task.title)
                    .strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
            } icon: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
            }
        }
        .accessibilityValue(task.status == .done ? "Bitti" : "Açık")
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
