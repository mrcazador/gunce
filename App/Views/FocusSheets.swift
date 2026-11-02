import SwiftUI

/// Shown when the paused-work limit is reached. A new break waits until one paused task is
/// finished or let go; then the break (or switch) goes ahead by itself.
struct LimitSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: LimitRequest

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.parkedTasks) { task in
                        PausedChoiceRow(task: task, primary: .finish)
                    }
                } header: {
                    Text("\(AppStore.pausedLimit) yarım işin var")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                } footer: {
                    Text("Yeni bir işe ara vermeden önce birini bitir ya da bırak. Bıraktığın iş Görevler'de arşivde kalır.")
                }
            }
            .themedBackground()
            .navigationTitle("Önce birini kapat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
            }
            // A slot is free: carry on with what was asked for.
            .onChange(of: store.parkedTasks.count) { _, count in
                if count < AppStore.pausedLimit {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        store.continueAfterLimit(request)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The daily two-minute tidy-up: paused tasks one by one, longest waiting first, each with
/// three honest choices. Nothing is decided for you; skipping is fine.
struct ReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Tasks handled in this session, so the queue moves on.
    @State private var handled: Set<String> = []

    private var queue: [TaskItem] {
        store.parkedTasks.filter { !handled.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let task = queue.first {
                    Text("\(queue.count) yarım iş")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    card(task)
                        .id(task.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                          removal: .move(edge: .leading).combined(with: .opacity)))
                    VStack(spacing: 10) {
                        ActionButton(title: "Devam et", symbol: "play.fill", prominent: true) {
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                store.requestStart(task)
                            }
                        }
                        ActionRow {
                            ActionButton(title: "Yarına", symbol: "sunrise") {
                                next(task) { await store.edit(task) { $0.remindAt = Self.tomorrowMorning } }
                            }
                            ActionButton(title: "Bırak", symbol: "xmark") {
                                next(task) { await store.letGo(task) }
                            }
                        }
                    }
                } else {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.themeSage)
                        .accessibilityHidden(true)
                    Text("Toparlandı")
                        .font(.title2.weight(.bold))
                    Text("Bugün için yarım işlerin net.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ActionButton(title: "Kapat", symbol: "checkmark", prominent: true) { dismiss() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBackground)
            .navigationTitle("Toparla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }

    private func card(_ task: TaskItem) -> some View {
        let idle = Calendar.current.dateComponents([.day], from: store.lastProgress(of: task), to: .now).day ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            if let area = store.area(task.areaId) {
                AreaLabel(area: area)
                    .font(.subheadline)
            }
            Text(task.title)
                .font(.title2.weight(.semibold))
            if let note = task.parkNote, !note.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kaldığın yer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.system(.title3, design: .serif).italic())
                        .foregroundStyle(.secondary)
                }
            }
            Text(idle == 0 ? "Bugün ara verdin" : "\(idle) gündür bekliyor")
                .font(.footnote)
                .foregroundStyle(idle >= AppStore.stalledAfterDays ? Color.orange : Color.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private func next(_ task: TaskItem, _ action: @escaping () async -> Void) {
        withAnimation(reduceMotion ? nil : .snappy) { _ = handled.insert(task.id) }
        Task { await action() }
    }

    private static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// A paused task with the two ways to close it: finish it or let it go.
private struct PausedChoiceRow: View {
    @Environment(AppStore.self) private var store
    enum Primary { case finish }
    let task: TaskItem
    let primary: Primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.headline)
            if let note = task.parkNote, !note.isEmpty {
                ParkNoteText(note: note)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Button("Bitti", systemImage: "checkmark") {
                    Task { await store.complete(task) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                Button("Bırak", systemImage: "xmark") {
                    Task { await store.letGo(task) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.secondary)
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }
}
