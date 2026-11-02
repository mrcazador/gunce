import EventKit
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

                TodaySection()

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
            .themedBackground()
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

/// Today at a glance under the active task: what is due or reminding today and the day's
/// calendar events, the oldest stalled site, and the full day and week one tap away.
private struct TodaySection: View {
    @Environment(AppStore.self) private var store
    @State private var events: [EKEvent] = []

    private struct Item: Identifiable {
        let id: String
        let time: Date
        let allDay: Bool
        let title: String
        let source: String
        let taskID: String?
    }

    var body: some View {
        let items = todayItems
        let stalled = store.city().stalled
        Section {
            if items.isEmpty {
                Text("Bugün için planlanmış bir şey yok.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(4)) { item in
                if let id = item.taskID {
                    NavigationLink(value: id) { row(item) }
                } else {
                    row(item)
                }
            }
            if let oldest = stalled.first {
                NavigationLink(value: oldest.id) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(stalled.count) açık inşaat duruyor")
                            Text("En eskisi: \(oldest.title), \(oldest.idleDays) gün")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pause.circle")
                    }
                    .font(.subheadline)
                }
            }
            NavigationLink {
                TodayView()
            } label: {
                Label("Haftayı gör", systemImage: "calendar")
            }
        } header: {
            Text("Bugün")
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in load() }
        .onChange(of: store.calendarSyncEnabled) { load() }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Text(item.allDay ? "Tüm gün" : StartTime.clock(item.time))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            Text(item.title)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(item.source)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func load() {
        guard !store.isDemo, store.calendarSyncEnabled else {
            events = []
            return
        }
        events = CalendarSync.shared.events(on: Calendar.current.startOfDay(for: .now))
    }

    /// Open tasks due or reminding today, then calendar events, in time order.
    private var todayItems: [Item] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        var items: [Item] = []
        for task in store.tasks.values where task.status.isOpen && task.deletedAt == nil {
            let times = [task.dueAt, task.remindAt].compactMap { $0 }.filter { calendar.isDateInToday($0) }
            if let first = times.min() {
                items.append(Item(id: task.id, time: first, allDay: false, title: task.title, source: "Görev", taskID: task.id))
            }
        }
        for event in events where event.startDate < end && event.endDate > start {
            let allDay = event.isAllDay || event.startDate < start
            items.append(Item(
                id: "event-\(event.eventIdentifier ?? UUID().uuidString)",
                time: allDay ? start : (event.startDate ?? start),
                allDay: allDay,
                title: event.title ?? "Etkinlik",
                source: "Takvim",
                taskID: nil
            ))
        }
        return items.sorted { $0.time < $1.time }
    }
}

private struct ActiveTaskCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    /// Each time Şimdi opens, the building stretches up and settles, as if work just resumed.
    @State private var beat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The task's building in Şehir, as it stands right now.
            if let building = store.city().buildings.first(where: { $0.id == task.id }) {
                CityBuildingImage(building: building, tileWidth: 96)
                    .modifier(CityDance(move: 2, beat: beat))
                    .frame(maxWidth: .infinity)
                    .frame(height: 180, alignment: .bottom)
                    .accessibilityLabel(CityText.accessibility(building))
            }
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
                        .fixedSize(horizontal: false, vertical: true)
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
                Label("Tüm katlar çıktı; teslim edebilirsin", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if note.isEmpty {
                FirstStepField(task: task)
            }

            ActionRow {
                ActionButton(title: "İnşaatı durdur", symbol: "pause.fill", prominent: true) {
                    store.requestPark(task)
                }
                ActionButton(title: "Teslim et", symbol: "checkmark") {
                    Task { await store.complete(task) }
                }
            }
        }
        // Take the full height at large text sizes instead of squeezing rows together.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if !reduceMotion { beat += 1 }
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
        Button("Şantiyeye dön") {
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
            Button("Şantiyeye dön", systemImage: "play") {
                store.requestStart(task)
            }
            .tint(Color.primary)
        }
        .contextMenu {
            Button("Şantiyeye dön", systemImage: "play") { store.requestStart(task) }
            Button("Teslim et", systemImage: "checkmark") {
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
                .tint(Color.themeSage)
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
