import SwiftUI

/// The floating "Aklına geleni yaz…" field above the tab bar. Captures land in the inbox.
struct CaptureBar: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Aklına geleni yaz…", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityLabel("Hızlı ekle")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: save) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Gelen kutusuna ekle")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }

    private func save() {
        let title = text
        text = ""
        focused = false
        Task { await store.capture(title) }
    }
}
