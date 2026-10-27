import SwiftUI

/// The menu bar popover: the whole day's loop without opening the phone or the main window.
/// The active task with its next step, Park et / Bitti, the parked tasks with Devam et, and
/// quick capture.
struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    /// A park or a switch waiting for its "nerede kaldın?" note, shown inline.
    @State private var pending: ParkRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.isSignedIn {
                signedOut
            } else if let pending {
                MacParkForm(
                    taskTitle: pending.task.title,
                    confirmTitle: pending.next == nil ? "Park et" : "Park et ve geç"
                ) {
                    withAnimation(.snappy) { self.pending = nil }
                } onConfirm: { note, reason, remindAt in
                    let request = pending
                    withAnimation(.snappy) { self.pending = nil }
                    Task { await store.macPark(request, note: note, reason: reason, remindAt: remindAt) }
                }
            } else {
                activeSection
                parkedSection
                MacCaptureField()
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Sections

    @ViewBuilder
    private var activeSection: some View {
        if let task = store.activeTask {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    if let area = store.area(task.areaId) {
                        MacAreaLabel(area: area)
                            .font(.subheadline)
                    } else {
                        Label("Şimdi", systemImage: "bookmark.fill")
                            .font(.subheadline)
                    }
                    Spacer()
                    if let started = task.startedAt {
                        Text(StartTime.sentence(started))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(StartTime.spoken(started))
                    }
                }
                Text(task.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = task.parkNote, !note.isEmpty {
                    MacParkNote(note: note, small: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let step = store.nextStep(of: task.id) {
                    let progress = store.progress(of: task.id)
                    Button {
                        Task { await store.complete(step) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                            Text(step.title)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Text("\(progress.done)/\(progress.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Adımı bitir")
                    .accessibilityLabel("Sıradaki adım: \(step.title). Bitti olarak işaretle")
                }
                HStack {
                    Button {
                        withAnimation(.snappy) { pending = ParkRequest(task: task, next: nil) }
                    } label: {
                        Label("Park et", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await store.complete(task) }
                    } label: {
                        Label("Bitti", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Aktif görev yok", systemImage: "bookmark")
                    .font(.headline)
                Text(store.parkedTasks.isEmpty
                     ? "Aklına geleni yaz ya da gelen kutusundan bir görev başlat."
                     : "Kaldığın yerden devam etmek için bir görev seç.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var parkedSection: some View {
        let parked = Array(store.parkedTasks.prefix(5))
        if !parked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kaldığın yerler")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(parked) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: store.area(task.areaId)?.symbol ?? "pause.circle")
                            .foregroundStyle(store.area(task.areaId)?.macTint ?? Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .lineLimit(1)
                            if let note = task.parkNote, !note.isEmpty {
                                MacParkNote(note: note, small: true)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Devam et") { resume(task) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PickUp", systemImage: "bookmark.fill")
                .font(.headline)
            Text("Giriş yapmak için PickUp penceresini aç.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("PickUp'ı aç") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .keyboardShortcut("o")
            Spacer()
            if store.isOffline {
                Label("Çevrimdışı", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .help("Sunucuya ulaşılamadı; bağlantı gelince kendiliğinden eşitlenir.")
            }
            if store.isSyncing {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Çık") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: - Actions

    /// Resuming while another task is active asks where you left off on that one first.
    private func resume(_ task: TaskItem) {
        if let current = store.activeTask, current.id != task.id {
            withAnimation(.snappy) { pending = ParkRequest(task: current, next: task) }
        } else {
            Task { await store.start(task, previousNote: nil, previousReason: nil) }
        }
    }
}

/// The menu bar icon: filled while a task is active, with its title shortened.
struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        if let task = store.activeTask {
            Label(Self.short(task.title), systemImage: "bookmark.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "bookmark")
                .accessibilityLabel("PickUp")
        }
    }

    private static func short(_ title: String) -> String {
        title.count > 22 ? String(title.prefix(21)) + "…" : title
    }
}
