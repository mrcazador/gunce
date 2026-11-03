import SwiftUI

extension Area {
    /// Color means area only, always with the area's SF Symbol.
    var macTint: Color { AreaPalette.color(color) }
}

extension Font {
    /// The signature style for park notes (New York italic), smaller. Nothing else uses serif.
    static let parkNoteSmall = Font.system(.callout, design: .serif).italic()
}

/// A chunky themed button: brick for the one main action, sand for the rest.
struct MacChunkyButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var fill = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: 34)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChunkyButtonStyle(prominent: prominent))
    }
}

/// The task's building in Şehir, as it stands today.
struct MacBuildingImage: View {
    @Environment(AppStore.self) private var store
    let taskID: String
    var height: CGFloat = 120

    var body: some View {
        if let building = store.city().buildings.first(where: { $0.id == taskID }) {
            Image(building.imageName)
                .resizable()
                .scaledToFit()
                .saturation(building.stage == .stalled ? 0.7 : 1)
                .opacity(building.stage == .planned ? 0.55 : 1)
                .frame(height: height)
                .accessibilityLabel(CityText.accessibility(building))
        }
    }
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
            .font(small ? .parkNoteSmall : .parkNote)
            // The app uses rounded type; park notes keep their serif signature.
            .fontDesign(.serif)
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

    private var statusColor: Color {
        switch task.status {
        case .active: .themeBrick
        case .done: .themeSage
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
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

/// "Ara ver": one line on where you left off. Reason and reminder wait under a closed
/// "Neden ve hatırlatma"; an empty note becomes the next step. Used in the menu bar panel
/// and in the main window's sheet.
struct MacParkForm: View {
    let taskTitle: String
    let confirmTitle: String
    /// Written for you when the note is left empty, e.g. "Sıradaki adım: …".
    var autoNote: String? = nil
    let onCancel: () -> Void
    let onConfirm: (_ note: String?, _ reason: ParkReason, _ remindAt: Date?) -> Void

    @State private var note = ""
    @State private var reason: ParkReason = .later
    @State private var remind: Reminders.Preset = .none
    @State private var showMore = false
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
            TextField(autoNote ?? "Tek cümle yeter", text: $note, axis: .vertical)
                .font(.parkNote)
                .fontDesign(.serif)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 12))
                .focused($noteFocused)
                .onSubmit(confirm)
            DisclosureGroup("Neden ve hatırlatma", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 8) {
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
                }
                .padding(.top, 6)
            }
            .font(.subheadline)
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ChunkyButtonStyle(prominent: false))
                MacChunkyButton(title: confirmTitle, symbol: "pause.fill", prominent: true, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { noteFocused = true }
    }

    private func confirm() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(trimmed.isEmpty ? autoNote : trimmed, reason, remind.date())
    }
}

/// The paused-work limit is reached: finish or let go one paused task, then what was asked
/// for goes ahead by itself.
struct MacLimitView: View {
    @Environment(AppStore.self) private var store
    let onCancel: () -> Void
    /// Called once a slot is free.
    let onFreed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(AppStore.pausedLimit) yarım işin var")
                    .font(.headline)
                Text("Yeni bir işe ara vermeden önce birini bitir ya da bırak. Bıraktığın iş arşivde kalır.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.parkedTasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .lineLimit(1)
                        if let note = task.parkNote, !note.isEmpty {
                            MacParkNote(note: note, small: true)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Button("Bitti") { Task { await store.complete(task) } }
                        .buttonStyle(ChunkyButtonStyle(prominent: false))
                    Button("Bırak") { Task { await store.letGo(task) } }
                        .buttonStyle(ChunkyButtonStyle(prominent: false))
                }
                .padding(10)
                .background(Color.themeCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onChange(of: store.parkedTasks.count) { _, count in
            if count < AppStore.pausedLimit { onFreed() }
        }
    }
}

extension AppStore {
    /// The note written for you when "Nerede kaldın?" is left empty: the next step.
    func autoParkNote(for task: TaskItem) -> String? {
        if let step = nextStep(of: task.id) { return "Sıradaki adım: \(step.title)" }
        if let next = task.nextStep, !next.isEmpty { return "Sıradaki adım: \(next)" }
        return nil
    }

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
        .padding(10)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 12))
    }

    private func add() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        text = ""
        Task { await store.capture(title) }
    }
}
