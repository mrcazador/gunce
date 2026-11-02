import SwiftUI

/// Asks "nerede kaldın?" before parking a task, or before switching to another one.
struct ParkSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ParkRequest

    @State private var note = ""
    @State private var reason: ParkReason = .later
    @State private var remind: Reminders.Preset = .none
    @FocusState private var noteFocused: Bool

    @State private var showMore = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // One line, one tap: Return takes the break. Everything else is optional.
                    TextField("Bir cümleyle: nerede kaldın?", text: $note)
                        .font(.parkNote)
                        .fontDesign(.serif)
                        .focused($noteFocused)
                        .submitLabel(.done)
                        .onSubmit(confirm)
                } header: {
                    Text(request.task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let fallback = autoNote {
                            Text("Boş bırakırsan “\(fallback)” yazılır.")
                        }
                        if let next = request.next {
                            Text("Sonra “\(next.title)” başlayacak.")
                        }
                    }
                }

                Section {
                    DisclosureGroup("Neden ve hatırlatma", isExpanded: $showMore) {
                        Picker("Neden", selection: $reason) {
                            ForEach(ParkReason.allCases) { reason in
                                Label(reason.title, systemImage: reason.symbol).tag(reason)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Picker("Hatırlat", selection: $remind) {
                            ForEach(Reminders.Preset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        if let date = remind.date() {
                            Text("Bildirim: \(date.formatted(.dateTime.weekday(.wide).hour().minute()))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .themedBackground()
            .navigationTitle("Nerede kaldın?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.next == nil ? "Ara ver" : "Ara ver ve geç", action: confirm)
                        .buttonStyle(.glassProminent)
                }
            }
            .onAppear {
                // Start from where you left off last time; edit it or write over it.
                if note.isEmpty { note = request.task.parkNote ?? "" }
                noteFocused = true
            }
            .onChange(of: reason) { _, newValue in
                remind = Self.suggestedReminder(for: newValue)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Written for you when the note is left empty: the step you would pick up next.
    private var autoNote: String? {
        if let step = store.nextStep(of: request.task.id) { return "Sıradaki adım: \(step.title)" }
        if let next = request.task.nextStep, !next.isEmpty { return "Sıradaki adım: \(next)" }
        return nil
    }

    /// Waiting on someone or missing information: come back tomorrow morning by default, so
    /// postponed work gets a nudge without an extra tap. "Sonra devam" stays quiet.
    static func suggestedReminder(for reason: ParkReason) -> Reminders.Preset {
        switch reason {
        case .waiting, .needInfo: .tomorrowMorning
        case .later: .none
        }
    }

    private func confirm() {
        let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = typed.isEmpty ? (autoNote ?? "") : typed
        let reason = reason
        let request = request
        let remindAt = remind.date()
        dismiss()
        Task {
            if remindAt != nil { await Reminders.requestPermission() }
            if let next = request.next {
                await store.start(next, previousNote: note, previousReason: reason)
                if let remindAt, let parked = store.tasks[request.task.id] {
                    await store.edit(parked) { $0.remindAt = remindAt }
                }
            } else {
                await store.park(request.task, note: note, reason: reason, remindAt: remindAt)
            }
        }
    }
}
