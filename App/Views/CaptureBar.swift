import SwiftUI

/// The floating "Aklına geleni yaz…" bar above the tab bar. Tapping it opens the capture
/// sheet, which sits above the keyboard so you always see what you type.
struct CaptureBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.captureRequest = CaptureRequest()
        } label: {
            HStack(spacing: 10) {
                Text("Aklına geleni yaz…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Yeni görev ekle")
    }
}

/// Quick capture: a title, an optional area and date. Return adds and keeps the sheet open
/// for the next thought; "Bitti" closes it.
struct CaptureSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: CaptureRequest

    @State private var title = ""
    @State private var areaId: String?
    @State private var hasDate = false
    @State private var dueAt = Date.now
    @State private var added = 0
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Aklına geleni yaz…", text: $title, axis: .vertical)
                        .font(.title3)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(add)
                } footer: {
                    if added > 0 {
                        Label("\(added) görev gelen kutusuna eklendi", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.sortedAreas) { area in
                                AreaChip(area: area, selected: areaId == area.id) {
                                    areaId = areaId == area.id ? nil : area.id
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Toggle("Tarih", isOn: $hasDate.animation())
                    if hasDate {
                        DatePicker("Ne zaman", selection: $dueAt)
                    }
                }
            }
            .navigationTitle("Yeni görev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(added > 0 ? "Bitti" : "Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ekle", action: add)
                        .buttonStyle(.glassProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let preset = request.dueAt {
                    hasDate = true
                    dueAt = preset
                }
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func add() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let area = areaId
        let due = hasDate ? dueAt : nil
        title = ""
        withAnimation { added += 1 }
        focused = true
        Task { await store.capture(text, areaId: area, dueAt: due) }
    }
}

/// A selectable area pill: symbol and name in the area's color.
struct AreaChip: View {
    let area: Area
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(area.name, systemImage: area.symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? Color.white : area.tint)
                .background(selected ? area.tint : area.tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
