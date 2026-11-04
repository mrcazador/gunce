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
                // Offline: changes are kept on the phone and sent when the connection is back.
                if store.isOffline || !store.outbox.isEmpty {
                    Label {
                        Text(store.outbox.isEmpty
                             ? "Çevrimdışı · bağlantı gelince eşitlenecek"
                             : "Çevrimdışı · \(store.outbox.count) değişiklik bağlantı gelince gönderilecek")
                    } icon: {
                        Image(systemName: "icloud.slash")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }

                Section {
                    if let task = store.activeTask {
                        ActiveTaskCard(task: task)
                    } else if let waiting = store.parkedTasks.max(by: { ($0.parkedAt ?? .distantPast) < ($1.parkedAt ?? .distantPast) }) {
                        // Nothing in hand: what you were just doing, and where you left it, comes
                        // first and big, so getting back in takes no remembering.
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Geçen sefer")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(waiting.title)
                                .font(.title3.weight(.semibold))
                            if let note = waiting.parkNote, !note.isEmpty {
                                Text(note)
                                    .font(.system(.title2, design: .serif).italic())
                                    .fontDesign(.serif)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("Kaldığın yer: \(note)")
                            }
                            ActionButton(title: "Devam et", symbol: "play.fill", prominent: true) {
                                store.requestStart(waiting)
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        ContentUnavailableView(
                            "Elinde iş yok",
                            systemImage: "cup.and.saucer",
                            description: Text("Aklına geleni aşağıdaki çubuğa yaz, sonra “Başla” ile ele al.")
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
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                TaskRow(task: task)
                                Spacer(minLength: 0)
                                Button("Başla") { store.requestStart(task) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .frame(minHeight: 44)
                                    .accessibilityHint("Bu görevi elindeki iş yapar")
                            }
                            // The whole row opens the task; the button stays tappable.
                            .background {
                                NavigationLink(value: task.id) { EmptyView() }
                                    .opacity(0)
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
        let chores = store.tasks.values
            .filter { $0.parentId == nil && $0.repeats != nil && $0.status != .archived && $0.deletedAt == nil }
            .filter { $0.isDueThisRound() || $0.isDoneThisRound() }
            .sorted { ($0.isDoneThisRound() ? 1 : 0, $0.title) < ($1.isDoneThisRound() ? 1 : 0, $1.title) }
        Section {
            // Daily work first: one tap closes today's round and plants something in the city.
            ForEach(chores) { task in
                ChoreRow(task: task)
            }
            if items.isEmpty && chores.isEmpty {
                Text("Bugün için planlanmış bir şey yok.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(items.filter { item in !chores.contains { $0.id == item.taskID } }.prefix(5)) { item in
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
                            Text("\(stalled.count) inşaat duruyor")
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
            if store.parkedTasks.count >= 2 {
                Button {
                    store.reviewRequested = true
                } label: {
                    Label("Toparla · \(store.parkedTasks.count)/\(AppStore.pausedLimit) yarım iş", systemImage: "tray.full")
                }
                .accessibilityHint("Yarım işlerini tek tek gözden geçirirsin: devam, yarına ya da bırak")
            }
            NavigationLink {
                TodayView(startsInWeek: true)
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
            Text(item.time == .distantPast ? "Geçti" : item.allDay ? "Tüm gün" : StartTime.clock(item.time))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            Text(item.title)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(item.source)
                .font(.caption)
                .foregroundStyle(item.time == .distantPast ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
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
            // Overdue work comes first, so it is not left behind in the week view.
            if let due = task.dueAt, due < start {
                items.append(Item(id: task.id, time: .distantPast, allDay: true, title: task.title, source: "Gecikmiş", taskID: task.id))
                continue
            }
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

/// A repeating task in Bugün: a circle to tick off today's round, the title, how often.
private struct ChoreRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        let done = task.isDoneThisRound()
        HStack(spacing: 12) {
            Button {
                if !done { Task { await store.complete(task) } }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.themeSage : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(done)
            .accessibilityLabel(done ? "\(task.title), bugün yapıldı" : "\(task.title), yapıldı olarak işaretle")
            NavigationLink(value: task.id) {
                HStack {
                    Text(task.title)
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                    Spacer(minLength: 0)
                    Label(task.repeats?.title ?? "", systemImage: "repeat")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 44)
    }
}

private struct ActiveTaskCard: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The task's building in Şehir, as it stands right now.
            if let building = store.city().buildings.first(where: { $0.id == task.id }) {
                CityBuildingShowcase(building: building, level: store.city().level)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180, alignment: .bottom)
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
            // Resumed from a break: where you left off comes first, big enough to read at a glance.
            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kaldığın yer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(.system(.title3, design: .serif).italic())
                                    .fontDesign(.serif)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Kaldığın yer: \(note)")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.themeBackground, in: RoundedRectangle(cornerRadius: 14))
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
                Label("Tüm adımlar bitti; işi bitirebilirsin", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // A new step can always be added here, not only the first one.
            FirstStepField(task: task, isFirst: progress.total == 0)

            ActionRow {
                ActionButton(title: "Ara ver", symbol: "pause.fill", prominent: true) {
                    store.requestPark(task)
                }
                ActionButton(title: "Bitti", symbol: "checkmark") {
                    Task { await store.complete(task) }
                }
            }
        }
        // Take the full height at large text sizes instead of squeezing rows together.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }
}

/// An empty card asks for the first step; it is added as the task's first subtask.
private struct FirstStepField: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    var isFirst = true
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(isFirst ? "İlk adımı yaz" : "Adım ekle", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
                .accessibilityLabel(isFirst ? "İlk adım" : "Yeni adım")
                .accessibilityHint("Yazdığın metin görevin sonuna yeni bir adım olarak eklenir")
            TaskVoiceButton(task: task)
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
            let idle = Calendar.current.dateComponents([.day], from: store.lastProgress(of: task), to: .now).day ?? 0
            if idle >= AppStore.stalledAfterDays {
                Label("\(idle) gündür adım yok", systemImage: "pause.circle")
                    .foregroundStyle(Color.orange)
            } else if let parked = task.parkedAt {
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
            BrickProgress(done: done, total: total, height: 12, label: "\(total) adımın \(done) tanesi bitti")
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
