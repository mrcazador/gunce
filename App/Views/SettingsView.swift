import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(ProfileKeys.name) private var name = ""
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingReminders = 0
    @State private var testsSent = 0

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        HStack(spacing: 14) {
                            Avatar(name: name, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name.isEmpty ? "Profilim" : name)
                                    .font(.headline)
                                Text("Hesap ve istatistikler")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    notificationRow
                    Toggle(isOn: calendarBinding) {
                        Label("Apple Takvim ile eşitle", systemImage: "calendar")
                    }
                    Toggle(isOn: $store.liveActivityEnabled) {
                        Label("Canlı Etkinlik", systemImage: "rectangle.inset.topright.filled")
                    }
                    NavigationLink {
                        ClaudeConnectView()
                    } label: {
                        Label("Claude ile bağla", systemImage: "sparkles")
                    }
                } header: {
                    Text("Bağlantılar")
                } footer: {
                    Text("Tarihli görevler telefonundaki PickUp takvimine yazılır; etkinliği orada taşırsan görevin tarihi de değişir. Canlı Etkinlik aktif görevi kilit ekranında ve Dynamic Island'da gösterir; widget'lar bundan bağımsız çalışır.")
                }

                Section("Alanlar") {
                    ForEach(store.sortedAreas) { area in
                        AreaLabel(area: area)
                    }
                }

                ConnectionTestSection()

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
            .task {
                notificationStatus = await Reminders.status()
                pendingReminders = await Reminders.pendingCount()
            }
            .sensoryFeedback(.success, trigger: testsSent)
        }
    }

    @ViewBuilder
    private var notificationRow: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            LabeledContent {
                Text(pendingReminders == 0 ? "Açık" : "Açık · \(pendingReminders) planlı")
            } label: {
                Label("Bildirimler", systemImage: "bell")
            }
            Button {
                Task {
                    await Reminders.sendTest()
                    testsSent += 1
                }
            } label: {
                Label(testsSent == 0 ? "Deneme bildirimi gönder" : "5 saniye içinde gelecek", systemImage: "bell.badge")
            }
            .accessibilityHint("Beş saniye sonra PickUp'tan bir bildirim gelir")
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                LabeledContent {
                    Text("Ayarlar'da aç")
                } label: {
                    Label("Bildirimler kapalı", systemImage: "bell.slash")
                }
            }
        default:
            Button {
                Task {
                    await Reminders.requestPermission()
                    notificationStatus = await Reminders.status()
                    store.tasksChanged()
                }
            } label: {
                Label("Bildirimlere izin ver", systemImage: "bell.badge")
            }
        }
    }

    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { store.calendarSyncEnabled },
            set: { on in
                if on {
                    Task {
                        let granted = await store.enableCalendarSync()
                        if !granted, CalendarSync.shared.isDenied,
                           let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                } else {
                    store.calendarSyncEnabled = false
                }
            }
        )
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

enum ProfileKeys {
    static let name = "pickup.profile.name"
    static let email = "pickup.profile.email"
}

/// Initials in a circle, or a person symbol when there is no name.
struct Avatar: View {
    let name: String
    let size: CGFloat

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0) }.joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.primary)
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.background)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.background)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Profilim": who is signed in, since when, a few numbers, and account actions.
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProfileKeys.name) private var name = ""
    @AppStorage(ProfileKeys.email) private var email = ""
    @State private var memberSince: Date?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Avatar(name: name, size: 80)
                    TextField("Adını ekle", text: $name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textContentType(.name)
                        .submitLabel(.done)
                    Text(email.isEmpty ? "Apple ile giriş yapıldı" : email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("Hesap") {
                LabeledContent("Giriş yöntemi", value: "Apple ile giriş")
                if let memberSince {
                    LabeledContent("Üyelik", value: memberSince.formatted(date: .long, time: .omitted))
                }
            }

            Section("Özet") {
                LabeledContent("Bu hafta biten", value: "\(doneThisWeek)")
                LabeledContent("Toplam biten", value: "\(doneTotal)")
                LabeledContent("Kaldığın yerler", value: "\(store.parkedTasks.count)")
                LabeledContent("Açık görev", value: "\(openTotal)")
            }

            Section {
                Button("Çıkış yap") {
                    Task { await store.signOut() }
                }
                Button("Hesabı sil", role: .destructive) {
                    confirmDelete = true
                }
            } footer: {
                Text("Adın yalnızca bu telefonda saklanır.")
            }
        }
        .navigationTitle("Profilim")
        .navigationBarTitleDisplayMode(.inline)
        .task { memberSince = await store.loadMemberSince() }
        .confirmationDialog("Hesabın silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Hesabı ve tüm verileri sil", role: .destructive) {
                Task { await store.deleteAccount() }
            }
        } message: {
            Text("Tüm görevlerin ve geçmişin kalıcı olarak silinir. Bu geri alınamaz.")
        }
    }

    private var topLevel: [TaskItem] {
        store.tasks.values.filter { $0.parentId == nil }
    }

    private var doneTotal: Int { topLevel.filter { $0.status == .done }.count }

    private var openTotal: Int { topLevel.filter { $0.status.isOpen }.count }

    private var doneThisWeek: Int {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return topLevel.filter { $0.status == .done && ($0.completedAt ?? .distantPast) >= start }.count
    }
}
