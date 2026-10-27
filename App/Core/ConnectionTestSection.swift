import SwiftUI

/// Settings → Bağlantı testi: times the app's own requests so a "Sunucuya ulaşılamadı"
/// report can say which request stalls and over which HTTP version.
struct ConnectionTestSection: View {
    @Environment(AppStore.self) private var store
    @State private var results: [ConnectionCheck] = []
    @State private var isRunning = false

    var body: some View {
        Section {
            Button {
                Task {
                    isRunning = true
                    results = []
                    results = await store.checkConnection()
                    isRunning = false
                }
            } label: {
                HStack {
                    Label("Bağlantıyı test et", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if isRunning { ProgressView() }
                }
            }
            .disabled(isRunning)
            ForEach(results) { check in
                LabeledContent {
                    Text(check.detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(check.ok ? Color.secondary : Color.red)
                } label: {
                    Label(check.name, systemImage: check.ok ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(check.ok ? Color.primary : Color.red)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Bağlantı")
        } footer: {
            if !results.isEmpty {
                Text("Bir satır kırmızıysa bu ekranın görüntüsünü gönder.")
            }
        }
    }
}
