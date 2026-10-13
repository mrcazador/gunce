import SwiftUI

/// Asks "nerede kaldın?" before parking a task, or before switching to another one.
struct ParkSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ParkRequest

    @State private var note = ""
    @State private var reason: ParkReason = .later
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bir cümleyle: nerede kaldın?", text: $note, axis: .vertical)
                        .font(.parkNote)
                        .lineLimit(2...5)
                        .focused($noteFocused)
                } header: {
                    Text(request.task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                } footer: {
                    if let next = request.next {
                        Text("Sonra “\(next.title)” başlayacak.")
                    }
                }

                Section("Neden ara veriyorsun?") {
                    Picker("Neden", selection: $reason) {
                        ForEach(ParkReason.allCases) { reason in
                            Label(reason.title, systemImage: reason.symbol).tag(reason)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Nerede kaldın?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.next == nil ? "Park et" : "Park et ve geç", action: confirm)
                        .buttonStyle(.glassProminent)
                }
            }
            .onAppear { noteFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirm() {
        let note = note
        let reason = reason
        let request = request
        dismiss()
        Task {
            if let next = request.next {
                await store.start(next, previousNote: note, previousReason: reason)
            } else {
                await store.park(request.task, note: note, reason: reason)
            }
        }
    }
}
