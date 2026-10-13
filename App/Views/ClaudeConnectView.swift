import SwiftUI
import UIKit

/// Links Claude to PickUp: Claude adds the server as a custom connector, and the person
/// types a short code from here on the page Claude opens.
struct ClaudeConnectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var link: ClaudeLinkCode?
    @State private var connections: [ClaudeConnection] = []
    @State private var isCreating = false
    @State private var confirmDisconnect = false
    @State private var copies = 0

    var body: some View {
        Form {
            Section {
                Text("Claude görevlerini okuyabilir, yeni görev ekleyebilir, başlatıp park edebilir ve bitirebilir. Claude'un eklediği görevler gelen kutuna düşer.")
                    .foregroundStyle(.secondary)
            }

            if !connections.isEmpty {
                Section("Bağlı") {
                    ForEach(connections, id: \.self) { connection in
                        LabeledContent {
                            Text(connection.lastUsedAt, style: .relative)
                        } label: {
                            Label(connection.label ?? "Claude", systemImage: "checkmark.circle.fill")
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button("Bağlantıyı kaldır", systemImage: "link.badge.minus", role: .destructive) {
                        confirmDisconnect = true
                    }
                }
            }

            Section {
                step(1, "Claude'da Ayarlar → Bağlayıcılar → Özel bağlayıcı ekle'ye git.")
                VStack(alignment: .leading, spacing: 8) {
                    step(2, "Sunucu adresi olarak bunu yapıştır:")
                    HStack {
                        Text(store.claudeServerURL)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Kopyala", systemImage: "doc.on.doc") {
                            copy(store.claudeServerURL)
                        }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Sunucu adresini kopyala")
                    }
                }
                step(3, "Bağlan'a dokun ve açılan sayfaya aşağıdaki kodu yaz.")
            } header: {
                Text("Nasıl bağlanır?")
            }

            Section {
                if let link, link.expiresAt > .now {
                    VStack(spacing: 8) {
                        Text(link.code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityLabel("Kod: \(link.code.map { String($0) }.joined(separator: " "))")
                        Text("Kalan süre \(link.expiresAt, style: .timer)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    Button("Kodu kopyala", systemImage: "doc.on.doc") { copy(link.code) }
                } else {
                    ActionButton(title: "Bağlantı kodu oluştur", symbol: "key", prominent: true) {
                        Task { await createCode() }
                    }
                    .disabled(isCreating)
                }
            } footer: {
                Text("Kod 10 dakika geçerlidir ve bir kez kullanılır.")
            }
        }
        .navigationTitle("Claude ile bağla")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: copies)
        .confirmationDialog("Claude bağlantısı kaldırılsın mı?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Bağlantıyı kaldır", role: .destructive) {
                Task {
                    await store.disconnectClaude()
                    connections = await store.claudeConnections()
                }
            }
        } message: {
            Text("Claude görevlerine artık erişemez. İstediğin zaman yeniden bağlayabilirsin.")
        }
        .task { connections = await store.claudeConnections() }
        // Coming back from Claude: show the new connection.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { connections = await store.claudeConnections() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }

    private func createCode() async {
        isCreating = true
        defer { isCreating = false }
        if let code = await store.createClaudeLinkCode() {
            withAnimation(.snappy) { link = code }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copies += 1
    }
}
