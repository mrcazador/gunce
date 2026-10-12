import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Alanlar") {
                    ForEach(store.sortedAreas) { area in
                        AreaLabel(area: area)
                    }
                }

                Section("Hesap") {
                    Button("Çıkış yap") {
                        Task {
                            await store.signOut()
                            dismiss()
                        }
                    }
                    Button("Hesabı sil", role: .destructive) {
                        confirmDelete = true
                    }
                }

                Section {
                    LabeledContent("Sürüm", value: version)
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
            .confirmationDialog("Hesabın silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Hesabı ve tüm verileri sil", role: .destructive) {
                    Task {
                        await store.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text("Tüm görevlerin ve geçmişin kalıcı olarak silinir. Bu geri alınamaz.")
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
