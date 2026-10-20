import SwiftUI

extension Area {
    /// Color means area only, always with the area's SF Symbol.
    var macTint: Color { AreaPalette.color(color) }
}

extension Font {
    /// The signature style for park notes (New York italic). Nothing else uses serif.
    static let macParkNote = Font.system(.body, design: .serif).italic()
    static let macParkNoteSmall = Font.system(.callout, design: .serif).italic()
}

/// Area name and symbol in the area's color.
struct MacAreaLabel: View {
    let area: Area

    var body: some View {
        Label(area.name, systemImage: area.symbol)
            .foregroundStyle(area.macTint)
            .accessibilityLabel("Alan: \(area.name)")
    }
}

struct MacParkNote: View {
    let note: String
    var small = false

    var body: some View {
        Text(note)
            .font(small ? .macParkNoteSmall : .macParkNote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Kaldığın yer: \(note)")
    }
}

/// One task in a list: status, title, area, date and where you left off.
struct MacTaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    private var statusSymbol: String {
        switch task.status {
        case .active: "play.circle.fill"
        case .parked: "pause.circle"
        case .done: "checkmark.circle.fill"
        case .archived: "archivebox"
        case .inbox: "circle"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(task.status == .active ? .primary : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .lineLimit(2)
                    .strikethrough(task.status == .done, color: .secondary)
                HStack(spacing: 8) {
                    if let area = store.area(task.areaId) {
                        MacAreaLabel(area: area)
                    }
                    let steps = store.progress(of: task.id)
                    if steps.total > 0 {
                        Label("\(steps.done)/\(steps.total)", systemImage: "checklist")
                            .accessibilityLabel("\(steps.total) adımdan \(steps.done) tanesi bitti")
                    }
                    if let due = task.dueAt, task.status.isOpen {
                        Label(due.formatted(.relative(presentation: .named)), systemImage: "calendar")
                            .foregroundStyle(due < .now ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if task.status == .parked, let note = task.parkNote, !note.isEmpty {
                    MacParkNote(note: note, small: true)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "Nerede kaldın?": the note, a reason and an optional reminder. Used in the menu bar
/// panel and in the main window's sheet.
struct MacParkForm: View {
    let taskTitle: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: (_ note: String?, _ reason: ParkReason, _ remindAt: Date?) -> Void

    @State private var note = ""
    @State private var reason: ParkReason = .later
    @State private var remind: Reminders.Preset = .none
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nerede kaldın?")
                    .font(.headline)
                Text(taskTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField("Bir cümleyle not al", text: $note, axis: .vertical)
                .font(.macParkNote)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
                .onSubmit(confirm)
            Picker("Neden", selection: $reason) {
                ForEach(ParkReason.allCases) { reason in
                    Label(reason.title, systemImage: reason.symbol).tag(reason)
                }
            }
            Picker("Hatırlat", selection: $remind) {
                ForEach(Reminders.Preset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { noteFocused = true }
    }

    private func confirm() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(trimmed.isEmpty ? nil : trimmed, reason, remind.date())
    }
}

extension AppStore {
    /// Park or switch from the Mac UI: asks for notification permission when a reminder is set.
    func macPark(_ request: ParkRequest, note: String?, reason: ParkReason, remindAt: Date?) async {
        if remindAt != nil { await Reminders.requestPermission() }
        if let next = request.next {
            await start(next, previousNote: note, previousReason: reason)
            if let remindAt, let parked = tasks[request.task.id] {
                await edit(parked) { $0.remindAt = remindAt }
            }
        } else {
            await park(request.task, note: note, reason: reason, remindAt: remindAt)
        }
    }
}

/// Quick capture: Enter adds to the inbox and keeps the field ready for the next one.
struct MacCaptureField: View {
    @Environment(AppStore.self) private var store
    var prompt = "Aklına geleni yaz…"
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(add)
                .accessibilityLabel("Yeni görev")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func add() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        text = ""
        Task { await store.capture(title) }
    }
}
